---
applyTo: '.agents/**'
paths:
  - '.agents/**'
---

# Agent Scaffold Rules

## Business Invariants
- `.agents/` is the canonical home for agent configuration. Edit files here, never through a `.claude/` symlink mirror.
- Transient ledgers (`.genome-ledger`, `.mutagen-ledger`, `.sources-ledger`, `.wrap-state-*`, `.compaction-pending`) are runtime state. They are gitignored and must not be edited by hand.
- `config.json` is per-repo local. It is gitignored; tune `config.json.example` instead. Tooling writes to it (`sync-mcp.sh` persists MCP toggles), so it is mutable local state, not a source.
- Commit generated output only when all three hold: every input is tracked, generation is deterministic, and the output holds nothing machine-local. `.codex/agents/*.toml` and `.claude/agents/*.md` qualify, because their personas are tracked. `.mcp.json`, `.kimi-code/mcp.json`, and `.codex/config.toml` do not, because they derive from the gitignored `config.json`. Ledgers, `.tsbuildinfo-claude`, and `settings.local.json` never qualify. Where output stays out of the tree, its source must be in the tree with one command that rebuilds it — `sync-claude-agents.sh`, `sync-mcp.sh`, `sync-codex.sh`.
- Every skill obeys the Agent Skills format: `name` within 64 chars and matching its directory, `description` within 1024 chars and in third person, `SKILL.md` body within 500 lines, reference files linked only from `SKILL.md` and carrying a `## Contents` past 100 lines. `.agents/lint-skills.sh` is the enforceable statement of these rules and the lint gate runs it on every skill edit — read the script rather than restating the limits in a skill's own `AGENTS.md`.

## Abnormal Cases and Rationale
- Skills and hooks are read through symlinks by Claude Code. A broken symlink means a missing canonical file, not a missing symlink.

## Out of Scope
- Do not restate the layout table in `.agents/README.md`. This file governs invariants, not inventory.
