---
applyTo: '.agents/skills/seo-geo-growth-audit/**,.claude/skills/seo-geo-growth-audit/**'
paths:
  - '.agents/skills/seo-geo-growth-audit/**'
  - '.claude/skills/seo-geo-growth-audit/**'
---

# Seo-Geo-Growth-Audit Skill Rules

## Business Invariants
- `scripts/quick-audit.sh` is an evidence baseline, not a gate. Findings must never change its exit code. It must exit 0 when the audit ran and exit 2 only on a usage error.
- Check IDs (`TS-`, `SD-`, `GE-`, `PF-`, `AA-`, `CS-`, `PS-`, `LC-`) are the join key across `quick-audit.sh`, the `references/*.md` files, and the report template. If you rename or add an ID, you must update all three and the reference index.

## Abnormal Cases and Rationale
- None recorded yet.

## Out of Scope
- Do not restate `SKILL.md` usage instructions. This file governs edits to the skill.
