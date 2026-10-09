# Layer 6c — Lead Capture and Conversion

The machinery that turns organic visitors into recorded leads. Audit for capture coverage (including abandonment), abuse protection on every public write endpoint, and conversion elements on high-intent pages.

## Contents

- Lead capture checks (LC-01 to LC-12)
- Abuse protection checks (LC-13 to LC-15)
- Conversion element checks (LC-16 to LC-25)
- Lead magnet and list checks (LC-26 to LC-32)
- Mailing checks (LC-33 to LC-35)
- Claim and CTA integrity checks (LC-36 to LC-41)
- Reference: landing-page order in shipped products
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
| LC-14 | EVERY public write endpoint protected — sweep contact, comments, subscribe, delete-request routes for captcha or rate limiting, including forms that post straight from the browser to a third-party email relay (real failure mode: hardened contact form next to a completely open comments endpoint) | List `POST` routes; grep each for verification/rate-limit tokens |
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
| LC-25 | Landing copy is concrete: a benefit grid of 3-6 specific value propositions, and copy built on specificity, risk reversal, and social proof rather than adjectives; the hero pairs an outcome headline and the primary CTA with a one-line trust strip (what access the product needs, what the user installs, how to cancel) | Read the hero + benefits sections of the top landing page |

## Lead magnet and list checks

| ID | Check | Verify by |
|----|-------|-----------|
| LC-26 | Every form's required configuration (relay keys, endpoint URL) is validated at build or boot, and a test submission is verified end to end in each environment | A build without the keys renders a working-looking form that fails only at submit; check what the build and the first page load do when a key is missing |
| LC-27 | A gated asset is not statically reachable, and its send path runs server-side behind abuse protection; a browser-held relay key with the recipient taken from the form turns the form into a relay that mails anyone | Request the asset's URL directly; read the email template's recipient field and where the send credential lives |
| LC-28 | The opt-in mode is stated and justified: double opt-in for any list that will be mailed, single opt-in only as a recorded decision naming its abuse risk; each row stores the consent text version and an unsubscribe token before the first send | Signup handler + schema + the decision record |
| LC-29 | The signup endpoint reveals nothing and absorbs abuse: the same response for new and already-listed addresses; a filled honeypot returns success and writes nothing; a global rate limit on top of per-IP limits; raw addresses kept out of logs; an insert-only database login; any return-to parameter accepted only as a same-site path | Read the handler and its logging; probe a duplicate address and a `//other-host` return path |
| LC-30 | A failed lead write raises an alert | A digest that counts stored rows reads a failing insert as no demand |
| LC-31 | A public lookup or calculator that triggers a paid vendor call is rate-limited per IP, checks coverage before calling, and returns only what the page needs | Trace the handler to the vendor call |
| LC-32 | An eligibility or coverage dead end ("not available in your area yet") captures the visitor into a waitlist with the reason and the page it came from, rather than ending the funnel. Refusals are told apart by cause: "not available here" only when ineligibility is confirmed, and a missing, expired, or unreadable input gets a page saying what to fix; each refusal is logged with its reason so the funnel can count them | Walk each refusal path with a confirmed-ineligible input and with a malformed one |

## Mailing checks

| ID | Check | Verify by |
|----|-------|-----------|
| LC-33 | Bounce and complaint feedback reaches a suppression list the sender honours; a fallback provider takes over only on transient errors (4xx, network), never on configuration errors it would mask | The provider webhook handler and the send path |
| LC-34 | Unsubscribe works in one click by POST (`List-Unsubscribe` with `List-Unsubscribe-Post`), and the GET link shows a confirmation page that changes nothing — mail scanners prefetch links; list mail carries the sender's legal footer | Read the unsubscribe routes and a rendered template |
| LC-35 | Every emailed button has a plain-link fallback beneath it and renders in Outlook; confirmation and sign-in links resolve to the environment's own origin, which is on the auth provider's redirect allowlist | Render the templates; trigger a signup from staging and follow the link |

## Claim and CTA integrity checks

| ID | Check | Verify by |
|----|-------|-----------|
| LC-36 | The primary above-the-fold CTA reaches the product's primary conversion — the store or install for an app, signup for SaaS — not a support form | Click the hero CTA |
| LC-37 | Every claim is bounded by evidence: numeric social proof ("12,000+ users", "5.0 rating") has a source; illustrative results are labelled as samples; "exact" and comparative claims stay within what the product measures; a hidden or commented-out component leaves no claim string live in the content layer | Grep the content files for numbers and superlatives and trace each |
| LC-38 | Plan, price, and free-tier claims match the store listing and the product (see GE-09) | Compare the pricing and FAQ copy with the listing and the in-app purchases |
| LC-39 | A deploy check blocks placeholder copy (`[Hero headline — …]`, lorem ipsum, template slogans) from shipping | The deploy script or CI; grep the built pages |
| LC-40 | Pages an app store requires (privacy policy, account deletion, support) are reachable on the web, match the URLs in the listing, are named for what they contain, and are indexed or `noindex` by decision | Fetch each URL from the listing |
| LC-41 | Every claim about where or whom the product serves — the trust line, testimonials, FAQ answers, `areaServed` in structured data, meta descriptions — matches the markets it serves today, and eligibility is enforced on the server, not only in the copy | After any change to the served markets, grep pages, schema, and sitemap for the regions that were dropped |

## Reference: landing-page order in shipped products

Not a check; a starting order to compare against. Product-led landing pages that convert tend to run: hero (outcome headline, primary CTA, trust strip), how it works or features, proof (named testimonials, a labelled sample result), FAQ handling objections, closing CTA, then support material and contact. A page whose only CTA sits below the FAQ, or whose proof precedes any statement of what the product does, is worth a look.

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
| A lead magnet gated only in the browser | The asset is public and the send path is an open relay | Server-side send, asset off the public path (LC-27) |
| Building funnel steps that never mount | Effort spent, zero leads captured, audits overcount capability | Verify mounting, not existence (LC-02) |
