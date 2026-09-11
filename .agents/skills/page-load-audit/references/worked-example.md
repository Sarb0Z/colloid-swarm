# Worked example: "some of my students can't load the site"

One system's evidence, reconstructed from the session transcripts that produced
the `perf/load-time` branch. The numbers are that system's and date to
September 2026; the method in `SKILL.md` is what carries.

## Contents

- [The report](#the-report)
- [Triage](#triage)
- [Hypothesis 1: a render-blocking third party](#hypothesis-1-a-render-blocking-third-party)
- [Hypothesis 2: the CDN](#hypothesis-2-the-cdn)
- [What the analytics could and could not show](#what-the-analytics-could-and-could-not-show)
- [The CDN that cached nothing](#the-cdn-that-cached-nothing)
- [Bundle diet](#bundle-diet)
- [Images](#images)
- [Monitoring](#monitoring)
- [Mistakes made on the way, kept as rules](#mistakes-made-on-the-way-kept-as-rules)
- [What stayed the operator's](#what-stayed-the-operators)

### The report

A teacher in Kazakhstan wrote that some students had been unable to open the
platform for three days: "It just wouldn't load." The screenshot showed Safari
on macOS, the address bar holding the domain with a padlock, and a white page
with no error. The advice already given was "clear your browsing data".

### Triage

Read-only probes from outside the country:

- root document `200`, `cache-control: no-cache`, served through a CDN;
- an authenticated API route answered `401`, proving the backend and its auth
  middleware were running;
- the health route returned the app's HTML — the catch-all was answering it,
  so any monitor pointed there measured the web server, not the API;
- the entry JavaScript was one chunk: 3,841,394 bytes raw, 1,126,813 gzipped.

The padlock over a blank page settled the state: HTML arrived, the app never
started. That excluded "the site is down" and pointed at whatever ran after
the document.

### Hypothesis 1: a render-blocking third party

The served stylesheet opened with three `@import` rules to a third-party font
host. Nothing else render-blocking left the origin.

The hang-versus-refuse experiment against live production, sampling the DOM on
a timer:

| Engine | Condition | Root children at 30 s | Visible text |
| --- | --- | --- | --- |
| Chromium | baseline | 2 | 8,202 chars at 3.4 s |
| Chromium | font host refuses | 2 | 8,202 chars at 3.7 s |
| Chromium | **font host hangs** | **0** | **0 — never** |
| Chromium | font host answers after 20 s | 2 | after 20 s |
| WebKit | font host hangs | 2 | rendered, but app stylesheet never applied |

Only a hang produced the reported symptom, and only in Chromium. WebKit in
this harness rendered an unstyled page instead; Playwright's WebKit is not
Safari, and the analytics showed the affected students were overwhelmingly on
Chrome (325 of ~400 sessions) and Windows, so the Chromium result was the one
that mattered.

The cache that hid it: the font host served its stylesheet with
`cache-control: private, max-age=86400`. Every browser re-fetched daily, so
the fault looked intermittent and per-student, and clearing site data deleted
the one copy that had been masking it.

Remedy: three `@fontsource` packages, imported per weight and style to match
exactly what the third party had served. Verified with the font hosts blocked
in both engines: mount in 0.5–0.8 s, zero external requests. Text-node widths
matched production to 0.0 px across eight measured nodes. The bundled Inter
carried Cyrillic subsets the third party had been serving separately.

### Hypothesis 2: the CDN

The user suggested the CDN. Encrypted Client Hello — the one CDN setting that
reliably breaks networks with deep packet inspection — was checked through the
HTTPS DNS record: `alpn=h2` with IP hints and no `ech=`, and the CDN's own
trace endpoint reported `sni=plaintext`. Ruled out.

Research found no primary evidence that the font host was blocked in the
country, and several secondary reports of blank pages on CDN-fronted sites
from local carriers, resolved by VPN. So the honest position was: a real,
demonstrated fragility was fixed, and it may not have been the only cause.

The user's counter — "the teacher said down, not slow" — strengthened the
first hypothesis rather than weakening it. A blocked path gives a browser
error page; a padlock over white means the document was served.

### What the analytics could and could not show

The CDN's web analytics, filtered to the country, showed traffic flowing:
139 visits in 24 hours, 2,270 over two weeks. Not a blackout. But visits were
down 25.3% while page views were down 0.95% — sessions failing to start while
started sessions behaved normally. And the beacon that produces those charts
runs after paint, so a student on a blank page was invisible in them by
construction. The P99 paint time spiked to 12.2 s and 11.1 s on the two days
before the complaint window.

The debug view named the slowest element: the landing-page hero image at
10,036 ms across 90 samples. It was a 1.03 MB JPEG.

### The CDN that cached nothing

Every static asset answered `cf-cache-status: BYPASS`. The dashboard
eliminated the easy causes: development mode off, cache level standard, zero
cache rules, zero cache response rules. No `Set-Cookie`.

The response itself named the cause. It carried `vary: Origin` and a weak
decimal ETag, `W/"3841394-1788963021492"` — neither of which the web server
generates. A runtime static handler was answering: the old frontend process on
port 3002 that the repository's web-server config had been written to retire
a month earlier and that had never been applied. Its CORS middleware added
`Vary: Origin`, and the CDN refuses to store a response that varies on
anything but `Accept-Encoding`.

Two more mismatches from the same drift: the repository asked for
`1y immutable` on assets and the live server sent four hours, because the
CDN's browser-cache TTL was pinned to four hours and overriding the origin.
Fixing the server would change nothing a browser saw until that setting was
switched to respect origin headers.

The repository fix was a script: back up `sites-enabled`, install the config,
gate on the syntax check, restore on failure, reload, then verify by
mechanism — weak ETag, `Vary`, bypass after two requests — and refuse to
report on a missing asset, because the catch-all answers `200` with the app's
HTML for one. Its verify-only mode, run against production, reported exactly
the three failures above.

### Bundle diet

Attribution by source map, from a build script that forces maps on and
suppresses the upload plugin:

| Lever | Entry chunk, gzipped |
| --- | --- |
| baseline | 1,102 kB |
| spreadsheet library on demand (five admin handlers) | 962 kB |
| PDF library on demand (one memoised loader; three static imports had been defeating an existing dynamic one) | 820 kB |
| 45 pages on demand, five cold-entry routes kept eager | 283 kB |
| vendor chunks for the framework packages | 184 kB + 106 kB vendor |

First load against what production served: 1,144 kB → 320 kB, a 72% cut,
across 113 chunks. Repeat visit after a deploy: 214 kB.

The plan's forecast for route splitting had credited "~890 kB app code". The
measured split was `src/components` 676 kB against `src/pages` 215 kB, and a
page only evicts a component nothing eager imports. It came out better than
the forecast anyway — components in the entry fell to 77 kB — because the
chart and editor libraries reached only lazy pages and left with them.

The vendor split was proved, not assumed: changing a rendered string moved the
entry hash and left both vendor hashes untouched. The first attempt used a
trailing comment, which minification stripped, so the output was identical and
the probe proved nothing.

Nineteen routes were swept in a browser after route splitting and again after
the vendor split. In-app navigation on a throttled 400 kbit link showed no
fallback, because the router ran navigation in a transition.

### Images

| File | Before | After |
| --- | --- | --- |
| unreferenced 4096×2734 PNG | 6.89 MB | deleted |
| hero, 2879×1919 JPEG | 1,027 KB | 172 KB WebP at 2048 wide |
| illustration, 834×1250 PNG, rendered at 130 px and 400 px | 797 KB | 86 KB WebP at native width |
| report screenshot, rendered at 550 px | 329 KB | 27 KB WebP at 1100 wide |
| favicon, also the default class avatar | 75 KB | 6.3 KB, palette-quantised, box kept |

The first illustration attempt sized for the 130 px call site only. The
second call site rendered it at 400 px, so it was regenerated at native width.

### Monitoring

Neither the client nor the server said anything when its DSN was missing —
`if (!dsn) return;` on one side, `if (enabled) { … }` on the other. Both
environments had shipped without one. The build, the browser, and the server
boot now each announce the gap; none throw. Three tests pin the client guard,
and restoring the bare return fails the first.

A probe with an invalid token and the upload endpoint pointed at a closed
local port showed the upload plugin still ran on a normal build, failed, and
the build exited 0 with the maps already deleted — contradicting a comment
that claimed a failed upload fails the build. The user's ruling: the behaviour
is right, a monitoring outage must not block a deploy; the comment goes.

### Mistakes made on the way, kept as rules

- `const URL = …` shadowed the global in the first probe and broke
  `new URL()` inside the route handler. Name the target something else.
- The first measurement loop stopped polling the moment the app mounted, so it
  captured DOM state before the stylesheet applied and reported an unstyled
  page as the steady state. Sample on a fixed timer to the end of the budget.
- `screenshot()` timed out under the hang condition because it waits on the
  page. Give it its own short timeout and sample frames instead.
- A production build with no API URL threw at boot and produced the same blank
  page as the fault under investigation. Set the variable before trusting any
  local verification.
- `build:analyze` forced source maps on without suppressing the upload plugin.
  On a machine with credentials it would have published a release and deleted
  the maps. Invisible locally only because no credentials were present.
- `git rm` had staged four deletions before an unrelated commit swept them up.
  Check what is staged before every commit, not only what was added.

### What stayed the operator's

Apply the web-server config on the box; switch the CDN's browser-cache TTL to
respect origin headers; purge once; set the DSN in both environments; decide
whether one landing-page animation is worth 121 kB of animation library in the
entry chunk. Each named with what it changes, none done by the agent.
