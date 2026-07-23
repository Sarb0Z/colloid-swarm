---
applyTo: '.agents/skills/thermo-nuclear-code-quality-review/**,.claude/skills/thermo-nuclear-code-quality-review/**'
paths:
  - '.agents/skills/thermo-nuclear-code-quality-review/**'
  - '.claude/skills/thermo-nuclear-code-quality-review/**'
---

# Thermo-Nuclear-Code-Quality-Review Skill Rules

## Business Invariants
- Keep `disable-model-invocation: true` in the frontmatter. This review is opt-in only. It is the strictest and most expensive review and must never auto-trigger.

## Abnormal Cases and Rationale
- None recorded yet.

## Out of Scope
- Do not restate `SKILL.md` usage instructions. This file governs edits to the skill.
