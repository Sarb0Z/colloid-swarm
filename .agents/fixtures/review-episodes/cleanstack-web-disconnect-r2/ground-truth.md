# Ground truth — CleanStack-web Disconnect, ROUND 2

Reviewer output: transcript line 317 (subagent `a8529b9d502578b7a`, 50250 tokens, 10 tool uses).
Artifact reviewed: `artifact.tsx` (= `src/app/dashboard/connect/page.tsx`, 374 lines).
8 findings.

The headline result: **round 2 found that round 1's own accessibility fix was wrong**
(finding 1). That is the highest-signal item in this fixture.

Findings 6 and 7 target `src/app/globals.css` and part of finding 8 targets
`src/hooks/use-escape-key.ts`; both files are **NOT RECOVERED** (see NOTE). Findings
1-5 and the `page.tsx` half of 8 are reachable from `artifact.tsx`.

---

## 1. `role="status"` is on the wrong node — announces the footnote, never the outcome

ROUND: 2
FINDING: The live region sits on the always-mounted footnote; the real result lives in
`banner`, which has no `role="alert"` or `aria-live` anywhere in the codebase.
CLASS: QUALITY
DISPOSITION: ADOPTED
EVIDENCE: "The live region is on the one string that never carries news, and silent on the one that always does."
DISPOSITION NOTE: Fixed at transcript lines 328 and 333 — wrapped `banner` in a
permanently-mounted `<div role="status">` and stripped `role="status"` off the footnote.
The lead conceded directly (line 322): "it found that my round-1 accessibility \"fix\"
was actively wrong."

---

## 2. Live region spams on mount

ROUND: 2
FINDING: `aria-live=polite` on a permanently-mounted node announces on every page load
when `loadStatus` resolves and the footnote text swaps to "Connected 7/16/2026".
CLASS: QUALITY
DISPOSITION: ADOPTED
EVIDENCE: "that's a content change to a live region, so it announces. Every page load, for every connected org, unprompted."

---

## 3. `.catch()` launders real HTTP failures into "check your connection"

ROUND: 2
FINDING: A `TimeoutError`, a CORS-less 5xx and a malformed `API_URL` all report as
"Check your connection"; `throw new Error(...)` discards the original with no `cause`.
CLASS: QUALITY
DISPOSITION: ADOPTED
EVIDENCE: "Your backend 500 is now reported to the user as their Wi-Fi being down. That's a real HTTP error reported as a connectivity error"
DISPOSITION NOTE: Partial. At transcript line 336 the message was made cause-neutral
("Could not complete the disconnect. Please try again.") with the reasoning inlined as a
comment. The reviewer's second ask — preserving the original via `{ cause: err }` for
telemetry — was **not** implemented and was not explicitly declined.
The reviewer explicitly cleared the promise-semantics question it was asked to probe:
"The 429 throw is not affected, and the catch cannot swallow it. No bug there."

---

## 4. `aria-describedby` pointing at a live region causes double announcement

ROUND: 2
FINDING: `aria-describedby="connect-footnote"` targets the node carrying `role="status"`,
so on arm the live region announces and the description reads the same string.
CLASS: QUALITY
DISPOSITION: ADOPTED
EVIDENCE: "The description and the announcement are the same sentence from the same node. Pick one channel."
DISPOSITION NOTE: Resolved by the finding-1 fix — removing `role="status"` from the
footnote (transcript line 333) leaves `aria-describedby` pointing at an inert node.

---

## 5. State lie: a timed-out disconnect leaves the card claiming "Connected"

ROUND: 2
FINDING: The route revokes at Google before answering, so at 20.001s the client aborts
while the server completes; the card then shows Connected over a dropped grant.
CLASS: QUALITY
DISPOSITION: ADOPTED
EVIDENCE: "Google has dropped the grant, the DB row is `disconnected`, and the card shows **Connected** + a green pill"
DISPOSITION NOTE: Fixed at transcript line 338 by adding `void loadStatus()` to the
catch block, then proven in a browser against a mock that revokes-then-500s
(transcript lines 391-408). The reviewer flagged its own status honestly: "finding 5
proposes adding a `loadStatus()` call, which is a behavior change rather than a pure
defect report — flagging it as such so you can weigh it separately."

