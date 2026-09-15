---
date: 2026-09-15
subject: What actually stops a job-board scraper — measured against career-ops' 326 tracked boards and this repo's own web reader; Wayback CDX reliability, the `id_` link-base trap, and four failure classes that look alike from a log
kind: research
source: see `## Sources`
---

# Archive fallback and scraper failure classes

Opened by an operator asking how to make career-ops scrape better. Mining 13
of its Claude sessions and its own audit ledger turned up a different shape
than expected: its HTTP layer was more mature than this repo's, and the
failures that looked like one problem were four, two of which needed no fix.

## Claims

Grades: `[P]` primary read directly · `[S]` secondary · `[?]` unverified ·
`[A]` our own measurement or analysis.

### The Internet Archive as a fallback

- `[A]` The CDX index at `web.archive.org/cdx/search/cdx` fails often enough
  that one attempt makes it unusable. Sequential reads of one URL produced
  timeouts at 20 s and `503`s interleaved with `200`s. Adding a three-attempt
  policy took a measured run from zero successes in three to two in three, and
  a later run still lost one call of two — retry improves it, nothing makes it
  reliable. Budget for the failure rather than assuming it away.
- `[A]` `filter=statuscode:200&collapse=digest&limit=-1` returns the newest
  good capture in one row; the negative limit walks back from the newest.
- `[P]` The `id_` suffix (`/web/<ts>id_/<url>`) serves captured bytes verbatim,
  with no rewritten links and no injected toolbar. That is what makes a capture
  parseable by a scraper written for the live site.
- `[A]` **The `id_` link-base trap.** Because the capture is *fetched from*
  `web.archive.org`, any extractor resolving links against the fetch URL turns
  a site-root link like `/jobs?page=2` into `https://web.archive.org/jobs?page=2`,
  a path that was never captured. The CDX row's `original` field is the correct
  base. This repo's `fetch_readable` had the bug; fixed 2026-09-15 with a test
  that reproduces the wrong URL.
- `[A]` **A capture is history, not listings.** The newest capture of a
  bot-walled Built In board was 146 days old. Substituting it silently would
  manufacture stale leads, which is worse than the 403 because it reads as
  fresh coverage. Build the fallback for static pages (rosters, company lists,
  confirming what a board looked like) and gate it by capture age everywhere
  else.

### Failure classes that look identical in a log

Measured against career-ops' `portal-audit-baseline` over 326 tracked boards:
202 ok, 52 small, 48 no-provider, 22 empty, 2 error.

- `[A]` **Genuinely empty is not a defect.** All 22 `empty` boards really did
  have zero postings, confirmed directly against the Ashby GraphQL and
  Greenhouse board APIs, which both returned empty arrays. A browser tier would
  have "fixed" nothing here. Check the upstream API before calling an empty
  result a scrape failure.
- `[A]` **A refused redirect can be the right answer.** One of the two `error`
  boards 302s to `/settings/account/expired.php`: the employer's ATS account
  lapsed. The anti-forgery guard refusing that redirect was correct, and
  following it would have turned a right answer into a JSON parse error over an
  HTML page. The other `error` board answered `200` on three later attempts, so
  it was purely transient. Two identical verdicts, opposite causes.
- `[A]` **The expensive class is "handed to the agent with no tools".** 48
  boards had no provider and were delegated to the agent, whose config named a
  browser it did not have. Across all 13 sessions there were zero browser calls
  and zero web-fetch calls; every scrape ran through the shell.
- `[A]` **Silent field extraction is its own class.** Four boards returned
  postings with a date on none of them (0/99, 0/16, 0/45, 0/45) and one
  returned no location on any (0/10), all on fetches that succeeded. Nothing at
  the fetch layer distinguishes this from working.

### Retry policy, as two implementations compared

- `[A]` career-ops' `providers/_http.mjs` is the better reference: it retries
  `429`, any `5xx`, and status-less transport errors; refuses to retry other
  `4xx`; honours `Retry-After` but clamps it so a hostile `86400` cannot park
  the process; and reserves jitter *out of* the delay ceiling rather than
  adding it on top, so the configured maximum still holds.
- `[A]` It also distinguishes a redirect refused by its own guard — a bare
  `TypeError` whose `cause.message` is `unexpected redirect`, shaped exactly
  like a transient network error — and declines to retry it, since it is
  deterministic. That wording is undocumented upstream and pinned by a test.
- `[A]` A mature shared layer does not help code that bypasses it. 25 requests
  across 13 discovery modules used the non-retrying entry points, and 8 further
  scripts hand-rolled weaker copies (429-only, no jitter, one with no timeout
  at all), despite the shared module existing to prevent exactly that. Wrapping
  the context once where it is constructed fixed all 25 without touching a
  call site.
- `[A]` Retrying on a status-less error also retries a permanent DNS failure.
  An unresolvable host costs the full attempt budget plus backoff before it
  fails. Cheap to live with, worth knowing when a sweep looks slow.

## Sources

- career-ops working tree at `~/Projects/career-ops`, commit `dec50203f`:
  `providers/_http.mjs`, `providers/bamboohr.mjs`, `portals.yml`,
  `data/portal-audit-baseline-2026-09-15.json`, `data/portal-health.tsv`.
- 13 Claude session transcripts under
  `~/.claude/projects/-Users-mac-Projects-career-ops/`.
- Live reads, 2026-09-15: `builtin.com` (403), the Wayback CDX endpoint,
  `boards-api.greenhouse.io`, `jobs.ashbyhq.com` GraphQL,
  `glydways.bamboohr.com` (302 to an account-expired page).
