---
name: seo-geo-growth-audit
description: "Audits and improves the discoverability of the deployed site a codebase drives: technical SEO (crawlability, sitemaps, robots, canonicals, metadata), structured data (JSON-LD), GEO/AI-search visibility (llms.txt, entity signals, AI-crawler policy), Core Web Vitals, analytics and UTM attribution, and growth systems (content engines, programmatic SEO, lead capture, conversion). Fingerprints the stack first and adapts to any framework; audits both repository code and the live site; produces a scored report with evidence, a prioritized P0-P3 fix plan, implemented fixes, and post-fix verification. Use when asked for an SEO audit, GEO audit, growth audit, or pre-launch checklist; when organic traffic is flat or conversions underperform; when setting up analytics attribution; or when improving AI search visibility in ChatGPT, Perplexity, or Gemini. Trigger phrases: SEO audit, why is organic traffic flat, AI search visibility, llms.txt, structured data, sitemap problems, Core Web Vitals."
metadata:
  version: "2.0"
context: fork
---

# SEO, GEO, Analytics and Organic Growth Audit

Run a full audit-and-improve loop on the discoverability of the deployed site this codebase drives. The skill is portable: it works on any web stack. Code snippets are labeled adaptable patterns (Next.js App Router flavored — translate for other frameworks), and every concrete value in this skill (timeouts, chunk sizes, thresholds) is a validated example from a production system, not a requirement: adapt to the target.

## When to use

- Onboarding a new codebase and mapping its SEO/growth posture
- Pre-launch checks for marketing sites, landing pages, content platforms
- Diagnosing flat organic traffic or underperforming conversions
- Setting up analytics attribution from scratch
- Preparing for AI-search visibility (ChatGPT, Perplexity, Gemini)

## Operating principles

1. **Audit the live site, not just the repo.** Redirects, bot rules, and caching often live at the CDN and are invisible in code; sitemap wiring often breaks only in production.
2. **Distinguish built from live.** Shipped code may be disabled by kill-switches, commented out, or unmounted. Dormant instrumentation and dead database models count as absent.
3. **Every finding carries evidence:** a `file:line` reference or a URL plus the observed value. No evidence, no finding.
4. **Never fabricate signals.** No invented ratings, authors, review counts, or freshness stamps — fixes must use real data or omit the markup.
5. **Defer to existing docs.** In step 0, inventory SEO checklists/docs already in the target repo; page-type-specific ones override this skill's generic checks for those pages.

## Audit workflow

Copy this checklist and track progress:

```
Audit progress:
- [ ] 0. Fingerprint stack + inventory existing SEO docs
- [ ] 0b. Classify the go-to-market motion per template
- [ ] 1. Run scripts/quick-audit.sh (evidence baseline)
- [ ] 2. Layer 1: technical SEO foundation
- [ ] 3. Layer 2: structured data
- [ ] 4. Layer 3: GEO / AI-search visibility
- [ ] 5. Layer 4: performance and Core Web Vitals
- [ ] 6. Layer 5: analytics and attribution
- [ ] 7. Layer 6: growth systems (content / PSEO / leads)
- [ ] 8. Write the report (template below)
- [ ] 9. Confirm the fix plan with the user
- [ ] 10. Implement P0-first, verify each fix live
```

**Step 0 — Fingerprint.** Identify framework and router, rendering model (SSG/ISR/SSR), hosting/CDN (this determines where redirects and bot rules live), and the production BASE_URL (ask the user if not obvious). Then search the repo for existing SEO documentation (`grep -ril "seo\|checklist" --include="*.md" .`) — read anything found and defer to page-type-specific rules.

Then settle two things before scoring anything. **Purpose:** is this a public site that wants to be found, a private app, or a mixed product with a public front? For a private surface the audit's job is to confirm it stays out of the index (TS-34) and that crawler files still serve; mark the growth layers not applicable rather than failing them. **Serving platform:** identify it from live response headers (`server`, `via`, platform request-ID headers), not from config files — a `vercel.json` or `_headers` file in a repository served by something else is dead evidence, and every redirect, header, and rewrite claim must be re-tested live.

