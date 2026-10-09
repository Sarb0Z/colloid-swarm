---
name: page-load-audit
description: >
  Diagnoses why a web app loads blank, slow, or not at all, then shrinks what it
  ships. Works the path from URL to first paint in order: triage the symptom
  (unreachable, slow, or blank — a padlock over a white page means the HTML
  arrived and the app never started), find render-blocking third-party
  dependencies and prove them with a hang-versus-refuse experiment, diagnose a
  CDN that caches nothing (Vary, Set-Cookie, TTL overrides, which process
  actually answered), attribute the bundle and apply the levers in order
  (on-demand libraries, route splitting with cold-entry routes eager, narrow
  vendor chunks), size images to their display box, and make monitoring announce
  its own absence. Every lever is measured before and after; every guard ships
  with a test proven to fail without it. Use for "site won't load", "blank
  page", "white screen", "some users can't access it", "slow to load", "bundle
  too big", "CDN not caching", "cf-cache-status BYPASS", "errors aren't reaching
  Sentry", or "why is first load slow".
---

# Page Load Audit

A page that will not load is three different faults wearing one symptom. This
skill separates them, proves which one is live, fixes what the repository
controls, and hands the operator the exact steps for what it does not.

The method generalises. The evidence does not: worked numbers from one system
live in [`references/worked-example.md`](references/worked-example.md), and the
probe scripts in [`references/probes.md`](references/probes.md).

## When to use this

- A report says the site is down, blank, or slow for some users and not others.
- A CDN sits in front of the origin and assets still travel the whole way.
- The entry bundle is the reason first paint is late.
- Errors happen in production and nothing reports them.

Do not use it for backend latency under load; that is `scalability-audit`.

## §1 Triage: read the symptom before touching anything

**Three states, three causes.** Settle which one you have from the evidence,
not the wording of the report.

| What the user sees | What it means | Where to look |
| --- | --- | --- |
| Browser error page ("can't open the page") | Nothing arrived: DNS, TLS, or network path | Outside the app; §3 if a CDN is involved |
| Content, eventually | Slow: bytes, round trips, or origin distance | §3, §4, §5 |
| **White page, padlock in the address bar, no error** | **HTML arrived and the app never started** | §2, then §4 |

The padlock is the tell. TLS completed and a document was served, so the
network path works. Something after the HTML gates the app: a render-blocking
resource that never settles, or a script that never finishes downloading.

**Prove what is alive** with read-only probes before forming a hypothesis:

- The root document: status, `cache-control`, CDN cache header.
- One hashed asset the document references: status, cache headers, ETag.
- One authenticated API route: a `401` proves the backend and its auth
  middleware are both running. A `404` from a POST-only route on GET is also
  proof of life.
- The health route: check whether it returns the app's HTML. A single-page app
  served with a catch-all (`try_files … /index.html`) answers `200` for a dead
  backend, and an uptime monitor pointed there measures the web server, not the
  API.

**Prove the deployed build is the current one.** Find a string introduced by
the newest commit and grep the live bundle for it. Staleness is a cheaper
explanation than a bug, so eliminate it first.

**Read analytics with the survivorship caveat.** Core Web Vitals and similar
beacons run after the page paints. A user looking at a blank page never fires
one, so the affected cohort is invisible in those charts by construction. Look
instead at visits diverging from page views (sessions failing to start while
the ones that start behave normally), and at the P99 tail, not the median.

## §2 Render-blocking third parties

Only two things gate first paint and the deferred module script: parser-inserted
stylesheets, including every `@import` they chain to, and synchronous scripts in
`<head>`. Inventory them from the **served** document and stylesheet, not the
source — a build step may inline or rewrite either.

**Detection question:** does any render-blocking chain leave the origin?
`grep -oE 'https?://[^"'\''() ]+' <served-stylesheet>` answers it in one line.
Then sweep the served scripts for code fetched from another origin at run
time — a dynamic `import()` of a CDN URL, a module worker loaded from one.
Those do not block first paint, but the feature behind them hangs the same
way, and a module script served with the wrong MIME type is refused outright.
After correcting a content type or cache header on a hashed or long-cached
asset, change its URL as well (a new hash or a version query): browsers that
cached the bad response keep serving it from cache.

