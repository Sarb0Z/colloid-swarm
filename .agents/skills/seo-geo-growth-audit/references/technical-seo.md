# Layer 1 — Technical SEO Foundation

Crawlability, indexability, and URL hygiene. Audit both the repository and the live site: canonical-host behavior often lives at the CDN (invisible in the repo), and sitemap wiring frequently breaks only in production.

## Contents

- Sitemap checks (TS-01 to TS-11)
- Metadata and canonical checks (TS-12 to TS-20)
- Infrastructure and URL hygiene checks (TS-21 to TS-31)
- Rendering, access, and host checks (TS-32 to TS-38)
- Adaptable pattern: dynamic metadata with tiered indexing
- Anti-patterns

## Sitemap checks

| ID | Check | Verify by |
|----|-------|-----------|
| TS-01 | Sitemap index at `/sitemap.xml` aggregates all sub-sitemaps | `curl -s $BASE_URL/sitemap.xml` returns a `<sitemapindex>` |
| TS-02 | Every sitemap listed in the index resolves live with HTTP 200 and an XML content type | HEAD-request each child `<loc>`; a listed-but-unrouted sitemap 404s silently, and on a single-page app it answers 200 `text/html` from the catch-all instead (real failure modes: index entry with no matching route/rewrite; sitemap served as the app shell) |
| TS-03 | No orphan sitemap routes: every sitemap route in the repo is reachable via the index or a route/rewrite | Diff sitemap route files against index entries and routing config |
| TS-04 | Large datasets are chunked, with one consistent chunk size across all routes | Read the chunk constant in each route; ~5,000 URLs/chunk is a validated working size (50,000 is the protocol ceiling); mismatched constants across routes signal drift |
| TS-05 | Hybrid static + dynamic sitemaps apply a quality gate: only URLs whose content actually exists and is published get included | Read the query filters in dynamic sitemap routes |
| TS-06 | `<lastmod>` is accurate: it changes when the page's content changes and at no other time. Google ignores `<priority>` and `<changefreq>` and uses `<lastmod>` only when it is consistently verifiable | Compare `<lastmod>` on a few URLs with their real last content change; a lastmod that equals the build time on every URL is noise |
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
| TS-17 | Open Graph on every shareable template: title, description, 1200x630 image, `og:type`, `og:locale` — sweep for templates missing `og:image` (a high-value route missing it is a real failure mode) | Grep `openGraph` per template, then fetch every `og:image`/`twitter:image` URL live: expect 200, an `image/*` type, and at least 1200x630 (real failure mode: an `og:image` path under `/public/`, which the build strips, so the catch-all answers it with HTML) |
| TS-18 | Twitter card `summary_large_image` on visual content pages | Grep `twitter` metadata |
| TS-19 | Freshness signals: current month/year in titles and descriptions where content is actively maintained — computed at render/revalidate time, never hardcoded | Read title builders |
| TS-20 | Draft/preview mode lets editors view unpublished content without exposing it (draft mode + CMS draft status fetch) | Grep `draftMode` or the CMS preview flag |

## Infrastructure and URL hygiene checks

