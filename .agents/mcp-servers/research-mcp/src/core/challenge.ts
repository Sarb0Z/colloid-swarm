/**
 * Recognises an anti-bot interstitial served in place of the page.
 *
 * A challenge arrives as HTTP 200 with a short body, so nothing at the
 * transport layer distinguishes it from a real, brief page. Left undetected it
 * is returned as content: the caller reads "Just a moment..." and treats it as
 * the article, or an extractor finds no body and reports the page as an index.
 * Either way the failure is silent, and a silent block is worse than a refusal
 * because it reads as coverage.
 *
 * Patterns follow career-ops' `liveness-core.mjs`, which arrived at this set
 * against live job boards. Matching is deliberately narrow: these strings are
 * specific to interstitials, and a false positive would hide a real page. That
 * source also matches a bare `ray id`; `cf-ray` covers the same interstitial
 * without also matching an article that happens to quote a Cloudflare error.
 */

const CHALLENGE_PATTERNS: readonly RegExp[] = [
  /just a moment/i,
  /performing security verification/i,
  /checking your browser before/i,
  /verify you are (a |not a )?human/i,
  /enable javascript and cookies to continue/i,
  /attention required.*cloudflare/i,
  /\bcf-ray\b/i,
  /please complete the security check/i,
  /\bddos protection by\b/i,
];

/**
 * Only the head is scanned. An interstitial carries its marker near the top,
 * while a page that merely *discusses* bot protection puts the same words in
 * its body.
 */
const SCAN_CHARS = 4_096;

/**
 * A challenge page carries no content, so its whole document is small. A real
 * page above this size that happens to use one of the phrases — an article on
 * captchas, a title beginning "Just a moment" — is not an interstitial, and
 * discarding it would be the same silent loss in the opposite direction.
 *
 * Generous on purpose: observed interstitials run a few kilobytes, and the
 * cost of setting this too low is a live page thrown away.
 */
const MAX_CHALLENGE_CHARS = 64_000;

/**
 * The matched pattern's source when the text is an interstitial, else null.
 *
 * The source string is returned rather than a boolean so the caller can say
 * which signal fired; "blocked" with no reason is not actionable.
 */
export function detectChallenge(text: string): string | null {
  if (!text || text.length > MAX_CHALLENGE_CHARS) return null;
  const head = text.slice(0, SCAN_CHARS);
  return CHALLENGE_PATTERNS.find((pattern) => pattern.test(head))?.source ?? null;
}
