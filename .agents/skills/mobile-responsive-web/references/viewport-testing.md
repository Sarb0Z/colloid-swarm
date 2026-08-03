# Viewport Testing with Playwright

## Contents
- Standard Viewport Sizes
- Screenshot Workflow
- Common Issues in Screenshots
- Mandatory Scenarios
- Core Web Vitals During Testing
- Post-Change Verification Checklist

## Standard Viewport Sizes

Test at minimum these three viewports:

| Device | Width | Height | Why |
|--------|-------|--------|-----|
| iPhone 14 / 15 | 390 | 844 | Most common modern phone |
| iPhone SE / mini | 375 | 667 | Small phone edge case |
| iPad Mini | 768 | 1024 | Tablet breakpoint |

## Screenshot Workflow

### 1. Before Changes

```typescript
import { test, expect } from '@playwright/test'

const viewports = [
  { width: 390, height: 844, name: 'mobile' },
  { width: 768, height: 1024, name: 'tablet' },
]

for (const vp of viewports) {
  test(`landing page at ${vp.name}`, async ({ page }) => {
    await page.goto('http://localhost:3000')
    await page.setViewportSize({ width: vp.width, height: vp.height })
    await page.waitForTimeout(1000) // Let animations settle

    // Hero viewport
    await page.evaluate(() => window.scrollTo(0, 0))
    await page.screenshot({ path: `before-${vp.name}-hero.png` })

    // Full page
    await page.screenshot({ path: `before-${vp.name}-full.png`, fullPage: true })
  })
}
```

### 2. During Development

Use MCP Playwright tools for rapid iteration:

```javascript
// Navigate and set viewport
await page.goto('http://localhost:3000')
await page.setViewportSize({ width: 390, height: 844 })

// Scroll to specific sections for targeted checks
await page.evaluate(() => window.scrollTo(0, 0))
await page.screenshot({ path: 'hero-check.png' })

await page.evaluate(() => window.scrollTo(0, 800))
await page.screenshot({ path: 'destinations-check.png' })
```

### 3. Lazy-Loaded Content

Lazy-loaded sections need **smooth scrolling** to trigger IntersectionObserver:

```javascript
// ❌ Wrong — jumping scroll won't trigger lazy load
await page.evaluate(() => window.scrollTo(0, 3000))

// ✅ Correct — smooth scroll or sequential steps
await page.evaluate(() => {
  window.scrollTo({ top: 3000, behavior: 'smooth' })
})
await page.waitForTimeout(1500)
```

Or use a helper:

```javascript
async function scrollThroughPage(page) {
  const height = await page.evaluate(() => document.body.scrollHeight)
  const steps = 5
  for (let i = 0; i <= steps; i++) {
    await page.evaluate((y) => window.scrollTo(0, y), (height / steps) * i)
    await page.waitForTimeout(400)
  }
}
```

### 4. Check DOM Element State

```javascript
const indicator = await page.evaluate(() => {
  const el = document.querySelector('[aria-label="Page sections"]')
  if (!el) return 'NOT FOUND'
  const rect = el.getBoundingClientRect()
  const style = window.getComputedStyle(el)
  return {
    display: style.display,
    opacity: style.opacity,
    zIndex: style.zIndex,
    visible: rect.width > 0 && rect.height > 0,
  }
})
console.log(indicator)
```

### 5. Open/Close Interactive Elements

```javascript
// Open mobile menu
await page.locator('button[aria-label="Open menu"]').first().click()
await page.waitForTimeout(300)
await page.screenshot({ path: 'menu-open.png' })

// Close with Escape
await page.keyboard.press('Escape')
```

## Common Issues in Screenshots

| Symptom | Cause | Fix |
|---------|-------|-----|
| Blank white sections | Lazy load not triggered | Scroll smoothly, wait for content |
| Faded/transparent text | ScrollReveal animation mid-run | Wait longer before screenshot |
| Content cut off | `overflow: hidden` on parent | Check container constraints |
| Overlapping elements | Missing z-index or position | Add `z-index` hierarchy |
| Horizontal scrollbar | Fixed-width element | Check for `min-w` or explicit widths |

## Mandatory Scenarios

DevTools device-mode does **not** simulate real touch, iOS Safari chrome,
or OS-specific rendering. Every responsive change must be verified against
at least this set before declaring done:

1. **Portrait** at 390, 375, 768 — default flow.
2. **Landscape** at 844 × 390 — hero, primary CTA, forms.
3. **Landscape with keyboard** — focus an input in landscape; form must
   stay reachable, no content trapped under the keyboard.
4. **200 % system font scale** — iOS Settings → Display → Text Size max.
   No clipping, no horizontal scroll, no broken grids.
5. **Browser zoom 200 %** — content must reflow, not introduce horizontal
   scroll.
6. **Notched device (iPhone 14/15)** — hero padding clears the notch,
   bottom bars clear the home indicator.
7. **Slow 4G + 4× CPU throttle** — Lighthouse mobile audit; median of 5.
8. **Reduced motion** — OS setting on; non-essential animations suppress.
9. **Screen reader** — VoiceOver / TalkBack pass for landmarks and focus.

## Core Web Vitals During Testing

```js
// Paste into console on the running page
import('https://unpkg.com/web-vitals@4?module').then(({ onLCP, onINP, onCLS }) => {
  onLCP(v => console.log('LCP', v.value))
  onINP(v => console.log('INP', v.value))
  onCLS(v => console.log('CLS', v.value))
})
```

Or run Lighthouse mobile from DevTools — but remember single runs are
noisy; median of 5 is the trustworthy number.

## Post-Change Verification Checklist

- [ ] Screenshot hero at 390 px — title fits, search form clean.
- [ ] Screenshot hero at 375 px — no overflow on smallest phone.
- [ ] Full-page screenshot at 390 px — all sections visible.
- [ ] Landscape screenshot at 844 × 390 — no broken stacking.
- [ ] Open mobile menu — full-screen panel, items tappable.
- [ ] Scroll indicator visible on hero, destinations, and trips sections.
- [ ] Tablet (768 px) screenshot — 2-column grids work.
- [ ] 200 % font scale — no clipping.
- [ ] Safe-area padding honoured on notched device.
- [ ] Lighthouse mobile: LCP ≤ 2.5 s, INP ≤ 200 ms, CLS ≤ 0.1.
- [ ] No console errors, no hydration warnings.
- [ ] `bun run typecheck` passes.
- [ ] `bun run lint` passes (0 errors).
