# Layer 2 — Structured Data (JSON-LD)

Machine-readable entity and content markup. In Google it earns a rich result only for types Google still supports, and Google's generative AI search needs none of it; other engines and parsers also read it, so factual accuracy matters as much as validity.

## Contents

- Checks (SD-01 to SD-13)
- Schema type map
- Adaptable pattern: safe JSON-LD injection
- Anti-patterns

## Checks

| ID | Check | Verify by |
|----|-------|-----------|
| SD-01 | Every major template injects the JSON-LD types relevant to its content (see type map below) | View source per template; count `application/ld+json` blocks |
| SD-02 | Site-wide entities (Organization, WebSite) have exactly one source-of-truth builder module | Grep all files defining the entity; duplicated definitions drift (real failure mode: two Organization schemas disagreeing on foundingDate by two years) |
| SD-03 | Entity facts are consistent across JSON-LD, llms.txt, and visible page content | Compare founding date, headcount, locations, claims across all three |
| SD-04 | Ratings and review counts come from real data; zero hardcoded `aggregateRating` values | Grep `aggregateRating` and trace every instance to a data source (real failure mode: a fabricated 4.9/13,542 rating shipped site-wide — a manual-action risk). Google's review-snippet guidelines also exclude fake and undisclosed incentivized reviews |
| SD-05 | Field semantics are correct: `numberOfEmployees` means employees (not marketplace pool size), `datePublished` means published (not fetched), `author` is a real person or org | Review every numeric or factual claim in schema builders |
| SD-06 | HTML is stripped from text fields before injection (`striptags` or equivalent, applied in the builder) | Read the schema builder utilities |
| SD-07 | All image/url/logo references are absolute URLs; the page's main entity (the `WebPage`, `Article`, or `Product` the page is about) has a `url` equal to the page's canonical, and breadcrumb `item` values sit on the canonical host (practice: Google documents no host rule, but a mismatch splits signals between hosts) | Grep for relative paths inside schema builders; on the live site compare each JSON-LD URL with the page's `rel="canonical"` (real failure modes: entity URLs on the apex host while pages canonicalize to `www`; an article `url` pointing at the CMS collection path instead of the public one) |
| SD-08 | `@context: "https://schema.org"` present; related schemas on one page combined in a single `@graph` array rather than scattered script tags | View source |
| SD-09 | Injection is a server-rendered plain `<script type="application/ld+json">`; framework-specific loader props (Next.js `strategy=`) are invalid on native script tags and JSON-LD must never be deferred — crawlers read the initial HTML | `grep -rn '<script' --include='*.jsx' \| grep 'strategy='` (real failure mode: five templates shipping the invalid attribute) |
| SD-10 | Markup validates and eligible types actually earn enhancements in Search Console | Google's Rich Results Test for types Google supports; validator.schema.org for everything else (the Rich Results Test no longer checks retired types); Search Console enhancement reports |
| SD-11 | No type is recommended for a Google rich result Google no longer shows: confirm it in the current Search gallery first. Retired: HowTo (2023), sitelinks search box (2024), Course Info, Claim Review, Estimated Salary, Learning Video, Special Announcement, Vehicle Listing (2025), FAQ (May 2026). Dataset markup feeds Dataset Search only | developers.google.com/search/docs/appearance/structured-data/search-gallery and the Search Central changelog |
| SD-12 | No empty or placeholder values: no empty strings in `sameAs`, `name`, `url`, or `image`, no unfilled template fields (a CMS field left blank renders `""` into every page of the collection). Star ratings on `Organization` or `LocalBusiness` (and their subtypes) are ineligible when the entity controls the reviews about itself, including reviews shown through an embedded third-party widget; a site that reviews other businesses stays eligible | Parse every JSON-LD block on a sample of each template and list empty values; developers.google.com/search/docs/appearance/structured-data/review-snippet for the self-serving rule |
| SD-13 | Publication dates (`datePublished`, `dateModified`, `uploadDate`) are ISO 8601 with a time zone (Google recommends one and otherwise assumes Googlebot's), `dateModified` is never earlier than `datePublished`, neither is in the future, and both match the dates shown on the page. Forward-looking dates (`startDate`, `priceValidUntil`, `validThrough`) are out of scope | Compare the two fields on a sample of articles; a modified date earlier than the published one usually means the CMS's publish and update fields are mapped the wrong way round |

## Schema type map

Apply where the site has the corresponding content. Absence of a type is only a finding when the content type exists.

| Schema type | Where it belongs |
|-------------|------------------|
| `Organization` | Site-wide, single builder (logo, `sameAs` social/authority links, contact) |
| `WebSite` | Homepage; supplies the site name (`SearchAction` no longer earns a sitelinks search box) |
| `WebPage` | Every page |
| `Product` | Product/pricing pages (real `aggregateRating`, `offers`); e-commerce merchant listings add shipping and return policy per Google's merchant listing documentation |
| `Service` | Service pages (`areaServed` for local relevance, `OfferCatalog`) |
| `HowTo` | Optional on step-by-step guides for non-Google parsers; earns no Google rich result |
| `FAQPage` | Optional on FAQ sections (`Question`/`acceptedAnswer` pairs, plain text) for non-Google parsers; earns no Google rich result |
| `ItemList` / `CollectionPage` | Listings, directories, category pages |
| `BlogPosting` / `Article` / `NewsArticle` | Posts, case studies, engineering content (author, publisher, dates, image); these are the three types Google's Article documentation lists, so prefer them over subtypes such as `TechArticle` |
| `BreadcrumbList` | Every major page type |
| `ProfilePage` + `Person` | People/professional profiles |
| `PodcastEpisode` + `PodcastSeries` | Podcast pages (ISO 8601 `duration`) |
| `LearningResource` | Courses, roadmaps, structured learning paths |
| `SoftwareSourceCode` | Open-source projects, repos |
| `WebApplication` | SaaS tools, calculators, utilities |
| `Review` + `VideoObject` | Testimonials backed by video |
| `JobPosting` | Live career listings (not job-description templates) |
| `SpeakableSpecification` | News articles only, where the publisher wants Google Assistant read-aloud (beta, US English) |

## Adaptable pattern: safe JSON-LD injection (Next.js App Router)

Build each entity in one shared module; render in a server component:

```jsx
import { buildOrganizationSchema } from '@/lib/schema/organization';

export default function Page() {
  const schema = buildOrganizationSchema(); // single source of truth, striptags inside
  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(schema) }}
      />
      {/* page content */}
    </>
  );
}
```

## Anti-patterns

| Anti-pattern | Why it is bad | Fix |
|--------------|---------------|-----|
| Hardcoded `aggregateRating` / review counts | Misleading structured data risks a Google manual action; also feeds false facts to AI answers | Compute from real review data or omit the field |
| Framework loader props on native `<script>` tags | Invalid HTML; can cause hydration errors; signals copy-paste of client-script patterns onto crawler-critical markup | Plain server-rendered script tag (pattern above) |
| Duplicated entity builders per page | Facts drift apart; contradictory signals to crawlers and AI engines | One builder module per site-wide entity (SD-02) |
| Adding FAQPage or HowTo to win a Google rich result | Google no longer shows either | Spend the effort on a supported type (SD-11) |
| Deferring or lazy-loading JSON-LD | Crawlers and AI bots read initial HTML; deferred markup may never be seen | Server-render it |
