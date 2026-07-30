# Ground truth — CleanStack-web Disconnect, ROUND 1

Reviewer output: transcript line 76 (subagent `a4d06b21892869f62`, 61508 tokens, 10 tool uses).
Artifact reviewed: `artifact.tsx` (= `src/app/dashboard/connect/page.tsx`, 330 lines).
8 findings. Reviewer's own severity labels preserved in parentheses.

Findings 7 and the cascade note target `src/app/globals.css`, which is **NOT RECOVERED**
(see NOTE at the end). Findings 1-6 and 8 are reachable from `artifact.tsx`.

---

## 1. (HIGH) Focus destroyed on every state flip

ROUND: 1
FINDING: Clicking Disconnect unmounts the focused button and mounts Cancel/Confirm, so
focus resets to `<body>`; keyboard users must Tab from the document top.
CLASS: QUALITY
DISPOSITION: ADOPTED
EVIDENCE: "React unmounts the focused element, so focus resets to `<body>`. A keyboard user who presses Enter on Disconnect loses focus entirely"

---

## 2. (HIGH) State change is silent to assistive tech

ROUND: 1
FINDING: The footnote swaps and buttons change meaning in place with no `aria-live` /
`role="status"` and no `aria-describedby` pointing at the warning.
CLASS: QUALITY
DISPOSITION: ADOPTED
EVIDENCE: "nothing carries `aria-live`/`role=\"status\"`, and the confirm buttons have no `aria-describedby` pointing at the warning"

---

## 3. (MEDIUM) No Escape to cancel

ROUND: 1
FINDING: An armed destructive prompt has a mouse-only exit, while `use-escape-key.ts`
already exists in the repo and `drawer.tsx` uses it.
CLASS: QUALITY
DISPOSITION: ADOPTED
EVIDENCE: "An armed destructive prompt with a mouse-only exit. `src/hooks/use-escape-key.ts` already exists"

---

## 4. (MEDIUM) `connecting` never resets on success; `disabled={connecting}` wedges Disconnect

ROUND: 1
FINDING: On a bfcache restore the heap returns with `connecting === true`, leaving
Reconnect stuck on "Redirecting…" and now wedging Disconnect dead too.
CLASS: QUALITY
DISPOSITION: IGNORED
EVIDENCE: "On a bfcache restore (Safari/Firefox back-button from Google's consent screen) the heap comes back with `connecting === true`"
DISPOSITION NOTE: Never addressed and never explicitly declined. Absent from the
round-2 prompt's "already fixed, do NOT re-report" list (transcript line 316), and the
round-2 artifact still has `setConnecting(false)` only inside the `catch` of `connect()`.
Round 2 did not re-raise it either.

---

## 5. (MEDIUM) Cancel disabled mid-flight with no timeout; card can freeze indefinitely

ROUND: 1
FINDING: Both buttons are disabled while `disconnecting` and the `fetch` has no timeout
or AbortController, so a hung Google revoke leaves the card dead with no escape.
CLASS: QUALITY
DISPOSITION: ADOPTED
EVIDENCE: "If Google hangs, both buttons stay dead with no escape. Use `AbortSignal.timeout`, or leave Cancel enabled to abort."

---

## 6. (LOW-MED) Generic error string discards cases the backend distinguishes

ROUND: 1
FINDING: Every `!res.ok` maps to "Please try again", but the route is throttled 10/min,
so a 429 advises retrying when retrying is precisely what is refused.
CLASS: QUALITY
DISPOSITION: ADOPTED
EVIDENCE: "a 429 tells the user to retry when retrying is precisely what's refused; a 401 tells them to retry when they need to re-authenticate"

---

## 7. (LOW) `:disabled` does not suppress the hover fill

ROUND: 1
FINDING: `globals.css` `:disabled` sets only opacity/cursor/transform, so `:hover` still
matches and the inert "Disconnecting…" button still washes red.
CLASS: QUALITY
DISPOSITION: ADOPTED
EVIDENCE: "`:hover` still matches disabled buttons, so the inert \"Disconnecting…\" button still washes red — reads live while dead"
REACHABILITY: NOT reachable from `artifact.tsx` — targets `src/app/globals.css` (NOT RECOVERED).

---

## 8. (LOW) Unrelated change bundled in the working tree

ROUND: 1
FINDING: `src/types/database.ts` (a doc-path fix) is unrelated to Disconnect, and
CLAUDE.md requires atomic commits.
CLASS: REQUIREMENT
DISPOSITION: ESCALATED
EVIDENCE: "`src/types/database.ts` (doc-path fix) has nothing to do with Disconnect; CLAUDE.md requires atomic commits."
DISPOSITION NOTE: Put to the user via AskUserQuestion at transcript line 312 ("How
should the unrelated database.ts doc fix be handled?"). User chose "Separate commit
(Recommended)"; the implementer then committed it separately at line 424.
REACHABILITY: NOT reachable from `artifact.tsx` — concerns a sibling file's presence in
the working tree, not this file's contents.

---

## Reviewer's explicit non-findings (recorded so a grader does not credit them as misses)

The reviewer checked and cleared: the `.btn--danger:hover` cascade does win (but only on
source order); `--red`/`--red-wash` exist; there is no connect/disconnect race in either
direction; the banner copy matches the backend; no tombstone comments and no dead code.

---

## NOTE — `globals.css` NOT RECOVERED

The reviewed state of `src/app/globals.css` could not be faithfully reconstructed. The
transcript contains only partial slices (lines 1-60 and scattered grep hits, transcript
lines 43 and 51), never a full read. The repository `/Users/mac/Projects/CleanStack-web`
no longer exists on disk, so no git base is available to replay the one CSS edit
(transcript line 55) onto. Per instruction, it is marked NOT RECOVERED rather than
partially synthesised.

Consequence: finding 7 is present in the ground truth but cannot be found by a reviewer
given only `artifact.tsx`. Score it as out-of-scope, or supply the CSS separately.
