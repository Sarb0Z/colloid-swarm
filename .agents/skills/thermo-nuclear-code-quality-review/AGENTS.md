---
applyTo: '.agents/skills/thermo-nuclear-code-quality-review/**,.claude/skills/thermo-nuclear-code-quality-review/**'
paths:
  - '.agents/skills/thermo-nuclear-code-quality-review/**'
  - '.claude/skills/thermo-nuclear-code-quality-review/**'
---

# Thermo-Nuclear-Code-Quality-Review Skill Rules

## Business Invariants
- The skill is explicit-invocation-only: `disable-model-invocation: true` matches upstream and keeps the most expensive review in the set from firing on model discretion. The `description` names the trigger phrases — "thermo-nuclear", "thermonuclear", "deep code quality audit", "harsh maintainability review" — so the operator and docs know what to type; it does not route autonomously.
- Keep the approval bar strict. This is the harshest and most expensive review in the set; softening it removes the reason to have a separate skill at all.
- The body stays byte-identical to upstream (`cursor-team-kit/skills/thermo-nuclear-code-quality-review/SKILL.md`). Local edits orphan the copy from upstream updates; see `knowledge/research/2026-08-17-thermo-nuclear-skill-provenance.md` before proposing one.

## Abnormal Cases and Rationale
- None recorded yet.

## Out of Scope
- Do not restate `SKILL.md` usage instructions. This file governs edits to the skill.
