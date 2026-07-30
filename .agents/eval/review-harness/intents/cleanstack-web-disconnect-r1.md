# Intent — CleanStack-web "Disconnect" button

## User request, verbatim

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

## Backend contract as verified by the implementer, verbatim

> Backend confirmed firsthand: `POST /api/auth/google/disconnect` returns
> `{status:"disconnected"}`, revokes at Google, deletes the Vault secret, and flips the
> row.

## Implementation plan as stated, verbatim

> Backend's solid. Implementing now: a ghost **Disconnect** beside Reconnect, with an
> inline confirm step — a mis-click costs a full Workspace-admin re-consent, so I'm
> guarding it, but with the existing button styles rather than a new modal primitive.

## Scope statement, verbatim

> Scope of the ask was deliberately narrow: revoke permission, nothing extra. It is the
> intermediate step before a reconnect.

## Governing repo rules

CLAUDE.md rules to enforce: no tombstone comments, no dead code, YAGNI, atomic commits.
