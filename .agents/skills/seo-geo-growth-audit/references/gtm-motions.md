# Step 0b — Go-to-Market Motion

How a business wins customers decides which checks matter, which page types carry revenue, what the conversion is, and which failures are fatal. Classify the motion before scoring anything, then weight every layer by it. Statements marked **documented** trace to a search-engine or platform source; **practice** marks working judgement with no primary source behind it.

## Contents

- Classification checks (GM-01 to GM-04)
- Detection signals
- What holds for every motion
- Motion profiles (M1 to M11)
- Hybrids
- Anti-patterns

## Classification checks

| ID | Check | Verify by |
|----|-------|-----------|
| GM-01 | Each page template is classified by the conversion it serves (M1-M11 below), with the evidence for the call; the site's own statement of how it makes money is confirmed with the owner | Detection signals below; ask the owner when signals disagree |
| GM-02 | Findings are weighted by the share of revenue each motion carries: a defect on the template that converts most outranks a cleaner fix elsewhere | Ask for the conversion split; record it in the report header |
| GM-03 | The motion's primary conversion is measured end to end, from the landing page through to the system that records revenue (CRM stage, order, activated account, install) | Walk one tagged visit through the whole path (AA-22 to AA-27) |
| GM-04 | Each motion's fatal failure modes (in its profile below) are checked explicitly, not left to the generic layer passes | The motion profile's failure list, ticked off with evidence |

## Detection signals

Practice: none of these is decisive alone; two or more agreeing signals, confirmed with the owner, classify a template.

| Motion | Signals in the site and codebase |
|--------|----------------------------------|
| M1 Product-led SaaS | "Start free" or signup CTA with no demo wall; self-serve pricing tiers; `/tools` or calculators; an app subdomain with auth routes; a billing SDK |
| M2 Sales-led B2B | "Book a demo" or "Contact sales" as the only CTA; "contact us" pricing; CRM or marketing-automation scripts; gated PDFs; case-study and security pages |
| M3 Local or service-area lead gen | LocalBusiness markup; address and phone in the footer; `/locations/` or city and county pages; click-to-call; call-tracking numbers; a Business Profile link |
| M4 Marketplace | Separate buyer and seller onboarding; listing-creation flows; payout SDK; user-to-user messaging; search and filter routes |
| M5 E-commerce | Cart and checkout routes; Product markup with offers; a product feed; shipping and returns pages |
| M6 Mobile app | Store badges as the main CTA; `apple-itunes-app` meta; `.well-known` association files |
| M7 Content, media, affiliate | Ad slots; affiliate link patterns and disclosures; Article markup on most URLs; newsletter as the main CTA |
| M8 Developer tools, open source | `/docs`, `/api`, SDK install snippets, package-registry and repository links, a changelog, versioned URLs |
| M9 Programmatic or data-driven | Route templates with dynamic segments; very large sitemaps; data-backed pages with swapped tokens |
| M10 Partner or channel | `/partners`, partner locator, partner portal, partner IDs in URLs |
| M11 Regulated (finance, tax, health, legal) | Licensed-professional content, disclaimers, license numbers, outcome or savings claims |

## What holds for every motion

- **Documented.** Google's AI Overviews and AI Mode need a page that is indexed and snippet-eligible, nothing more; Google states that llms.txt, AI-specific markup, chunking, and rewriting for AI are not needed, and that structured data still matters for rich-result eligibility (developers.google.com/search/docs/fundamentals/ai-optimization-guide). Business Profile and Merchant Center data feed Google's AI answers.
- **Documented.** Zero-click exposure is real: in a March 2025 panel of US Google users, visits with an AI summary clicked a traditional result 8% of the time against 15% without one, and clicked a source cited in the summary 1% of the time (Pew Research Center, 2025-07-22). Question-form and long queries trigger summaries most.
- **Documented.** Doorway abuse includes pages "targeted at specific regions or cities that funnel users to one page" and "substantially similar pages that are closer to search results than a clearly defined, browseable hierarchy"; scaled content abuse is many pages generated mainly to manipulate rankings, however they are made (developers.google.com/search/docs/essentials/spam-policies).
- **Documented.** Star ratings in Organization or LocalBusiness markup are ineligible when the entity controls the reviews about itself, including through an embedded third-party reviews widget (developers.google.com/search/docs/appearance/structured-data/review-snippet).
- **Documented.** Microsoft's guidance for Bing and Copilot recommends clear headings, tables, and FAQ sections (blogs.bing.com/webmaster, 2026-02-10, the AI Performance report launch post) and warns against hiding answers in tabs or expandable menus (about.ads.microsoft.com, 2025-10-08), where Google says no special structure is needed; answer-shaped content (GE-10 to GE-13) earns its place with readers and non-Google engines, not as a Google lever.

