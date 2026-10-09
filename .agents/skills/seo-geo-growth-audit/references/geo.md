# Layer 3 — GEO (Generative Engine Optimization)

Visibility in AI answers. Google's AI Overviews and AI Mode draw on the ordinary Search index: a page needs to be indexed and snippet-eligible, nothing more, and Google states that it ignores llms.txt and AI-specific markup. Other engines (ChatGPT, Claude, Perplexity, Copilot, Meta AI) run their own crawlers or a partner index. So the levers are: decide crawler access per crawler class, keep the controls that remove a site from AI features in the state you intend, publish entity facts consistently, and measure AI visibility where the engines report it.

## Contents

- Discovery checks (GE-01 to GE-05)
- Entity signal checks (GE-06 to GE-09)
- Answer-shaped content checks (GE-10 to GE-14)
- Control and measurement checks (GE-15 to GE-16)
- Crawler classes
- Template: llms.txt
- Anti-patterns

## Discovery checks

| ID | Check | Verify by |
|----|-------|-----------|
| GE-01 | `/llms.txt`, when shipped, follows the spec: an H1 naming the site (the only required part), a blockquote summary, then H2 sections of `[name](url): notes` link lists, small enough to fit in a model's context. It is optional (P3): Google states Search ignores it, and the AI vendors' crawler pages describe robots.txt controls, not llms.txt | `curl -s $BASE_URL/llms.txt`; a 200 `text/html` answer is the catch-all, not a file |
| GE-02 | Pages that have an llms.txt or markdown copy point to them: `<link rel="describedby" href="/llms.txt">` (or an HTTP `Link:` header) and `<link rel="alternate" type="text/markdown" href="…">` | View source or `curl -sI` a page. `rel="llms"` is not in the spec |
| GE-03 | `/llms-full.txt` (extended corpus) — optional; note as an enhancement, not a gap | curl it |
| GE-04 | Crawler policy is an EXPLICIT decision per crawler class, verified live: for each training and search-index token in the crawler-class table, determine explicit-allow / explicit-block / wildcard-block (no group of its own, but `*` blocks everything) / unspecified from the live robots.txt, applying robots rules as crawlers do (a group naming the token beats `*`; stacked `User-agent` lines share one group). Record any `Content-Signal:` line (`search`, `ai-input`, `ai-train`). Blocking a training crawler does not remove a site from that vendor's search answers; blocking its search-index crawler does | Parse `curl -s $BASE_URL/robots.txt` per token |
| GE-05 | The edge does not silently override the policy: CDN bot management and AI-crawler controls (Cloudflare AI Crawl Control, managed robots.txt) can block or rewrite what the repository declares. A robots token is a request, not enforcement: user-triggered fetchers generally ignore robots.txt, and some crawlers have been reported evading it, so blocking that must hold belongs at the CDN, verified by IP and reverse DNS, never by user agent alone | CDN dashboard settings; compare live fetch behavior with robots.txt |

## Entity signal checks

| ID | Check | Verify by |
|----|-------|-----------|
| GE-06 | Clear entity definition: who/what the page is about stated in the H1 and first paragraph, not implied | Read key pages as an outsider |
| GE-07 | Entity-hub page: a dedicated route (e.g. `/about`) consolidating company facts with its own Organization schema, linked from llms.txt when one exists | Route + schema + the llms.txt link |
| GE-08 | Organization schema `sameAs` links to authority profiles (Wikipedia, Crunchbase, LinkedIn, GitHub) | Schema builder |
| GE-09 | Fact consistency across llms.txt, JSON-LD, visible content, and every other place the product describes itself (app-store listing, in-app pricing) — founding year, headcount, locations, plans, prices, claims (real failure modes: two different founding dates plus a headcount field actually holding marketplace pool size; a FAQ promising a free tier the app does not have) | Diff the sources field by field; where the sources disagree with each other, publish neither figure until they agree |

## Answer-shaped content checks

General content quality that helps every engine extract an answer. Google states none of it is required for its AI features, and that rewriting or splitting content for AI is unnecessary; producing page variants to match AI "fan-out" queries falls under its scaled-content-abuse policy. Microsoft's guidance for Bing and Copilot does recommend them ("Clear headings, tables, and FAQ sections help surface key information", Bing Webmaster Blog, 2026-02-10), and warns that AI systems may not render answers hidden in tabs or expandable menus (Microsoft Advertising, 2025-10-08), so these checks earn their place with readers and non-Google engines; score them as such, never as a Google ranking lever.