**The decisive experiment.** Refusal and hang are different faults with
different symptoms, and only the experiment tells them apart:

| Condition | Simulate with | Predicts |
| --- | --- | --- |
| Host refuses | abort the request (connection refused) | Page renders, wrong typeface or missing style |
| Host **hangs** | intercept and never resolve | **Page never renders; root stays empty** |
| Host answers late | delay by N seconds, then continue | Blank for N seconds, then renders |

A network that filters silently drops packets; that is a hang, not a refusal.
Run the experiment in the engine of the reported browser, sample the DOM on a
timer (root child count, visible text length, stylesheet count, computed body
background) rather than waiting on load events that never fire, and screenshot
with a short timeout, because `screenshot()` itself waits on the still-loading
page. Script in [`references/probes.md`](references/probes.md).

**Find the cache that hides it.** Check `cache-control` on the third-party
resource. A short private lifetime means every browser re-fetches on a
schedule, so the fault looks intermittent and per-user, and "clear your cache"
guarantees the failing request. Say so before that advice goes out.

**Remedy: self-host.** Fonts through a package that bundles the files and
emits `@font-face` with `unicode-range`, so a visitor downloads only the
subsets their text needs. Then prove the swap is invisible: measure the
bounding boxes of the same text nodes on production and on the new build; the
widths must match to the pixel. Leave a comment on the import that says why no
`@import` may point outside the origin, because the next person will not run
the experiment.

## §3 The CDN that caches nothing

When every asset's cache header reads `BYPASS` or `MISS` (`cf-cache-status`,
`x-cache`, or the provider's equivalent), eliminate in this order, cheapest
first. Each step is a question with a checkable answer.

1. **Development or bypass mode on?** Dashboard toggle; auto-expires on some
   providers, so check the state, not the memory of it.
2. **Cache level or a cache rule set to bypass?** Zero rules is an answer too:
   it moves the cause to the response itself.
3. **`Set-Cookie` on the response?** Most CDNs will not store one.
4. **`Vary` on anything but `Accept-Encoding`?** Most CDNs will not store one.
   `Vary: Origin` is the signature of CORS middleware — which means a process
   with middleware answered a request for a static file.
5. **Browser cache TTL override?** If the origin sends `immutable` for a year
   and the browser sees four hours, the CDN is rewriting it. Fixing the origin
   changes nothing a browser sees until that override is set to respect
   origin headers. Sequence the fix accordingly.

**Which process actually answered?** The ETag says. A strong hex ETag
(`"68c0f2ad-3aa1b2"`) is a web server serving from disk. A weak decimal one
(`W/"3841394-1788963021492"`) is a runtime static handler. If the repository's
web-server config says "serve from disk" and the live ETag says "runtime", the
live config is not the repository's file. Prove drift with headers, then make
applying the config a script rather than a runbook paragraph:

- copy the live config aside first, and restore it if the syntax check fails;
- treat the syntax check as the gate and reload only after it;
- verify by mechanism, not symptom: weak ETag means the wrong process, `Vary`
  means the CDN cannot cache, a bypass after two requests points at rules;
- refuse to report on the wrong artefact — a catch-all route answers `200` with
  the app's HTML for a missing asset, so check `content-type` before reading
  any other header.

Purge the CDN once after the origin headers change, so entries stored with the
old `Vary` are replaced.

## §4 Bundle diet, in lever order

**Measure first.** Attribute the entry chunk's bytes back to packages, source
areas, and pages by walking its source map. A number typed into a comment
drifts from the truth within days; compute it every time. If source maps only
emit when an upload token is present, add a build script that forces them on
**and suppresses the upload plugin** — otherwise measuring bundle size
publishes a release and then deletes the maps it uploaded.

Apply levers in this order, and measure after each. Skipping the measurement
turns a lever into a guess.

**Lever 1 — heavy leaf libraries on demand.** Spreadsheet, PDF, and chart
libraries are usually a quarter of the chunk and reach a fraction of visitors.
Move the import inside the handler that needs it. Then check the trap: **a
single static import anywhere defeats every dynamic import of the same
package.** One memoised loader per library, and every call site through it.

