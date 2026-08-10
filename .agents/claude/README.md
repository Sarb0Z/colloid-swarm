# Agent Hooks

Programmatic reinforcement for `AGENTS.md` (the canonical instruction file;
`CLAUDE.md` and `.github/copilot-instructions.md` are symlinks to it). The
md owns philosophy and judgment calls; hooks own deterministic rules where
a mechanical check beats prose.

## Architecture

Two layers, strict separation:

```
.agents/hooks/policy/   engine-agnostic policy (the actual checks)
.agents/playbooks/      the procedures agents follow (hostile review, reports)
.claude/hooks/          Claude Code adapter (stdin normalization)
.kimi/hooks/            Kimi CLI adapter (stdin normalization)
```

Policy scripts take a small, fixed JSON contract on stdin and signal
blocks via `exit 2` + stderr — the protocol both Claude Code and Kimi
CLI accept natively. Adapters are thin: they translate the engine's
hook payload into the policy contract and `exec` the policy. No policy
logic lives in `.claude/` or `.kimi/`; no engine-specific field names
live in `.agents/hooks/policy/`.

### Contract per policy

| Policy | Stdin JSON |
|--------|------------|
| `guard-destructive.sh` | `{"command": "..."}` |
| `sources-capture.sh` | `{"project_dir": "...", "agent": "...", "kind": "...", "value": "..."}` |
| `research-prime.sh` | `{"project_dir": "...", "prompt": "..."}` |
| `post-edit-check.sh` | `{"project_dir": "...", "files": ["..."]}` |
| `grader-lock.sh` | `{"project_dir": "...", "files": ["..."]}` |
| `session-wrap.sh` | `{"project_dir": "...", "stop_hook_active": bool, "transcript_path": "...", "session_id": "..."}` |
| `stop-investigate.sh` | `{"project_dir": "...", "transcript_path": "...", "stop_hook_active": bool}` |
| `session-start.sh` | `{"project_dir": "...", "source": "...", "session_id": "...", "transcript_path": "..."}` |
| `pre-compact.sh` | `{"project_dir": "...", "trigger": "auto"\|"manual"}` |
<!-- colloid-only -->

`genome-inject.sh` takes `{"subagent_type": "..."}`.
<!-- /colloid-only -->

All policies: `exit 0` = allow, `exit 2` + stderr = block with reason.
Exception: `session-start.sh` is a *context* policy, not a gate — it always
exits 0 and emits a JSON `hookSpecificOutput.additionalContext` object, which
Claude adds to the session.

### Agent scoping (Claude adapter)

Subagents inherit the project's hooks. Claude tags every hook payload fired
inside a spawned subagent with `agent_id` *and* `agent_type`. It tags a main
session launched as `claude --agent <name>` with `agent_type` alone, and a plain
main session with neither. Only `agent_id` separates a spawned subagent from the
main agent, so the adapter keys on that field. The adapter turns it into an
optional selector that gates whether the policy runs for a given invocation:

```
.claude/hooks/adapter.sh [--agent <selector>] <policy.sh>
```

| Selector | Policy runs for |
|----------|-----------------|
| *(absent)* | every agent — main and subagents alike |
| `main` | the main agent only, `--agent` launch included (no `agent_id`) |
| `subagent` | any spawned subagent (has `agent_id`) |
| a type name | spawned subagents of that type only |

For several types, pass them joined by a literal `|` (e.g. `--agent
Explore|Plan`). `main` and `subagent` are reserved selector words, so a
subagent whose type is literally `main`/`subagent` can't be targeted by
name — Claude's built-in types aren't. A non-matching invocation exits 0
(no-op) before the policy runs; a gate that can't read the payload falls
through to running it, so a broken gate never silently disables a policy.
The gate lives in the adapter because `agent_type` is Claude-specific —
policies stay engine-agnostic and never see it.

