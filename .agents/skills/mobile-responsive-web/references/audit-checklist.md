# Mobile Responsive Audit Checklist

Run through this for every page being audited. Grouped by concern; each
item must be verified — not assumed — on a real device or accurate emulator.

## Text & Typography

- [ ] Hero title uses `break-words` + `clamp()`, never `text-balance`.
- [ ] No text truncation with ellipsis unless truncation is intentional UX.
- [ ] Subtitle progression: `text-base sm:text-lg md:text-xl`.
- [ ] Section headings: `text-2xl sm:text-3xl md:text-4xl`.
- [ ] Body text minimum `text-sm` (14 px); inputs minimum 16 px to avoid
      iOS Safari focus-zoom.

## Viewport Units

- [ ] Heroes use `min-h-[100svh]`, never `min-h-screen` / `h-[100vh]`.
- [ ] Bottom-anchored elements (sheets, modals, sticky footers) use `dvh`.
- [ ] `dvh` is not applied to heavy layouts with many children (scroll jank).
- [ ] `<meta name='viewport' content='…viewport-fit=cover'>` is set so
      safe-area insets work.

## Spacing & Padding

- [ ] Section vertical padding: `py-10 md:py-16` (not flat `py-16`).
- [ ] Section heading margin: `mb-3 sm:mb-4`.
- [ ] Card padding: `p-3 sm:p-6`.
- [ ] Grid gaps: `gap-3 sm:gap-6`.
- [ ] No horizontal overflow — never mask with `overflow-x: hidden`; find
      and fix the offending element.

## Layout & Grids

- [ ] Grids collapse to 1 column on mobile: `grid-cols-1 md:grid-cols-2 lg:grid-cols-3`.
- [ ] Consider `[grid-template-columns:repeat(auto-fit,minmax(18rem,1fr))]`
      for card collections — no breakpoint ladder needed.
- [ ] Components reused in narrow and wide slots use a **container query**
      rather than media queries.
- [ ] Featured cards have `aspect-[16/10] md:aspect-auto` so the image
      does not collapse when the row re-stacks.
- [ ] Stats grid `grid-cols-2 md:grid-cols-4`.
- [ ] Trust badges use vertical (`flex-col`) layout on mobile for text room.
- [ ] No content hidden behind fixed header / scroll indicator / tab bar.

## Forms & Inputs

- [ ] Labels hidden on mobile (`hidden md:block`); placeholder + icon used.
- [ ] Input height `min-h-11` (44 px) minimum; `min-h-12` preferred.
- [ ] Inputs `rounded-xl` for premium feel.
- [ ] Primary button `w-full` in stacked mobile layouts.
- [ ] Stepper / +/− buttons minimum 44 × 44 px with 8 px spacing.
- [ ] Date picker `numberOfMonths={1}` below `md`.
- [ ] Input `type` matches content (`tel`, `email`, `url`, `number`) to
      trigger the correct virtual keyboard.
- [ ] No `<input>` with computed `font-size < 16px`.

## Images & Media

- [ ] Every image has `width` + `height` or a sized aspect container.
- [ ] `sizes` attribute is accurate — verified in DevTools Network tab.
- [ ] `priority` + `fetchPriority='high'` on the LCP element **only**.
- [ ] No `loading='lazy'` above the fold.
- [ ] AVIF/WebP served (Next.js `images.formats` configured).
- [ ] ProgressiveImage has `fallbackVariant` matching the final aspect ratio.
- [ ] Lazy-loaded sections trigger on a slow smooth scroll.

## Touch & Pointer

- [ ] Every interactive element ≥ 44 × 44 px (WCAG 2.2 floor 24 px;
      project standard 48 px).
- [ ] At least 8 px between adjacent targets.
- [ ] Hover-dependent reveals are also accessible by tap or focus.
- [ ] `@media (hover: hover)` gates hover-only effects, or Tailwind's
      `hover:*` is used alongside a non-hover fallback.
- [ ] `pointer-coarse:*` expands padding on touch-coarse devices where
      relevant.

## Navigation

- [ ] Hamburger button `h-10 w-10` minimum.
- [ ] Menu is full-screen or ≥ `max-w-sm` side panel — not a small dropdown.
- [ ] Menu items have `p-3.5` minimum touch targets.
- [ ] Backdrop is dark + blur, not light translucent.
- [ ] Menu closes on route change (`useEffect` cleanup).
- [ ] Primary actions sit in the bottom thumb zone on mobile.

## Fixed Elements & Safe Areas

- [ ] Fixed bottom bars use `pb-[max(env(safe-area-inset-bottom),1rem)]`.
- [ ] Fixed top elements use `pt-[max(env(safe-area-inset-top),…)]` where
      content extends under the notch.
- [ ] Scroll indicator `z-[100]`, solid `bg-white`, strong shadow.
- [ ] Scroll indicator does not overlap a primary CTA at the bottom of
      any section.
- [ ] Header does not cover in-page anchor targets — add
      `scroll-margin-top` on sections.

## Animations

- [ ] `useReducedMotion()` respected for all non-essential animation.
- [ ] ScrollReveal parents use `items-stretch` so rows don't jitter.
- [ ] Stagger delays ≤ 0.1 s so sequences finish quickly on mobile.
- [ ] No `height`-from-0 animations — use `opacity` + `y` in a sized parent.

## Orientation & System Settings

- [ ] Portrait and landscape both verified.
- [ ] Landscape with virtual keyboard open — forms still usable, no
      content trapped behind the keyboard.
- [ ] System font size set to maximum (200 % on iOS) — no clipping,
      overflow, or broken grids.
- [ ] Zoom to 200 % — content reflows, no horizontal scroll.
- [ ] `user-scalable=no` / `maximum-scale=1` are **not** present in the
      viewport meta.

## Core Web Vitals

- [ ] Lighthouse mobile run (Slow 4G, 4× CPU) — LCP ≤ 2.5 s, INP ≤ 200 ms,
      CLS ≤ 0.1. Take the median of 5 runs; single runs are noisy.
- [ ] LCP element is identified and owns `priority` + correct `sizes`.
- [ ] No long task > 50 ms during initial interaction.
- [ ] Third-party scripts behind `strategy='lazyOnload'` or `afterInteractive`.
- [ ] DOM node count < 1 500.

## Accessibility

- [ ] Screen reader pass (VoiceOver on iOS, TalkBack on Android) —
      landmarks, headings, focus order sensible.
- [ ] All interactive elements focusable and visible focus ring present.
- [ ] Colour contrast ≥ 4.5 : 1 for body text, 3 : 1 for large text.
- [ ] Form errors announced and associated via `aria-describedby`.

## Final Verification

- [ ] Screenshots at 390, 375, 768 (portrait) and 844 × 390 (landscape).
- [ ] Real-device sanity check (iPhone SE + a modern Android) for at
      least the hero and primary CTA flow.
- [ ] `bun run typecheck` passes.
- [ ] `bun run lint` passes (0 errors).