**Step 0b — Go-to-market motion.** Load [references/gtm-motions.md](references/gtm-motions.md) and classify each page template by how the business wins customers through it (product-led signup, sales-led demo, local lead generation, marketplace, store, app install, content, developer tools, programmatic data, partner channel, regulated advice). The motion decides which checks carry weight, what the conversion is, and which failures are fatal (GM-01 to GM-04). Ask the owner for the revenue split across motions when the site mixes them, and record both in the report header.

**Step 1 — Baseline.** Run:

```bash
bash scripts/quick-audit.sh <repo-dir> <base-url> [--sample N] [--max-links N]
bash scripts/quick-audit.sh --no-repo <base-url>   # live site only, no repository checks
```

`--sample N` fetches up to N sitemap pages, 3 per URL family before any family gets a fourth, without following redirects, and checks each one's status, indexability, metadata, JSON-LD, inline scripts, and head resources (default 40, `0` turns it off); `--max-links N` probes that many of their internal links (default 60). Measured runs made 9 requests (a single-page app with no sitemap), 29 (a site whose homepage is the whole sample), and 57 (`--sample 20 --max-links 30`). With the defaults the sample adds at most 171 requests (10 index children, 39 pages, 2 per probed link when HEAD is refused, 2 app-association files) to at most 217 for the live checks (2 per sitemap-index child, capped by `--max-children`), plus the redirect hops the live checks follow. At most 4 requests run at once, each bounded by `--timeout`.

Capture the output — its `[FAIL]`/`[WARN]` lines with check IDs are your first evidence, and SUMMARY maps failed IDs to the reference file to load. The script degrades gracefully: without a BASE_URL (or network) it runs static checks only; findings never affect its exit code.

**Steps 2-7 — Layer passes.** Work the layers in order; each builds on the previous. Load one reference file at a time, run its checks against repo + live site, and record findings with evidence and a P0-P3 tier.

| Pass | Layer | Key question | Load | Skip when |
|------|-------|--------------|------|-----------|
| 2 | Technical SEO | Can crawlers find, fetch, and index the right URLs? | [references/technical-seo.md](references/technical-seo.md) | Never |
| 3 | Structured data | Do machines get accurate entity/content markup? | [references/structured-data.md](references/structured-data.md) | Never |
| 4 | GEO | Will AI engines discover and cite this site correctly? | [references/geo.md](references/geo.md) | Never |
| 5 | Performance | Do CWV meet targets, and is anyone measuring them? | [references/performance.md](references/performance.md) | Never; for a blank or stalled page, use the `page-load-audit` skill where the repository carries it |
| 6 | Analytics | Does measurement fire, and does attribution survive to the CRM? | [references/analytics-attribution.md](references/analytics-attribution.md) | Site has no conversion goal |
| 7a | Content systems | Do engines produce, refresh, and interlink credible content? | [references/content-systems.md](references/content-systems.md) | Pure product/app site with no content play |
| 7b | Programmatic SEO | Are combination pages worth indexing — and actually live? | [references/pseo.md](references/pseo.md) | No repeatable location/category combinations |
| 7c | Leads and conversion | Do visitors become recorded, attributed leads? | [references/leads-conversion.md](references/leads-conversion.md) | Site has no lead capture |

**Step 8 — Report.** Fill the template below. Every finding cites a check ID and evidence.

**Step 9 — Confirm.** Present the prioritized fix plan; get user sign-off on scope before changing code.

**Step 10 — Implement and verify.** Fix in priority order. Close a finding only per the "Verify fixes" section.

## Priority matrix

Assign every finding one tier by criteria, not by category:

- **P0 — blocks indexing or measurement entirely.** Fix immediately. Examples: missing/broken robots.txt or sitemap; site-wide noindex mistakes; no HTTPS; analytics not firing at all; lead form not persisting leads; soft-404s on real pages.
- **P1 — indexed but underperforming.** Fix this sprint. Examples: no structured data on key templates; missing or unresolvable OG images; LCP > 4s; zero funnel events behind a loaded analytics vendor; thin pages indexed without quality gates; client-rendered public routes that serve one shared title and canonical.
- **P2 — compounding growth infrastructure.** Fix this quarter. Examples: no content freshness pipeline; no RUM/CWV monitoring; attribution not persisted to the datastore; missing PSEO layer where combinations exist; no partial-lead capture.
- **P3 — marginal or speculative.** Backlog. Examples: llms.txt and llms-full.txt (Google Search ignores them; useful only for other consumers); dynamic OG image generation; server-side tag manager.

