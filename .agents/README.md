# Agent scaffold

`.agents/` owns the tool-neutral contracts. Host directories contain static
symlinks, adapters, or host-native persona files; they are not generated from a
second model registry.

## Ownership

| Canonical | Claude | Codex | Kimi |
| --- | --- | --- | --- |
| root `AGENTS.md` | `CLAUDE.md` link | native | native |
| `personas/*.md` | `.claude/agents/*.md` links | `.codex/agents/*.toml` static roles | generic dispatch |
| `skills/*` | `.claude/skills/*` links | native discovery | native discovery |
| `rules/*.md` | `.claude/rules/*` links | nearest `AGENTS.md` only | nearest `AGENTS.md` only |
| `hooks/policy/*` | Claude adapter | Codex adapter | Kimi adapter |
| `mcp.json` | `.mcp.json` | `.codex/config.toml` | `.kimi-code/mcp.json` |
| `lsp.json` | Claude plugins | none | none |

Run `python3 .agents/check-layout.py` after changing a persona, skill, rule, or
host link. It validates scaffold-owned links and leaves operator files alone.

## Personas and delegation

Personas are common paths, not a dispatch allowlist:

- `explorer` and `mechanic`: Haiku / Luna low
- `implementer`, `qa-verifier`, and `researcher`: Claude Sonnet 5 / Terra medium
- `reviewer`: Claude Opus 5 / Sol high
- `learning-reporter`: caller-selected; no dispatch default

Claude configuration lives in each persona's YAML frontmatter. Codex TOMLs
state the exact model and effort the caller passes at dispatch because Codex
does not consume Claude's per-agent tools, MCP, skill, memory, or hook fields.
Use a generic cell when no persona fits, with only the task's needed context and
capabilities.

## MCP state

`.agents/mcp.json` contains each server, description, and project `enabled`
state. Defaults are `context7`, `playwright`, and `research-mcp`; everything
else is off until requested.

This is a manual state-change command over the small project registry, not a
scheduled path. Run it when the registry or host state changes and at transplant.

```sh
python3 .agents/mcp.py
python3 .agents/mcp.py enable appium-mcp
python3 .agents/mcp.py disable appium-mcp
```

The tool writes host-native project files and preserves unrelated Claude local
settings. `enable` and `disable` change the tracked registry directly. Restart
the session after a state change because MCP clients connect at startup.

Disabled Codex records remain present to mask same-name user records. Unknown
user or plugin server names still merge normally; project config is not a
machine-wide allowlist. `codex_enabled: false` omits a provider-incompatible
record.

`sources` names the tools whose calls produce a source the provenance ledger
must record — a tool list, or `["*"]` for a server with no distinctive tool
name. `sources-matcher.py` builds every host's `sources-capture` hook matcher
from those declarations, so a server cannot be enabled without its capture
following it. Run it after changing a `sources` key; `--check` fails on drift
and `test-sources-matcher.py` gates it.

Repository-owned servers under `mcp-servers/` ship committed `dist/` bundles so
clients can launch from a clean clone. After changing their source, run that
server's `npm run build` and `npm run check`.

## Hooks

Policies read normalized JSON from stdin. Host adapters translate event names
and payload shapes; they do not own behavior. `config.json.example` contains
hook defaults; a repository states its own policy in the tracked
`policy.json` — a hook it runs without, the scripts its publish guard must ask
about under `hooks.guard_publish.outward_commands` — and an operator's ignored
`config.json` overrides either per machine.

`worktree-provision.sh` runs at subagent start under Claude only: a cell that
starts inside a linked worktree gets that worktree's dependencies installed by
`.agents/provision.sh` before its first turn, and a failed install blocks the
start. The session's own directory is never provisioned, so an operator who
launches from a worktree keeps their `node_modules`. A worktree whose
lockfile matches the session checkout's byte for byte links that checkout's
`node_modules` instead of installing (`hooks.worktree_provision.share`,
default on; measured here 1 s and 9 MB against 54 s and 262 MB), and drops
the link before any real install once its lockfile changes. Installs run with
lifecycle scripts off; `hooks.worktree_provision.allow_scripts` turns them on
for a repository whose native modules need a build step, at the cost of
executing whatever a branch's lockfile names with no prompt and outside every
`PreToolUse` guard. Codex's hook set is hash-trusted and its subagents share
the checkout, and Kimi's `SubagentStart` is observation-only and cannot block
a start; on both, parallel writers go through `workloop.py`, which provisions
each lane itself.

