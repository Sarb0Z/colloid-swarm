# Handoff: example — rate-limit the export endpoint

## Objective

`GET /exports/:id` serves at most 10 requests a minute per account.

## Current state

The limiter middleware exists and is wired to the route; the per-account key is
not yet read from the session.

## Evidence

- `npm test -- exports` passes 14 of 15; the failing case is the per-account key.

## Decisions

- Limit per account, not per IP: shared offices sit behind one address.

## Limitations

- Load behavior above 100 accounts is unmeasured.

## Remaining gates

- The operator approves the production config change.

## Next action

Read the account id from the session in `limiter.ts` and rerun the export tests.
