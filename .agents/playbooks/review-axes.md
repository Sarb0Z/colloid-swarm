# Review axes

The reviewer contract in `hostile-review.md` points here. Four groups, three or
four axes each.

Work one group at a time and finish it before starting the next. Report each
finding with `file:line`, why it bites, and the fix. Skip any axis the artifact
cannot exhibit — an axis with nothing to say needs no mention. Say when you are
unsure rather than inventing a finding to fill a group.

## 1. Boundaries — who may act, and what a hostile caller can do

- **Access control** — for every route, endpoint, and page: who may call it,
  and is that enforced on the server? Identity lifecycle counts as access —
  disabled and deleted users holding live sessions, role changes that only
  take effect at the next login, roles resolved in the client or absent from
  the session at login, and any flow that lets a user mint a role above their
  own. Check that an admin surface refuses a non-admin, and that each role
  sees only its own rows.
- **Abuse and limits** — unmetered endpoints, reset and invite links with no
  expiry, no single use, and no attempt cap. Anything a script can call in a
  loop.
- **Dangerous patterns** — data loss, unsafe deletes, unvalidated input,
  injection, swallowed errors, secrets or environment-specific values
  hardcoded.

## 2. Correctness and failure — does it behave, and does failure surface

- **Race conditions** — unguarded shared state, check-then-act, missing
  locks/transactions, non-atomic read-modify-write, ordering assumptions.
- **Failed checks read as verdicts** — any check that can fail has three
  outcomes, not two: genuine yes, genuine no, and *it did not complete*. A
  bool or an empty list holds two, so the third collapses into the falsy one,
  which is almost always the reassuring one — clean, not listed, no record.
  `except Exception: return False` is the signature. Catch only what means a
  genuine negative; carry the failure in a field the caller reads separately
  from the verdict. Never let a check that errored downgrade good state.
- **Hard-to-debug code** — silent failures, no logging at failure points, magic
  control flow, deep nesting, side effects behind innocent names. A failure
  logged but not raised, counted but not paged, or returned in a payload
  nobody reads is indistinguishable from success — trace each failure mode to
  the human who learns about it, and if that trace ends at a log line or a 200
  response, say so. In a batch, one bad item must neither kill the run nor
  vanish: it belongs in its own counted bucket, never folded into a legitimate
  skip, while a systemic fault still aborts loudly instead of being swallowed
  once per item.

## 3. Cost at N — what happens as the numbers climb

- **Scalability** — unbounded growth, missing pagination, work that won't
  survive 100x load, per-request cost that should be amortized. State the
  arithmetic: N today, cost per item, runs per day — an operation whose
  product you cannot name is not designed. Every store is a reservoir: name
  its source and its drain. A source with no drain grows to a hard limit; a
  drain with no source empties until the feature quietly stops working on an
  unrepresentative pool. Every constant is a fossil of the moment it was
  chosen — ask what N was then and what it is now, and for every ratio, what
  fraction of the system its denominator still covers. Register the ceilings
  that are not yours: provider quotas, field lengths, concurrency caps. Some
  are walls, not slopes.
- **Blast radius and correlation** — an automated mutation designed one
  entity at a time and then scaled by a loop: what is the most entities one
  run can change? If the answer is all of them, it needs a per-run cap and a
  second corroborating signal. Duration limits are not blast-radius limits.
  Then ask what is shared across those entities — one proxy, one resolver,
  one credential, one region, one template. Each is shared fate dressed as a
  shared resource, and it converts one incident into a fleet-wide one.
- **Suboptimal queries** — N+1, full-table scans, missing indexes, `SELECT *`,
  queries inside loops, fetching far more rows than used.
- **Wasted round-trips** — several calls where one would do, responses far
  larger than the caller reads, a whole list or page refetched when one row
  changed.

## 4. Surface and structure — what a person hits, and how it holds up

- **Input and edge cases** — validation at the boundary, not only in the type
  system: duplicate and near-identical names or emails, impossible dates and
  inverted ranges, empty values, maximum values. Each one refused at entry,
  with a message that tells the user what to do next.
- **Reachable, operable UI** — dead routes, screens with no way back, actions
  that stay enabled while invalid, state changes that are silent to keyboard
  and assistive technology, signed-in users redirected somewhere they did not
  ask to go.
- **Weak architecture** — leaky layer boundaries, tight coupling, duplicated
  sources of truth, logic in the wrong layer, abstractions that lie.
