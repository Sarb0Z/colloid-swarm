# Claude Code mods in the scaffold

A Claude Code mod is a plugin. Its hooks are a JavaScript or TypeScript module
that loads once into the session. Unlike a settings hook—a fresh shell process
per event—a mod keeps state for the session. It sits in the event chain as
middleware. It observes, rewrites, or answers events. It calls back into Claude
Code: dialogs, panes, slash commands, model calls, subagent spawns, and messages
into running subagents. Mods are Claude-only. This spec describes which scaffold
behavior moves into mods, and in what shape and order.

## The rule

Behavior moves into a mod only when the value it gains exceeds the portability
it loses across Codex and Kimi. See `mods-where-value-exceeds-portability` in
`.agents/decisions.md`.

- **Value** is a measured failure the mod removes. Cite it from a breadcrumb,
  debt entry, decision, or transcript count. It can be a workaround the mod
  deletes: dot-file state, transcript re-reads, lock directories, or
  deny-by-permission mode. It can be a capability no settings hook has: waiting
  on a human, pushing into a running subagent, or waking an idle session.
  Measure token savings before counting them.
- **Loss** is the coverage Codex and Kimi sessions have today and would lose. A
  behavior wired only for Claude loses nothing. A rule stated in `AGENTS.md`
  loses nothing while the prose stays.
- **Layering** keeps the settings hook and adds the mod above it. Do this when
  the hook serves Codex or Kimi, or when it is the floor of a gate whose harm
  is irreversible. A layered mod never re-implements the hook's logic. It feeds
  the hook an input or runs the same policy by argv.

### Invariants

1. **Irreversible-harm gates keep a settings-hook floor. A mod never overrides
   their decision.** Three gates must stay as settings hooks: `guard-destructive`,
   `guard-publish`, and `parallel-writers-gate`. `guard-destructive` handles
   destructive shell commands. `guard-publish` handles pushes, deploys, and
   hosted writes. `parallel-writers-gate` handles two writers clobbering
   uncommitted edits, which Git cannot restore. A mod may supply an input such
   a hook reads. It may not turn a `deny` into `allow`.
2. **A mod may replace a gate whose harm is reversible** when three conditions
   hold. First, every hook must register a `.catch` handler. It runs when the
   hook throws or overruns its budget, and its answer stands. Second, CI must
   run the mod's tests. Third, M2 must report an unloaded mod.
3. **Session state only.** A mod may keep values in `$.state`. It survives a
   hot reload but not a `--resume`. Never keep values in `$.store` or a
   committed file; see `durable-state-in-repository`. Gitignored runtime files
   on the terms of `.wrap-state-*` are allowed where named: the M1 approval token and the M2
   heartbeat. Seen-message and lane state must stay with their existing owners.
4. **Prose that Codex and Kimi read stays in `AGENTS.md`.** A mod may enforce
   or deliver it on Claude. It does not become the only statement of a rule.
5. **One policy, one implementation.** Python policy in `.agents/hooks/lib/`
   is not ported to TypeScript. A mod runs it by argv (`$.process.run`).
6. **Tests gate the merge.** Each mod must pass `claude plugin validate`. This
   rejects an event name the build does not declare. Each mod must also pass
   `claude plugin test` with a firing test. The testing script is
   `.agents/test-mods.sh`. It joins the Verification list in
   `.agents/AGENTS.md`. It runs in CI with a pinned Claude Code install. No
   settings hook may be deleted until that CI job is green.
7. **Config switches stay where hooks keep theirs.** A mod reads its keys at
   `session.start`. It runs `hooks/lib/config.py .agents/config.json
   hooks.<name>.enabled=true …` by argv. `policy.json` and `config.json` layer
   exactly as they do for shell hooks.

## Platform facts

Sources: the declarations Claude Code 2.1.287 writes (`claude-code.d.ts`), the
bundled `plugin-authoring` reference, the hooks documentation, and the `mods/`
folder of `anthropics/claude-code`.

- The classic hook chain is `[managed settings hooks, ...hooks modules, the
  other settings hooks as core]`. `classic.PreToolUse` fires inside `tool.call`.
  It fires beneath every mod's `tool.call` hook (d.ts, `ClassicEventOf`,
  `PreToolUseResult`).
- When several PreToolUse settings hooks disagree, precedence is: deny > defer >
  ask > allow. An exit-2 block routes the same way as deny. All matching hooks
  run in parallel. For an `allow`, deny and ask rules are still evaluated
  regardless of what the hook returns (hooks documentation).
