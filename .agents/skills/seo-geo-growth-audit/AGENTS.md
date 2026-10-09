---
applyTo: '.agents/skills/seo-geo-growth-audit/**,.claude/skills/seo-geo-growth-audit/**'
paths:
  - '.agents/skills/seo-geo-growth-audit/**'
  - '.claude/skills/seo-geo-growth-audit/**'
---

# Seo-Geo-Growth-Audit Skill Rules

## Business Invariants
- `scripts/quick-audit.sh` is an evidence baseline, not a gate. Findings must never change its exit code. It must exit 0 when the audit ran and exit 2 only on a usage error.
- `scripts/test-quick-audit.sh` drives every live and static file check against a local server and fixture repositories, then runs `scripts/test-sample.sh`, which covers `sample.sh` and `analyze-pages.py` the same way; run it after any change to any of the three scripts (it needs `python3` and `curl`). Set `PYTHON` to run the analyzer under another interpreter; it must pass under the oldest supported one, Python 3.8.
- Check IDs (`TS-`, `SD-`, `GE-`, `PF-`, `AA-`, `CS-`, `PS-`, `LC-`, `GM-`) are the join key across `quick-audit.sh`, the `references/*.md` files, and the report template. If you rename or add an ID, you must update all three and the reference index.
- A live file check (robots.txt, sitemap, llms.txt) passes only a non-empty `200` whose body is not an HTML page, warning when the content is right but labelled `text/html`; each sitemap-index child must answer `200` without an HTML content type; a sitemap must list at least one page `<loc>`. A single-page app's catch-all answers every path `200` with its index page, so a status-only check passes a site that serves none of those files.
- The sampled-page section is bounded: at most `--sample` pages and `--max-links` link probes, at most 4 requests in flight, at most 5 MB read from any body, GET and HEAD only, `http`/`https` only, URLs taken literally (no curl globbing), and only URLs on the audited host or its www/apex pair. A sitemap or link URL on another host or scheme is counted, never fetched; a canonical naming another host changes what SD-07 compares against, never what is requested.
- The sample takes up to 3 URLs per first path segment in sitemap order, then fills round-robin across segments to `--sample`. When `/sitemap.xml` gives no usable URL it reads the on-site `Sitemap:` lines of robots.txt before falling back to the homepage alone; at most 10 sitemap files are fetched either way.
- A sampled page is fetched without following redirects and analyzed only when it answered 200 itself; a redirect is evidence (its status and `Location`), not a page. The homepage is the exception: the STACK fetch follows its redirects, and the LIVE head checks and the sample both start from the page it lands on. TS-37 fetches an app-association file only when the site presents the app as its own (an app meta tag, or a store link in the header, nav, or footer).
- In the sampled-page section, a response that is blocked (401/403/429/503, `cf-mitigated`, a challenge title) is a SKIP or WARN, never a FAIL, and blocked is decided before any 5xx rule; `page_blocked` in `sample.sh` is the one definition, used for pages, link probes, and association files. A timed-out, truncated, or crashed step is a SKIP or WARN with its reason, never silent, and a 429 stops every further sampled request. The LIVE checks keep their own rules: a robots.txt or sitemap answering 403 is still their FAIL.
- A check prints PASS only when it verified something: a blocked or failed fetch counts toward no PASS.
- `analyze-pages.py` makes no network requests; `sample.sh` fetches and the analyzer reads what it saved. Bash reads the analyzer's output only after checking its exit status, so a crash is one `SKIP SAMPLE` carrying its last error line, never a pass.
- A static check counts robots.txt and sitemap XML as shipped only under a `public/` or `static/` directory, unless the repository has neither; a copy elsewhere is a WARN, because the build never publishes it.

## Abnormal Cases and Rationale
- None recorded yet.

## Out of Scope
- Do not restate `SKILL.md` usage instructions. This file governs edits to the skill.
