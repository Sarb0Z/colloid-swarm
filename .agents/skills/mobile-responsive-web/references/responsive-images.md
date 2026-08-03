# Responsive Images

## Contents
- 1. Next.js `<Image>` (Preferred in this Codebase)
- 2. Art Direction with `<picture>`
- 3. Breakpoint Strategy: File-Size Steps, Not Device Widths
- 4. DPR Cap: 2× Is Enough
- 5. Formats: AVIF → WebP → JPEG/PNG
- 6. CLS Prevention Checklist
- 7. ProgressiveImage Fallbacks
- 8. Sizes Attribute Recipes

Three concerns must be handled simultaneously: **resolution switching**,
**art direction**, and **format selection**. Getting any of them wrong
shows up as a CLS regression, a blurry LCP element, or wasted bandwidth on
mobile networks.

## 1. Next.js `<Image>` (Preferred in this Codebase)

```tsx
import Image from 'next/image'

<Image
  src='/hero.jpg'
  alt='…'
  width={1600}
  height={900}
  priority                        // LCP element only
  fetchPriority='high'
  sizes='(max-width: 640px) 100vw, (max-width: 1024px) 80vw, 1200px'
  className='aspect-[16/9] h-auto w-full object-cover'
/>
```

Required every time:
- `width` + `height` (or `fill` + a sized parent) — reserves space, prevents CLS.
- `sizes` — tells the browser which variant to pick before layout.
- `priority` + `fetchPriority='high'` on the LCP element only. Never on
  below-the-fold images.
- Never `loading='lazy'` on above-the-fold imagery.

## 2. Art Direction with `<picture>`

Use when the mobile shot needs a different crop, not just a smaller file:

```tsx
<picture>
  <source
    media='(max-width: 640px)'
    type='image/avif'
    srcSet='/hero-mobile-400.avif 400w, /hero-mobile-800.avif 800w'
    sizes='100vw'
  />
  <source
    type='image/avif'
    srcSet='/hero-1200.avif 1200w, /hero-1800.avif 1800w'
    sizes='100vw'
  />
  <img
    src='/hero-1200.jpg'
    alt='…'
    width={1200}
    height={600}
    loading='eager'
    fetchPriority='high'
  />
</picture>
```

Order matters: earliest matching `<source>` wins. Put mobile-cropped and
modern-format sources first, fall back to `<img>` for everything else.

## 3. Breakpoint Strategy: File-Size Steps, Not Device Widths

Do **not** pick breakpoints from device catalogues (320, 375, 414, 768…).
Generate variants by file-size delta — add a new width whenever the output
file drops by ~20–30 KB.

| Set | Widths |
|-----|--------|
| Minimal | 400, 800, 1600 |
| Standard | 400, 800, 1200, 1600, 2400 |

Next.js image-optimisation defaults already follow this shape via
`deviceSizes` / `imageSizes` in `next.config.ts`.

## 4. DPR Cap: 2× Is Enough

Research from Twitter and Shopify shows the perceptual gap between 2× and
3× on phone-sized displays is negligible, while the bandwidth cost is
real. Serve up to 2× for content imagery; reserve 3× for critical logos
or brand glyphs where crispness is load-bearing.

## 5. Formats: AVIF → WebP → JPEG/PNG

AVIF beats WebP by ~20–30 % at equivalent quality. Next.js `<Image>`
negotiates formats automatically when `images.formats` includes
`['image/avif', 'image/webp']`. For raw `<picture>`, provide sources in
that priority order.

## 6. CLS Prevention Checklist

- [ ] Every image has `width` + `height` attributes **or** a sized
      aspect-ratio container (`aspect-[4/3]`, `aspect-video`, etc.).
- [ ] Featured cards on mobile have an explicit `aspect-[16/10]` — they
      collapse to 0 height without it because the flex row re-stacks.
- [ ] Ads / embeds / third-party widgets live inside a `min-h-*` reservation.
- [ ] Web fonts use `font-display: swap` and the critical face is preloaded.
- [ ] Dynamically injected banners never push existing content down unless
      the user triggered it.

## 7. ProgressiveImage Fallbacks

When using the repo's `ProgressiveImage` component, always set
`fallbackVariant` so a skeleton renders before the source resolves. The
skeleton must match the final aspect ratio so CLS stays at 0.

## 8. Sizes Attribute Recipes

```tsx
// Full-bleed hero
sizes='100vw'

// Two-column card grid
sizes='(max-width: 768px) 100vw, 50vw'

// Three-column card grid with max container
sizes='(max-width: 768px) 100vw, (max-width: 1280px) 33vw, 400px'

// Sidebar thumbnail, capped
sizes='(max-width: 768px) 100vw, 320px'
```

Wrong `sizes` is the #1 cause of Next.js shipping a 1600px-wide image to
a 320px-wide mobile slot. Always sanity-check with DevTools → Network →
filter by image → check "Resource Size" column against rendered size.
