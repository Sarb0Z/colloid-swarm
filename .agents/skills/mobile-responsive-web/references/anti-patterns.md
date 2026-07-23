# Mobile Responsive Anti-Patterns

Fast lookup. If you catch any of these in a diff, fix before shipping.

| Anti-pattern | Why it breaks | Fix |
|--------------|---------------|-----|
| `min-h-screen` / `h-[100vh]` on heroes | Overflows behind iOS address bar on first paint | `min-h-[100svh]` |
| `vh` on modals/bottom sheets | Jumps when browser chrome animates | `dvh` on the specific element |
| `text-balance` on long headings | Breaks mid-syllable on narrow widths | `break-words` + `clamp()` |
| Form input `font-size < 16px` | iOS Safari zooms on focus, re-lays out page | Minimum `text-base` (16px) on `<input>`, `<select>`, `<textarea>` |
| Device-specific breakpoints (320/375/414…) | New devices break the logic | Content-based breakpoints or container queries |
| `display: none` to hide mobile content | Still downloaded; hurts SEO; wastes bandwidth | Progressive disclosure (`<details>`, accordions, tabs) or don't render it |
| Hover-only dropdowns | Completely broken on touch | Click/tap toggles; gate hover effects with `@media (hover: hover)` |
| Fixed heights on text containers | Text overlaps or clips when wrapping | `min-height`, let content dictate size |
| `user-scalable=no` in viewport meta | WCAG violation; blocks low-vision users | Never use it |
| `maximum-scale=1` | Same problem as above | Never use it |
| 3× DPR images everywhere | Tiny perceptual gain, huge bandwidth cost | Cap at 2×; 3× only for brand glyphs |
| Long JS tasks on main thread | Freezes taps; fails INP | `scheduler.yield()`, code-split, Web Workers |
| Images without `width`/`height` | CLS; LCP element never reserves space | Always set dimensions or `aspect-*` container |
| `priority` on every image | Floods connection, delays actual LCP element | `priority` + `fetchPriority='high'` on the LCP image only |
| Labels visible on mobile forms | Eats vertical room, feels clunky | Hide labels `md:hidden`, use placeholder + icon |
| Small tap targets (< 44 px) | WCAG 2.2 fail, frustrating on touch | `min-h-11` minimum, `min-h-12` preferred |
| Touch targets < 8 px apart | Mis-taps | `gap-2` minimum between interactive elements |
| Fixed CTAs without safe-area padding | Clipped by home indicator on notched phones | `pb-[max(env(safe-area-inset-bottom),1rem)]` |
| `overflow-x: hidden` on `<body>` to mask issues | Hides the real overflow cause | Find the offending element; fix its width |
| Heavy Framer Motion on mobile | Drops frames, spikes INP | `useReducedMotion()`, limit to key hero moments |
| Animating `height` from 0 | Triggers layout, causes CLS | Animate `opacity` + `y` inside a sized parent |
| Mixed `null` / `undefined` for optional props | TS2322 and runtime surprises | Single canonical nullability (see `AGENTS.md`) |
| `numberOfMonths={2}` on mobile date picker | Overflows 375 px viewport | `numberOfMonths={1}` below `md`, `{2}` above |
| ScrollReveal without `items-stretch` parent | Rows re-jitter as items fade in | Add `items-stretch` to the grid |
| Featured card without mobile aspect ratio | Image collapses to 0 height | `aspect-[16/10] md:aspect-auto` |

## Behavioural anti-patterns

- **"It works in DevTools device mode"** — DevTools does not simulate real
  touch, real mobile Safari quirks, or real network. Always verify on a
  real device or BrowserStack before declaring done.
- **Testing only portrait** — Landscape with open keyboard is a common
  break. Rotate during testing.
- **Skipping 200 % system font scale** — Accessibility fail. Check at
  Settings → Display → Text Size max.
- **"I'll optimise images later"** — Later never comes and LCP regresses
  immediately. Do it in the same PR as the layout change.
