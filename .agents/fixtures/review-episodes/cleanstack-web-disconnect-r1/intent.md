# Intent — CleanStack-web "Disconnect" button (round 1)

Source session: `/Users/mac/.claude/projects/-Users-mac-Projects-CleanStack-web/86c895c8-a740-469c-9e71-e0ea48ab2dfa.jsonl` (2026-07-16/17)

Artifact under review: `src/app/dashboard/connect/page.tsx`, uncommitted working tree,
as it stood at the round-1 review dispatch (transcript line 74).

## User request (verbatim, transcript line 9)

> We want to add a disconnect button here.  It should revoke permission but not do
> anything extra. Basically adding an intermediate step for reconnect.
> I believe backend work is already done.

> Before this, the only way an org's Google grant ever went away was lazily: a worker
> would try to use the token, Google would reject it, and the code flipped the row to
> disconnected. Nothing revoked anything at Google, and nothing ever deleted the stored
> tokens. So a "Disconnect" button had nothing to call.

> What I added
>
> POST /api/auth/google/disconnect (src/auth/auth.controller.ts:64) — bearer-guarded,
> throttled 10/min per IP, org taken from the verified session. Returns 200
> {"status":"disconnected"}, and is idempotent if there's no connection on file. It
> revokes the grant at Google, deletes the tokens from Vault, and sets the row to
> status='disconnected', connected_at=null, vault_key=null. Audits, tools, and directory
> rows are untouched — exactly the intermediate-step-before-reconnect scope you asked
> for, not a delete-my-data button.

## Backend contract as verified by the implementer (verbatim, transcript line 41)

> Backend confirmed firsthand: `POST /api/auth/google/disconnect` returns
> `{status:"disconnected"}`, revokes at Google, deletes the Vault secret, and flips the
> row.

## Implementation plan as stated (verbatim, transcript line 54)

> Backend's solid. Implementing now: a ghost **Disconnect** beside Reconnect, with an
> inline confirm step — a mis-click costs a full Workspace-admin re-consent, so I'm
> guarding it, but with the existing button styles rather than a new modal primitive.

## Scope statement given to the reviewer (verbatim, transcript line 74)

> Scope of the ask was deliberately narrow: revoke permission, nothing extra. It is the
> intermediate step before a reconnect.

## Governing repo rules referenced during review

CLAUDE.md rules the reviewer was told to enforce: no tombstone comments, no dead code,
YAGNI, atomic commits.

## Companion file NOT in this fixture

Round-1 findings 7 and part of the cascade analysis target
`src/app/dashboard/../globals.css`. That file is **NOT RECOVERED** — see
`ground-truth.md` for which findings are unreachable from `artifact.tsx` alone.
