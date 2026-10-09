# Layer 4 — Performance and Core Web Vitals

Performance is a ranking signal and a conversion multiplier. Audit the build config, the rendering strategy, and — critically — whether the measurement layer actually runs.

## Contents

- Targets
- Build and delivery checks (PF-01 to PF-09)
- Rendering strategy checks (PF-10 to PF-16)
- Measurement checks (PF-17 to PF-20)
- Third-party and asset weight checks (PF-21 to PF-22)
- Deep-dive commands
- Anti-patterns

## Targets

| Metric | Target |
|--------|--------|
| LCP | < 2.5s |
| INP | < 200ms |
| CLS | < 0.1 |
| TTFB | < 800ms (web.dev's "good"; a diagnostic, not a Core Web Vital) |
| Initial JS | < 200KB (a working budget, not a web.dev threshold) |

## Build and delivery checks

| ID | Check | Verify by |
|----|-------|-----------|
| PF-01 | Build optimization at framework defaults or better: minification on, production console stripping (preserve `error`/`warn`), package-import optimization / per-icon imports for icon and motion libraries | Read the framework config (option names are version-specific — check what the installed version supports rather than expecting exact flags) |
| PF-02 | Critical CSS inlined (critters or framework equivalent) | Config flag + view-source of a production page |
| PF-03 | Bundle analyzer wired and invocable on demand (e.g. `ANALYZE=true` build script) | package.json scripts |
| PF-04 | Images are sized for their display box: the framework image component where one exists; on a plain single-page app, raw `<img>` sources encoded at about twice their largest rendered width, in WebP or AVIF, with explicit dimensions | Ratio of image-component imports to raw `<img>`; on a plain app, compare each image's intrinsic size with its rendered size (real failure mode: a 1.7 MB 1860x2520 PNG hero rendered about 384 px wide) |
| PF-05 | Modern formats explicitly enabled — AVIF is typically NOT a default; absence of a formats config means WebP-only | Read the images config (real failure mode: assuming AVIF while the config never enables it) |
| PF-06 | LCP image gets `priority`/`fetchPriority="high"`, plus `<link rel="preload">` for hero assets | Root layout + hero components |
| PF-07 | `sizes` on every responsive image | Grep image components missing `sizes` |
| PF-08 | dns-prefetch + preconnect only for third-party origins that load after first paint (tag manager, scheduling widgets). A render-blocking dependency on an origin the site does not control is removed, not warmed up — see PF-21 | Root layout head |
| PF-09 | Long-lived caching: 1-year immutable for hashed static assets/images/fonts; stale-while-revalidate for cacheable HTML, with framework data requests excluded from those rules (see technical-seo TS-30); after correcting a header on a long-cached asset, change its URL, because browsers keep the cached copy | Headers config + `curl -sI` on an asset and a page |

## Rendering strategy checks

| ID | Check | Verify by |
|----|-------|-----------|
| PF-10 | Font strategy: self-hosted or framework fonts with `display: swap` (or `optional` for non-critical faces), preload only the critical family; no stylesheet `@import` of a font host, which blocks rendering on that host | Font config module; grep CSS for `@import url(` (real failure mode: a self-hosting font package installed while the stylesheet still imports the font host) |
| PF-11 | Below-the-fold code split via dynamic imports on the heaviest pages — check the homepage first; it is often the one page nobody split | Grep `dynamic(`/lazy imports per page |
| PF-12 | Streaming SSR: Suspense boundaries with skeleton fallbacks around slow data sections | Grep `Suspense` on data-heavy templates |
| PF-13 | `content-visibility: auto` utility applied to long below-fold sections | CSS + usage grep |
| PF-14 | Conversion-focused pages skip heavy chrome (conditional layout that drops header/footer on tools, checkout, thank-you) | Layout wrapper logic |
| PF-15 | ISR/revalidation on content pages; static generation for high-traffic parameterized routes | `revalidate` + `generateStaticParams` coverage |
| PF-16 | PWA for tool/utility pages (manifest + service worker) where return visits matter | public/ manifest + registration component |

## Measurement checks

| ID | Check | Verify by |
|----|-------|-----------|
| PF-17 | Real-user CWV measurement actually ships: a web-vitals (or equivalent) client reporting LCP/INP/CLS/TTFB to an endpoint | Dependency present AND the reporter is mounted — commented-out loggers and dead endpoints count as ABSENT (real failure mode: full RUM layer built, then 100% commented out, still described as implemented). A CDN can inject a beacon with no code in the repository, so also check the live HTML and network trace before calling RUM absent; slice its slowest-element report by country and device to choose targets |
| PF-18 | RUM endpoint filters bots before recording | Read the endpoint's user-agent handling |
| PF-19 | Field data cross-checked: CrUX via PageSpeed Insights / Search Console CWV report | Run PSI against the live URL |
| PF-20 | Regression visibility: periodic report or alert on CWV movement (cron, dashboard, or Search Console review cadence) | Ask for the process; absence is a finding |

## Third-party and asset weight checks

| ID | Check | Verify by |
|----|-------|-----------|
| PF-21 | Entry routes load no render-blocking stylesheet or script from an origin the site does not control — including fonts, and libraries pulled at run time by dynamic `import()` or module workers. A host that hangs, rather than refuses, leaves the page blank behind a valid padlock, and a browser cache can mask it for a day at a time | List every external origin the entry routes request; simulate a hang, not just a refusal. When the repository carries the `page-load-audit` skill, run its hang-versus-refuse experiment |
| PF-22 | The published directory ships nothing unused or oversized: no unreferenced files, no raster heavier than its display box needs, no template leftovers | `find public -type f -size +200k`, then grep the source for each file's name; an unreferenced multi-megabyte image is pure cost on every deploy and every crawl |

## Deep-dive commands

Lighthouse (needs npx + Chrome; run outside the quick-audit script):

```bash
npx lighthouse "$BASE_URL" --preset=desktop --output=json --quiet \
  | jq '{seo: .categories.seo.score, perf: .categories.performance.score, lcp: .audits["largest-contentful-paint"].displayValue}'
```

PageSpeed Insights API (field + lab data, no local Chrome):

```bash
curl -s "https://www.googleapis.com/pagespeedonline/v5/runPagespeed?url=$BASE_URL&strategy=mobile" \
  | jq '.loadingExperience.metrics'
```

## Anti-patterns

| Anti-pattern | Why it is bad | Fix |
|--------------|---------------|-----|
| Dormant instrumentation counted as implemented | Decisions get made on metrics nobody collects | PF-17: verify the code path executes in production, not that files exist |
| Missing `sizes` on responsive images | Mobile devices download desktop-size bytes | Always set responsive breakpoints |
| Version-pinned config cargo-culting | Copying flags from another major version silently no-ops | Check the installed framework version's docs before adding flags |
| Preconnecting to a font host the page cannot render without | Speeds up the dependency instead of removing it; a hang still blanks the page | Self-host the fonts (PF-10, PF-21) |
| Chasing lab scores while field data is red | Lab (Lighthouse) and field (CrUX) can disagree; rankings use field | Prioritize CrUX/RUM numbers (PF-19) |
