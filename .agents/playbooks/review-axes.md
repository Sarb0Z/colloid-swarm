# Static review axes

Hostile review inspects source and intent. QA executes scenarios. Skip an axis
that the artifact cannot exhibit; name every group you worked.

## 1. Contract and exposure

- **Intent and ambiguity** — the ask, plan, and artifact agree; two plausible
  readings are reported, never chosen silently.
- **Authority and abuse** — server-side authorization, privilege changes,
  unmetered or replayable actions, unsafe input, injection, secrets, and delete
  paths resist a hostile caller.
- **External contract** — public API, persistence, and UI changes preserve the
  stated contract or deliberately update every affected consumer.

## 2. State and failure

- **Data integrity** — races, check-then-act, non-atomic updates, ordering
  assumptions, and duplicate processing cannot corrupt or lose state.
- **Failure semantics** — an unavailable check is distinct from a negative;
  errors reach an owner and batch-item failures are counted rather than hidden.
- **Boundary ownership** — validation, normalization, and business rules live
  at the boundary that can enforce them; no client-only or type-only invariant.

## 3. System shape

- **Cost and ceilings** — pagination, loop work, N+1 queries, reservoirs,
  provider limits, and per-run blast radius have stated bounds or a finding.
- **Structure** — dependencies point the right way, one source owns each fact,
  duplication is justified below three callers, and abstractions match reality.
- **Operability** — changes leave a diagnosable failure path, a usable rollback
  or containment boundary where mutation is broad, and an executable QA target
  or an explicit coverage gap.