---

## 6. `globals.css` comment is false

ROUND: 2
FINDING: The comment "Variants set `--btn-*` and nothing else" is contradicted within 50
lines: `.btn--ghost`, `.btn--danger` and `.btn--block` each set more.
CLASS: QUALITY
DISPOSITION: ADOPTED
EVIDENCE: "The claim is contradicted within 50 lines of itself."
DISPOSITION NOTE: Reworded at transcript line 323 to the narrower true claim.
REACHABILITY: NOT reachable from `artifact.tsx` — targets `src/app/globals.css` (NOT RECOVERED).

---

## 7. `transform` is still order-dependent after the var refactor

ROUND: 2
FINDING: `.btn:disabled { transform: none }` and `.btn:hover { transform: translateY(-1px) }`
are both (0,2,0) — a specificity tie broken only by source order.
CLASS: QUALITY
DISPOSITION: ADOPTED
EVIDENCE: "both (0,2,0) — a specificity tie broken only by `:disabled` appearing later"
DISPOSITION NOTE: Fixed at transcript line 325 by adding `transform: none` to
`.btn:disabled:hover`. The reviewer cleared the two things it was asked to verify:
`.btn:disabled:hover` is (0,3,0) and "wins on specificity, order irrelevant", and
`--btn-bg` is the right colour for a disabled primary.
REACHABILITY: NOT reachable from `artifact.tsx` — targets `src/app/globals.css` (NOT RECOVERED).

---

## 8. Stale doc comments describe the code as it was before the diff

ROUND: 2
FINDING: `use-escape-key.ts:3-4` names only the drawers as callers, and `page.tsx:8-11`
describes reading status and starting OAuth though the page now also revokes.
CLASS: REQUIREMENT
DISPOSITION: ADOPTED
EVIDENCE: "Both describe the code as it *was* before this diff — CLAUDE.md wants comments describing the code as it is."
DISPOSITION NOTE: Split verdict. The `page.tsx` half was adopted outright
(transcript line 341). The `use-escape-key.ts` half was judged **wrong on the merits**
but reworded anyway (transcript line 348): "The hook pattern-matched \"Used to\" as a
tombstone. It's a false positive — that's \"used *in order to*\", not \"formerly\" — but
the phrasing is ambiguous, so I'll reword it rather than leave a tripwire." Two
successive rewordings followed at lines 344 and 349.
CLASS NOTE: Classed REQUIREMENT because both round prompts named CLAUDE.md's
"no tombstone / history-narrating comments" rule as an explicit review target.
REACHABILITY: PARTIAL — the `page.tsx:8-11` half is in `artifact.tsx`; the
`use-escape-key.ts` half is not (file NOT RECOVERED).

---

## Reviewer's explicit non-findings (recorded so a grader does not credit them as misses)

The reviewer probed and cleared, with the instruction "don't re-litigate": the focus
`useEffect` and `wasArmed` ref (no mount steal, honest dep array, no mouse focus ring,
both exit paths land correctly, `wasArmed` is load-bearing); `AbortSignal.timeout`
baseline support and SSR safety (build confirms the route prerenders static); and
whether `connecting` and `disconnecting` can both be true ("Unreachable... The two flows
are structurally exclusive").

---

## NOTE — `globals.css` and `use-escape-key.ts` NOT RECOVERED

Neither file's reviewed state could be faithfully reconstructed. The transcript contains
only partial slices of `globals.css` (transcript lines 43 and 51) and never a full read
of either file. The repository `/Users/mac/Projects/CleanStack-web` no longer exists on
disk, so there is no git base to replay the CSS edits (transcript lines 55, 97, 103)
onto. Per instruction they are marked NOT RECOVERED rather than partially synthesised.

Consequence: findings 6, 7 and half of 8 are in the ground truth but cannot be found by
a reviewer given only `artifact.tsx`. Score them as out-of-scope, or supply the two
files separately.
