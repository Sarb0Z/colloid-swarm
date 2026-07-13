# Layer 6b — Content Systems

The engines that produce, maintain, and interlink content. Audit for existence, freshness automation, and credibility (E-E-A-T) — stale or anonymous content underperforms regardless of technical SEO.

## Contents

- Content engine checks (CS-01 to CS-07)
- Pipeline and freshness checks (CS-08 to CS-13)
- Credibility checks (CS-14 to CS-16)
- Adaptable pattern: stale-content regeneration script
- Anti-patterns

## Content engine checks

Absence of an engine is only a finding when the business has a use for it.

| ID | Check | Verify by |
|----|-------|-----------|
| CS-01 | Blog: multi-level categories, TOC, reading-progress, comments, related/recent posts | Route structure + components |
| CS-02 | FAQ hub: multi-tier routes for long-tail queries (`/faqs` -> `/faqs/topic` -> `/faqs/topic/question`), each tier with FAQPage schema | Route tree |
| CS-03 | Guides/roadmaps: step-by-step content carrying `HowTo`/`LearningResource` schema | Templates |
| CS-04 | Podcast/media pages: transcript on-page (indexable), timestamps, ISO 8601 durations in schema | Episode template |
| CS-05 | Case studies with concrete outcomes (before/after, numbers) | Templates + content sample |
| CS-06 | Resource library (templates, checklists, downloadables) as lead-magnet inventory | Routes |
| CS-07 | Free tools as top-of-funnel: utilities that earn links and funnel to conversion CTAs | tools/ routes |

## Pipeline and freshness checks

| ID | Check | Verify by |
|----|-------|-----------|
| CS-08 | AI-assisted generation (if used) has a deduplication pass — batch generation converges on repeated phrasing; post-generation prose dedup scripts are a validated approach | Find dedupe/patch scripts; sample openings of 5 generated pieces |
| CS-09 | Batch generation uses the provider's batch API for cost (roughly half price) when volume justifies it | Read the generation service |
| CS-10 | Stale-content regeneration: scripts or crons refresh content older than N days, with dry-run, concurrency, and retry controls (pattern below) | scripts/ directory |
| CS-11 | CMS sync direction verified, not assumed: inbound webhooks OR script/endpoint-triggered sync — either is fine, but the audit must state which exists, and every sync path must end in a cache purge | Trace one content update from CMS to live page |
| CS-12 | Draft/preview mode for editors (covered as TS-20; confirm it spans all content types) | Grep draft-mode usage per content route |
| CS-13 | Internal linking engine: related content, breadcrumbs, and contextual in-body links to conversion pages (link injection scripts are a validated approach) | Components + any link-injection scripts |

## Credibility checks

| ID | Check | Verify by |
|----|-------|-----------|
| CS-14 | Real authors with verifiable credentials: linked profiles, external presence (GitHub, Stack Overflow, LinkedIn) | Author selection logic + rendered bylines |
| CS-15 | Reviewer/fact-checker layer on top of authorship — a second credible name reviewing content is an E-E-A-T signal most sites skip | Reviewer badge/data model |
| CS-16 | Author-content fit: authors are matched to topics they plausibly know (skill match), not rotated randomly | Read the assignment logic |

## Adaptable pattern: stale-content regeneration script

Validated shape (per-content-type scripts beat one generic script — different content types need different prompts, thresholds, and sync endpoints):

```
node scripts/regenerate-stale-<type>.mjs [flags]

--dry-run          list what would regenerate, change nothing
--days=N           staleness threshold (default 10 — content older than ~1.5 weeks
                   drifts from current-month freshness signals; tune per type)
--slug=<slug>      target one item
--concurrency=N    parallel regenerations (default 2; cap ~10 to protect the API)
--retries=N        per-item retries with backoff (default 2)
--timeout-ms=N     per-request timeout (default 15000)
--batch-size=N     max items this run
--offset=N         skip first N (resumable batches)
--api-base=<url>   target environment
```

Implementation notes: authenticate to the internal sync endpoint with a server-side token (e.g. `INTERNAL_SYNC_TOKEN` header); POST `{ slug, contentType }` to a sync route that regenerates, persists, and purges caches; log per-item outcomes so a failed batch is resumable via `--offset`.

## Anti-patterns

| Anti-pattern | Why it is bad | Fix |
|--------------|---------------|-----|
| Fake E-E-A-T (invented authors, stock-photo bylines, fabricated credentials) | Helpful-content systems demote it; destroys trust if discovered | Real people with verifiable external presence (CS-14) |
| AI generation without dedup | Hundreds of pages opening with the same three phrasings read as spam at scale | Post-generation dedup pass (CS-08) |
| Freshness theater (updating dates without updating content) | Crawlers compare content hashes; users bounce | Regenerate substance on a threshold (CS-10) |
| Assuming CMS webhooks exist | Stale pages ship silently when sync is actually manual | Trace the real sync path once (CS-11) |
