---
applyTo: '.agents/**'
paths:
  - '.agents/**'
---

# Agent Scaffold Rules

## Ownership

- `.agents/` is canonical. Host paths are static adapters or symlinks; never edit through a symlink.
- Runtime ledgers (`.sources-ledger`, `.wrap-state-*`, `.compaction-pending`) are gitignored state.
<!-- colloid-only -->
- `.genome-ledger` and `.mutagen-ledger` are runtime state on the same terms.
<!-- /colloid-only -->
- `config.json.example` defines hook defaults. `config.json` is the ignored per-repository override.
- `mcp.json` is the MCP registry and its project state. Change it through `python3 .agents/mcp.py enable|disable <name>` when possible; commit intentional state changes.
- `personas/*.md` are Claude-native definitions and `.claude/agents/*.md` links to them. `.codex/agents/*.toml` are static Codex definitions. Model/effort is explicit in those files, not generated from a tier registry.
- `check-layout.py` verifies scaffold-owned links. It never creates, rewrites, or prunes operator files.

## Editing contracts

- Keep the scaffold small. Add a generator only when a real artifact cannot be represented directly or linked.
- A persona is a cached hot path, not the only legal subagent. Give it only the tools, skills, MCP servers, hooks, and memory its role repeatedly needs.
- Claude persona configuration belongs in YAML frontmatter. Codex model and effort remain invocation-time controls; its TOML description states the exact dispatch.
- Every skill follows Agent Skills format and carries `AGENTS.md`; `lint-skills.sh` is the authority for its enforceable limits.
- Put load-bearing skill instructions first: compaction may retain only the beginning of long skills.
- A hook policy ships with a direct firing test. Prefer testing observable behavior over mutation machinery that tests the test harness.
- Hook payloads travel on stdin. Keep adapters thin and shared behavior in `hooks/policy/` or `hooks/lib/`.
- Repository-owned MCP bundles under `mcp-servers/*/dist/` are committed because clients launch them before any install or build. Run each server's bundle check after source changes.
- A stack pack declares both `paths:` and `detect:`. This repository carries all packs; an export drops `stack_packs.carrier`, and each target deletes packs its codebase does not use.

## Hierarchical instructions

Read the nearest `AGENTS.md` before editing a subtree. Canonical scoped files use both `applyTo:` and `paths:` frontmatter: Copilot and Claude consume those keys, while Codex and Kimi read the file as ordinary instructions.

| Scope | Canonical |
| --- | --- |
| Scaffold | `.agents/AGENTS.md` |
| Claude adapter | `.agents/claude/AGENTS.md` |
| Skill | `.agents/skills/<name>/AGENTS.md` |
| Path or stack rule | `.agents/rules/<name>.md` |

<!-- colloid-only -->
| Scope | Canonical |
| --- | --- |
| Demo | `demo/AGENTS.md` |
| Tensium trial | `tensium-trial/AGENTS.md` |
<!-- /colloid-only -->

Fan-out is by symlink:

- Copilot: `.github/instructions/*.instructions.md` to canonical files.
- Claude: layer `CLAUDE.md` to sibling `AGENTS.md`; `.claude/skills/*`, `.claude/agents/*`, and `.claude/rules/*` to `.agents/`.
- Codex: `.codex/hooks.json` and hook adapter links; persona TOMLs stay host-native because Codex does not consume Claude frontmatter.

A skill `AGENTS.md` governs editing the skill; `SKILL.md` governs using it. A file under `rules/` governs product code matching its globs.

## Verification

Run the narrow checks for the surface changed:

```sh
python3 .agents/check-layout.py
.agents/lint-skills.sh
.agents/test-session-start.sh
.agents/test-mcp.sh
.agents/test-codex.sh
```

Use `export-scaffold.py` only from a reviewed commit. It reads Git, not the working tree.
