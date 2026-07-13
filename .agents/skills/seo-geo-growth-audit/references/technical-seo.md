# Layer 1 — Technical SEO Foundation

Crawlability, indexability, and URL hygiene. Audit both the repository and the live site: canonical-host behavior often lives at the CDN (invisible in the repo), and sitemap wiring frequently breaks only in production.

## Contents

- Sitemap checks (TS-01 to TS-11)
- Metadata and canonical checks (TS-12 to TS-20)
- Infrastructure and URL hygiene checks (TS-21 to TS-31)
- Adaptable pattern: dynamic metadata with tiered indexing
- Anti-patterns

## Sitemap checks

| ID | Check | Verify by |
|----|-------|-----------|
| TS-01 | Sitemap index at `/sitemap.xml` aggregates all sub-sitemaps | `curl -s $BASE_URL/sitemap.xml` returns a `<sitemapindex>` |
| TS-02 | Every sitemap listed in the index resolves live with HTTP 200 | HEAD-request each child `<loc>`; a listed-but-unrouted sitemap 404s silently (real failure mode: index entry with no matching route/rewrite) |
| TS-03 | No orphan sitemap routes: every sitemap route in the repo is reachable via the index or a route/rewrite | Diff sitemap route files against index entries and routing config |
| TS-04 | Large datasets are chunked, with one consistent chunk size across all routes | Read the chunk constant in each route; ~5,000 URLs/chunk is a validated working size (50,000 is the protocol ceiling); mismatched constants across routes signal drift |
| TS-05 | Hybrid static + dynamic sitemaps apply a quality gate: only URLs whose content actually exists and is published get included | Read the query filters in dynamic sitemap routes |
| TS-06 | `<priority>` tiers reflect traffic value (e.g. 1.0 home, 0.8 hubs, 0.3-0.4 long-tail profiles) | Read priority values per route |
| TS-07 | XSL stylesheet renders sitemaps human-readable in a browser | Open `/sitemap.xml` in a browser; look for an `xml-stylesheet` reference |
| TS-08 | Content mutations purge both the page cache and the matching sitemap cache | Trace the purge path (framework revalidation + CDN purge API); purging the page but not its sitemap leaves stale lastmod/URL sets |
| TS-09 | Every dynamic sitemap query has a timeout fail-safe returning a partial or empty set instead of hanging | Look for a race/timeout wrapper around DB queries in each sitemap route, not just one |
| TS-10 | Empty query results inject a fallback URL so the XML stays valid | Read the empty-result branch of dynamic routes |
| TS-11 | Sitemaps are served cached (ISR/revalidate 3600-86400), never fully dynamic | Grep sitemap routes for `force-dynamic`; see anti-patterns |

## Metadata and canonical checks

| ID | Check | Verify by |
|----|-------|-----------|
| TS-12 | Global metadata base URL set once (framework `metadataBase` or equivalent) | Root layout/config |
| TS-13 | Dynamic metadata generation on every parameterized route type (blog, product, profile, category, listing) | Count `generateMetadata` (or equivalent) against dynamic route directories |
| TS-14 | Explicit canonical URL on every indexable page | View-source spot checks + template review |
| TS-15 | Tiered canonical/noindex logic: unknown slug -> `noindex,nofollow`; known-but-unpublished (quality gate failed) -> `noindex,follow` + canonical rewritten to the parent listing; published -> self-canonical; CMS canonical override supported | Read the metadata branch logic on the highest-traffic dynamic route |
| TS-16 | Conditional noindex for thin content: empty categories, zero-result listings, pagination (`index:false` beyond page 1, `follow` through roughly page 3) | Read listing/pagination metadata |
| TS-17 | Open Graph on every shareable template: title, description, 1200x630 image, `og:type`, `og:locale` — sweep for templates missing `og:image` (a high-value route missing it is a real failure mode) | Grep `openGraph` per template |
| TS-18 | Twitter card `summary_large_image` on visual content pages | Grep `twitter` metadata |
| TS-19 | Freshness signals: current month/year in titles and descriptions where content is actively maintained — computed at render/revalidate time, never hardcoded | Read title builders |
| TS-20 | Draft/preview mode lets editors view unpublished content without exposing it (draft mode + CMS draft status fetch) | Grep `draftMode` or the CMS preview flag |