## Motion profiles

Each profile: the intents and page types that carry the motion; the structured data Google rewards for it; how AI answers change it; the conversion and what to measure; the failures to hunt; and which check families to weight up or down.

### M1 Product-led SaaS

- **Pages:** problem and how-to content, free tools and calculators, use-case and integration pages, comparisons, pricing, docs, signup.
- **Markup (documented):** SoftwareApplication with `offers.price` (0 when free) and a real rating; Organization, Breadcrumb, Article.
- **AI answers:** definitions and calculators are the most exposed to zero-click; original data, benchmarks, and working tools are what gets cited.
- **Conversion:** signup, then activation, then paid. Attribution survives the OAuth round trip and reaches the user record (AA-15, AA-18, AA-24).
- **Hunt:** a tool behind a login or rendered only client-side; a tool page with no path to signup; signup events missing on free, promo, or OAuth paths (AA-23); templated "free tool" pages at scale.
- **Weight up:** AA, LC-23, LC-31, LC-36 to LC-38, TS-32. **Down:** LC-04 unless sales takes over.

### M2 Sales-led B2B

- **Pages:** category and "best X for Y", comparisons, pricing logic, security and compliance, case studies, integrations, demo request.
- **Markup:** Organization, Breadcrumb, Article, SoftwareApplication if software. No lead-generation type exists.
- **AI answers:** buyers research with AI before talking to sales, so the content a sales rep would send (pricing logic, security, comparisons) has to be public and citable. Practice: no primary study quantifies this.
- **Conversion:** demo request qualified to a pipeline stage, measured in the CRM, not at form submit; the click ID travels with the lead for offline conversion import.
- **Hunt:** attribution kept only in notifications (AA-18); form fills counted as the conversion; gated PDFs nobody can cite; account-targeted landing pages indexed as near-duplicates.
- **Weight up:** AA-18 to AA-24, LC-01 to LC-15, LC-21, LC-37, GE-06 to GE-09, CS-05. **Down:** PS, TS-37.

### M3 Local or service-area lead generation

- **Pages:** one page per real location; a page per genuinely served area; service-in-city pages only where each carries distinct, real local substance; the Business Profile.
- **Markup (documented):** LocalBusiness per location in its most specific subtype; Organization; Breadcrumb. `Service` and `areaServed` earn no Google feature. Own-review stars are ineligible.
- **AI answers (documented):** Google states that Business Profile information helps local businesses appear in AI responses (developers.google.com/search/docs/fundamentals/ai-optimization-guide); Microsoft states that keeping a Bing Places listing current keeps address, hours, and contact details "eligible for inclusion in AI-generated responses" (blogs.bing.com/webmaster, 2026-02-10). Local ranking rests on relevance, distance, and prominence.
- **Conversion:** call or form lead, then booked or won job. Measure calls by source, form-to-job rate, and per-location review flow.
- **Hunt:** city or county pages that differ only in the place name (doorway); a Business Profile with keyword-stuffed names or a virtual address; name, address, and phone disagreeing across site, markup, and profile; empty service-area pages left indexed; eligibility claims wider than the area served (LC-41).
- **Weight up:** PS-01 to PS-13 (quality gates first), SD, GE-07 to GE-09, LC-32, LC-41, call tracking. **Down:** CS-07, PF-16.

### M4 Marketplace

