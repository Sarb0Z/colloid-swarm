# Layer 2 — Structured Data (JSON-LD)

Machine-readable entity and content markup. Structured data feeds both rich results and AI-search answers, so factual accuracy matters as much as validity.

## Contents

- Checks (SD-01 to SD-10)
- Schema type map
- Adaptable pattern: safe JSON-LD injection
- Anti-patterns

## Checks

| ID | Check | Verify by |
|----|-------|-----------|
| SD-01 | Every major template injects the JSON-LD types relevant to its content (see type map below) | View source per template; count `application/ld+json` blocks |
| SD-02 | Site-wide entities (Organization, WebSite) have exactly one source-of-truth builder module | Grep all files defining the entity; duplicated definitions drift (real failure mode: two Organization schemas disagreeing on foundingDate by two years) |
| SD-03 | Entity facts are consistent across JSON-LD, llms.txt, and visible page content | Compare founding date, headcount, locations, claims across all three |
| SD-04 | Ratings and review counts come from real data; zero hardcoded `aggregateRating` values | Grep `aggregateRating` and trace every instance to a data source (real failure mode: a fabricated 4.9/13,542 rating shipped site-wide — a manual-action risk) |
| SD-05 | Field semantics are correct: `numberOfEmployees` means employees (not marketplace pool size), `datePublished` means published (not fetched), `author` is a real person or org | Review every numeric or factual claim in schema builders |
| SD-06 | HTML is stripped from text fields before injection (`striptags` or equivalent, applied in the builder) | Read the schema builder utilities |
| SD-07 | All image/url/logo references are absolute URLs | Grep for relative paths inside schema builders |
| SD-08 | `@context: "https://schema.org"` present; related schemas on one page combined in a single `@graph` array rather than scattered script tags | View source |
| SD-09 | Injection is a server-rendered plain `<script type="application/ld+json">`; framework-specific loader props (Next.js `strategy=`) are invalid on native script tags and JSON-LD must never be deferred — crawlers read the initial HTML | `grep -rn '<script' --include='*.jsx' \| grep 'strategy='` (real failure mode: five templates shipping the invalid attribute) |
| SD-10 | Markup validates (Google Rich Results test, schema.org validator) and eligible types actually earn enhancements in Search Console | Paste rendered HTML into the validator; check Search Console enhancement reports |

## Schema type map

Apply where the site has the corresponding content. Absence of a type is only a finding when the content type exists.

| Schema type | Where it belongs |
|-------------|------------------|
| `Organization` | Site-wide, single builder (logo, `sameAs` social/authority links, contact) |
| `WebSite` + `SearchAction` | Homepage; enables sitelinks search box for content hubs |
| `WebPage` | Every page; add `speakable` for voice-friendly sections |
| `Product` | Product/pricing pages (real `aggregateRating`, `offers`) |
| `Service` | Service pages (`areaServed` for local relevance, `OfferCatalog`) |
| `HowTo` | Tutorials, step-by-step guides, process pages |
| `FAQPage` | FAQ sections (`Question`/`acceptedAnswer` pairs, plain text) |
| `ItemList` / `CollectionPage` | Listings, directories, category pages |
| `BlogPosting` / `Article` / `TechArticle` | Posts, case studies, engineering content (author, publisher, dates, image) |
| `BreadcrumbList` | Every major page type |
| `ProfilePage` + `Person` | People/professional profiles |
| `PodcastEpisode` + `PodcastSeries` | Podcast pages (ISO 8601 `duration`) |
| `LearningResource` | Courses, roadmaps, structured learning paths |
| `SoftwareSourceCode` | Open-source projects, repos |
| `WebApplication` | SaaS tools, calculators, utilities |
| `Review` + `VideoObject` | Testimonials backed by video |
| `JobPosting` | Live career listings (not job-description templates) |
| `SpeakableSpecification` | Voice-search-friendly summaries |

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
| Deferring or lazy-loading JSON-LD | Crawlers and AI bots read initial HTML; deferred markup may never be seen | Server-render it |