## Infrastructure and URL hygiene checks

| ID | Check | Verify by |
|----|-------|-----------|
| TS-21 | robots.txt is config/route-driven with granular disallows: API and admin paths, faceted-filter query params, framework data probes (e.g. `/*_rsc=*`) | Read the robots source; `curl -s $BASE_URL/robots.txt` |
| TS-22 | robots disallows and sitemap inclusion are consistent: any URL set that is sitemapped but robots-blocked must be a documented, deliberate crawl-budget decision, not an accident | Cross-reference disallow rules against sitemap contents |
| TS-23 | Canonical host verified live: HTTPS enforced, www vs apex 301/308s to one form, trailing-slash policy consistent — these often live at the CDN and are invisible in the repo, so curl the variants | `curl -sI` on `http://`, `www.`, and trailing-slash variants |
| TS-24 | Permanent redirects (301/308) for moved or renamed pages | Framework redirects config + middleware |
| TS-25 | Tracking-parameter hygiene: canonicals point to clean URLs; server-side redirect to the clean URL where cheap (which params to strip client-side, and when, is an analytics-layer decision) | Read redirect/canonical handling for URLs carrying query params |
| TS-26 | Slug normalization for special characters with a bidirectional mapping (C++ -> cpp, C# -> c-sharp, .NET -> dotnet) | Find the slug utility; test both directions |
| TS-27 | Custom 404: branded, navigable, and returns a real 404 status — probe a garbage URL; a 200 response is a soft-404 | `curl -s -o /dev/null -w '%{http_code}' $BASE_URL/no-such-page-xyz` |
| TS-28 | Security headers: server fingerprint off (`X-Powered-By` removed), `frame-ancestors` CSP restricting embedding (allowing CMS preview hosts is fine when deliberate) | `curl -sI` the homepage |
| TS-29 | On-demand cache purge mechanism (API endpoint or middleware bridge) exists for content mutations | Grep for the purge route/util |
| TS-30 | Framework data requests do not poison the HTML cache (Next.js RSC: `Vary` on RSC headers, `no-store` on data probes, `missing`-header conditions on stale-while-revalidate rules) | Read cache headers config; compare `curl` with and without the framework's data-request header |
| TS-31 | High-traffic parameterized routes are statically generated (build-time params) with ISR/revalidation; long-tail routes at minimum revalidate | Grep `generateStaticParams`/`revalidate` (or the framework equivalent) per route |

## Adaptable pattern: dynamic metadata with tiered indexing (Next.js App Router)

Concrete values and field names are validated examples — adapt to the target.

```jsx
export async function generateMetadata({ params }) {
  const page = await fetchPage(params.slug);
  if (!page) {
    // Unknown slug: keep it out of the index entirely
    return { title: 'Page Not Found', robots: { index: false, follow: false } };
  }
  const publishable = page.requiredSectionsPublished; // quality gate
  return {
    title: `${page.metaTitle || page.title} | Brand`,
    description: page.metaDescription || page.excerpt?.slice(0, 160),
    alternates: {
      // Thin/unpublished content canonicalizes to its parent listing; CMS may override
      canonical: page.canonicalOverride
        || (publishable ? `${BASE}/section/${page.slug}` : `${BASE}/section`),
    },
    robots: publishable ? { index: true, follow: true } : { index: false, follow: true },
    openGraph: {
      title: page.title,
      description: page.excerpt,
      images: [{ url: page.ogImage, width: 1200, height: 630 }],
      type: 'article',
      locale: 'en_US',
    },
    twitter: { card: 'summary_large_image' },
  };
}
```

## Anti-patterns

| Anti-pattern | Why it is bad | Fix |
|--------------|---------------|-----|
| `force-dynamic` on sitemap routes | Uncached DB query on every crawler hit; crawlers hit sitemaps constantly | ISR with revalidate 3600+ |
| Sitemap listed in the index without a live route/rewrite | Silent 404 wastes crawl budget and erodes crawler trust in the index | Enforce TS-02 in CI or via the quick-audit script |
| Robots-blocking URL sets that the sitemap submits | Contradictory crawl signals; pages may index URL-only with no snippet | Make it a documented decision or fix whichever side is wrong |
| Hardcoded year/month in titles | Goes stale and then signals neglect | Compute freshness at render/revalidate time |