- **Pages:** category, location-and-category, listing and profile pages, supply-side onboarding, buyer guides; internal search results kept out of the index.
- **Markup:** Product snippet where the item cannot be bought on the page, merchant listing where it can; ProfilePage; DiscussionForumPosting for genuine user posts.
- **Conversion:** two funnels with separate attribution: listing created then first transaction on the supply side; inquiry or purchase on the demand side.
- **Hunt:** filter and facet URLs indexed; zero-result pages indexed (TS-16); thin generated profiles; expired listings answering 200 instead of 404 or 410; user links not marked `rel="ugc"`.
- **Weight up:** PS, TS-15, TS-16, TS-24, TS-33, SD-04, LC-14, LC-15. **Down:** CS-14 to CS-16 unless there is editorial content.

### M5 E-commerce

- **Pages:** product and category pages with crawlable pagination, buying guides, shipping and returns, store locator.
- **Markup (documented):** Product with merchant listing (shipping and return policy, variants, loyalty), Organization-level return policy, LocalBusiness for physical stores, plus a Merchant Center feed whose price and availability match the page.
- **AI answers:** product data in Merchant Center surfaces in Google's AI answers; agent-driven checkouts are arriving, so order attribution must not drop orders that come through them. Practice: rollout details change monthly; confirm before advising.
- **Conversion:** purchase, with add-to-cart, checkout start, and revenue per session; a server-side purchase carries the click ID (AA-24).
- **Hunt:** price or availability disagreeing between page, markup, and feed; variant URLs duplicating the parent; filtered URLs indexed; copied manufacturer text; review markup not from real buyers.
- **Weight up:** SD (Product family), TS-13 to TS-16, TS-25, TS-31, PF, AA-23, AA-24, LC-37, LC-38. **Down:** LC-04.

### M6 Mobile app

- **Surfaces:** the store listing (where installs are won) and the web pages that rank; store-required privacy, support, and account-deletion pages (LC-40).
- **Markup (documented):** SoftwareApplication or MobileApplication with price and a real rating. Android App Links and Apple Universal Links route web links into the app; Firebase App Indexing is deprecated.
- **Store listing (documented for Apple):** app name, keywords, primary category, and ratings feed App Store search; the description does not. Keep store claims and web claims identical (GE-09, LC-38).
- **Conversion:** install, then first open or activation, then subscription; carry campaign data through the store redirect (Play Install Referrer on Android, campaign links on iOS).
- **Hunt:** the hero CTA not reaching the store (LC-36); association files wrong or redirected (TS-37); a single thin page as the whole web presence; installs counted without activation.
- **Weight up:** TS-37, LC-36, LC-38, LC-40, GE-09, AA-22 to AA-24. **Down:** CS, PS.

### M7 Content, media, affiliate

- **Pages:** articles, reviews and roundups, hubs, evergreen guides; Discover traffic needs large images and no markup.
- **Markup:** Article, Video, Breadcrumb, paywalled-content markup where it applies, Review and Product snippet on genuine editorial reviews, ProfilePage for authors.
- **AI answers:** the most exposed motion — commodity informational content is what AI summaries replace; first-hand testing, original measurement, and named expertise are what survive.
- **Conversion:** engaged sessions for ads, outbound clicks to affiliate sales; affiliate and paid links carry `rel="sponsored"`.
- **Hunt:** thin affiliation (copied merchant descriptions); third-party content hosted for the domain's ranking signals (site reputation abuse); scaled generated articles; fake freshness (TS-19); anonymous authorship.
- **Weight up:** CS (all), TS-06, TS-19, TS-20, SD, GE-14, PF (ad-driven layout shift), AA-07, AA-08. **Down:** LC, PS unless programmatic.

### M8 Developer tools, open source

