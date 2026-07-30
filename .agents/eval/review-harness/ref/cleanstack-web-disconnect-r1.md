# Reference findings
Each entry is one previously-reported finding on this artifact.

## R1
Focus destroyed on every state flip

Clicking Disconnect unmounts the focused button and mounts Cancel/Confirm, so focus resets to `<body>`; keyboard users must Tab from the document top.

## R2
State change is silent to assistive tech

The footnote swaps and buttons change meaning in place with no `aria-live` / `role="status"` and no `aria-describedby` pointing at the warning.

## R3
No Escape to cancel

An armed destructive prompt has a mouse-only exit, while `use-escape-key.ts` already exists in the repo and `drawer.tsx` uses it.

## R4
`connecting` never resets on success; `disabled={connecting}` wedges Disconnect

On a bfcache restore the heap returns with `connecting === true`, leaving Reconnect stuck on "Redirecting…" and now wedging Disconnect dead too.

## R5
Cancel disabled mid-flight with no timeout; card can freeze indefinitely

Both buttons are disabled while `disconnecting` and the `fetch` has no timeout or AbortController, so a hung Google revoke leaves the card dead with no escape.

## R6
Generic error string discards cases the backend distinguishes

Every `!res.ok` maps to "Please try again", but the route is throttled 10/min, so a 429 advises retrying when retrying is precisely what is refused.

## R7
`:disabled` does not suppress the hover fill

`globals.css` `:disabled` sets only opacity/cursor/transform, so `:hover` still matches and the inert "Disconnecting…" button still washes red.

## R8
Unrelated change bundled in the working tree

`src/types/database.ts` (a doc-path fix) is unrelated to Disconnect, and CLAUDE.md requires atomic commits.
