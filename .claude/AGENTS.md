---
applyTo: '.claude/**'
paths:
  - '.claude/**'
---

# Claude Adapter Layer Rules

## Business Invariants
- `.claude/` mirrors canonical content owned by other subtrees. Never write content directly into a `.claude/` file that is a symlink. Edit the canonical target instead.

## Abnormal Cases and Rationale
- `settings.local.json` is per-operator local config. It is gitignored and must not be committed.

## Out of Scope
- Do not document Claude Code settings semantics here. Tool documentation owns that.
