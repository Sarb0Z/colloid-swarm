---
applyTo: '.agents/skills/thermo-nuclear-code-quality-review/**,.claude/skills/thermo-nuclear-code-quality-review/**'
paths:
  - '.agents/skills/thermo-nuclear-code-quality-review/**'
  - '.claude/skills/thermo-nuclear-code-quality-review/**'
---

# Thermo-Nuclear-Code-Quality-Review Skill Rules

## Business Invariants
- Keep the `description` naming the phrases that should reach this skill — "thermo-nuclear", "thermonuclear", "deep code quality audit", "harsh maintainability review". The description is the only routing signal, so a phrase missing from it is a phrase that never arrives.
- Keep the approval bar strict. This is the harshest and most expensive review in the set; softening it removes the reason to have a separate skill at all.

## Abnormal Cases and Rationale
- None recorded yet.

## Out of Scope
- Do not restate `SKILL.md` usage instructions. This file governs edits to the skill.
