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

Repository-owned servers under `mcp-servers/` ship committed `dist/` bundles so
clients can launch from a clean clone. After changing their source, run that
server's `npm run build` and `npm run check`.

## Hooks

Policies read normalized JSON from stdin. Host adapters translate event names
and payload shapes; they do not own behavior. `config.json.example` contains
hook defaults and ignored `config.json` may override them per repository.

Codex hashes hook declarations. After changing `.agents/codex/hooks.json` or a
Codex hook command, inspect it and run:

```sh
python3 .agents/codex/trust-hooks.py "$(pwd)"
```

## Parallel work

For a durable, parallel implementation/review cycle, use the `workloop` skill
and `.agents/workloop.py`. It holds lane ownership, evidence, review references,
attention acknowledgements, and the QA completion gate in ignored runtime state.
The controller is portable and exports with the scaffold; it prepares prompts
but does not attempt host-specific agent dispatch.

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
python3 .agents/test-guard-destructive.py
python3 .agents/test-guard-publish.py
.agents/test-mcp.sh
.agents/test-codex.sh
.agents/test-export.sh
```

`test-codex.sh` reports whether the installed Codex binary loaded the project
MCP configuration; syntax checks alone do not prove runtime discovery.

<!-- colloid-only -->
## Export

`export-scaffold.py` reads Git, removes repository-only genome and research
artifacts, and emits canonical plus host-native paths. Run it only from the
reviewed commit intended for transplant. The target-specific procedure is in
`export/README.md`.
<!-- /colloid-only -->
