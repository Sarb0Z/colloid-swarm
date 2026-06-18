# Agent Hooks

Programmatic reinforcement for `AGENTS.md` (the canonical instruction file;
`CLAUDE.md` and `.github/copilot-instructions.md` are symlinks to it). The
md owns philosophy and judgment calls; hooks own deterministic rules where
a mechanical check beats prose.

## Architecture

Two layers, strict separation:

```
.agents/hooks/policy/   engine-agnostic policy (the actual checks)
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
| `genome-guard.sh` | `{"prompt": "...", "subagent_type": "..."}` |
| `sources-capture.sh` | `{"project_dir": "...", "agent": "...", "kind": "...", "value": "..."}` |
| `research-prime.sh` | `{"project_dir": "...", "prompt": "..."}` |
| `post-edit-check.sh` | `{"project_dir": "...", "files": ["..."]}` |
| `session-wrap.sh` | `{"project_dir": "...", "stop_hook_active": bool, "transcript_path": "..."}` |
| `stop-investigate.sh` | `{"project_dir": "...", "transcript_path": "...", "stop_hook_active": bool}` |
| `session-start.sh` | `{"project_dir": "...", "source": "..."}` |
| `pre-compact.sh` | `{"project_dir": "...", "trigger": "auto"\|"manual"}` |

All policies: `exit 0` = allow, `exit 2` + stderr = block with reason.
Exception: `session-start.sh` is a *context* policy, not a gate — it always
exits 0 and emits a JSON `hookSpecificOutput.additionalContext` object, which
Claude adds to the session.

### Agent scoping (Claude adapter)

Subagents inherit the project's hooks. Claude tags every hook payload
fired inside a subagent with `agent_type` (and `agent_id`); the main
agent's payload omits them. The Claude adapter turns that into an optional
selector that gates whether the policy runs for a given invocation:

```
.claude/hooks/adapter.sh [--agent <selector>] <policy.sh>
```

| Selector | Policy runs for |
|----------|-----------------|
| *(absent)* | every agent — main and subagents alike |
| `main` | the main agent only (no `agent_type`) |
| `subagent` | any subagent (has `agent_type`) |
| a type name | that agent type only |

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

### `guard-destructive.sh` — PreToolUse (shell)
Blocks irreversible shell commands: `rm -rf` on broad paths, `git push
--force`, `git reset --hard`, `--no-verify`, SSH-into-prod mutations
(`systemctl restart|stop|reload`, `postsuper`, `postqueue -f`, package
installs, `sed -i`, piping into `/etc/`), and destructive SQL (`DROP
TABLE/DATABASE/SCHEMA/INDEX`, `TRUNCATE`, unrestricted `DELETE`/`UPDATE`).
Reason points at the correct channel (ask the user, or ship through the
deploy path).

### `genome-guard.sh` — PreToolUse (`Task|Agent`)
Enforces the genome-stamping protocol: every substantive subagent dispatch must
carry exactly one genome stamp, prepended by the orchestrator from
`.agents/genome.sh` (see `genomes.md`). A hook cannot inject context into a
spawned subagent — `PreToolUse` `additionalContext` reaches the *parent*, not
the child, and it cannot rewrite the dispatch input — so this guard cannot
*supply* the genome; it blocks a dispatch that lacks one (`exit 2`, reason names
the fix) and a dispatch that doubles one. Read-only utility types
(`Explore`, `Plan`, `claude-code-guide`, `statusline-setup`) are exempt; a
personality on a search that cannot write is noise. `learning-reporter` is exempt
too — for the adjacent reason: it *does* write (a teaching report), but in a fixed
instructional voice that a variable persona only distorts (an aggressive genome —
Pyroclast's "burn it", Supernova's "collapse it" — is actively wrong for material
a junior is learning from). The exempt set is therefore "agents that gain nothing
from a genome," not strictly "read-only agents." The matcher is `Task|Agent`
because the dispatch tool is named `Task` on some Claude Code builds and `Agent`
on others. Like every policy here it relies on subagents inheriting the
project's hooks (see *Agent scoping* below): wherever a build fires `PreToolUse`
on a subagent's own tool calls, a nested dispatch is guarded the same way. Either
way, the per-edge re-stamp is the minion's own responsibility — `genomes.md`
states the rule (a genome rides one hop; a minion that spawns children draws a
fresh one for each). Fails **open** on an empty/unreadable payload, like
`guard-destructive.sh`.

Claude-only. `.agents/genome.sh` itself is engine-neutral, so the orchestrator
protocol works under Kimi; the guard is not wired there because Kimi's
subagent/hook surface differs (see `.kimi/config.toml.example`).

### `sources-capture.sh` — PostToolUse (`WebSearch|WebFetch|mcp__playwright__browser_navigate`)
The search scaffold's evidence trail. Observes web lookups — the main agent's
*and* any researcher cell's, since subagents inherit hooks — and appends one row
`ts · agent · kind · value` to `.agents/.sources-ledger` (`agent` from
`agent_type`, so a researcher's rows are tagged apart from `main`). Always exits
0; a trail is never a gate. The adapter maps `tool_name` → kind and pulls the
source value (`WebSearch.query`, `WebFetch.url`, `browser_navigate.url`). The
ledger is transient and gitignored; safe to delete.

Matcher caveat: `WebSearch|WebFetch|mcp__playwright__browser_navigate` is an
*exact* `|`-list (letters/digits/`_`/`|` only), so each name matches literally —
including the one MCP tool. Switching to "all playwright tools"
(`mcp__playwright__.*`) would flip the whole matcher into regex mode and change
how `WebSearch|WebFetch` is read; keep it exact unless you mean to.

### `research-prime.sh` — UserPromptSubmit (`--agent main`, Claude-only)
The search scaffold's nudge — a *context* policy, not a gate (always exits 0).
A Stop hook can't remind the model without blocking the turn, so the reminder
lands here, *before* the answer: when the user's prompt matches high-signal
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

| Extension | Tools run | Configured by |
|-----------|-----------|---------------|
| `*.py` | `ruff check --fix` → `ruff format` → `ruff check` (residuals) | `pyproject.toml` `[tool.ruff]` |
| `*.ts`, `*.tsx` | `tsc --noEmit --incremental` (output scoped to edited files) | `frontend/tsconfig.json` |

Tools that aren't installed are silently skipped. Install a tool to opt
in; drop the config to tune rules.

### `session-wrap.sh` — Stop (`--agent main`)
Main agent only — the wrap-up never fires inside a subagent's turn, only
when the agent the user is waiting on stops.

Gated by magnitude, so a one-line tweak or a quick question never triggers a
hostile-review subagent, but a heavy session is never lost. Three outcomes on
the first end-of-turn:

| Session | Outcome |
|---------|---------|
| Trivial diff (`≤ WRAP_TRIVIAL_FILES` files **and** `≤ WRAP_TRIVIAL_LINES` lines, default 2 / 30) | skip silently |
| Substantial diff | block — reason asks the agent to ask the user *"full wrap, or skip?"* before walking the checklist (clean-up, behavior-impact, hostile review, report, commit draft), **scoped to the changed files only** |
| No diff but a long session (`≥ WRAP_HEAVY_LINES` transcript events, default 200) — a debugging/research session | block — reason asks the user *"want a session report?"* with a findings/evidence template |

Churn = tracked diff lines (vs `HEAD`) + untracked file lines; a binary change,
or churn we can't measure (no commit yet), counts as substantial — a safety wrap
fails toward more review. The changed-file list (`git status --porcelain=v1
--untracked-files=all`) excludes the kit's own transient state by name (the five
`.agents/.*-ledger` / marker files), so a ledger write never reads as session
work, and a real file in `.agents/` is never hidden. The no-diff prompt is
throttled to once per session (keyed by `transcript_path`, marker
`.agents/.wrap-prompted`) so an active session isn't asked every turn. Re-entry
guarded by `stop_hook_active`.

**Pairing mode (`hooks.learning_report`, opt-in, OFF by default).** When
pair-coding with a junior who learns by reviewing, the *substantial-diff* branch
additionally asks the agent to produce a **learning report**: distill the
session's decisions (the *why*, tradeoffs, alternatives rejected) into a brief,
then dispatch the `learning-reporter` subagent (see *Native agents*), which pairs
each decision with the actual code (`file:line`) and writes it to `docs/learning/`.
It is **folded into this hook** — one `Stop` hook, one `exit 2`, the learning
section appended to the same stderr — rather than a second `Stop` hook, because
parallel `Stop` hooks merge their `exit 2` stderr unpredictably; a second
competing checklist is the bug, not the feature. To avoid reintroducing that
conflict *inside* the one hook, the appended learning instruction is explicitly
**decoupled from the wrap's "full wrap, or skip?" choice** — the report is its
own deliverable, produced even when the user skips the cleanup wrap, so a
wrap-skip can't silently swallow the very report the mode exists to produce. The
brief is the data flow: the
orchestrator holds the discussion in context and the subagent does not, so the
subagent is *seeded*, never pointed at the raw transcript. Unlike every other
toggle here, this one reads `.get("enabled", False)` — a missing or broken config
must leave pairing mode OFF, never silently on. Throttled once per session (marker
`.agents/.learning-prompted`, keyed by `transcript_path`) so the junior gets one
consolidated report, not one per turn; delete the marker to regenerate. Generated
reports under `docs/learning/` are excluded from the change-magnitude scan (like
the kit's transient markers), so a report never re-inflates the session that
produced it. Requires `session_wrap` enabled (it rides this hook) and a transcript
path (Claude); silent on engines without one.

The no-diff path measures *length* as the transcript's **line count** (one line
per exchange) — schema-agnostic, so it works on any engine that passes a
transcript path, not just one transcript format, and it can't crash on a
malformed transcript. It still needs *a* transcript path: Kimi exposes none, so
a no-diff session is silent there; the diff tiering is fully engine-agnostic
(git only). The `--agent main`-gated ask routes through the agent because a Stop
hook cannot call `AskUserQuestion` itself.

### `stop-investigate.sh` — Stop (Claude only, `--agent main`)
Main agent only — a subagent that hits a dead end should report it back to
the main agent (which stays subject to this guard), not be trapped
re-investigating with no user to clarify from.

Blocks end-of-turn when the last assistant message contains high-
precision hedging or give-up patterns ("unable to determine without",
"please clarify which", "out of scope", etc.). Re-states the
investigate-then-act principle. `stop_hook_active` re-entry guard.
Tune by editing `hedges=` in the script.

Not wired in Kimi: depends on transcript access. Current Kimi hook
docs expose `stop_hook_active` but not a transcript path or last-
message field, so a faithful port is not available yet.

### `session-start.sh` — SessionStart (Claude only)
A *context* policy, not a gate: always exits 0, never blocks. Surfaces
deferred work so it isn't lost across sessions:

- **Breadcrumbs** — every markdown `- ` bullet in `.agents/breadcrumbs.md`
  (deferred non-blocking subprojects) is re-shown at session start. Silent
  when there are none.
- **Post-compaction nudge + Discovered Subprojects policy** — when `source`
  is `compact`, it emits a checkpoint reminder tailored to the trigger
  (recovered from the `.compaction-pending` marker `pre-compact.sh` left, and
  consumed here) plus the full Discovered Subprojects policy (blocking /
  non-blocking / trivial). That policy lives here, not in `AGENTS.md` —
  relocated so it lands exactly when re-scoping discipline matters, instead
  of costing always-loaded context. The marker only carries the trigger
  word; `source=compact` is what fires the block.

It emits a single JSON object on stdout carrying
`hookSpecificOutput.additionalContext`. Plain stdout is **not** injected for
`source=compact` (anthropics/claude-code#15174); the structured
`additionalContext` field is injected regardless of source, so it is the
robust channel. Not wired in Kimi (no `SessionStart`).

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

All hooks respect `.agents/config.json` — they read it at startup and become
no-ops when their toggle is `false`. Engine wiring (`settings.json`,
`config.toml`) stays static; the config file is the single source of truth for
what's active and how it behaves.

### Hook toggles

| Config key | Hook | What happens when `false` |
|---|---|---|
| `hooks.guard_destructive` | `guard-destructive.sh` | No destructive-command blocking |
| `hooks.genome_guard` | `genome-guard.sh` | No genome-stamp enforcement |
| `hooks.sources_capture` | `sources-capture.sh` | No `.sources-ledger` writes |
| `hooks.research_prime` | `research-prime.sh` | No research nudge on UserPromptSubmit |
| `hooks.post_edit_check` | `post-edit-check.sh` | No lint/format/typecheck on edits |
| `hooks.session_wrap` | `session-wrap.sh` | No end-of-session wrap prompt |
| `hooks.learning_report` | `session-wrap.sh` (pairing mode) | No junior learning-report dispatch — **the default**; this toggle is opt-in |
| `hooks.stop_investigate` | `stop-investigate.sh` | No hedge/give-up blocking |
| `hooks.session_start` | `session-start.sh` | No breadcrumbs / compaction nudge |
| `hooks.pre_compact` | `pre-compact.sh` | No `.compaction-pending` marker |

Missing or broken config = all enabled (backward compatible) — with one
deliberate exception: `hooks.learning_report` is opt-in and reads
`.get("enabled", False)`, so a missing or broken config leaves pairing mode OFF.
It is the only toggle that fails toward *disabled*.

### Model routing

`.agents/config.json` → `.agents/sync-claude-agents.sh` → `.claude/agents/*.md`.
Edit the model in one place, run the sync script, and the agent definitions are
regenerated with the correct frontmatter. Do not hand-edit files in
`.claude/agents/`.

```sh
# Change researcher model to Opus
jq '.models.researcher = "opus"' .agents/config.json > tmp && mv tmp .agents/config.json
.agents/sync-claude-agents.sh
```

## Native agents

### `researcher` — `.claude/agents/researcher.md`

A Claude-native subagent definition (generated by `.agents/sync-claude-agents.sh`
from `.agents/config.json`) that guarantees research tasks run on the configured
model regardless of the parent session's model. The agent's system prompt
carries the full researcher contract (escalation ladder, cross-checking,
`CLAIMS / SOURCES / GAPS` return shape). The orchestrator dispatches it with:

```
Task(subagent_type='researcher', prompt='[genome stamp] + [research question]')
```

The genome stamp stays in the prompt (so `genome-guard` is satisfied), the
contract stays in the agent definition, and `sources-capture` logs the cell's
web lookups because subagents inherit hooks. See the `search-and-cite` skill for
the full delegation protocol.

### `learning-reporter` — `.claude/agents/learning-reporter.md`

Generated by the sync script from `.agents/learning-reporter.md` (source contract)
and `.agents/config.json` (`models.learning_reporter`, default null → inherit the
parent model). Dispatched only by `session-wrap.sh`'s pairing mode (above), at the
end of a substantial pairing session, to produce a junior's learning report:

```
Task(subagent_type='learning-reporter', prompt='[decision-brief] + [changed files]')
```

Two design points. (1) It is **seeded, not cold**: the orchestrator distills the
session's decisions (the *why* — tradeoffs, rejected alternatives — which it holds
in live context) into the brief and passes it in; the subagent reads only
`git diff HEAD` and the named files for the *code*, never the raw transcript (which
is tool-call noise the orchestrator is far better placed to interpret). (2) It is
**exempt from genome stamping** (`swarm.exempt_subagent_types`), so the dispatch
carries no stamp — a teaching report wants a fixed instructional voice, not a
variable persona (see `genome-guard.sh` above). Its product is the file in
`docs/learning/`; its return value to the orchestrator is just a one-line pointer.
Claude-only (rides the transcript-gated wrap); not wired in Kimi.

## Drop-in extensions (not active)

Intentionally deferred — YAGNI beats pre-emptive tooling:

- **ESLint + `@typescript-eslint`** — stray `any`, unused vars, non-null-
  assertion abuse in the frontend. Add `eslint.config.js` in `frontend/`
  and extend `post-edit-check.sh` dispatch.
- **jscpd** — cross-file duplicate detection. Too slow per-edit; wire
  into a `Stop` or `PreCompact` hook.
- **mypy** / **pyright** — mypy is installed. Not wired because without
  a repo-wide type config they produce pre-existing noise. Add
  `[tool.mypy]` with `strict = true` on a single package first.

## Runtime requirements

- `bash`, `python3` (stock macOS / Linux CI)
- Adapters locate the policy via `$CLAUDE_PROJECT_DIR` (Claude) or the
  `cwd` field of the hook payload (Kimi).

## Adding a policy

1. Drop the script in `.agents/hooks/policy/`, `chmod +x`. It must
   consume the policy-contract JSON on stdin and signal via exit 2 +
   stderr.
2. Extend the adapter normalizers in `.claude/hooks/adapter.sh` and
   `.kimi/hooks/adapter.sh` to map the engine's payload into your new
   contract.
3. Wire the adapter into `.claude/settings.json` — add `--agent
   <main|subagent|type>` to scope it to an agent context — and, if
   applicable, `.kimi/config.toml.example`.
4. Document it here.

Keep policy deterministic. Anything requiring judgment belongs in
`AGENTS.md`, not a hook.
