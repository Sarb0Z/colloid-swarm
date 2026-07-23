---
applyTo: '.agents/**'
paths:
  - '.agents/**'
---

# Agent Scaffold Rules

## Business Invariants
- `.agents/` is the canonical home for agent configuration. Edit files here, never through a `.claude/` symlink mirror.
- Transient ledgers (`.genome-ledger`, `.mutagen-ledger`, `.sources-ledger`, `.wrap-state-*`, `.compaction-pending`) are runtime state. They are gitignored and must not be edited by hand.
- `config.json` is per-repo local. It is gitignored; tune `config.json.example` instead.

## Abnormal Cases and Rationale
- Skills and hooks are read through symlinks by Claude Code. A broken symlink means a missing canonical file, not a missing symlink.

## Out of Scope
- Do not restate the layout table in `.agents/README.md`. This file governs invariants, not inventory.
