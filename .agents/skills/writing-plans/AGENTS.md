---
applyTo: '.agents/skills/writing-plans/**,.claude/skills/writing-plans/**'
paths:
  - '.agents/skills/writing-plans/**'
  - '.claude/skills/writing-plans/**'
---

# Writing-Plans Skill Rules

## Business Invariants
- This skill emits the plan document that `executing-plans` consumes. The header block and the checkbox (`- [ ]`) step format are a shared contract. If you change the format here, you must update `executing-plans` to match.

## Abnormal Cases and Rationale
- None recorded yet.

## Out of Scope
- Do not restate `SKILL.md` usage instructions. This file governs edits to the skill.
