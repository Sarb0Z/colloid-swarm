# OpenCode adapter

`.opencode/opencode.json` and `.opencode/instructions/colloid.md` are generated
by `.agents/mcp.py` and gitignored, like the Codex and Kimi connection files.
They appear on the first `python3 .agents/mcp.py sync`.

`.agents/mcp_opencode.py` renders them from the harness's own sources:

| OpenCode field | Source |
| --- | --- |
| `permissions` | `.agents/claude/settings.json` — `permissions.ask`, then `.deny` |
| `agents` | `.agents/personas/*.md` |
| `mcp.servers` | `.agents/mcp.json`, enabled servers only |
| `instructions` | the body of `.agents/claude/output-style.md` |

## What OpenCode reads without an adapter

- `AGENTS.md` at the project root, plus `.agents/AGENTS.md` once the agent
  explores that subtree. V2 reads `AGENTS.md` only and does not fall back to
  `CLAUDE.md`.
- Skills from `.agents/skills` and `.claude/skills`, which V2 searches as
  project compatibility sources.
- `~/.claude/CLAUDE.md`, because the user's own settings name it in
  `instructions`. That is a per-machine choice, not this repository's.

## Rules

The translation is mechanical, and `test-opencode.sh` holds it in both
directions. `Bash(prefix:*)` becomes `shell` / `prefix *`; a bare
`Bash(command)` stays exact; `mcp__server` becomes `server_*`, and
`mcp__server__tool` becomes `server_tool`. OpenCode takes the last matching
rule, so every deny is emitted after every ask; that reproduces Claude's
deny-over-ask precedence. `Artifact` names a Claude tool with no counterpart
here and is dropped.

An MCP name keeps letters, digits, `_` and `-`; any other character becomes
`_`, which is how OpenCode names a tool. A `${NAME}` credential in an
environment value or header becomes `{env:NAME}`. A remote URL carrying a
placeholder fails the render, because OpenCode does not expand one there.

## Agents

Each persona becomes a `subagent` whose `system` is the persona body and whose
`permissions` reproduce its tool grant. OpenCode's base policy allows every
action, so each agent opens with a deny and then allows the tools the persona
names — an explorer cannot edit, and a reviewer's `Bash` grant comes back. The
global ask and deny rules follow for the actions that agent holds, so a
persona with `Bash` still meets the outward-mutation ask; a persona without it
gets no shell rule at all. `disallowedTools` and `mcpServers` narrow the grant
further. `TaskStop` has no OpenCode action and is dropped.

`model` is left unset, so a subagent inherits the session's model: OpenCode
requires a `provider/model` id, and pinning one would fail on a machine that
never authenticated that provider.

## Known gaps

- The hook policies do not run. The generated `permissions` carry the outward
  ask list, but `guard-destructive.sh` and `denied-tool.sh` have no
  counterpart, and neither does the parser coverage in `guard-publish.sh`
  for shapes a prefix rule cannot state. The post-edit, UI, provenance, and
  workloop gates are also absent. Their events and payloads are Claude's, so a
  plugin is its own unit.
- `.agents/rules/*.md` are path-scoped for Claude and Copilot. OpenCode has no
  path-scoped instruction, so they are not loaded; listing them in
  `instructions` would apply every stack's rules to every session.
- An SSE server is left out of `mcp.servers`: OpenCode's remote transport is
  Streamable HTTP. `atlassian` is the registry entry affected.
- A fresh worktree has no `.opencode/` until `mcp.py sync` runs there, the same
  as `.codex/config.toml`.
- An untranslatable permission rule or a persona without a `tools` list fails
  `mcp.py sync` before any host file is written. The other hosts stay as they
  were rather than running a half-rendered set.
