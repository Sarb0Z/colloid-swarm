---
applyTo: '.agents/skills/mobile-responsive-web/**,.claude/skills/mobile-responsive-web/**'
paths:
  - '.agents/skills/mobile-responsive-web/**'
  - '.claude/skills/mobile-responsive-web/**'
---

# Mobile-Responsive-Web Skill Rules

## Business Invariants
- The `references/` are tuned to a Next.js + React + Tailwind + Framer Motion + shadcn/ui stack. When adding a rule, mark it stack-specific (a Tailwind class, a shadcn component) versus universal (a viewport unit, a Core Web Vitals budget), so a different-stack repo can tell what transfers.

## Abnormal Cases and Rationale
- None recorded yet.

## Out of Scope
- Do not restate `SKILL.md` usage instructions. This file governs edits to the skill.
