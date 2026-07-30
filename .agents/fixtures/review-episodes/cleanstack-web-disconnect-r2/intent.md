# Intent — CleanStack-web "Disconnect" button (round 2)

Source session: `/Users/mac/.claude/projects/-Users-mac-Projects-CleanStack-web/86c895c8-a740-469c-9e71-e0ea48ab2dfa.jsonl` (2026-07-16/17)

Artifact under review: `src/app/dashboard/connect/page.tsx`, uncommitted working tree,
as it stood at the round-2 review dispatch (transcript line 316) — i.e. **after** all
round-1 fixes and the browser-driven layout fixes, **before** any round-2 fix.

Same feature and same file as `cleanstack-web-disconnect-r1`; this is the second
sequential review round on the evolved artifact.

## User request (verbatim, transcript line 9)

> We want to add a disconnect button here.  It should revoke permission but not do
> anything extra. Basically adding an intermediate step for reconnect.
> I believe backend work is already done.

> POST /api/auth/google/disconnect (src/auth/auth.controller.ts:64) — bearer-guarded,
> throttled 10/min per IP, org taken from the verified session. Returns 200
> {"status":"disconnected"}, and is idempotent if there's no connection on file. It
> revokes the grant at Google, deletes the tokens from Vault, and sets the row to
> status='disconnected', connected_at=null, vault_key=null. Audits, tools, and directory
> rows are untouched — exactly the intermediate-step-before-reconnect scope you asked
> for, not a delete-my-data button.

## Implementation plan as stated (verbatim, transcript line 54)

> Backend's solid. Implementing now: a ghost **Disconnect** beside Reconnect, with an
> inline confirm step — a mis-click costs a full Workspace-admin re-consent, so I'm
> guarding it, but with the existing button styles rather than a new modal primitive.

## Contract restated to the round-2 reviewer (verbatim, transcript line 316)

> Context: a "Disconnect" button was added to the Google Workspace card. It POSTs
> {API_URL}/api/auth/google/disconnect with a supabase bearer token; backend returns 200
> {"status":"disconnected"}. It arms an inline confirm step before firing.

## Round-1 fixes declared out of scope (verbatim, transcript line 316)

The round-2 reviewer was told not to re-report these. A fixture consumer should apply
the same exclusion when grading.

> Round 1 findings ALREADY FIXED — do NOT re-report: focus management across the confirm
> swap, role=status + aria-describedby, Escape-to-cancel, AbortSignal.timeout, 429
> handling, .btn:disabled:hover, --btn-bg-hover making hover colours order-independent.

## Verification already performed before round 2 (verbatim, transcript line 316)

> Already verified in a real browser: happy path, 429 path, Escape, focus on arm/after-success,
> no layout reflow, POST carries bearer.

## Governing repo rules referenced during review

CLAUDE.md rules the reviewer was told to enforce: no tombstone / history-narrating
comments, no dead code, YAGNI, no comments that rescue bad code.

## Companion files NOT in this fixture

Round-2 findings 6 and 7 target `src/app/globals.css`; finding 8 partly targets
`src/hooks/use-escape-key.ts`. Neither file is recovered — see `ground-truth.md`.