`workloop-inbox.sh` turns the controller's durable inbox into push: at
subagent start a cell hears its host agent id and claims its lane with it;
between tool calls it hears each unread message for that lane once; at every
prompt and at session start the lead hears which lanes await review, carry
attention, are stale or broken, and when a run is ready to integrate.
Delivery is remembered in `.agents/.inbox-seen-<session>-<agent>`; the toggle
is `hooks.workloop_inbox.enabled`.

`parallel-writers-gate.sh` is the rail that makes that the default rather than
a choice: on Claude it watches every `Agent` dispatch, lets the first writer of
a turn through, and denies a second writer while another is live — in the same
message or still running in the background — unless its prompt is a workloop
brief. The denial names the three commands that turn the dispatch into a lane.
It also denies the lead's own `Edit` or `Write` while an uncoordinated writer
is live and no workloop run is active. Read-only personas never count; a
generic cell declares itself read-only by starting its prompt with
`READ-ONLY`; an unknown persona counts as a writer. An edit whose every target
lies outside the checkout passes. State lives in
`.agents/.writers-live-<session>`, `.agents/.writers-turn-<session>` and
`.agents/.writers-kinds-<session>` (the writer types each turn dispatched,
which decides whether a started cell registers); `session-start.sh` clears
them at startup and resume, and deleting the live
file is the manual reset for a cell known to have died. The toggle is
`hooks.parallel_writers.enabled`.

Codex hashes hook declarations. After changing `.agents/codex/hooks.json` or a
Codex hook command, inspect it and run:

```sh
python3 .agents/codex/trust-hooks.py "$(pwd)"
```

## Parallel work

For a durable, parallel implementation/review cycle, use the `workloop` skill
and `.agents/workloop.py`. It holds lane ownership, evidence, review references,
attention acknowledgements, and the QA completion gate in ignored runtime state;
it creates and provisions each lane's worktree, refuses a claim whose lockfiles
moved since the install, leases named exclusive resources between lanes,
verifies the merged lanes once with `integrate`, and removes what it created
with `teardown` — worktrees, branches it has landed, and Docker resources
labelled with the run and lane. A lane whose worker stopped without
submitting has its labelled resources reaped at the lead's next prompt. The controller is portable and exports
with the scaffold; it prepares prompts but does not attempt host-specific agent
dispatch.

How many cells a host will run at once is adapter-owned, not a property of the
subscription. `.agents/codex/config.toml` states the Codex cap; see
`.agents/codex/README.md`. Kimi's `AgentSwarm` ramps concurrency with no upper
limit unless `KIMI_CODE_AGENT_SWARM_MAX_CONCURRENCY` is set, so it needs nothing
here to run wide.

## Skills, rules, and stack packs

A skill's `SKILL.md` governs use; its `AGENTS.md` governs edits. Path rules live
in `rules/`. `stack-*.md` files additionally declare `detect:` markers so a
target cannot silently keep guidance for a framework it does not run.

```sh
.agents/lint-skills.sh
python3 .agents/check-stack-packs.py
```

## Verification

```sh
python3 .agents/check-layout.py
.agents/lint-skills.sh
.agents/test-session-start.sh
.agents/test-workloop.sh
.agents/test-post-edit-check.sh
.agents/test-stop-investigate.sh
.agents/test-provenance-gate.sh
.agents/test-review-contract.sh
python3 .agents/lint-breadcrumbs.py
python3 .agents/test-sources-matcher.py
python3 .agents/test-guard-destructive.py
python3 .agents/test-guard-publish.py
.agents/test-mcp.sh
.agents/test-codex.sh
.agents/test-export.sh
python3 demo/check-inventory.py
```

`test-review-contract.sh` runs `review-harness/bin/extract-contract.sh --check`,
which fails when `contract.md` differs from a fresh extraction of
`hostile-review.md`. Run the same script without `--check` to regenerate it.

`test-codex.sh` reports whether the installed Codex binary loaded the project
MCP configuration; syntax checks alone do not prove runtime discovery.

<!-- colloid-only -->
## Export

`export-scaffold.py` reads Git, removes repository-only genome and research
artifacts, and emits canonical plus host-native paths. Run it only from the
reviewed commit intended for transplant. The target-specific procedure is in
`export/README.md`.
<!-- /colloid-only -->
