# Core Web Vitals for Mobile

Responsive decisions directly change LCP, INP, and CLS — the three metrics
Google evaluates on the **mobile** crawl. Treat CWV as a design constraint,
not a post-launch audit.

| Metric | Measures | Good | Usual mobile offenders |
|--------|----------|------|-----------------------|
| **LCP** | Largest Contentful Paint | ≤ 2.5 s | Hero image, web fonts, render-blocking CSS |
| **INP** | Interaction to Next Paint | ≤ 200 ms | Long JS tasks, hydration, third-party scripts |
| **CLS** | Cumulative Layout Shift | ≤ 0.1 | Images without dimensions, web fonts, injected ads |

## LCP

The LCP element on a landing page is almost always the hero image or the
H1. For images:

1. `<Image priority fetchPriority='high' />` on the hero only.
2. Serve AVIF/WebP via Next image optimisation.
3. Correct `sizes` — wrong `sizes` ships a 2400w file for a 390w viewport.
4. Preload the hero image in `<head>` when it's deterministic
   (`<link rel='preload' as='image' href='…' imagesrcset='…' imagesizes='…'>`).
5. Never lazy-load above-the-fold imagery.

For fonts:

1. `font-display: swap` everywhere.
2. `<link rel='preload' as='font' type='font/woff2' crossOrigin='anonymous'>`
   the one face used in the hero H1.
3. Use `next/font` which inlines the `@font-face` and self-hosts.

For CSS: inline critical styles, defer the rest. In Next.js App Router this
is handled by default — just keep above-the-fold components server-rendered.

## INP

INP replaced FID in March 2024 and measures **every** interaction, not just
the first. A janky tap anywhere on the page hurts the score.

Fixes, in priority order:
1. **Split long tasks** (> 50 ms) with `scheduler.yield()` or
   `await new Promise(r => setTimeout(r, 0))`. Hydration bundles and
   analytics init are the usual culprits.
2. **Defer third-party scripts** — analytics, A/B testing, chat widgets go
   behind `<Script strategy='lazyOnload'>` or `afterInteractive`.
3. **Minimise DOM size** — aim for < 1 500 nodes, depth < 32. Landing
   pages with many repeated cards often breach this; use virtualisation
   or pagination.
4. **Move heavy work to Web Workers** — image processing, large
   `JSON.parse`, map tile computation.
5. **Code-split by route** — Next.js does this for you; don't undo it by
   importing a 500 KB chart library at the top of a layout.

## CLS

See the CLS prevention checklist in `responsive-images.md`.
Additional rules:

- Skeletons must match the final element's dimensions, not a generic box.
- `ScrollReveal`/Framer entrance animations must animate `opacity` + `y`
  **inside** a sized parent — never animate `height` from 0.
- `items-stretch` on grids that contain `StaggeredItem` children, so the
  row height is stable before animation finishes.

## Measuring

In-browser during development:
```js
// In any page, during dev
import { onLCP, onINP, onCLS } from 'web-vitals'
onLCP(console.log)
onINP(console.log)
onCLS(console.log)
```

Pre-deploy: Lighthouse mobile audit with **Slow 4G** + **4× CPU throttle**.
Any single run is noisy — take the median of 5.

Post-deploy: CrUX dashboard or `web-vitals` RUM piped to an analytics sink.
Real-user data is the ground truth; lab scores are directional.

## 90-Day Roadmap (When CWV Is the Primary Goal)

| Weeks | Focus | Expected gain |
|-------|-------|---------------|
| 1–2 | Image `sizes` + dimensions, font preload, remove above-fold lazy-load | 20–30 % LCP |
| 3–6 | Critical CSS, CDN, eliminate render-blocking resources | Further 15–20 % LCP |
| 7–10 | Task splitting, third-party audit, DOM trim | INP under 200 ms |

## Don't

- Don't disable image optimisation to "fix" a specific image — fix the
  source instead.
- Don't add `will-change: transform` everywhere to "smooth" animations.
  It burns GPU memory and can regress INP.
- Don't ship a 200 KB icon font for six icons. Use inline SVG or
  `lucide-react` tree-shaken imports.