- **Pages:** docs, API reference, changelogs, tutorials, error-message pages, integrations, comparisons.
- **Markup:** SoftwareApplication; Article or BlogPosting for tutorials (Google's Article documentation lists only `Article`, `NewsArticle`, and `BlogPosting`, so mark technical articles as one of those); Breadcrumb. `SoftwareSourceCode` earns no Google feature.
- **AI answers:** coding agents are the clearest consumers of llms.txt and markdown copies of docs (practice; Google Search ignores both), so GE-01 to GE-03 matter more here than anywhere.
- **Conversion:** API key or first successful call, then paid; much of the funnel happens off-site (package installs).
- **Hunt:** docs rendered only client-side or behind a login; versioned duplicates without a canonical to the current version; stale code samples.
- **Weight up:** TS-32, TS-14, TS-38, GE-01 to GE-03, CS-03. **Down:** LC-04 to LC-09, PS, TS-37.

### M9 Programmatic or data-driven

- **Pages:** entity pages, category-and-location combinations, rankings, downloadable datasets.
- **Markup:** Dataset (feeds Dataset Search only), Breadcrumb, LocalBusiness where entities are businesses.
- **AI answers:** unique, structured data is the most citable asset, and government sources are over-represented in Google's AI summaries (Pew: 6% of cited sources against 2% of standard results); mass combinations are the doorway and scaled-content risk.
- **Conversion:** whatever the site monetises — find it first. Measure the share of generated URLs that are indexed and earn impressions.
- **Hunt:** pages that differ only in swapped tokens; a programmatic layer disabled by a kill-switch (PS-01); sitemaps listing non-indexable URLs; no quality gate before indexing (PS-08); stale data.
- **Weight up:** PS-01 to PS-13, TS-01 to TS-11, TS-16, TS-31, TS-33, CS-10. **Down:** LC, GE-12, GE-13.

### M10 Partner or channel

- **Pages:** partner directory and profiles, locator, co-branded and integration pages, partner recruitment pages per profession.
- **Conversion:** partner-sourced lead or registered deal, attributed by a partner ID that reaches the order or CRM, not by a web analytics event.
- **Hunt:** thin generated partner pages; syndicated duplicates across partner sites; partner terms (commission, referral reward) that differ by page (LC-42).
- **Weight up:** TS-14, TS-22, SD-02, SD-03, PS, AA-17, AA-18, GE-08, GE-09, LC-42. **Down:** PF-16, CS-07.

### M11 Regulated: finance, tax, health, legal

- **Pages:** expert-reviewed guides, calculators, practitioner and office pages, and the who-is-behind-this pages: about, credentials, licensing, contact, complaints.
- **Documented:** Google's rater guidelines hold "Your Money or Your Life" topics (health, financial security, legal) to the highest standard and weigh trust most; the guidelines do not set rankings directly, but AI Overviews are built on the same quality systems.
- **Conversion:** consultation, application, or booking, under claims a regulator would accept; measurement that keeps personal data out of analytics.
- **Hunt:** anonymous or unqualified authors; no review layer; missing licensing or complaints information; outcome promises and savings claims without evidence (LC-37, LC-38, LC-41); fabricated reviews.
- **Weight up:** CS-14 to CS-16, GE-07, GE-14, SD-03, SD-04, LC-37, LC-38, LC-41, TS-34. **Down:** PF-16, CS-07.

## Hybrids

Audit per template, not per site, and report findings sized by each motion's share of conversions (GM-02). Practice examples:

- **Local lead generation with a self-serve checkout:** score the location pages as M3 (doorway risk, Business Profile), the checkout as M5 (price parity between page, markup, and claims), and the hand-off between them as one funnel whose click ID must survive the move (AA-27).
- **App with a marketing site:** score the store listing as an owned page beside the web pages; the site's hero CTA, association files, price claims, and install measurement must agree with the listing.
- **Partner programme bolted onto a consumer site:** score partner recruitment pages as M10 and keep their terms consistent with the consumer referral programme (LC-42).

## Anti-patterns

| Anti-pattern | Why it is bad | Fix |
|--------------|---------------|-----|
| Scoring every site against every check | A private app fails growth checks it never needed; a marketplace's fatal facet problem drowns among cosmetic findings | Classify first (GM-01), weight by revenue (GM-02) |
| Treating informational traffic as the goal on a lead-generation site | AI summaries absorb most of it; the pages that convert are the ones that must win | Measure and prioritise the converting templates (GM-03) |
| Copying a content-site playbook onto a local service | City pages at scale read as doorways | Real local substance per page, or fewer pages (M3) |
