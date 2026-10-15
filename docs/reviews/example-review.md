# Hostile review: example — export rate limit

One round over the plan, base `abc1234`.

Reviewer: `reviewer` on opus. CONFORMANCE: no. EFFECTS: none.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | The limit keys on IP, so one office shares a single budget | Fix: key on the account id |
| 2 | P2 | The 429 response omits `Retry-After` | Fix |
| 3 | P2 | No load measurement above 100 accounts | Deferred: breadcrumb |
