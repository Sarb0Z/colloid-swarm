---
name: mobile-responsive-web
description: >
  Makes web pages and components fully mobile responsive, with a premium,
  mobile-first feel. Use when the user reports a mobile layout defect
  (text overflow, truncation, cramped spacing, poor touch targets,
  broken grids, hero cut off behind the address bar, layout shift,
  sluggish taps), asks to "make it mobile friendly/responsive", wants
  Core Web Vitals optimised on mobile, or when building new pages or
  components that must hold up across breakpoints, notched devices, and
  200% font scale. Tuned for Next.js 15 + React + Tailwind CSS + Framer
  Motion + shadcn/ui. Covers viewport units (svh/dvh/lvh), container
  queries, fluid typography with clamp(), responsive images (Next Image,
  picture, srcset, AVIF/WebP), touch targets and hover/pointer media
  queries, safe-area insets, Core Web Vitals (LCP/INP/CLS), and
  mandatory real-device testing.
---

# Mobile responsive web

Design constraint-aware components: a card, form, or hero must render correctly in a sidebar, a modal, a full-bleed section, or the main column.

## Principles

These are binding; detail and examples are in [references/modern-css.md](./references/modern-css.md).

1. **Mobile-first CSS.** Author base styles for the smallest viewport and layer `sm:`, `md:`, and `lg:` on top; `max-width` queries are banned.
2. **`svh` for heroes, `dvh` for bottom-anchored elements.** Never `100vh` or `min-h-screen`, which overflow behind the iOS address bar.
3. **Fluid typography through `clamp()`,** not breakpoint ladders. Pair it with `break-words`; never `text-balance` on long headings.
4. **Container queries for reusable components.** When a card lives in more than one slot, switch from media queries to container queries.
5. **48 × 48 px touch targets, 8 px spacing.** WCAG 2.2 sets 24 px as the floor; this project holds 48 px as the standard.
6. **Hover is not universal.** Gate hover effects with `@media (hover: hover)` or Tailwind `hover:*`, and never hide critical information behind hover.
7. **Safe-area insets on notched devices.** `viewport-fit=cover` with `env(safe-area-inset-*)` for fixed bars and full-bleed content.
8. **No input `font-size < 16px`.** iOS Safari zooms on focus below 16 px.
9. **CWV is a design constraint.** LCP, INP, and CLS are evaluated on the mobile crawl; they are not a post-launch audit.

## Core workflow

Follow these five steps for every responsive fix.

### 1. Audit — screenshot the current state

Capture the page at mobile viewport **before any code changes**.

```typescript
const viewports = [
  { width: 390, height: 844, name: 'iPhone-14' },    // Modern iPhone
  { width: 375, height: 667, name: 'iPhone-SE' },    // Small phone
  { width: 768, height: 1024, name: 'iPad-Mini' },   // Tablet
]
```

Take full-page, hero, and scrolled-section screenshots, and record every text overflow, truncation, cramped spacing, collapsed image, overlapping element, lazy section that never loads, and jank as the address bar shows and hides.

### 2. Fix the hero and above-the-fold first

The highest-impact area, and the LCP element. Hero patterns are in [references/component-patterns.md](./references/component-patterns.md); LCP rules in [references/performance-cwv.md](./references/performance-cwv.md).

### 3. Fix content sections top to bottom

Work through [references/audit-checklist.md](./references/audit-checklist.md).

### 4. Fix navigation and fixed elements

Bottom bars, scroll indicators, and sticky CTAs must clear the home indicator through safe-area padding.

### 5. Verify — screenshots and the mandatory scenarios

Re-screenshot, then run the mandatory scenarios in [references/viewport-testing.md](./references/viewport-testing.md): portrait, landscape, landscape with keyboard, 200% font scale, notched device, and Slow 4G Lighthouse. Run `bun run typecheck` and `bun run lint`.

## Codebase conventions

### Tailwind breakpoints

| Breakpoint | Width | Use for |
|-----------|-------|---------|
| `sm:` | 640px | Minor adjustments |
| `md:` | 768px | Major layout shifts (2-col → 1-col) |
| `lg:` | 1024px | Desktop layouts |

### Container

The `Container` component wraps with `mx-auto px-4` only and does **not** constrain inner content width; pair it with `max-w-5xl`, `max-w-2xl`, or another width class.

### Spacing scale

Padding is progressive, never a single-step value:

```tsx
<section className='py-10 md:py-16'>        {/* sections */}
<div     className='p-3 sm:p-6'>             {/* cards */}
<ul      className='grid gap-3 sm:gap-6'>    {/* grids */}
<h2      className='mb-3 sm:mb-4 md:mb-6'>   {/* headings */}
```

Use `gap-*` on containers, not margins on children.

### Typography

```tsx
// Section heading — Tailwind step progression is fine here
<h2 className='text-2xl font-bold sm:text-3xl md:text-4xl'>

// Hero — use clamp() so it scales smoothly and never breaks mid-word
<h1
  className='break-words font-bold leading-tight'
  style={{ fontSize: 'clamp(1.375rem, 4vw + 0.5rem, 4rem)' }}
>
```

### Hero height

```tsx
// ✅ Stable, no first-paint overflow
<section className='relative min-h-[100svh]'>

// ❌ Overflows behind iOS address bar
<section className='relative min-h-screen'>
```

### Form inputs