**Lever 2 — routes on demand.** Lazy-load pages. Keep eager only the routes a
visitor reaches before logging in, because a lazy route costs a second round
trip and that waterfall lands on the cold first visit. Those pages are small.
One suspense boundary around the router; a named-export unwrap helper if the
pages export names. Forecast honestly: lazy-loading a page evicts a component
only if nothing eager imports it, so the shared-components figure is an upper
bound, not a prediction. Heavy libraries reached only by lazy pages leave on
their own. In-app navigation shows no fallback when the router runs
navigation in a transition; check on a throttled link rather than assuming.

**Lever 3 — vendor chunks.** Split framework packages so a returning visitor
re-downloads app code alone after a deploy. Match named leaf packages, never
"everything in node_modules": a broad rule splits an import cycle across chunks
and fixes an evaluation order the app then violates at runtime. This lever
trades first-load bytes for repeat-visit bytes; report both. Prove the claim by
changing a rendered string, rebuilding, and confirming the entry hash moved and
the vendor hashes did not. A trailing comment does not survive minification
and proves nothing.

**Leave the cycle-breakers alone.** A module imported both statically and
dynamically because the dynamic import breaks a circular dependency is not a
size problem; the bundler is only noting the dynamic import cannot split it.

Re-run the full route sweep after Lever 3. It is the one that fails at runtime.

## §5 Images

Size each raster to roughly twice its largest CSS display box, not to the
source. Read every call site: the same file may render at 130 px in one place
and 400 px in another. Store photographs in a lossy format; a photograph saved
as PNG is pure waste. Delete files nothing references — grep the source for
each name. A file that doubles as tab icon and placeholder avatar keeps its
name, extension, and box, and is palette-quantised instead of resized; flat
artwork with a few dozen colours loses nothing. Look at the two heaviest
compressions by eye — fine UI text in a screenshot is the worst case.

## §6 Monitoring that announces its absence

An application that reports no errors looks exactly like one that never
errors. `if (!dsn) return;` is how a monitoring gap survives for months and
gets discovered by email. Announce the gap in three places, and throw in none
of them — losing an API URL makes the app useless, losing monitoring must not
take it down:

- at build time, when the production build carries no DSN;
- in the browser, on a production build;
- at server boot, in the production environment.

Ship the guard with tests that pin both halves — audible when absent, never
fatal — and prove they detect the defect by restoring the silent return and
watching the first one fail. A failed source-map upload must not fail the
build either; if a comment claims it does, the comment goes.

Two gaps the bundle-based monitor cannot close. A page that loads outside the
bundle (a hand-written HTML page, a static funnel page) needs its own
dependency-free reporter: a plain script tag that posts errors to a
rate-limited endpoint, caps reports per page load, deduplicates, and can never
throw itself. And a health check that runs on the machine it watches cannot
see that machine go down: at least one probe runs from outside, and a refused
or erroring probe reads as unknown, never as healthy.

## §7 Verification discipline

- One lever, one measurement. Report the table, not the intent.
- Sweep routes in a browser: every public route, protected routes redirecting,
  the catch-all, no console errors, no stuck fallback. Twice if a lever touches
  chunk boundaries.
- A guard without a test that fails in its absence is a comment.
- Stop every server and browser the audit started before reporting.
- "Pre-existing" is not a disposition. A failing check you ran is yours to fix
  or file, in that order.

## Output

1. **The diagnosis**, stated as which of the three states was live and the
   evidence that settled it.
2. **A lever table**: each lever, measured before and after, in the units the
   user can observe (bytes over the wire, seconds to first paint).
3. **The environment steps that are the operator's** — CDN settings, config
   applied on the box, variables set — named precisely, with what each changes.
4. **What was filed** rather than fixed, and why it needed a decision.

## Preflight

- The advice already given to users may be wrong. "Clear your cache" against a
  render-blocking hang makes the fault certain. Check before it goes out again.
- Screenshots of dashboards are evidence. Read the header row: a badge saying
  which plan, a TTL, a rule count.
- Do not test an upload plugin with real credentials. An invalid token and an
  endpoint pointed at a closed local port prove the wiring without publishing.
- The reporting browser matters. Engines differ in whether a stalled
  stylesheet blocks the deferred script; test the one in the screenshot.