- A hook that throws or overruns its budget is skipped unless its
  registration's `.catch` handler answers (d.ts, `Registration.catch`,
  `EngineEventOf`).
- `classic.PreToolUse`'s `e` is the tool envelope only, with no
  `permission_mode`, `cwd`, or `agentId`. `tool.call`'s `e` adds `agentId`.
  `$.session.cwd()` and `$.session.id()` exist. No call returns the permission
  mode.
- `$.ui.ask(question, options)` opens Claude Code's own question dialog as a
  `tool.call` of `AskUserQuestion`. It goes through every other hook. It
  resolves to the chosen label or typed text. It rejects when dismissed and
  under `claude -p`. Waiting inside a `$` call does not count against a hook's
  budget.
- `$.session.append({ message, agentId })` adds a model-visible user-role row to
  the main conversation or a running subagent's. `$.prompt.submit` queues a
  prompt that starts a turn once the session is idle.
- `agent.spawn` lets a hook rewrite the prompt a subagent runs with. `turn.step`
  streams the model's response.
- `$.http.fetch` exposes no DNS resolution or connection pinning.
- A plugin folder under the project's `.claude/skills/<name>` is auto-loaded and
  watched (reference.md, "Developing one").
- The built-in `agents-md` mod loads `AGENTS.md` only where no `CLAUDE.md`
  exists (`anthropics/claude-code` `mods/README.md`). The `CLAUDE.md ->
  AGENTS.md` symlink loads the contract once.

Not yet observed. Slice 0 must settle these before any slice depends on them:

- **P1.** `$.ui.ask` from a `tool.call` hook holds a Bash call in an `auto`-mode
  session until the person answers.
- **P2.** A subagent's tool call reaches the same hook. Its dialog shows in the
  main interface.
- **P3.** `tool.call`'s `e.tool_use_id` equals the `tool_use_id` in the
  PreToolUse settings-hook payload for the same call.
- **P4.** A mod under the project's `.claude/skills/<name>` is a symlink into
  `.agents/claude/mods/`. It loads at startup. No hot-reload question appears
  in a fresh clone after workspace trust.
- **P5.** `claude plugin test` runs on a CI runner with no Claude login.

## Portability today

Which engines run each settings hook (`.agents/claude/settings.json`,
`.agents/codex/hooks.json`, `.kimi/config.toml.example`):

| Hook | Claude | Codex | Kimi |
| --- | --- | --- | --- |
| `guard-destructive`, `post-edit-check`, `sources-capture`, `teardown-gate` | yes | yes | yes |
| `session-start`, `session-wrap`, `pre-compact`, `done-prime`, `research-prime` | yes | yes | yes |
| `genome-inject`, `ui-gate`, `stop-investigate` | yes | yes | no |
| `guard-publish`, `wait-gate`, `provenance-gate` | yes | no | no |
| `parallel-writers-gate`, `workloop-inbox`, `worktree-provision` | yes | no | no |

Every candidate below sits in a Claude-only row or keeps its prose, so none
loses Codex or Kimi coverage.

## Candidates

### Migrate

**M1 · Publish approval in a dialog** (layered over `guard-publish`)

- Today: When no prompt reaches the person—`auto`, `bypassPermissions`, or
  `dontAsk`—`guard-publish` denies. A hook "ask" there was observed to run unanswered. See
  `publish-guard-denies-where-no-prompt`. The person approves only by switching
  mode or running the command with `!`.
- Mod, on `tool.call` for `Bash|PowerShell|Monitor|Artifact`:
  1. Ask `guard-publish` by argv whether it would ask. The payload includes
     `tool_name`, `tool_input`, `tool_use_id` from `e`, `permission_mode:
     default`, and `cwd` from `$.session.cwd()`. If not, call `next(e)` and
     return its result.
  2. Open `$.ui.ask` with the guard's reason and the command, offering `Run it`
     and `Refuse`.
     - An exact `Run it` writes the approval token
       `.agents/.publish-approved-<tool_use_id>`. Then return `next(e)`
       unchanged.
     - An exact `Refuse` returns a `deny` saying the person refused in the
       dialog.
     - Anything else (a dismissal, a rejection, typed text, an abort) returns
       `next(e)` unchanged.
