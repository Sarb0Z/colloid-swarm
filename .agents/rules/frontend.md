---
applyTo: '**/*.tsx,**/*.jsx,**/*.vue,**/*.svelte,**/*.css,**/*.scss,**/*.html'
paths:
  - '**/*.tsx'
  - '**/*.jsx'
  - '**/*.vue'
  - '**/*.svelte'
  - '**/*.css'
  - '**/*.scss'
  - '**/*.html'
---

# Frontend and Browser Rules

## Business Invariants
- Design to Steve Jobs's standard: scannable at a glance, visually harmonious, frictionless. Typography, spacing, hierarchy, and micro-interactions are load-bearing, not decorative.
- Render and inspect the output itself before presenting it, and fix collisions, clipping, and readability first.
- When the user supplies a reference, match its quality before showing yours.
- Playwright MCP is the only browser surface. Route every browser task through it — a local dev server, a static file, or a public page — along with layout inspection, screenshots, responsive checks, interaction tests, and any page `WebFetch` cannot parse.

## Abnormal Cases and Rationale
- A page that renders through JavaScript returns markup with no content to `WebFetch`. The call succeeds and the content is absent, so the failure is silent. Playwright renders the page first, which is why it is the only surface and not the preferred one.

## Out of Scope
- Do not restate a framework's own conventions here. A stack rule under `.agents/rules/` owns those.
