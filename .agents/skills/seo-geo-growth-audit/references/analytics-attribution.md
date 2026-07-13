# Layer 5 — Analytics and Attribution

Measurement infrastructure: tag loading that protects performance, an event layer that actually fires, and attribution that survives from first touch to CRM row. The most common real-world failure is not a missing vendor — it is a vendor with nothing instrumented behind it.

## Contents

- Tag loading checks (AA-01 to AA-06)
- Event instrumentation checks (AA-07 to AA-09)
- Attribution checks (AA-10 to AA-17)
- Persistence and data-model checks (AA-18 to AA-21)
- Adaptable pattern: deferred tag-manager loader
- Adaptable pattern: sessionStorage attribution module
- Anti-patterns

## Tag loading checks

| ID | Check | Verify by |
|----|-------|-----------|
| AA-01 | Tag manager load is deferred until first interaction or a timeout, protecting LCP (validated example: 5000ms timeout with scroll/click/touchstart/mousemove triggers, `{ once: true, passive: true }`) | Read the loader component; confirm in DevTools that gtm.js loads late |
| AA-02 | Loader uses the framework's script primitive with an after-hydration strategy once triggered | Loader component |
| AA-03 | Event listeners removed on both the load path and the unmount path | Loader component cleanup |
| AA-04 | noscript iframe fallback present | Root layout |
| AA-05 | dns-prefetch + preconnect for the tag-manager origin | Root layout head |
| AA-06 | Container ID from an environment variable, not hardcoded | Grep for the literal container ID |

## Event instrumentation checks