`--agent` is Claude-adapter syntax only: the Kimi adapter doesn't parse it
(Kimi's payload has no agent type), so don't copy an `--agent` line into
`.kimi/config.toml`.

## Active policies

### `guard-destructive.sh` — PreToolUse (`Bash|PowerShell|Monitor`)
The matcher names all three shell-running tools. A hook matcher matches the tool
name, so `Bash` alone leaves `PowerShell` and `Monitor` unguarded even though
both carry their command in `tool_input.command`. Monitor's WebSocket form
carries no command, and the policy exits 0 on an empty one.

A matcher drawn only from `[A-Za-z0-9_,| -]` is compared as a list of exact tool
names rather than a regular expression, so this one does not match `BashOutput`.
Any character outside that class makes the whole value an unanchored regex,
which would. The class is recorded with its source in
`.agents/knowledge/research/2026-08-07-frontier-context-management-and-agent-scaffolding.md`
— read it there rather than trusting a paraphrase, because the two readings
disagree about `settings.json`'s `mcp__*` matcher.

Blocks irreversible shell commands: `rm -rf` on broad paths, `git push
--force`, `git reset --hard`, `--no-verify`, SSH-into-prod mutations
(`systemctl restart|stop|reload`, `postsuper`, `postqueue -f`, package
installs, `sed -i`, piping into `/etc/`), and destructive SQL (`DROP
TABLE/DATABASE/SCHEMA/INDEX`, `TRUNCATE`, unrestricted `DELETE`/`UPDATE`).
Reason points at the correct channel (ask the user, or ship through the
deploy path).

### `grader-lock.sh` — PreToolUse (`Edit|Write|MultiEdit|NotebookEdit`), `--agent subagent`
The party being graded does not edit its own grader. Refuses a spawned subagent
any write to the standard (`AGENTS.md`), the gates (`hooks/`, `lint-skills.sh`,
the `sync-*` scripts), the transport that carries a payload to one (`claude/`,
`codex/`, `.kimi/hooks/`), the config that switches one off, and the `test-*`
scripts that prove a gate fires. A skill stays writable: `lint-skills.sh` grades
a skill and is itself governed, so the grader is locked while the graded
artifact stays delegable.

The `--agent subagent` selector is what keeps the operator out of scope. Claude
tags a subagent's `PreToolUse` payload with `agent_id` and the main session's
with neither field, so the gate skips the main agent entirely and an amendment
reaches the standard the way every other operator decision does.

Every path resolves through `realpath` before the match. `CLAUDE.md` and
`.claude/settings.json` are symlinks onto canonical files inside the governed
set, and `.agents/AGENTS.md` forbids editing through the mirror — matching the
raw path would guard the mirror and miss the file it points at.

Claude only. The Codex and Kimi adapters take no `--agent` selector, so the same
wiring there would fire for the main session and lock the operator out of every
gate; `debt: colloid-grader-lock-claude-only`. Fails **open** on an unreadable
payload, an absent `files` list, or a missing decision module — a guard must
never block on its own blindness. It sees `Edit` and `Write` alone, so a shell
redirect reaches the same files: a guardrail against writing the rules by
accident, never a boundary against one that means to.
<!-- colloid-only -->

### `genome-inject.sh` — SubagentStart
Draws a genome from `.agents/genome.sh` and delivers it as
`hookSpecificOutput.additionalContext`, which the host writes into the spawned
cell's own transcript before its first prompt (see `genomes.md`). Every dispatch
is therefore stamped, including the ones the orchestrator forgets — the
treatment applies rather than being demanded, so an unstamped run is a control
arm rather than a failed one. Sortition uses the `.agents/.genome-ledger`
anti-repeat trail, so sequential cells in one fan-out condense as different
selves. Never blocks: a `genome.sh` that cannot parse `genomes.md` yields no
stamp rather than a half-formed personality.

Read-only utility types (`Explore`, `Plan`, `claude-code-guide`,
`statusline-setup`) are exempt; a personality on a search that cannot write is
noise. `learning-reporter` is exempt too — for the adjacent reason: it *does*
write (a teaching report), but in a fixed instructional voice that a variable
persona only distorts (an aggressive genome — Pyroclast's "burn it", Supernova's
"collapse it" — is actively wrong for material a junior is learning from). The
exempt set is therefore "agents that gain nothing from a genome," not strictly
"read-only agents." `.agents/hooks/lib/genome-exempt.py` owns that list.

Nothing checks that a dispatch carries a stamp. A `PreToolUse` gate that
demanded one shipped for months and blocked 14 dispatches while the orchestrator
prepended a stamp exactly once — every block was the gate asking a person to do
the injector's job. Where an engine has no `SubagentStart` event (Codex, Kimi),
the orchestrator prepends by hand and an unstamped cell simply runs unstamped.

The per-edge re-stamp is the minion's own responsibility either way —
`genomes.md` states the rule (a genome rides one hop; a minion that spawns
children draws a fresh one for each).

<!-- /colloid-only -->

### `sources-capture.sh` — PostToolUse (web lookups; matcher below)
The search scaffold's evidence trail. Observes web lookups — the main agent's
*and* any researcher cell's, since subagents inherit hooks — and appends one row
`ts · agent · kind · value` to `.agents/.sources-ledger` (`agent` from
`agent_type`, so a researcher's rows are tagged apart from `main`). Always exits
0; a trail is never a gate. The adapter maps `tool_name` → kind and pulls the
source value (`WebSearch.query`, `WebFetch.url`, `browser_navigate.url`,
`fetch_readable.url`, `resolve_open_access.query`). The
ledger is transient and gitignored; safe to delete.

Matcher caveat: the list names every logged tool literally. It now carries
hyphens (`mcp__playwright-reader__browser_navigate`,
`mcp__research-mcp__fetch_readable`), so it reads as a regex alternation rather
than a plain `|`-list. A hyphen outside a character class is a literal, so each
alternative still matches only its own tool. Do not add a metacharacter —
`mcp__playwright__.*` would widen the whole matcher, not just its own branch.
Add new web-reading tools here, or their lookups leave no trail.

### `research-prime.sh` — UserPromptSubmit (`--agent main`, Claude-only)
The search scaffold's nudge — a *context* policy, not a gate (always exits 0).
The reminder lands here, *before* the answer, because a reminder after the answer
is too late to change it — a Stop hook fires once the claim is already written.
(`Stop` *can* speak without an error: it accepts
`hookSpecificOutput.additionalContext` for "non-error feedback that continues the
conversation" — so the constraint is timing, not capability.) When the prompt
matches high-signal
research patterns (`latest`, `compatible with`, `current best practice`, version
questions…), it injects `hookSpecificOutput.additionalContext` nudging the agent
to search and cite (or delegate a researcher) rather than answer from memory.
Tight patterns on purpose — a reminder that fires every turn is one nobody
reads; tune `signals=` in the script. Honest ceiling: it can't *force* a search
(a from-memory claim makes no tool call), it primes the discipline. Not wired in
Kimi (no `UserPromptSubmit`).

### `post-edit-check.sh` — PostToolUse (file writes)
Runs the relevant linter / formatter / typechecker on the edited
file(s) only. Pre-existing issues in untouched files are suppressed so
edits don't turn into repo-wide cleanup missions.

Two hook entries, split by whether the work rewrites the tree. `POST_EDIT_MODE`
selects one, and the settings file wires both:

| Mode | Runs | Exit | Scheduling |
|------|------|------|------------|
| `write` | every fixer and formatter, then the advisory scans | always 0, findings through `additionalContext` | synchronous |
| `check` (default) | the read-only gates | 2 with the findings on stderr | `asyncRewake` — background, wakes the model on a finding |

`write` must stay synchronous. A formatter running in the background can read a
file, be overtaken by the agent's next edit, and write the pre-edit content back
over it. Nothing in `check` touches the tree, so `check` is the entry that can
carry the slow typecheckers off the critical path.

| Extension | `write` runs | `check` runs | Configured by |
|-----------|--------------|--------------|---------------|
| `*.py` | `ruff check --fix` → `ruff format` | `ruff check` | `pyproject.toml` `[tool.ruff]` |
| `*.py` | — | `pyright --outputjson` (errors only, scoped to edited files) | `pyrightconfig.json` or `[tool.pyright]`, per package |
| `*.ts`, `*.tsx` | — | `tsc --noEmit --incremental` (scoped to edited files) | the nearest `tsconfig.json` above the file |
| `*.ts`, `*.tsx`, `*.js`, `*.jsx`, `*.mjs`, `*.cjs` | `prettier --write`, `eslint --fix` | `eslint --format json` (errors only) | `.prettierrc` / `eslint.config.*`, per workspace |
| `skills/<name>/*.md` | — | `lint-skills.sh` on the owning skill | the script itself |

Every tool is resolved from the edited file's own workspace, walking up to
the repository root: a monorepo keeps `ruff` in `apps/api/.venv` and `eslint`
in `apps/web/node_modules`, and neither is visible from the root. A tool that
is installed nowhere above the file is skipped silently — but a tool that runs
and fails to produce a report is reported, because the two are
indistinguishable from an exit code alone.

It also runs an **advisory tombstone check** (`hooks.post_edit_check.tombstone_check`,
default on): the added lines of the edit (vs `HEAD` — no mid-session commits, by
policy) are scanned for diary/changelog narration ("previously", "used to", "was
refactored", dated `TODO`s). A banned phrase inside quotes or backticks is treated
as a citation and skipped, so the rule's own docs don't self-trip. Matches surface
as a nudge to move the rationale into `.agents/debt-log.md` and reference it inline
as `debt: <id>`. A flagged line is a judgment call, not a defect, so it leaves
through `additionalContext` at exit 0 — the exit-2 channel carries type and lint
failures alone and keeps meaning what it says.

### `session-wrap.sh` — Stop (`--agent main`)
Main agent only — the wrap-up never fires inside a subagent's turn, only
when the agent the user is waiting on stops.

**The script owns the gate; the prose lives in `.agents/playbooks/*.md`.** The
hook emits a short trigger (~12 lines) naming each section and its file; the
agent reads a file only if the user opts into the wrap. A skipped wrap therefore
costs the model nothing, where an inlined checklist costs the whole wall whether
or not it is used. Edit the checklists as markdown; the bash never changes.

**Magnitude tiers**, computed once from git plumbing (free — no tokens):

| Tier | Condition |
|------|-----------|
| `none` | no changed files |
| `trivial` | `≤ trivial_files` (2) **and** `≤ trivial_lines` (30) |
| `diff` | beyond trivial |
| `large` | `≥ review_files` (5) **or** `≥ review_lines` (150) |

**The gate is tier *escalation*, not "is there a diff".** A session that reaches
`diff` fires once; it does not re-fire next turn still sitting at `diff`.
Reaching `large` fires again (and adds the hostile-review section). A closed unit
of work re-arms the ladder, so **atomic commits give one wrap per unit of work
rather than one per turn**.

Measured on one 20-turn feature session with atomic commits (same session driven
through both versions):

| | Blocks | Total stderr |
|---|---|---|
| Before (every substantial turn, inline checklist) | 12 / 20 | 646 lines |
| After (escalation + pointers) | 5 / 20 | ~62 lines |

Re-arming watches **two** signals, because a tier drop is not the only way work
closes: a turn that commits *and* opens the next unit never dips to `none`, so
the ladder would stay latched and swallow the next wrap. The gate therefore
re-arms on a tier drop **or** on the commit count rising. It counts commits
rather than comparing `HEAD`, because a sha merely *moves* on `--amend`,
`rebase`, or `checkout` — none of which close a unit of work — and would re-fire
the wrap on an unchanged tree.

**Two measures**, because the tier reads the *uncommitted* tree. An agent that
edits and commits inside one turn leaves a clean tree at `Stop`, so its tier is
`none` every turn: the diff ladder never leaves the floor, and the work drops
through to the no-diff branch — which then reports a *research* session over a
heavily-committed implementation one. The second measure is what **landed**, on
the same thresholds, so committing inside the turn earns the wrap instead of
hiding it. The perverse incentive it removes is the sharp end: `hostile-review.md`
is offered only by these branches, so discipline about committing made the
mandated adversarial review *less* likely to be offered.

The committed range is `unreported..HEAD` — everything committed since the last
report, not the session total, and **reporting it consumes it** by advancing the
base. A tier ladder would be wrong here: the measure only grows, so a rung that
only climbs fires on the session's first unit and latches for every unit after
it. Consumption paces instead of latching, and committed work *below* threshold
is not dropped — the base does not advance, so a run of small commits accumulates
until it crosses. A one-line typo commit therefore leaves the investigation report
intact: that report asks whether the session **built** something (`implemented`),
not whether it committed anything.

Two shapes of history motion are refused rather than measured, because the emitted
text tells the agent to review "the files this session touched": HEAD not
descending from the base (`checkout`, `reset`, a rebase onto another base), and a
merge inside the range (`merge`, `pull`) — either would hand it someone else's
branch. Both re-base the range on `HEAD` and stay silent for the turn. What
remains unattributable is two concurrent sessions in one working tree: they share
a tree and a HEAD, so each measures the other's commits (`debt:
colloid-wrap-concurrent-attribution`). The two measures never speak on the same
turn: the committed one is reached only from a clean or trivial tree, and its
range is left unconsumed on a turn the dirty-tree branch owns, so pending
committed work waits rather than being swallowed.

Escalation, not every-turn, because every-turn blocking makes each turn cost two
assistant messages and forces the agent to triage a wall it will mostly ignore.
It is also self-defeating: [Claude Code overrides a Stop hook after it blocks
eight times in a row without progress](https://code.claude.com/docs/en/hooks-guide),
so a hook that always blocks spends its own budget on noise and is then ignored
exactly when it has something worth saying. The community reference hook
([disler/claude-code-hooks-mastery `stop.py`](https://github.com/disler/claude-code-hooks-mastery))
never blocks at all. The gate idiom — cheap git plumbing plus a persisted marker,
silent when nothing changed — follows
[OpenRouter's documented Stop-hook review pattern](https://openrouter.ai/docs/guides/coding-agents/automatic-code-review).
`hooks.session_wrap.report_every_turn=true` opts into the every-turn behavior.

Churn = tracked diff lines (vs `HEAD`) + untracked file lines; a binary change,
or churn we can't measure (no commit yet), is never trivial — a safety wrap fails
toward more review. The changed-file list (`git status --porcelain=v1
--untracked-files=all`) excludes the kit's own transient state by name, so a
ledger write never reads as session work and a real file in `.agents/` is never
hidden. Re-entry guarded by `stop_hook_active`.

State lives in `.agents/.wrap-state-<hash of session identity>` — **one file per
session**, so a new session starts fresh and two concurrent sessions in one repo
never clobber each other's *state* (a single shared file keyed by a line-1
identity makes each session reset the other's ladder and fire every turn). Their
*measures* still overlap, since they share one working tree. Line 1 is the highest
tier fired, line 2 a flag for the no-diff report, line 3 the commit count at last
write, line 4 the commit the committed range measures **from**, line 5 a flag for
the committed report. Each branch needs its own throttle: the tier ladder cannot
throttle the no-diff report (`none` never out-ranks a fresh `none`), and the
committed branch throttles by consuming its range rather than by rank. Lines 3
and 4 are not redundant — a count cannot name a diff range, and a sha cannot
answer "did a commit land". State is written on **every** invocation, not only
when the hook speaks: a commit turn emits nothing, so a re-arm persisted only from
an emit branch would live in memory and die there.

The identity is `session_id`, falling back to `transcript_path`; both are
[documented on every hook payload](https://code.claude.com/docs/en/hooks), and the
Kimi adapter supplies `session_id` too, so the throttle is not Claude-only. With
neither, the hook reads and writes nothing and every diff escalation fires; the
other two branches need a remembered baseline to mean anything and stay silent.

The baseline is seeded by **`session-start.sh`**, which runs before turn 1 — the
only hook early enough to see where the session actually started. `session-wrap`'s
own first write happens at the *end* of turn 1, by which time a turn that
implemented and committed has already hidden that work inside the baseline. The
seed writes only when the file is absent, so a `SessionStart` with
`source=compact` (or a resume) continues an existing session instead of erasing
its ladder mid-flight. Where the seed does not happen — another engine,
`session_start` disabled, an identity that changed under us — the wrap seeds
itself one turn late and the two branches that depend on the baseline stay silent
for exactly that one invocation, rather than guess. A late wrap costs a turn,
where a session labelled "research" because it committed its implementation is
the defect this exists to remove.

With **no identity at all** — neither `session_id` nor a transcript path — the
hook reads and writes no state and every diff escalation fires. Keying a shared
file on an empty identity would build one repo-wide ladder that every future
session inherits, silently suppressing wraps forever — a wrap must fail toward
review, never away from it. A state file it cannot *write* is the opposite case
and gets the opposite answer: the hook goes silent, because a throttle that
cannot remember re-fires the same wall every turn and spends the eight-block
override budget on repetition.

`hostile-review` fires only at `large`, so a 4-file/140-line change gets clean-up
and a report but no adversarial subagent. That is a deliberate cost of keeping
the subagent spawn off routine work; drop `review_files`/`review_lines` if you
want it back earlier.

**Learning report (`hooks.learning_report`, opt-in, OFF by default).** When
pair-coding with a junior who learns by reviewing, the diff branch adds one more
pointer — `.agents/playbooks/learning-report.md` — asking the agent to pair each of the
session's decisions (the *why*, tradeoffs, alternatives rejected) with the real
code (`file:line`) that embodies it. The instruction is explicitly **decoupled
from the "full wrap, or skip?" choice**: the report is its own deliverable,
produced even when the user skips the wrap, so a wrap-skip can't silently swallow
the very report the mode exists to produce. Produced INLINE by default; persisted
to `docs/learning/` via the `learning-reporter` subagent only when the user asks
— seeded with a decision-brief the orchestrator holds in live context, never
pointed at the raw transcript. Unlike every other toggle here, this one reads
`.get("enabled", False)` — a missing or broken config must leave pairing mode
OFF, never silently on. Generated reports under `docs/learning/` are excluded
from the magnitude scan, so a report never re-inflates the session that produced
it. Requires `session_wrap` enabled (it rides this hook).

The no-diff path measures *length* as the transcript's **line count** (one line
per exchange) — schema-agnostic, so it works on any engine that passes a
transcript path, not just one transcript format, and it can't crash on a
malformed transcript. It still needs *a* transcript path: Kimi's Stop payload
exposes none, so a no-diff session is silent there; both magnitude measures are
fully engine-agnostic (git only). It fires only while `implemented` is unset — a
clean tree means "nothing was built" only when neither measure has reported
substantial work. The `--agent main`-gated ask routes through the agent because a
Stop hook cannot call `AskUserQuestion` itself.

**Branch order: a closed unit outranks work in flight.** The committed branch is
tested first. The other way round, one stray untracked file above the trivial
floor pins the tier at `diff` for the whole session, the commit-count re-arm
re-fires that same stale wall every commit turn, and the units that actually
landed are never named. When both have something to say, the committed message
names the uncommitted remainder rather than claiming a clean tree.

Known and accepted: work reported while uncommitted is reported again once it
lands (the two measures cannot compare content across that boundary, and the
alternative — suppressing on a tier match — silently swallows real work when the
tree was dirty for an unrelated reason). A base rewritten by `--amend` of a
pre-session commit fails the ancestry test, so that one range is re-based and its
report lost; distinguishing that from a branch switch needs a heuristic that
re-opens the foreign-work problem. Follow-up commits from the wrap itself can earn
a second wrap — review fixes are unreviewed code, so that one is working as
intended.

**Note on the sibling Stop hook.** `stop-investigate.sh` is also wired on `Stop`,
so two hooks can both `exit 2` on one turn. The docs cover neighbouring cases but
not this one: matching hooks run in parallel and are deduplicated by command;
`PreToolUse` decisions resolve most-restrictive-first; `additionalContext` text is
"kept from every hook and passed to Claude together". For **two Stop hooks exiting
2 with different stderr**, no combination rule is documented. The escalation gate
keeps the collision rare by construction — the wrap speaks only on a tier change,
not every turn. Do not add an every-turn Stop blocker without resolving this
first, and note the eight-block override above: competing blockers burn that
budget together.

### `stop-investigate.sh` — Stop (Claude only, `--agent main`)
Main agent only — a subagent that hits a dead end should report it back to
the main agent (which stays subject to this guard), not be trapped
re-investigating with no user to clarify from.

Blocks end-of-turn when the last assistant message contains high-
precision hedging or give-up patterns ("unable to determine without",
"please clarify which", "out of scope", etc.). Re-states the
investigate-then-act principle. `stop_hook_active` re-entry guard.
Tune by editing `hedges=` in the script.

It also runs a **ratchet check** (`hooks.stop_investigate.ratchet_check`,
default on): a second pattern class over the same message, catching
disclaimers of *ownership* rather than of capability. The quality gate rises
over time, so provenance is not an exemption — a file this change touches
comes up to today's bar whoever wrote it, and "pre-existing" is an
observation about history, not a reason to leave it.

It is a **two-key gate with a proximity bound**, and it is **deliberately
aggressive**. Provenance alone never fires; it must sit within `NEAR` (140)
characters of a second key — either an explicit declination (`declines=`: "so I
left it alone", "out of scope") **or** a bare defect noun (`defects=`: error,
failure, warning, bug, lint…).

The defect key is the important half. The natural punt **never announces
itself** — it states provenance about a failure it just surfaced and moves on:
*"Those 4 lint errors are pre-existing in the edge function."* That declines
nothing out loud and fixes nothing either, and an announced-punts-only gate
misses it completely. A third key disarms: naming a sanctioned disposition
(`breadcrumbs.md`, `debt-log.md`, a `debt: <id>` ref) passes even when
declining, because that is the Discovered Subprojects policy working.

**The aggression is a knowing trade, not an oversight.** "Those tests are
pre-existing" is word-identical whether it dodges work or answers "did you break
this?" — only intent separates them, and intent is not in the text. So the gate
fires on the claim and the *reason* carries the resolution: it tells the agent
the check is aggressive by design and to say so in one line and stop if it
misread. The agent has the context the regex cannot — it knows whether the user
asked. One extra turn, then `stop_hook_active` lets it through. Expect honest
reports about suppressed pre-existing failures to trip it; that is the cost.

Tune `provenance=` / `declines=` / `defects=` / `filed=` / `NEAR=`, but keep the
co-occurrence and the proximity. Every relaxation has drawn blood: a single-key
version blocked "unrelated to this change, so I filed it in
`.agents/breadcrumbs.md`" — the very behavior its reason text asks for — and an
unbounded two-key version blocked a report that said "a pre-existing failure was
correctly suppressed" in one paragraph and "Left alone, every edit would drop a
file" (a conditional, not a declination) 233 characters later.

The two classes share this one hook because a second `Stop` hook would race this
one's stderr: matching hooks run in parallel, and no rule is documented for how
two of them exiting 2 with different stderr combine. Same constraint that folds
pairing mode into `session-wrap.sh`. Hedges are checked first (a give-up is the
harder failure), so a message that both hedges *and* disclaims shows only the
hedge reason. Unlike the hedge class, the ratchet class matches stripped text, and it
strips **two ways**. The triggers read `prose` (fences, blockquotes, inline code,
and quoted spans blanked) so citing a banned phrase is not making the claim. The
disarm reads `ledger` (fences and blockquotes dropped; inline code and quotes
*unwrapped*, whitespace flattened) because a path is conventionally written
`` `.agents/debt-log.md` `` — blanking inline code there would delete the very
evidence the disarm looks for and block a correct filing, whose reason text then
asks the agent to name where it filed, so it complies, backticks the path, and
blocks again. Apostrophes are deliberately not delimiters in either: single-quote
stripping would make the check contraction-dependent, passing "it's … so I've
left it" while blocking the identical "it is … so I have left it".

Not wired in Kimi: depends on transcript access. Current Kimi hook
docs expose `stop_hook_active` but not a transcript path or last-
message field, so a faithful port is not available yet.

### `session-start.sh` — SessionStart (Claude, Codex, and Kimi)
A *context* policy, not a gate: always exits 0 and never blocks. When
`hooks.learning_output_style` is on, it injects
`.agents/playbooks/learning-output-style.md` on startup, resume, and
compaction. The unique marker makes duplicate injection testable. The style
explains meaningful choices and completes the task. At a genuine decision, it
offers a small code contribution without blocking progress. It does not offer
configuration, boilerplate, or obvious work.

When `hooks.session_start` is on, it surfaces this operational state:

- **Breadcrumbs** — markdown `- ` bullets in `.agents/breadcrumbs.md` (deferred
  non-blocking *work*) are re-shown at session start. Past ten items the hook
  shows only the ten most recent and states the full count. Items are appended,
  so those are what recent sessions found and deferred, and the most likely to
  intersect the work in hand. Older items wait for a maintenance pass, which
  reads the file directly rather than through this cap. Silent when there are
  none. Its sibling `.agents/debt-log.md` (standing tradeoffs and
  deferred *decisions*) is deliberately **not** surfaced here: it's a durable
  reference pulled just-in-time when code carrying a `debt: <id>` ref is touched,
  not an actionable queue — re-injecting it every session would be context rot.
- **MCP state** — each registry MCP server that is off, with its description
  and the commands that enable or disable it.
- **Post-compaction nudge + Discovered Subprojects policy** — when `source`
  is `compact`, it emits a checkpoint reminder tailored to the trigger
  (recovered from the `.compaction-pending` marker `pre-compact.sh` left, and
  consumed here) plus the full Discovered Subprojects policy (blocking /
  non-blocking / trivial). That policy lives here, not in `AGENTS.md` —
  relocated so it lands exactly when re-scoping discipline matters, instead
  of costing always-loaded context. The marker only carries the trigger
  word; `source=compact` is what fires the block.

The learning switch does not control baseline seeding, breadcrumb display, MCP
display, or compaction-marker consumption. The operational switch does not
control the learning output style.

The policy emits one JSON object on stdout carrying
`hookSpecificOutput.additionalContext`. Plain stdout is **not** injected for
`source=compact` (anthropics/claude-code#15174); the structured
`additionalContext` field is injected regardless of source, so it is the
robust channel. The Kimi adapter unwraps this object to plain context. It also
maps Kimi `PostCompact` to `source=compact` so the same policy restores the
learning and recovery context after compaction.

### `pre-compact.sh` — PreCompact (`--agent main`, Claude only)
PreCompact fires right before compaction. It is control-only — its stdout is
discarded and it cannot inject context (it can only block) — so it does the
one useful pre-compaction thing: write the trigger (`auto`/`manual`) to
`.agents/.compaction-pending` for `session-start.sh` to consume on the next
`source=compact` start. Always exits 0; never blocks compaction. The marker
is gitignored and transient. Not wired in Kimi (no `PreCompact`).

## Tuning Claude's / Kimi's failure modes

Linter rules are the leverage point for real-time correction. The
active ruleset in `pyproject.toml` targets:

- `F` — unused imports, undefined names, duplicate function defs
- `I` — duplicate imports, unsorted imports
- `B` — mutable default args, bare `except`, assorted bug-bear traps
- `UP` — obsolete syntax (`Dict` → `dict`, `typing.Optional` → `| None`)
- `SIM` — redundant if/else, dead branches
- `RUF` — asyncio misuse, useless type aliases

When a new bad pattern shows up, add a rule. Keep scope per-file.

## Configuration

Each hook behavior reads `.agents/config.json`. A behavior becomes a no-op when
its toggle is `false`. Engine wiring (`settings.json`, `config.toml`) stays
static. The config file is the single source of truth for active behavior.

### Hook toggles

| Config key | Hook | What happens when `false` |
|---|---|---|
| `hooks.guard_destructive` | `guard-destructive.sh` | No destructive-command blocking |
| `hooks.grader_lock` | `grader-lock.sh` | A subagent may write the standard, the gates, and their tests |
| `hooks.sources_capture` | `sources-capture.sh` | No `.sources-ledger` writes |
| `hooks.research_prime` | `research-prime.sh` | No research nudge on UserPromptSubmit |
| `hooks.post_edit_check` | `post-edit-check.sh` | No lint/format/typecheck on edits |
| `hooks.post_edit_check.tombstone_check` | `post-edit-check.sh` | No tombstone-comment advisory (lint still runs) |
| `hooks.session_wrap` | `session-wrap.sh` | No end-of-session wrap prompt |
| `hooks.session_wrap.report_every_turn` | `session-wrap.sh` | *(default)* wrap fires only on tier escalation; `true` fires it every turn |
| `hooks.learning_report` | `session-wrap.sh` (learning report) | No junior learning-report dispatch — **the default**; this toggle is opt-in |
| `hooks.learning_output_style` | `session-start.sh` | No live teaching context |
| `hooks.stop_investigate` | `stop-investigate.sh` | No hedge/give-up blocking |
| `hooks.stop_investigate.ratchet_check` | `stop-investigate.sh` | No ownership-disclaimer blocking (hedge check still runs) |
| `hooks.session_start` | `session-start.sh` | No baseline seed, breadcrumbs, MCP display, compaction nudge, or marker consumption |
| `hooks.pre_compact` | `pre-compact.sh` | No `.compaction-pending` marker |
<!-- colloid-only -->

`hooks.genome_inject` gates `genome-inject.sh`: `false` means a spawned cell
receives no genome stamp.
<!-- /colloid-only -->

Missing or broken config = all enabled (backward compatible) — with one
deliberate exception: `hooks.learning_report` is opt-in and reads
`.get("enabled", False)`, so a missing or broken config leaves pairing mode OFF.
It is the only toggle that fails toward *disabled*.

### Model routing

`.agents/config.json.example` → `.agents/sync-claude-agents.sh` →
`.claude/agents/*.md`. Edit the model in one place, run the sync script, and the
agent definitions are regenerated with the correct frontmatter. Do not hand-edit
files in `.claude/agents/`.

`subagents.*` is the one key the local `config.json` does not override. The
frontmatter lands in a committed file, so reading a gitignored per-operator
value would commit one machine's routing and make every other checkout read as
drifted. Subagent routing is a repository decision; change it in the tracked
`.example`.

An entry carries `tools`, `tier`, `memory` and `effort`, and omits any line whose
value is null. The script refuses a key outside that set, because an unsupported
frontmatter key writes nothing and leaves the cell on the default with no
diagnostic.

`tier` is the one key that does not reach the frontmatter under its own name: it
indexes the `tiers` map and emits `model:`. A tier the map does not define stops
the run, because the alternative is a persona with no `model:` line — which
reads as "inherit the parent", the most expensive tier, reached by typo.

```sh
# Re-point the medium tier — every persona on it follows
jq '.tiers.medium = "opus"' .agents/config.json.example > tmp \
  && mv tmp .agents/config.json.example
.agents/sync-claude-agents.sh

# Gate: exit 1 when a committed definition disagrees with its inputs
.agents/sync-claude-agents.sh --check
```

## Native agents

### `researcher` — `.claude/agents/researcher.md`

A Claude-native subagent definition (generated by `.agents/sync-claude-agents.sh`
from `.agents/config.json.example`) that guarantees research tasks run on the configured
model regardless of the parent session's model. The agent's system prompt
carries the full researcher contract (escalation ladder, cross-checking,
`CLAIMS / SOURCES / GAPS` return shape). The orchestrator dispatches it with:

```
Task(subagent_type='researcher', prompt='[research question]')
```

The contract stays in the agent definition, and `sources-capture` logs the
cell's web lookups because subagents inherit hooks. See the `search-and-cite` skill for
the full delegation protocol.
<!-- colloid-only -->

Do not prepend a genome stamp to that prompt. `genome-inject.sh` stamps the cell
on `SubagentStart`, and a prepended stamp would give it a second personality.
<!-- /colloid-only -->

### `learning-reporter` — `.claude/agents/learning-reporter.md`

Generated by the sync script from `.agents/personas/learning-reporter.md` (source contract)
and `.agents/config.json.example` (`subagents.learning-reporter`, whose null `model`
inherits the parent). Dispatched only by `session-wrap.sh`'s pairing mode (above), at the
end of a substantial pairing session, to produce a junior's learning report:

```
Task(subagent_type='learning-reporter', prompt='[decision-brief] + [changed files]')
```

Two design points. (1) It is **seeded, not cold**: the orchestrator distills the
session's decisions (the *why* — tradeoffs, rejected alternatives — which it holds
in live context) into the brief and passes it in; the subagent reads only
`git diff HEAD` and the named files for the *code*, never the raw transcript (which
is tool-call noise the orchestrator is far better placed to interpret). (2) Its product is the file in
`docs/learning/`; its return value to the orchestrator is just a one-line pointer.
Claude-only (rides the transcript-gated wrap); not wired in Kimi.
<!-- colloid-only -->

It is also **exempt from genome stamping** (`swarm.exempt_subagent_types`), so
the dispatch carries no stamp — a teaching report wants a fixed instructional
voice, not a variable persona (see `genome-inject.sh` above).
<!-- /colloid-only -->

## Drop-in extensions (not active)

Intentionally deferred — YAGNI beats pre-emptive tooling:

- **jscpd** — cross-file duplicate detection. Too slow per-edit; wire
  into a `Stop` or `PreCompact` hook.
- **mypy** — pyright already covers the type gate. A second checker would
  double the noise for one more opinion.

## Runtime requirements

- `bash`, `python3` (stock macOS / Linux CI)
- Adapters locate the policy via `$CLAUDE_PROJECT_DIR` (Claude) or the
  `cwd` field of the hook payload (Kimi).

## Adding a policy

1. Drop the script in `.agents/hooks/policy/`, `chmod +x`. It must
   consume the policy-contract JSON on stdin and signal via exit 2 +
   stderr.
2. Extend the adapter normalizers in `.agents/claude/adapter.sh` and
   `.kimi/hooks/adapter.sh` to map the engine's payload into your new
   contract.
3. Wire the adapter into `.claude/settings.json` — add `--agent
   <main|subagent|type>` to scope it to an agent context — and, if
   applicable, `.kimi/config.toml.example`.
4. Document it here.

Keep policy deterministic. Anything requiring judgment belongs in
`AGENTS.md`, not a hook.