| ID | Check | Verify by |
|----|-------|-----------|
| TS-21 | robots.txt is config/route-driven with granular disallows: API and admin paths, faceted-filter query params, framework data probes (e.g. `/*_rsc=*`) | Read the robots source; `curl -s $BASE_URL/robots.txt` |
| TS-22 | robots disallows and sitemap inclusion are consistent: any URL set that is sitemapped but robots-blocked must be a documented, deliberate crawl-budget decision, not an accident | Cross-reference disallow rules against sitemap contents |
| TS-23 | Canonical host verified live: HTTPS enforced, www vs apex 301/308s to one form, trailing-slash policy consistent — these often live at the CDN and are invisible in the repo, so curl the variants | `curl -sI` on `http://`, `www.`, and trailing-slash variants |
| TS-24 | Permanent redirects (301/308) for moved or renamed pages; a removed page with no successor answers 410 | Framework redirects config + middleware, then `curl -sI` a removed path. On a single-page app the client router's catch-all cannot send either — only the server or CDN can (real failure mode: a deleted page "sent to the 404 view" by the router while the server still answers 200) |
| TS-25 | Tracking-parameter hygiene: canonicals point to clean URLs; server-side redirect to the clean URL where cheap (which params to strip client-side, and when, is an analytics-layer decision) | Read redirect/canonical handling for URLs carrying query params |
| TS-26 | Slug normalization for special characters with a bidirectional mapping (C++ -> cpp, C# -> c-sharp, .NET -> dotnet) | Find the slug utility; test both directions |
| TS-27 | Custom 404: branded, navigable, and returns a real 404 status — probe a garbage URL; a 200 response is a soft-404. A static or single-page host needs a server rule that returns 404 for unknown paths, or at minimum a not-found view that sets `noindex` | `curl -s -o /dev/null -w '%{http_code}' $BASE_URL/no-such-page-xyz` |
| TS-28 | Security headers: server fingerprint off (`X-Powered-By` removed), `frame-ancestors` CSP restricting embedding (allowing CMS preview hosts is fine when deliberate), HSTS and CSP on the HTML document response itself, not only on API responses — and set by the layer that actually serves the page | `curl -sI` the homepage. A headers file for one host (a Pages `_headers`, a `vercel.json`) does nothing when another server serves the site (real failure mode: CSP and HSTS declared in a file the production web server explicitly denies) |
| TS-29 | On-demand cache purge mechanism (API endpoint or middleware bridge) exists for content mutations | Grep for the purge route/util |
| TS-30 | Framework data requests do not poison the HTML cache (Next.js RSC: `Vary` on RSC headers, `no-store` on data probes, `missing`-header conditions on stale-while-revalidate rules) | Read cache headers config; compare `curl` with and without the framework's data-request header |
| TS-31 | High-traffic parameterized routes are statically generated (build-time params) with ISR/revalidation; long-tail routes at minimum revalidate | Grep `generateStaticParams`/`revalidate` (or the framework equivalent) per route |

## Rendering, access, and host checks

| ID | Check | Verify by |
|----|-------|-----------|
| TS-32 | Every indexable route of a client-rendered app returns its own title, description, canonical, `og:url`, H1, and main copy in the initial HTML; otherwise prerender, statically generate, or server-render the public routes (P1) | `curl` each public route without JavaScript and diff the head tags: identical titles, or a canonical pointing at `/` on every route, fold the whole site into the home page. An empty root element (`<div id="root"></div>`) is an empty page to any crawler that does not run JavaScript |
| TS-33 | Route table and sitemap agree both ways: no sitemapped URL that no route renders, no indexable route missing from the sitemap | Diff the router's route list against the live sitemap's `<loc>` set; on a single-page app an unrouted sitemap URL still answers 200 with the home page, so status alone never catches it |
| TS-34 | Private surfaces stay out of the index: staging and preview hosts, admin hosts, authenticated route trees, token-bearing links, and private downloads send `X-Robots-Tag: noindex` at the server or CDN (plus `Referrer-Policy: no-referrer` on token links), and none appears in a sitemap | `curl -sI` each surface. A robots.txt disallow alone does not deindex a URL that is linked elsewhere; the header does |
| TS-35 | Crawler files and static asset paths bypass both the catch-all rewrite and any auth middleware: robots.txt, sitemaps, llms.txt, social images, `.well-known/` files, and module scripts each return their own content type to an unauthenticated client, and range requests return 206 | Fetch each as a logged-out client and assert the type is not `text/html`. The failure recurs whenever a new static directory or extension is added without updating the matcher, so a post-deploy smoke per directory holds the line |
| TS-36 | A company or app site carries none of the template or previous project it was forked from: no old package names, domains, app IDs, placeholder API fallbacks (`api.yourservice.com`), or template README titles, including in `.well-known/`, env examples, and manifests | Grep the repository for the previous project's identifiers and for `example.com`/`yourservice`-style placeholders; a placeholder fallback URL that is live in production is a P1 |
| TS-37 | Companion-app sites: `apple-app-site-association` and `assetlinks.json` answer 200 with `application/json` and no redirect, their app IDs match the store listings, and their paths are scoped to app links rather than `*`; store badges point at the storefront for the target market, and every copy of a store link agrees | `curl -sI` both association files; compare the package and team IDs with the listing; grep store URLs for the country path (real failure modes: an Android package ID left from the template; every App Store button opening a different country's storefront) |
| TS-38 | Indexable HTML stays well under Googlebot's 2 MB fetch limit (uncompressed, applied per file, including each referenced CSS and JS file); content past the limit is not indexed | `curl -s $URL \| wc -c` on the heaviest templates; inline JSON payloads (framework data, embedded state) are the usual cause |

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
| `robots.txt` or `sitemap.xml` kept outside the directory the build publishes (`public/` for Vite, Next.js, and most bundlers) | A single-page app's catch-all answers the path `200` with its index page, so crawlers get HTML and the site looks fine to a status-only check | Keep the file in the published directory; TS-21 and TS-01 fail a live answer that is HTML |
| Robots-blocking URL sets that the sitemap submits | Contradictory crawl signals; pages may index URL-only with no snippet | Make it a documented decision or fix whichever side is wrong |
| Hardcoded year/month in titles | Goes stale and then signals neglect | Compute freshness at render/revalidate time |