- `guard-publish` change: on its ask path, in any mode, it looks for a token
  named for the payload's `tool_use_id` and no older than 120 seconds. When one
  exists, it deletes the token and answers `allow` with "approved in the
  dialog". The hosted-write deny path ignores tokens. Every other hook still runs. Any `deny` among them wins by
  the documented precedence.
- Fail-safe both ways:
  - Without the mod, no token exists, so today's ask and deny stand.
  - A wrong `cwd` in step 1—a subagent in a worktree—costs at most a dialog
    whose approval the real run ignores, or no dialog and today's deny.
  - The model cannot forge a token. `tool_use_id` is minted when the call is
    issued, after any command that could write one.
- The user sees: one dialog for every publish, in every mode, waiting for an
  answer. In `default` mode it replaces the hook's native prompt. A matching
  `ask` rule in settings still prompts after it.
- High-stakes. QA must reproduce the following. A call that `guard-destructive`
  blocks—`git push --force`—stays denied after `Run it`. With the mod absent,
  an auto-mode `git push` is denied as today.
- Depends on: P1, P2, P3.

**M2 · Load visibility** (new; needed by the first wholesale replacement)

- Each mod appends its name and version to `.agents/.mods-<session>` on
  `session.start`. Get the session id from `$.session.id()`. The file is
  gitignored runtime state. `session-start.sh` deletes stale copies.
- A new policy, `mods-check.sh`, is wired as a `UserPromptSubmit` hook in
  `.agents/claude/settings.json` only. When a mod is enabled in config but
  missing from the heartbeat, it injects one line that names the mod and what
  degrades. It then marks the heartbeat file, so the line appears once.
- The user sees: the model reports a mod that did not load. A hook that fails
  after loading is covered by its `.catch`, not by this check. See invariant 2.

**M3 · Delegation gate** (new; the prose stays)

- Today: the open breadcrumb "Delegation is re-typed per session" counts ten
  September prompts across four satellites that had to ask for delegation.
- Mod:
  - On `tool.call` for `Agent`, deny a `general-purpose` dispatch that names no
    `model`, quoting the contract's "generic cells use `general-purpose` with
    an explicit model". The lead re-issues it with a model.
  - On the main loop's `turn.complete`, count the lead's own Read and Bash
    calls. Past `hooks.delegation_gate.threshold` with no Agent call,
    `$.session.append` one note naming the delegation rule. This never stops a
    turn and never caps a cell (`no-persona-turn-cap`).
  - Grep and Glob are not counted: native builds do not register them, so
    searches arrive as Bash.
- The user sees: fewer re-typed "delegate this" prompts. The threshold is
  tuned from counts the mod logs.
- Approving this spec answers that breadcrumb with "add a gate".