| ID | Check | Verify by |
|----|-------|-----------|
| GE-10 | Direct answers first: pages answer their core query in the first 1-2 sentences, then elaborate | Read above the fold |
| GE-11 | Definition boxes: "What is X?" sections with a concise, extractable definition | Content templates |
| GE-12 | Structured comparisons: "X vs Y" tables | Key commercial pages |
| GE-13 | Pros/cons lists on product/service pages | Templates |
| GE-14 | Claims cite authoritative sources; expertise signals (real authors, credentials) present | Content sample |

## Control and measurement checks

| ID | Check | Verify by |
|----|-------|-----------|
| GE-15 | Google AI features are in the intended state: the page-level controls (`nosnippet`, `data-nosnippet`, `max-snippet`, `noindex`) and the Search Console setting that includes a site in Search generative AI features (AI Overviews and AI Mode) match a recorded decision. `Google-Extended` governs Gemini training and grounding outside Search only — it does not affect Search or AI Overviews | Live HTML and headers; ask for the Search Console setting |
| GE-16 | AI visibility is measured, not assumed: Search Console's generative AI performance report (impressions only, and the same impressions also appear in the main report — never sum them) and Bing Webmaster Tools' AI Performance report (Copilot and Bing citations). Bing is an upstream index for some AI answers, so it is verified and fed: IndexNow submissions on content changes | Ask for both reports; grep for an IndexNow key file and submit call |

## Crawler classes

Tokens as documented by each vendor (verify the vendor page before relying on a token; they change). Training and search-index crawlers honour robots.txt; user-triggered fetchers act for one user's request and generally do not.

| Vendor | Training | Search index | User-triggered |
|--------|----------|--------------|----------------|
| OpenAI | GPTBot | OAI-SearchBot | ChatGPT-User |
| Anthropic | ClaudeBot | Claude-SearchBot | Claude-User |
| Perplexity | — | PerplexityBot | Perplexity-User |
| Google | Google-Extended (robots token only; no crawler of its own) | Googlebot (also feeds AI Overviews and AI Mode) | Google-Agent and other user-triggered fetchers |
| Apple | Applebot-Extended (robots token only) | Applebot | — |
| Meta | Meta-ExternalAgent | Meta-WebIndexer | Meta-ExternalFetcher |
| Amazon | Amazonbot | Amzn-SearchBot | Amzn-User |
| Mistral | MistralAI-Training | MistralAI-Index | MistralAI-User |
| DuckDuckGo | — | DuckDuckBot, DuckAssistBot (AI answers, no training) | — |
| Common Crawl | CCBot (dataset used for training by many labs) | — | — |

`anthropic-ai` is not on Anthropic's crawler page, so a robots group naming only that token governs none of Anthropic's documented crawlers.

## Template: llms.txt

The spec's structure, with placeholders in brackets. Keep facts synchronized with the Organization schema (GE-09).

```
# [Site name]

> [One or two sentences: what the site or company is, for whom, and the key fact a reader must not get wrong.]

[Optional paragraphs of plain detail. No headings here.]

## Product

- [Pricing](https://[domain]/pricing): [plans and what is free]
- [Docs](https://[domain]/docs): [what the docs cover]

## Company

- [About](https://[domain]/about): [founding year, location, the entity facts]

## Optional

- [Changelog](https://[domain]/changelog): [secondary detail a reader can skip]
```

## Anti-patterns

| Anti-pattern | Why it is bad | Fix |
|--------------|---------------|-----|
| Blocking all AI bots by reflex | Drops the site from AI search answers along with training | Decide per crawler class (GE-04) |
| Blocking GPTBot (or ClaudeBot) and assuming the site is out of that vendor's AI answers | Those are training crawlers; the search-index crawler still fetches | Block the search-index token as well, or neither, deliberately |
| Treating llms.txt as a Google ranking lever | Google Search ignores it | Ship it, if at all, for non-Google consumers, as a P3 |
| llms.txt contradicting the site's schema | Models detect conflicts and trust neither source | Single fact source feeding both (GE-09) |
| Marketing fluff in llms.txt | Models extract facts; superlatives without numbers get dropped | Verifiable, specific claims only |