```tsx
// Mobile-premium: label hidden, placeholder + icon
<div className='relative'>
  <MapPin className='absolute left-3.5 top-1/2 h-4 w-4 -translate-y-1/2 md:hidden' />
  <Input
    placeholder='Where do you want to go?'
    className='min-h-11 rounded-xl pl-10 text-base md:text-sm'
  />
</div>

<FormLabel className='hidden md:block'>Destination</FormLabel>
```

`text-base` (16 px) on mobile input prevents iOS focus-zoom.

### Safe-area insets

```tsx
// Fixed bottom CTA bar clears the home indicator
<nav className='fixed inset-x-0 bottom-0 pb-[max(env(safe-area-inset-bottom),1rem)]'>

// Full-bleed hero clears the notch
<section className='pt-[max(env(safe-area-inset-top),1rem)]'>
```

Both need `<meta name='viewport' content='width=device-width, initial-scale=1, viewport-fit=cover'>` in the root layout.

### Z-index hierarchy

```
z-[100] — Mobile scroll indicator (above everything)
z-50    — Header, mobile menu panel
z-40    — Backdrops, overlays
z-30    — Ribbons, badges
z-20    — Floating action buttons
z-10    — Card overlays, gradients
```

## Quick reference

| Problem | Fix |
|---------|-----|
| Hero cut off behind address bar | `min-h-[100svh]`, not `min-h-screen` |
| Modal / bottom sheet jumps on scroll | `dvh` on that element only |
| Text breaks mid-word | `break-words` + reduce `clamp()` minimum |
| iOS zooms when tapping input | `text-base` (16 px) on the input |
| `py-16` too much on mobile | `py-10 md:py-16` |
| Trust badge text truncates | Vertical mobile layout, `break-words`, smaller text |
| Card image collapses when row re-stacks | `aspect-[16/10] md:aspect-auto` |
| Card reused in narrow + wide slots | Container query (`@container` + `@md:*`) |
| Search form feels basic | Remove labels, `rounded-xl`, `min-h-11`, hover shadows |
| Menu feels cheap | Full-screen slide-from-right panel, staggered items |
| Hover tooltip hides mobile info | Make it tap-to-reveal, gate hover with `@media (hover)` |
| Scroll indicator hidden on light bg | `z-[100]`, strong shadow, solid `bg-white` |
| Lazy content not loading in test | Smooth scroll (not jump) to trigger observer |
| Dropdown / popover clipped by parent | Remove `overflow-hidden` from ancestor Card/container |
| Sidebar stacks above content on mobile | Move to bottom sheet (see pattern below) |
| Duplicate count/label when columns stack | Hide one with `hidden sm:block` on the outer element |
| Button group overflows on mobile | `flex flex-wrap gap-2`, never bare `flex gap-2` |
| Tap targets feel small | `min-h-11` minimum, `pointer-coarse:min-h-12` |
| Bottom CTA clipped on iPhone | `pb-[max(env(safe-area-inset-bottom),1rem)]` |
| LCP > 2.5 s on mobile | `priority` + `fetchPriority='high'` + correct `sizes` on LCP image only |
| INP > 200 ms | Defer third-party scripts, split long tasks, trim DOM |
| CLS > 0.1 | Set `width`/`height` on every image; size skeletons to final dims |

## Cross-viewport traps

### A mobile fix must never break desktop, nor a desktop fix mobile

When fixing a mobile-specific defect, always verify the same interaction still works on desktop. Common breakages:

| Mobile bug | Naive fix | Desktop breakage |
|-----------|-----------|------------------|
| Dropdown auto-reopens after selection | Block `onFocus` + `useEffect` with a ref | Desktop user can't click back into input to see suggestions |
| `overflow-hidden` clips dropdown on mobile | Add `overflow-visible` only on mobile | Inconsistent stacking contexts, z-index bugs |
| Touch targets too small | Increase padding globally | Desktop layout shifts, forms look bloated |
| Sidebar → drawer on mobile | Move filters into sheet, delete sidebar code | Desktop loses sidebar entirely |

**Rule:** after any interaction fix, test the *exact same user flow* on both viewports. This codebase fixed the dropdown auto-reopen by blocking *only* the `useEffect` auto-open path (which fires when GraphQL results return) and leaving `onFocus`, manual user intent, untouched; a ref named `suppressAutoOpenRef` makes that explicit and does not suppress a manual reopen.

Worked case studies for this trap class — Card `overflow-hidden` clipping, sidebar → bottom sheet, stacked duplicate content, button-group wrap — live in [references/anti-patterns.md](./references/anti-patterns.md) under "Cross-viewport trap case studies".

## Resources

- **[references/modern-css.md](./references/modern-css.md)** — mobile-first architecture, `svh`/`dvh`/`lvh`, container queries, fluid `clamp()`, hover and pointer queries, safe-area insets.
- **[references/responsive-images.md](./references/responsive-images.md)** — Next.js `<Image>`, `<picture>` art direction, srcset and sizes, AVIF/WebP, DPR cap, CLS prevention.
- **[references/performance-cwv.md](./references/performance-cwv.md)** — LCP/INP/CLS optimisation focused on mobile and on this project's stack.
- **[references/component-patterns.md](./references/component-patterns.md)** — codebase-specific component shapes: hero, search form, card grids, mobile menu, scroll indicator.
- **[references/audit-checklist.md](./references/audit-checklist.md)** — full pre-ship checklist, grouped by concern.
- **[references/viewport-testing.md](./references/viewport-testing.md)** — Playwright flows and mandatory test scenarios: orientation, 200% font, safe area, Lighthouse.
- **[references/anti-patterns.md](./references/anti-patterns.md)** — fast lookup table of what review flags.