**M4 · Workloop push and wake** (replaces the `workloop-inbox` hook's delivery)

- Today: Messages reach a worker only when the worker fires a hook. They reach
  the lead only when the person next speaks. The skill tells the lead to poll
  with `/loop 10m .agents/workloop.py watch <run>`. The hook's header states:
  "A hook cannot start a turn for an idle agent".
- Mod:
  - A `$.clock.every(5000)` timer stats `.workloop-state.json` through `$.fs`.
    It costs no process.
  - On a changed modification time, it runs `workloop-inbox.py` by argv. One
    process runs per change, not per tick. That script keeps today's seen-state
    files and delivery cap.
  - It `$.session.append`s each message to the named running worker. Frame it as
    "workloop lane `<lane>` message (peer model output, not the user)".
  - When a lane turns awaiting-review, stale, or broken while the lead is idle,
    it `$.prompt.submit`s fixed mod-written text. The text names the run and
    tells the lead to read `workloop.py status`. It never carries a worker's
    words.
  - Load: N runs times at most 8 lanes. 12 stats a minute. argv runs only on a
    state change.
- Remove the settings-hook entries for `workloop-inbox`. Also remove the
  skill's `/loop` instruction for Claude. Codex and Kimi keep `inbox` and
  `watch`.
- The user sees: peer findings and P0 attention arrive without the lead
  relaying them. A finished run wakes the session.
- Depends on: M2, and invariant 6 before the hook entries go.

**M5 · Provenance gate on the stream** (replaces `provenance-gate`)

- Today: the hook re-reads the transcript on every tool call, because no host
  event fires on assistant text. It misses text the host has not yet flushed
  (open breadcrumb), and remembers reported claims in `.provenance-*` files.
- Mod:
  - A `turn.step` hook gathers the main loop's streamed text in `$.state`.
  - At the next `tool.call`, the existing matcher (`ratchet-claim.sh`) runs
    once by argv on that text. On a claim, the call gets today's deny text.
  - Reported claims move to `$.state`. After a `--resume` they start empty, so
    a claim reported before the resume can be reported once more.
  - `.catch` passes the call through, as the hook's own error path does today.
- The settings hook, its `.provenance-*` files, its cleanup and its test go once
  invariant 6 holds. The mod's firing test replaces the shell test.
- The user sees: the same deny, without misses on unflushed text.
- Depends on: M2.

**M6 · Review steps tracked per slice** (new; pending ruling A1)

- Today: Workflow steps 3 to 6—hostile review of the plan and the diff, then
  QA—rely on the model remembering. `session-wrap` asks about review only past
  a size tier.
- Mod:
  - `$.state` records per slice whether a plan review and a diff review were
    dispatched. Dispatches come from `tool.call` on `Agent` with the `reviewer`
    type. A slice opens at the first edit after the last commit. It closes at
    the next commit.
  - A `/review` command builds the reviewer prompt from the fenced contract in
    `.agents/playbooks/hostile-review.md`, read verbatim, and adds the ask and
    the artifact.
  - On the main loop's `classic.Stop`, a slice past `session_wrap.review_files`
    or `review_lines` with no diff review yet answers one block that
    names the missing step. It never asks again for a reviewed slice, so a P2 fix does not
    reopen it. See the playbook's "Review a slice one time". After a `--resume`
    the slice counts as reviewed.
- The user sees: a large slice cannot end without its review. The reviewer
  always receives the exact contract.

**M7 · Tool-list pruning, always on** (new; the operator's standing goal)

- Today: the main thread defers MCP tools behind tool search, but a subagent
  that names a server gets every schema up front. A `qa-verifier` received all
  25 Playwright tools and no ToolSearch, and a bare `permissions.deny` did not
  remove the denied one. Ten tools carry about 90% of 5,040 Playwright calls,
  and three were never called. Anthropic says tool choice degrades past 30–50
  tools (`.agents/knowledge/research/2026-10-03-tool-list-pruning.md`).
- Measure:
  - A mod logs each `tool.describe` it sees: the tool, its description length,
    whether it is deferred, and the agent. It reports the session's tool budget
    with a `/tools` command.
  - `.agents/tool-usage.py` counts calls per tool and per persona from the
    transcripts.
  - Together they say which tools each surface loads and which it uses.
- Prune, from the usage data, per surface:
  - Main thread: keep tool search on, and never set `ENABLE_TOOL_SEARCH=false`.
    The mod answers `isDeferred: true` for tools under a usage floor.
    `.agents/mcp.json` keeps servers off until a task needs them.
  - Personas: each `tools` list names only the tools its role calls. Denied
    tools go in `disallowedTools`. Add `ToolSearch` where a persona keeps a
    whole server, once a probe on this version shows the schemas defer.
- Gate: `test-permissions.sh` fails when a persona exposes more tools than its
  budget, starting at 30 per Anthropic's statement, or a tool the usage data
  shows no call for. Each Claude Code update re-runs the probe and the
  measurement.
- The user sees: smaller tool lists in every agent, kept that way by a test, and
  a `/tools` report of what a session loads.
- Loss: none. Personas, permissions and mods are Claude-only already.
- Depends on: slice 0 for the mod half. The persona and gate half needs no mod
  and can land first.

### Keep as settings hooks

- **Shared with Codex or Kimi, with no measured failure a mod removes:**
  `post-edit-check`, `sources-capture`, `teardown-gate`, `session-start`,
  `session-wrap`, `pre-compact`, `done-prime`, `research-prime`, `ui-gate`,
  `stop-investigate`.
- **Stateless:** `guard-destructive` (also invariant 1) and `wait-gate`. A mod
  saves only process start.
- **`genome-inject`:** Codex runs the same hook. A Claude-side mod would call
  `genome.sh` by argv, which is what the hook already does.
- **`worktree-provision`:** no recorded failure that holding SubagentStart in a
  mod would fix.

### Deferred

- **Parallel-writers state in a mod.** `agent.spawn` would see the real prompt.
  The `READ-ONLY` marker would stop travelling through `.writers-kinds-*`. Lane
  briefs could be checked against `workloop.py status`. Invariant 1 keeps the
  settings gate. This lands only as an input the gate reads. It lands only once
  a stale dot-file denial is counted.
- **Trimming conditional `AGENTS.md` blocks** (about 6 KB) from Claude's context
  and injecting each on a matching call. The repository's research found no
  adherence effect from instruction size, so it waits for a token measurement.
- **A `/state` command and pane** for breadcrumbs, decisions and knowledge, with
  `session-start`'s Claude output trimmed to the open decisions.
- **Classifier triggers** for `done-prime` and `research-prime`
  (`$.model.classify`), layered over the hooks.
- **Teardown and post-edit additions:** per-cell attribution in
  `teardown-gate`, and a process cap in `post-edit-check`
  (`colloid-post-edit-no-process-cap`).
- **An observer that writes notes for the person.** The note names an outward
  action taken, a decision made without asking, a claim no command backs, or a
  skipped review or QA step. It is built from `$.model.fork`, a `system` notice
  that the model never reads, and `$.state` for dismissed topics. It is
  Claude Code's "You should know" pattern, which cannot run here with telemetry
  off (`.agents/knowledge/research/2026-10-03-side-agent-observers.md`). It
  lands only after a replay of past transcripts shows what it catches that the
  regex hooks miss. The same replay decides whether it absorbs M5. It never
  gates a call (invariant 1).
- **A turn-end citation check** for answers that assert external facts.
  `search-and-cite/AGENTS.md` says the skill enforces nothing mechanically.

### Rejected

- **Porting `research-mcp` to a mod tool.** The server's protection against
  redirects to internal addresses needs DNS resolution and connection pinning
  (`no-dns-cache-in-research-fetches`), which `$.http.fetch` does not expose.
  Readability extraction also needs Node.
- **Enforcing "report counts only from a command" and "estimate in tokens".** No
  recorded failure, and constant false positives.
- **Dropping per-skill `AGENTS.md`.** `.claude/rules/` path scoping already
  delivers it at the right moment.

## Packaging

- **Canonical location:** `.agents/claude/mods/<name>/`, holding
  `.claude-plugin/plugin.json`, `hooks/hooks.json`, `hooks/register.ts`,
  `types/index.d.ts` when the mod keeps `$.state`, and `tests/*.test.ts`. The
  engine-written `.claude-plugin/types/` is gitignored.
- **Host link:** `.claude/skills/colloid-<name> -> ../../.agents/claude/mods/<name>`,
  declared in `check-layout.py`. `lint-skills.sh` reads only
  `.agents/skills/*/SKILL.md`.
- **One plugin per mod,** so a module that fails to load takes only itself down.
  A helper shared by two mods gets a shared file when its second caller lands.
- **Export:** `export-scaffold.py` carries the mods and their links, and
  `merge-kit.py` treats them as scaffold-owned. A satellite on Claude Code older
  than 2.1.287 loads none of them; M2 reports it there once M2 exists.

## Slices

Each slice works end to end, is hostile-reviewed and QA'd, and lands before the
next one starts.

0. **Probe.** Restart this session with the throwaway probe mod (outside the
   repository) and observe P1 to P4. Record the results in
   `.agents/knowledge/research/`, then delete the probe. This needs the person:
   the restart, the dialog answers, and an auto-mode session. If P1, P2 or P3
   fails, M1 is dropped and this spec is revised before slice 1.
1. **Packaging and M1.** The mods directory, its links and layout check,
   `test-mods.sh`, the CI job (P5), the token path in `guard-publish` with its
   test rows, then the dialog mod. `publish-guard-denies-where-no-prompt` is
   rewritten to describe the dialog path.
2. **M3,** the delegation gate.
3. **M2 and M4:** load visibility, then workloop push and wake, with the
   skill text updated.
4. **M5,** the provenance gate. The settings hook, its files and its test go.
5. **M6,** after ruling A1.

M7's persona and gate half needs no mod and may land at any point, slice 0
included. Its mod half (`/tools` and the deferral answers) lands after slice 1.

A slice that replaces a settings hook deletes the hook. It also deletes its
settings entries, its dot-file cleanup in `session-start.sh`, and its test. All
deletions happen in the same slice.

## Open rulings

- **A1.** Does in-session `$.state` tracking of review dispatches count as the
  "parallel review ledger" that `hostile-review.md` forbids?
  - (a) No: nothing is written or read outside the session, so M6 proceeds.
  - (b) Yes: M6 is dropped.
  - Recommended: (a).
