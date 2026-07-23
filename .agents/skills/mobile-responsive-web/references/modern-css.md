# Modern Responsive CSS (2026)

The techniques below are Baseline-widely-available and should be preferred over
older media-query-only approaches. All examples are Tailwind-compatible via
arbitrary values or the official `@tailwindcss/container-queries` plugin.

## 1. Mobile-First, Always

Author base styles for the smallest viewport, then layer `sm:` / `md:` / `lg:`
enhancements. `max-width` queries and "desktop compression" are banned — they
produce heavier CSS and regress whenever a new small device appears.

```tsx
// ✅ Mobile-first
<nav className='hidden md:flex'>…</nav>

// ❌ Desktop-first
<nav className='flex max-md:hidden'>…</nav>
```

## 2. Viewport Units: `svh` / `dvh` / `lvh`

`vh` is broken on mobile — it calculates against the *largest* viewport
(toolbars hidden), so `100vh` overflows behind the address bar on first paint.

| Unit | Behaviour | Use for |
|------|-----------|---------|
| `svh` | Small viewport (toolbars visible) — **stable** | Heroes, splash screens, above-the-fold |
| `dvh` | Dynamic — updates as browser chrome animates | Chat UIs, sticky footers, bottom sheets, modals anchored to visible bottom |
| `lvh` | Large viewport (toolbars hidden) | Rare — `vh` already behaves like this |

```tsx
// ✅ Hero — no jump when address bar retracts
<section className='min-h-[100svh]'>

// ✅ Bottom sheet — anchors to visible bottom
<div className='fixed inset-x-0 bottom-0 max-h-[100dvh]'>

// ❌ Forbidden — overflows on iOS Safari first paint
<section className='min-h-screen'>
```

**Performance caveat**: `dvh` triggers layout recalculation on every
address-bar animation. Do not put it on complex grids with many children —
use it only on the specific element that must track the visible bottom.

## 3. Fluid Typography with `clamp()`

Replace breakpoint-stepped font sizes with a single fluid rule:

```tsx
<h1 style={{ fontSize: 'clamp(1.375rem, 4vw + 0.5rem, 4rem)' }}>
<h2 style={{ fontSize: 'clamp(1.5rem, 2.5vw + 0.75rem, 2.5rem)' }}>
<p  style={{ fontSize: 'clamp(0.95rem, 0.5vw + 0.85rem, 1.125rem)' }}>
```

Formula: `clamp(min, preferred, max)` where `preferred` uses a `vw`-based
value so the size scales smoothly between extremes. Always pair with
`break-words` on headings — never `text-balance` (it breaks mid-syllable).

**Input rule**: never ship an input whose computed `font-size < 16px`. iOS
Safari zooms on focus below 16px and re-lays out the whole page.

## 4. Container Queries

Media queries respond to the viewport. Container queries respond to the
*parent element's* size — critical for components that appear in multiple
contexts (sidebar vs. main, modal vs. page).

```tsx
// Tailwind (requires @tailwindcss/container-queries plugin)
<div className='@container'>
  <article className='flex flex-col @md:flex-row'>
    <img className='w-full @md:w-1/3' />
    <div className='@md:flex-1'>…</div>
  </article>
</div>
```

Raw CSS fallback:

```css
.card-host { container-type: inline-size; }
@container (min-width: 400px) {
  .card { flex-direction: row; }
}
```

Rule of thumb: reach for a container query whenever you catch yourself
writing `md:` rules for a component that could be placed in a narrow slot.

## 5. Grid with `auto-fit` + `minmax()`

Eliminate manual grid breakpoints for card collections:

```tsx
<ul className='grid gap-4 [grid-template-columns:repeat(auto-fit,minmax(18rem,1fr))]'>
```

The grid reflows naturally — one column on phones, two on tablets, three on
desktops — without any `md:grid-cols-*` ladder. Use for card grids where
every card is the same width class.

For asymmetric layouts, keep `grid-template-areas` + media queries so you
can reassign hierarchy without changing DOM order.

## 6. Hover & Pointer Capability Queries

Not every device supports hover. Gate hover-dependent styles behind
`(hover: hover)` and give `(pointer: coarse)` devices larger targets:

```css
/* Tailwind: hover:* and pointer-coarse:* */
@media (hover: hover) and (pointer: fine) {
  .button:hover { transform: translateY(-1px); }
}
@media (pointer: coarse) {
  .button { min-height: 48px; padding-block: 0.75rem; }
}
```

```tsx
// Tailwind v3.4+
<button className='min-h-11 pointer-coarse:min-h-12 hover:shadow-lg'>
```

`hover:` in Tailwind already maps to `(hover: hover)` — safe to use, but
don't rely on hover to reveal critical information.

## 7. Safe-Area Insets (Notched Devices)

Respect the physical notch/home-indicator area on iOS:

```tsx
// Full-bleed hero that doesn't tuck under the notch
<section className='pt-[max(env(safe-area-inset-top),1rem)]'>

// Fixed bottom bar clear of the home indicator
<nav className='fixed bottom-0 pb-[max(env(safe-area-inset-bottom),1rem)]'>
```

Also required: `<meta name='viewport' content='width=device-width, initial-scale=1, viewport-fit=cover'>`
so the page extends into the safe area in the first place.

## 8. Spacing Scale

Progressive padding, never a single-step value:

```tsx
<section className='py-10 md:py-16'>         {/* sections */}
<div     className='p-3 sm:p-6'>              {/* cards */}
<ul      className='grid gap-3 sm:gap-6'>     {/* grids */}
<h2      className='mb-3 sm:mb-4 md:mb-6'>    {/* headings */}
```

Use `gap-*` on flex/grid containers rather than margins on children — it
avoids the first/last-child margin-collapse bugs that show up on mobile
when items wrap.
