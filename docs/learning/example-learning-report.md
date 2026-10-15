# Learning report: example — rate-limit the export endpoint

## **Key the limit on the account, not the IP**

- **Why** — offices share one address; an IP key would let one user exhaust a
  whole team's budget. Rejected: IP keys, which need no session.
- **The code** — `src/limiter.ts:12`

  ```ts
  const key = `export:${session.accountId}`;
  ```

- **How it works** — every request for the same account increments one counter.
- **Pattern** — throttle keyed by tenant.
- **Recognition cue** — when users share infrastructure, key limits on identity.