| ID | Check | Verify by |
|----|-------|-----------|
| AA-07 | Instrumentation depth: a tag vendor with ZERO custom events is analytics theater — pageviews alone cannot optimize a funnel (real failure mode: GTM shipped site-wide, not one `dataLayer.push` anywhere) | `grep -rn "dataLayer.push" src/` excluding the bootstrap snippet; count must be > 0 |
| AA-08 | Funnel stages emit events: `form_start`, `form_submit`, `lead_capture`, `cta_click`, `scroll_depth`, scheduling events (e.g. `calendly_scheduled` from the widget's postMessage) | Grep each event name; walk the form code |
| AA-09 | A conversion page (thank-you) exists AND key conversions also fire as events — a URL-based trigger breaks the moment the redirect changes | Thank-you route + event on the scheduling callback |

## Attribution checks

| ID | Check | Verify by |
|----|-------|-----------|
| AA-10 | First-touch attribution captured client-side into sessionStorage (validated example key: `leadSource`) with fields source/medium/campaign/term (+ content if campaigns use it) | Find the attribution module |
| AA-11 | Capture hierarchy: explicit `utm_*` params -> paid/social click IDs -> referrer hostname -> `direct` | Module logic |
| AA-12 | Click-ID coverage includes `gclid` and `msclkid`, not just `fbclid`/`twclid`/`li_fat_id` — Google Ads traffic is usually the expensive gap | Module's ID list |
| AA-13 | Timing rule: strip social/paid click IDs from the URL after capture, but KEEP `utm_*` in the URL until the analytics vendor has loaded — with a deferred tag manager (AA-01), stripping UTMs immediately destroys the vendor's own campaign attribution | Module: confirm it deletes click-ID params only |
| AA-14 | Auto-term assignment: organic/direct visits get the landing-page slug as term, so content attribution exists without campaigns | Module logic |
| AA-15 | OAuth-aware: sign-in round-trips (`?code=`, auth flags) do not overwrite stored attribution | Module's param handling |
| AA-16 | Internal links never mutated with UTM params (functions may exist as explicit no-ops — that is correct) | Grep for link-rewriting code |
| AA-17 | Outbound attribution bridge: a `buildUtmQueryString()`-style helper forwards stored attribution to external tools (scheduling, checkout) | Grep usages on external-widget URLs |

## Persistence and data-model checks

| ID | Check | Verify by |
|----|-------|-----------|
| AA-18 | Attribution is PERSISTED to the datastore on lead creation, not only forwarded to chat/CRM notifications — Slack messages are not queryable (real failure mode: UTM in every notification, zero UTM columns written) | Lead table schema + the insert call |
| AA-19 | Lead model carries attribution fields (source/medium/campaign/term, referrer, landing page) and a status pipeline (`new -> contacted -> qualified -> proposal_sent -> closed_won/lost`) | Schema |
| AA-20 | No dead models: every analytics/lead table in the schema has code writing to it (real failure mode: a perfectly designed lead model with zero references while inserts go to a bare contacts table) | Grep model names across the codebase |
| AA-21 | Server-side forwarding to CRM/notification channels includes the attribution, and notification sends are environment-gated (production or explicit override flag) | Notification builder + env checks |

## Adaptable pattern: deferred tag-manager loader (Next.js App Router)

```jsx
'use client';
import Script from 'next/script';
import { useEffect, useState } from 'react';

const EVENTS = ['scroll', 'click', 'touchstart', 'mousemove'];

export default function TagManager() {
  const [load, setLoad] = useState(false);
  useEffect(() => {
    let done = false;
    const fire = () => {
      if (done) return;
      done = true;
      setLoad(true);
      EVENTS.forEach((e) => window.removeEventListener(e, fire));
    };
    const timer = setTimeout(fire, 5000); // ship-validated ceiling: analytics still catches the session
    EVENTS.forEach((e) => window.addEventListener(e, fire, { once: true, passive: true }));
    return () => {
      clearTimeout(timer);
      EVENTS.forEach((e) => window.removeEventListener(e, fire));
    };
  }, []);
  if (!load) return null;
  return (
    <Script id="gtm" strategy="afterInteractive">
      {`(function(w,d,s,l,i){w[l]=w[l]||[];w[l].push({'gtm.start':new Date().getTime(),event:'gtm.js'});var f=d.getElementsByTagName(s)[0],j=d.createElement(s),dl=l!='dataLayer'?'&l='+l:'';j.async=true;j.src='https://www.googletagmanager.com/gtm.js?id='+i+dl;f.parentNode.insertBefore(j,f);})(window,document,'script','dataLayer','${process.env.NEXT_PUBLIC_GTM_ID}');`}
    </Script>
  );
}
```

## Adaptable pattern: sessionStorage attribution module

```javascript
const KEY = 'leadSource';
const UTM_KEYS = ['source', 'medium', 'campaign', 'term'];
const CLICK_IDS = { gclid: 'google-ads', msclkid: 'bing-ads', fbclid: 'facebook', twclid: 'twitter', li_fat_id: 'linkedin' };

export function initLeadSource(pathname) {
  const url = new URL(window.location.href);
  const stored = read();
  const utm = Object.fromEntries(
    UTM_KEYS.map((k) => [k, url.searchParams.get(`utm_${k}`)]).filter(([, v]) => v)
  );
  if (Object.keys(utm).length) {
    save(utm); // keep utm_* in the URL: the deferred analytics vendor still needs them
  } else if (!stored) {
    const clickId = Object.keys(CLICK_IDS).find((k) => url.searchParams.get(k));
    save({
      source: clickId ? CLICK_IDS[clickId] : referrerSource() || 'direct',
      medium: clickId ? 'paid' : document.referrer ? 'referral' : 'none',
      term: slugOf(pathname),
    });
  }
  stripClickIds(url); // remove ONLY click-ID params via history.replaceState
}

export function buildUtmQueryString() {
  const a = read();
  if (!a) return '';
  const p = new URLSearchParams();
  UTM_KEYS.forEach((k) => a[k] && p.set(`utm_${k}`, a[k]));
  return p.toString();
}
```

## Anti-patterns

| Anti-pattern | Why it is bad | Fix |
|--------------|---------------|-----|
| Analytics theater (vendor loaded, zero events) | Funnel is unmeasurable; every CRO decision is a guess | Instrument the funnel stages (AA-07/08) |
| Stripping `utm_*` from the URL before analytics loads | Deferred vendor never sees the campaign; sessions report as direct | Strip click IDs only; keep UTMs (AA-13) |
| UTM params appended to internal links | Session fragmentation, duplicate URLs, self-referral noise | Store once in sessionStorage; never rewrite internal links (AA-16) |
| Loading the tag manager immediately | Blocks LCP; performance pays for measurement | Defer until interaction/timeout (AA-01) |
| Attribution that dies in Slack | Notifications are not a database; cohort analysis impossible | Persist attribution columns on the lead row (AA-18) |
