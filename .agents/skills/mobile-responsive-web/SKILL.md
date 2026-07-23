---
name: mobile-responsive-web
description: >
  Make web pages and components fully mobile responsive with a premium,
  mobile-first feel. Use when the user reports mobile layout issues
  (text overflow, truncation, cramped spacing, poor touch targets,
  broken grids, hero cut off behind the address bar, layout shift,
  sluggish taps), asks to "make it mobile friendly/responsive",
  optimise Core Web Vitals on mobile, or when building new pages /
  components that must work cleanly across breakpoints, notched
  devices, and 200% font scale. Tuned for Next.js 15 + React +
  Tailwind CSS + Framer Motion + shadcn/ui. Covers viewport units
  (svh/dvh/lvh), container queries, fluid typography with clamp(),
  responsive images (Next Image, picture, srcset, AVIF/WebP), touch
  targets and hover/pointer media queries, safe-area insets,
  Core Web Vitals (LCP/INP/CLS), and mandatory real-device testing.
---

# Mobile Responsive Web Skill

## Mindset

Mobile responsive work in 2026 is not "fitting desktop into a phone".
It is designing **constraint-aware components** where a card, a form,
or a hero renders correctly whether it lives in a sidebar, a modal, a
full-bleed section, or the main column. Every rule below exists to
keep that invariant true on real devices.

## Core Workflow

Follow this 5-step process for every responsive fix:

### 1. Audit — Screenshot Current State

Capture the page at mobile viewport **before touching any code**.

```typescript
const viewports = [
  { width: 390, height: 844, name: 'iPhone-14' },    // Modern iPhone
  { width: 375, height: 667, name: 'iPhone-SE' },    // Small phone
  { width: 768, height: 1024, name: 'iPad-Mini' },   // Tablet
]
```

Take full-page + hero + scrolled section screenshots. Identify: text
overflow, truncation, cramped spacing, collapsed images, overlapping
elements, lazy sections that never load, jank on address-bar show/hide.

### 2. Fix Hero & Above-the-Fold First

Highest-impact area; also the LCP element. See
[references/component-patterns.md](./references/component-patterns.md)
for hero patterns and [references/performance-cwv.md](./references/performance-cwv.md)
for LCP rules.

### 3. Fix Content Sections Top-to-Bottom

Work through [references/audit-checklist.md](./references/audit-checklist.md).

### 4. Fix Navigation & Fixed Elements

Mobile menu should feel native-app-grade. Bottom bars, scroll indicators,
and sticky CTAs must clear the home indicator via safe-area padding.

### 5. Verify — Screenshots + Mandatory Scenarios

Re-screenshot, then run through the mandatory test scenarios in
[references/viewport-testing.md](./references/viewport-testing.md)
(portrait, landscape, landscape + keyboard, 200% font scale, notched
device, Slow 4G Lighthouse). Run `bun run typecheck` and `bun run lint`.

## Principles (The Foundation)

These are non-negotiable. Full detail and examples in
[references/modern-css.md](./references/modern-css.md).

1. **Mobile-first CSS.** Author base styles for the smallest viewport;
   layer `sm:` / `md:` / `lg:` on top. `max-width` queries are banned.
2. **`svh` for heroes, `dvh` for bottom-anchored.** Never `100vh` /
   `min-h-screen` — it overflows behind the iOS address bar.
3. **Fluid typography via `clamp()`.** Not breakpoint ladders. Pair
   with `break-words`; never `text-balance` on long headings.
4. **Container queries for reusable components.** When a card lives in
   multiple slots, switch from media queries to container queries.
5. **48 × 48 px touch targets, 8 px spacing.** WCAG 2.2 sets 24 px as
   the floor; this project uses 48 px as the standard.
6. **Hover is not universal.** Gate hover effects with `@media (hover: hover)`
   / Tailwind `hover:*`, and never hide critical info behind hover.
7. **Safe-area insets on notched devices.** `viewport-fit=cover` +
   `env(safe-area-inset-*)` for fixed bars and full-bleed content.
