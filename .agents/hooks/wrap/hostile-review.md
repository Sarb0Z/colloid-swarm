# Hostile review

Dispatch a subagent to review the diff against the surrounding architecture.

The dispatch must carry a genome stamp or `genome-guard` will block it. Draw one
and prepend its output to the subagent's prompt:

```sh
.agents/genome.sh --register none
```

## The question that comes first

Does the code actually do what it is supposed to do? Trace the change against
its intent and the inputs and edge cases it must handle, and prove it correct —
or pinpoint exactly where it does the wrong thing. A clean-looking diff that
doesn't do its job is the worst defect.

## Then hunt these

Each reported with `file:line`, why it bites, and the fix.

- **Dangerous patterns** — data loss, unsafe deletes, auth/permission gaps,
  unvalidated input, injection, secrets in code, swallowed errors.
- **Scalability** — unbounded growth, missing pagination, work that won't
  survive 100x load, per-request cost that should be amortized.
- **Race conditions** — unguarded shared state, check-then-act, missing
  locks/transactions, non-atomic read-modify-write, ordering assumptions.
- **Suboptimal queries** — N+1, full-table scans, missing indexes, `SELECT *`,
  queries inside loops, fetching far more rows than used.
- **Hard-to-debug code** — silent failures, no logging at failure points, magic
  control flow, deep nesting, side effects behind innocent names.
- **Weak architecture** — leaky layer boundaries, tight coupling, duplicated
  sources of truth, logic in the wrong layer, abstractions that lie. For
  structural depth on this axis — abstraction quality, dramatic simplification,
  spaghetti growth, file-size smells — hand off to the
  thermo-nuclear-code-quality-review skill instead of duplicating it here.

Fold valid objections; escalate genuine disagreements to the user.
