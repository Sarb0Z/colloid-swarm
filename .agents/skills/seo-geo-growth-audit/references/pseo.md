# Layer 6a — Programmatic SEO (PSEO)

Landing pages generated from dimension data (location x category x attribute). Load this file only if the site serves repeatable combinations; otherwise skip the layer entirely.

## Contents

- Decision tree (run first)
- Checks (PS-01 to PS-13)
- Adaptable patterns: quality gate, kill-switch
- Anti-patterns

## Decision tree

```
Does the business serve multiple locations/categories/attributes?
  NO  -> Skip this layer.
  YES -> Do you have unique data per combination (listings, prices, counts)?
           YES -> Full PSEO: unique content + data + social proof per page
           NO  -> Light PSEO: templated content with dynamic variables,
                  strict quality gates, small page set
         100+ combinations?
           YES -> Dedicated architecture (subfolder /city/category preferred;
                  subdomains only with a strong isolation reason)
           NO  -> Static generation of the full set is fine
```

## Checks

| ID | Check | Verify by |
|----|-------|-----------|
| PS-01 | The PSEO subsystem is actually LIVE, not just shipped: middleware kill-switches, redirects-to-home, or commented-out rewrites disable it invisibly | Curl 2-3 generated URLs in production; a 308 to the homepage means the whole layer is dormant (real failure mode) |
| PS-02 | Dimension data centralized in config modules (locations, categories, salaries, currencies, timezones), not scattered in templates | Find the data layer; every template reads from it |
| PS-03 | Unique title/description/OG per combination, with real differentiating data (local salary, count, availability) injected | Read `generateMetadata` on the PSEO route |
| PS-04 | Dynamic structured data per combination: `Service` with `areaServed`, `FAQPage`, `BreadcrumbList` | Read the PSEO page schema builders |
| PS-05 | Dynamic FAQs inject the specific category/location/data into questions AND answers | Read the FAQ generator |
| PS-06 | Real data per combination (listings, market rates, testimonials filtered to the market) — not the same content with a swapped city name | Compare two rendered combinations |
| PS-07 | Cross-links between related combinations (same category other locations, same location other categories) | Read the internal-linking section of the template |
| PS-08 | Quality gate wired ON THE PSEO ROUTE: conditional noindex until the combination meets a content threshold (real failure mode: gate implemented on another route type, PSEO pages always indexable) | Read the PSEO route's robots logic specifically |
| PS-09 | Build-time generation (`generateStaticParams` or equivalent) for all valid combinations; ISR alone means first visitors (often crawlers) hit cold renders | Grep the PSEO route for static params |
| PS-10 | hreflang only where regions genuinely differ (country-level pages), always with `x-default`; mirrored in the PSEO sitemap | Read alternates config + sitemap route |
| PS-11 | Subdomain architecture only: DNS automation script (bulk-create records from the same dimension config) and per-subdomain robots.txt | Find the DNS script; curl a subdomain's `/robots.txt` |
| PS-12 | PSEO sitemap exists, is quality-gated, and is reachable from the index | Curl it live |
| PS-13 | A rollback path exists: the system can be disabled without deleting code (kill-switch), and its state (on/off) is documented | Read middleware/config for the switch |

## Adaptable pattern: quality gate (Next.js App Router)

```jsx
async function assessQuality({ category, location }) {
  const listings = await countListings(category, location);
  const market = await getMarketData(category, location);
  return { shouldIndex: listings > 0 && market != null };
}

export async function generateMetadata({ params }) {
  const quality = await assessQuality(params);
  return {
    robots: quality.shouldIndex
      ? { index: true, follow: true }
      : { index: false, follow: true }, // stays crawlable, out of the index
  };
}
```

## Adaptable pattern: kill-switch (middleware)

Disable a live PSEO surface without deleting it — and make the audit aware the layer is off:

```js
// middleware.js — temporary 308 while the subsystem is being reworked
if (isPseoHost(request.headers.get('host'))) {
  return NextResponse.redirect(new URL('/', request.url), 308);
}
```

## Anti-patterns

| Anti-pattern | Why it is bad | Fix |
|--------------|---------------|-----|
| PSEO pages without quality gates | Doorway-page penalty risk; thin duplicates dilute the domain | Conditional noindex until threshold (PS-08) |
| Counting shipped-but-disabled PSEO as implemented | The audit reports capability the site does not have; growth forecasts built on it are fiction | Verify live (PS-01); report built-vs-live explicitly |
| Same template text with only the city swapped | Near-duplicate content at scale | Inject real per-combination data (PS-06) or shrink the page set |
| hreflang across pages that do not differ by region | Wasted crawl signals, alternate-cluster confusion | Country-level only, with x-default (PS-10) |