8. **No input `font-size < 16px`.** iOS Safari zooms on focus below 16 px.
9. **CWV is a design constraint.** LCP, INP, and CLS are evaluated on
   the mobile crawl; they are not a post-launch audit.

## Codebase Conventions

### Tailwind Breakpoints

| Breakpoint | Width | Use for |
|-----------|-------|---------|
| `sm:` | 640px | Minor adjustments |
| `md:` | 768px | Major layout shifts (2-col → 1-col) |
| `lg:` | 1024px | Desktop layouts |

**Always mobile-first**: start with the mobile style, add `md:` / `lg:` for
larger screens.

### Container

The `Container` component wraps with `mx-auto px-4` only — it does **not**
constrain inner content width. Pair it with your own `max-w-5xl`,
`max-w-2xl`, etc.

### Spacing Scale

Progressive padding — never a single-step value:

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

### Hero Height

```tsx
// ✅ Stable, no first-paint overflow
<section className='relative min-h-[100svh]'>

// ❌ Overflows behind iOS address bar
<section className='relative min-h-screen'>
```

### Form Inputs

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

### Safe-Area Insets

```tsx
// Fixed bottom CTA bar clears the home indicator
<nav className='fixed inset-x-0 bottom-0 pb-[max(env(safe-area-inset-bottom),1rem)]'>

// Full-bleed hero clears the notch
<section className='pt-[max(env(safe-area-inset-top),1rem)]'>
```

Requires `<meta name='viewport' content='width=device-width, initial-scale=1, viewport-fit=cover'>`
in the root layout.

### Z-Index Hierarchy

```
z-[100] — Mobile scroll indicator (above everything)
z-50    — Header, mobile menu panel
z-40    — Backdrops, overlays
z-30    — Ribbons, badges
z-20    — Floating action buttons
z-10    — Card overlays, gradients
```

## Quick Reference

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

## Critical Cross-Viewport Traps

### A mobile fix must never break desktop (and vice versa)

When fixing a mobile-specific bug, always verify the same interaction still works
on desktop. Common breakage patterns:

| Mobile bug | Naive fix | Desktop breakage |
|-----------|-----------|------------------|
| Dropdown auto-reopens after selection | Block `onFocus` + `useEffect` with a ref | Desktop user can't click back into input to see suggestions |
| `overflow-hidden` clips dropdown on mobile | Add `overflow-visible` only on mobile | Inconsistent stacking contexts, z-index bugs |
| Touch targets too small | Increase padding globally | Desktop layout shifts, forms look bloated |
| Sidebar → drawer on mobile | Move filters into sheet, delete sidebar code | Desktop loses sidebar entirely |

**Rule**: Test the *exact same user flow* on both viewports after any interaction
fix. The fix in this codebase for the dropdown auto-reopen was to block *only*
the `useEffect` auto-open path (which fires when GraphQL results return), while
leaving `onFocus` (manual user intent) untouched. A ref named `suppressAutoOpenRef`
makes this intent explicit — it does NOT suppress manual reopen.

**Rule**: Test the *exact same user flow* on both viewports after any interaction
fix. The fix in this codebase for the dropdown auto-reopen was to block *only*
the `useEffect` auto-open path (which fires when GraphQL results return), while
leaving `onFocus` (manual user intent) untouched. A ref named `suppressAutoOpenRef`
makes this intent explicit — it does NOT suppress manual reopen.

### `overflow-hidden` on Card / container components

A Card with `overflow-hidden` clips any `absolute` positioned child (dropdown,
popover, tooltip) that tries to spill outside. The fix is usually to remove
`overflow-hidden` from the Card — inner content rarely needs it when the Card
already has padding. If you truly need clipping for decorative elements, apply
`overflow-hidden` to a dedicated inner wrapper, not the Card itself.

```tsx
// ❌ Clips absolute dropdowns
<Card className="overflow-hidden p-6">
  <LocationAutocomplete /> {/* dropdown is clipped */}
</Card>

// ✅ Dropdown spills outside correctly
<Card className="p-6">
  <LocationAutocomplete />
</Card>
```

### Sidebar → Bottom Sheet on Mobile

