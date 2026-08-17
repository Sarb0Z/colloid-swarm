# Mobile Responsive Anti-Patterns

Fast lookup. If you catch any of these in a diff, fix before shipping.

## Contents

- Anti-pattern table (below)
- [Behavioural anti-patterns](#behavioural-anti-patterns)
- [Cross-viewport trap case studies](#cross-viewport-trap-case-studies-stack-specific-tailwind--shadcnui)

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

## Cross-viewport trap case studies (stack-specific: Tailwind + shadcn/ui)

Worked fixes for bugs where the naive mobile fix breaks desktop. Each shows
the correct scoped repair.

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
