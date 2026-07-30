---
applyTo: '.agents/skills/scalability-audit/**,.claude/skills/scalability-audit/**'
paths:
  - '.agents/skills/scalability-audit/**'
  - '.claude/skills/scalability-audit/**'
---

# Scalability-Audit Skill Rules

## Business Invariants
- Keep the skill stack-agnostic. The laws hold for any runtime. Write "background job", not a named queue library; "cache or lock store", not a named product. A stack-specific enforcement rule belongs in that repo's scoped `AGENTS.md`, not here.
- Do not carry another system's incident figures. The laws generalise; the evidence does not. A number here dates the skill, which is Law 2 turned on itself.
- Keep the detection question on every law. A law without one is a slogan and cannot be audited against.

## Abnormal Cases and Rationale
- The frontmatter omits `disable-model-invocation` on purpose. The hostile-review hunt list hands off to this skill, so an agent must be able to invoke it.

## Out of Scope
- Do not restate `SKILL.md` usage instructions. This file governs edits to the skill.
- Do not duplicate the axes in `.agents/playbooks/review-axes.md`. Those carry the compressed detection questions for a diff; this skill carries the sweep for a system.