## Report template

```markdown
# Discoverability audit — <site> (<date>)
Stack: <framework/router/CDN> | Base URL: <url> | Quick-audit: <PASS/FAIL/WARN counts>
Motion: <M-id per template, e.g. M3 location pages + M5 checkout> | Revenue split: <share per motion, from the owner>

## Scorecard
| Layer | Verdict | P0 | P1 | Top issue |
|-------|---------|----|----|-----------|
| Technical SEO | red/amber/green | n | n | <one line> |
| Structured data | ... | | | |
| GEO | ... | | | |
| Performance | ... | | | |
| Analytics | ... | | | |
| Growth systems | ... | | | |

## Findings
### [P0] <CHECK-ID> <title>
- Evidence: <file:line or URL + observed value>
- Impact: <what it costs while broken>
- Fix: <specific change>
- Verify: <command or URL that proves the fix>

(repeat per finding, ordered P0 -> P3)

## Fix plan
| # | Priority | Findings | Effort (S/M/L) | Sequence rationale |
|---|----------|----------|----------------|--------------------|

## Verification log
(appended as fixes land: finding ID -> verification evidence -> closed date)
```

## Reference index

| File | Covers | Load when |
|------|--------|-----------|
| [references/gtm-motions.md](references/gtm-motions.md) | Go-to-market motions, how to detect each, what each weights, documented AI-answer and spam-policy facts (GM-*) | Step 0b, always |
| [references/technical-seo.md](references/technical-seo.md) | Sitemaps, metadata, canonicals, robots, URL hygiene, client rendering and script-only fixes, internal link graph, injected code, private surfaces, companion-app files, serving platforms (TS-*) | Pass 2, always |
| [references/structured-data.md](references/structured-data.md) | JSON-LD types, retired rich results, quality rules (hosts, empty values, dates), injection (SD-*) | Pass 3, always |
| [references/geo.md](references/geo.md) | Crawler classes and AI-feature controls, llms.txt, entity signals, AI-visibility measurement (GE-*) | Pass 4, always |
| [references/performance.md](references/performance.md) | CWV targets, build/rendering, RUM, third-party and asset weight (PF-*) | Pass 5, always |
| [references/analytics-attribution.md](references/analytics-attribution.md) | Tag loading, events, UTM, lead data model, conversion integrity, cross-origin hand-offs, tag inventory (AA-*) | Pass 6, if conversions matter |
| [references/content-systems.md](references/content-systems.md) | Content engines, freshness, E-E-A-T (CS-*) | Pass 7a, if content play exists |
| [references/pseo.md](references/pseo.md) | Programmatic pages, quality gates, kill-switches (PS-*) | Pass 7b, only if combination pages apply |
| [references/leads-conversion.md](references/leads-conversion.md) | Forms, capture, abuse protection, list and mailing hygiene, claim and CTA integrity, referral and comparison pages (LC-*) | Pass 7c, if lead capture exists |

## Verify fixes

A finding closes only when live behavior changes:

1. Re-run the relevant quick-audit section (or the specific `curl`) and confirm the check flips.
2. Structured-data fixes: validate the rendered page in Google's Rich Results Test for types Google supports, and in validator.schema.org for the rest.
3. Indexation fixes: confirm the directive in the live HTML/headers, then request reindexing in Search Console.
4. Performance fixes: re-measure (PageSpeed Insights) — lab first, watch field data over the following weeks.
5. AI-visibility fixes: watch Search Console's generative AI performance report and Bing Webmaster Tools' AI Performance report over the following weeks (GE-16).
6. Append each closure to the report's verification log with evidence.

## Scope boundaries

Out of scope: keyword research and content strategy, link building/outreach, paid acquisition, and retention mechanics (push notifications, personalization). Recommend separately if asked; do not fold into this audit's matrix.
