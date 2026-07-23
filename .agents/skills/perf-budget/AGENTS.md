---
applyTo: '.agents/skills/perf-budget/**,.claude/skills/perf-budget/**'
paths:
  - '.agents/skills/perf-budget/**'
  - '.claude/skills/perf-budget/**'
---

# Perf-Budget Skill Rules

## Business Invariants
- The baseline must never update automatically. A regression must be acknowledged by the user.
- Verdict `broken` (hard-cap violation) must block the merge. Verdict `regressed` warns; the lead decides.
- Lanes, measure commands, and budgets must come from repo-local config. Do not hardcode a package manager or directory layout. If the config is missing, infer lanes from the repo shape and persist the config first.

## Abnormal Cases and Rationale
- A missing baseline triggers establish-baseline mode: measure, write the baseline, gate nothing. Metrics without a baseline are noise.

## Out of Scope
- Do not restate `SKILL.md` usage instructions. This file governs edits to the skill.