A sidebar that stacks full-width above results on mobile forces users to scroll
through 800–1200 px of filters before seeing a single content item. The fix:

1. **Hide the sidebar on mobile** (`hidden lg:block` on the sidebar container)
2. **Add a filter button** that opens a bottom sheet with the same filter content
3. **Show an active-filter badge** on the button so users know filters are applied

```tsx
// In the results header — filter button visible only on mobile/tablet
<Sheet open={mobileFiltersOpen} onOpenChange={setMobileFiltersOpen}>
  <SheetTrigger asChild>
    <Button variant="outline" size="sm" className="lg:hidden">
      <SlidersHorizontal className="mr-2 h-4 w-4" />
      Filters
      {activeFiltersCount > 0 && (
        <Badge variant="secondary" className="ml-2 text-xs">{activeFiltersCount}</Badge>
      )}
    </Button>
  </SheetTrigger>
  <SheetContent side="bottom" className="h-[85vh] rounded-t-2xl">
    <SheetHeader className="border-b pb-4">
      <SheetTitle>Filters</SheetTitle>
      {activeFiltersCount > 0 && (
        <Button variant="ghost" size="sm" onClick={handleClearFilters}>
          <X className="mr-1 h-3 w-3" /> Clear all
        </Button>
      )}
    </SheetHeader>
    <div className="overflow-y-auto px-4 py-4">
      <FacetedNavigation ... />
    </div>
  </SheetContent>
</Sheet>

// Sidebar — desktop only
<div className="hidden space-y-6 lg:col-span-1 lg:block">
  <SavedSearches />
  <FacetedNavigation ... />
</div>
```

**Never** delete the sidebar code — hide it with `hidden lg:block` so desktop
keeps the full sidebar experience.

### Duplicate content when grid columns stack

When a parent layout shows a count/title and a child component also shows the
same count (e.g., "10 trips found"), they may sit side-by-side on desktop but
stack redundantly on mobile:

```
Desktop:  [Parent: 10 trips found]        [Child: 10 trips found + Sort]
Mobile:   [Parent: 10 trips found]
          [Child:  10 trips found + Sort]   ← duplicate!
```

Fix: Hide the outer count on mobile since the inner one comes with controls:

```tsx
// Parent — hide on mobile, child already shows count + sort
<div className="hidden sm:block">
  <h2>10 trips found</h2>
</div>
```

### Button groups must wrap

Groups of filter buttons, rating buttons, or view toggles that fit on desktop
will overflow on mobile. Always use `flex-wrap`:

```tsx
// ❌ Overflow on narrow screens
<div className="flex gap-2">
  {[1, 2, 3, 4, 5].map(r => <Button …>{r}+</Button>)}
</div>

// ✅ Wraps naturally on mobile
<div className="flex flex-wrap gap-2">
  {[1, 2, 3, 4, 5].map(r => <Button …>{r}+</Button>)}
</div>
```

## Resources

- **[references/modern-css.md](./references/modern-css.md)** — Mobile-first
  architecture, `svh`/`dvh`/`lvh`, container queries, fluid `clamp()`,
  hover/pointer queries, safe-area insets.
- **[references/responsive-images.md](./references/responsive-images.md)** —
  Next.js `<Image>`, `<picture>` art direction, srcset/sizes, AVIF/WebP,
  DPR cap, CLS prevention.
- **[references/performance-cwv.md](./references/performance-cwv.md)** —
  LCP/INP/CLS optimisation focused on mobile and on this project's stack.
- **[references/component-patterns.md](./references/component-patterns.md)** —
  Codebase-specific component shapes (hero, search form, card grids,
  mobile menu, scroll indicator).
- **[references/audit-checklist.md](./references/audit-checklist.md)** —
  Full pre-ship checklist grouped by concern.
- **[references/viewport-testing.md](./references/viewport-testing.md)** —
  Playwright flows and mandatory test scenarios (orientation, 200% font,
  safe area, Lighthouse).
- **[references/anti-patterns.md](./references/anti-patterns.md)** — Fast
  lookup table of what will get flagged in review.
