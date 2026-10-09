---
applyTo: '.agents/skills/seo-geo-growth-audit/**,.claude/skills/seo-geo-growth-audit/**'
paths:
  - '.agents/skills/seo-geo-growth-audit/**'
  - '.claude/skills/seo-geo-growth-audit/**'
---

# Seo-Geo-Growth-Audit Skill Rules

## Business Invariants
- `scripts/quick-audit.sh` is an evidence baseline, not a gate. Findings must never change its exit code. It must exit 0 when the audit ran and exit 2 only on a usage error.
- `scripts/test-quick-audit.sh` drives every live and static file check against a local server and fixture repositories; run it after any change to `quick-audit.sh` (it needs `python3` and `curl`).
- Check IDs (`TS-`, `SD-`, `GE-`, `PF-`, `AA-`, `CS-`, `PS-`, `LC-`) are the join key across `quick-audit.sh`, the `references/*.md` files, and the report template. If you rename or add an ID, you must update all three and the reference index.
- A live file check (robots.txt, sitemap, llms.txt) passes only a non-empty `200` whose body is not an HTML page, warning when the content is right but labelled `text/html`; each sitemap-index child must answer `200` without an HTML content type; a sitemap must list at least one page `<loc>`. A single-page app's catch-all answers every path `200` with its index page, so a status-only check passes a site that serves none of those files.
- A static check counts robots.txt and sitemap XML as shipped only under a `public/` or `static/` directory, unless the repository has neither; a copy elsewhere is a WARN, because the build never publishes it.

## Abnormal Cases and Rationale
- None recorded yet.

## Out of Scope
- Do not restate `SKILL.md` usage instructions. This file governs edits to the skill.
