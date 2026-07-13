# Layer 6c — Lead Capture and Conversion

The machinery that turns organic visitors into recorded leads. Audit for capture coverage (including abandonment), abuse protection on every public write endpoint, and conversion elements on high-intent pages.

## Contents

- Lead capture checks (LC-01 to LC-12)
- Abuse protection checks (LC-13 to LC-15)
- Conversion element checks (LC-16 to LC-25)
- Adaptable pattern: partial lead capture
- Anti-patterns

## Lead capture checks

| ID | Check | Verify by |
|----|-------|-----------|
| LC-01 | Contact flow breaks into micro-commitments — a state machine of small screens (identify -> qualify -> schedule) rather than one long form | Walk the form component's states |
| LC-02 | Dormant funnel components are not counted as implemented: built-but-unmounted step forms, commented-out entry points | Grep for imports of each funnel component; unreferenced = absent |
| LC-03 | OAuth pre-fill (Google sign-in populates name/email) to cut typing friction | Form component |
| LC-04 | Work-email gating: personal domains blocked against an explicit blocklist (~40 domains), WITH a visible opt-in override ("I don't have a work email") so real leads are not lost | Find the domain list + the override checkbox |
| LC-05 | Partial lead capture: after N minutes with a valid email in the field, capture it even without submit (pattern below; validated value 120000ms) | Form effect hooks |
| LC-06 | Partial captures deduplicated per session (sessionStorage key per email) so abandoners are not spammed into the CRM repeatedly | Dedupe key in the capture effect |
| LC-07 | International phone input: country flags, search, auto-format | Form dependencies |
| LC-08 | Validation on both client and server | Form + API route |
| LC-09 | Lead magnet: email-only capture for downloadable resources, unique-email constraint, automated delivery via a transactional email provider | Magnet component + API + mailer |
| LC-10 | New leads notify the team on their channels (Slack/Discord/Notion or CRM API) immediately | Lead API route (attribution content of these messages is an analytics-layer check) |
| LC-11 | Privacy/GDPR request flow (profile deletion, data request) exists and is bot-protected | Route + its captcha |
| LC-12 | Thank-you/confirmation page as a stable conversion anchor | Route exists; scheduling flows land on it |

## Abuse protection checks

| ID | Check | Verify by |
|----|-------|-----------|
| LC-13 | Score-based invisible bot verification on primary forms (reCAPTCHA v3/Enterprise, Turnstile, or equivalent): threshold around 0.5, a fallback path when the primary check errors, and dev-environment bypass gated so production always enforces | Client + server verification code |
| LC-14 | EVERY public write endpoint protected — sweep contact, comments, subscribe, delete-request routes for captcha or rate limiting (real failure mode: hardened contact form next to a completely open comments endpoint) | List `POST` routes; grep each for verification/rate-limit tokens |
| LC-15 | Rate limiting on lead/comment APIs as the second layer behind captcha | Middleware or per-route limiter |

## Conversion element checks

| ID | Check | Verify by |
|----|-------|-----------|
| LC-16 | One reusable, accessible CTA/button component | Component library |
| LC-17 | Contextual CTAs: "Hire {tech}" on tech pages, "View profile" on cards, topic-matched CTAs on posts — not one generic "Contact us" everywhere | Grep CTA text builders |
| LC-18 | Sticky CTA on high-intent pages (profiles, pricing, comparison) | Sticky components |
| LC-19 | CMS feature flags toggle page sections without deploys (default-on `show* !== false` gating) — lightweight A/B and kill-switches | CMS schema + template gating |
| LC-20 | Social proof near the ask: testimonials filtered by context, streamed with skeleton fallbacks so they never block the page | Testimonial section + Suspense wrapper |
| LC-21 | Comparison content (vs competitor, vs status quo) on decision pages | Components |
| LC-22 | Risk reversal: trial offer with specific terms stated | Trial component/copy |
| LC-23 | Interactive pricing/rate calculator that ends in a contact CTA | Calculator + its submit path |
| LC-24 | Free tools carry attribution and a conversion path (built-by credit + relevant hire/buy CTA) | Tool page templates |
| LC-25 | Landing copy is concrete: a benefit grid of 3-6 specific value propositions, and copy built on specificity, risk reversal, and social proof rather than adjectives | Read the hero + benefits sections of the top landing page |

## Adaptable pattern: partial lead capture

Reuse the main lead endpoint with an email-only flag — a separate partial-leads endpoint is a second thing to secure and monitor:

```jsx
useEffect(() => {
  if (!email || !isValidWorkEmail(email)) return;
  const dedupeKey = `partialLead:${email.toLowerCase()}`;
  if (sessionStorage.getItem(dedupeKey)) return;

  // 120000ms validated in production: long enough to mean abandonment,
  // short enough that the tab is usually still open
  const timer = setTimeout(async () => {
    await fetch('/api/contact', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        email,
        emailOnlyLead: true,
        leadSource: getLeadSource(),        // stored attribution
        pageUrl: window.location.pathname,
        recaptchaToken: await getToken(),   // partial leads still verify
      }),
    });
    sessionStorage.setItem(dedupeKey, 'true');
  }, 120000);
  return () => clearTimeout(timer);
}, [email]);
```

## Anti-patterns

| Anti-pattern | Why it is bad | Fix |
|--------------|---------------|-----|
| One hardened form, other write endpoints open | Spam finds the weakest endpoint (comments are the classic hole) | Sweep every public POST (LC-14) |
| Work-email gate without an override | Founders and freelancers with personal emails bounce silently | Explicit opt-in checkbox (LC-04) |
| Partial capture without dedupe | The same abandoner floods notifications every visit | sessionStorage dedupe key (LC-06) |
| Building funnel steps that never mount | Effort spent, zero leads captured, audits overcount capability | Verify mounting, not existence (LC-02) |
