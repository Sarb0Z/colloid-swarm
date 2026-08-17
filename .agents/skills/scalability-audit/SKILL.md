---
name: scalability-audit
description: Find where a growing system breaks before it breaks. Nine failure laws with detection questions, a nine-step audit across the whole system, and the remedy shapes that hold. Use for a scalability audit, scale review, capacity review, blast-radius review, reservoir or retention review, pool saturation or concurrency review, or when asking what breaks next as N grows.
---

# Scalability Audit

Predict where a growing system breaks, then find the breaks you have not hit
yet.

The laws in §2 explain failures a system has already had. The audit in §1 finds
the ones it has not. The audit does not require knowing the failure in advance,
which is the whole point of running it.

These laws come from mining 28 sessions and 181 findings in one production
system into 10 recurring failure classes, each re-verified against live code.
The laws generalise. The evidence does not travel, so this skill does not
reproduce another system's numbers — gather your own as you go.

## When to use this

| Situation | Read |
| --- | --- |
| Shipping a change today | §4 |
| Looking for the next incident | §1 |
| Explaining why something broke | §2 |
| Fixing one you found | §3 |

A hostile review flags the axis. This skill runs the sweep. Do not run both on
the same diff — the review covers a change, this covers a system.

## §1 The audit

A fixed procedure over the whole system. Work through every step. Each one
produces an artefact; a step with nothing to show means it was not run.

1. **Inventory every N.** List every quantity that grows: entities, rows,
   users, jobs, files. Record today's value and where it is measured.
2. **Build the 10x table.** For each operation, one row: N, cost per item,
   frequency, product today, product at 10x. Sort by the 10x column.
3. **Date every constant.** Every threshold, cap, window, batch size, cadence,
   timeout. Record the value, when it was chosen, and what N was then.
4. **Reservoir census.** Every store, with source, drain, and implied steady
   state. Flag missing drains and missing sources separately.
5. **Simultaneous-hold census.** Trace one request end to end and list every
   finite resource it holds at the same time: pools, slots, locks,
   reservations, sockets, and any external ceiling it waits on while those
   holds are open. Record the smallest link — that one, not the sum, is the
   path's real concurrency limit. Run it on the most expensive path as well as
   the common one.
6. **Blast-radius census.** Every automated mutation, with the maximum
   entities one run can change, and whether a cap and a corroborating signal
   exist.
7. **Correlation map.** Every resource shared across N, with the count of
   entities that fail with it.
8. **Boundary register.** Every external ceiling, with current usage, distance
   to the wall, and whether the wall degrades or fails.
9. **Signal trace.** Every failure mode, with the path from exception to human,
   and the time a fully broken component would run unnoticed.

### Turning findings into tripwires

A finding you cannot detect again is a finding you will re-earn. For each one,
add the cheapest thing that would have caught it: an assertion, a counter, a
query in a dashboard, a scheduled check. Prefer a tripwire that fails toward
alerting.

## Output

Report findings as a numbered list, ordered by product at 10x, not by how
interesting they are. For each: the law it violates, the location, the
arithmetic or census entry that proves it, the distance to the wall, and the
cheapest tripwire that would catch it again.

State which audit steps you ran and which you could not. A sweep that silently
skipped steps reads as coverage it does not have.

## §2 The nine laws

Full mechanism and evidence for each: `references/laws.md`.

| Law | Detection question |
| --- | --- |
| 1. Cost follows N, not intent | Can you state N, cost per item, and frequency, and multiply them? |
| 2. The system moves; the numbers do not | What was N when this constant was chosen, and what is N now? |
| 3. Two states cannot carry three outcomes | Can this verdict-returning function tell "no" from "I could not tell"? |
| 4. Every reservoir needs a source and a drain | Does this store have a named source, a named drain, and a steady state? |
| 5. Occupancy is arrival rate times holding time | What is arrival rate times mean holding time against this resource's size, and what does holding time become when the slowest dependency is slow? |
| 6. Blast radius is nobody's property | What is the maximum number of entities one run of this automation can mutate? |
| 7. Correlation is the multiplier | What is shared across N, and how many entities go down with it? |
| 8. A signal that cannot escape does not exist | Does the path from this exception to a human end anywhere but a log line? |
| 9. The binding constraint is usually someone else's | What is this dependency's documented ceiling, current usage, and distance to it? |

## §3 Remedy shapes

### Three-outcome checks

Wrap an unreliable external signal so the verdict and the failure are separate
fields.

- The helper that queries the source must not swallow everything. Catch only
  the exceptions that mean a genuine negative; let the rest propagate.
- The public function one layer up owns the catch-all, and it puts the failure
  in a field the caller reads independently of the verdict. Never overload the
  verdict field.
- A check that errored never downgrades good existing state. A write failure
  never downgrades a previously good read.
- Size the alerting to the check. A log line by default. A strike counter or a
  batch failure-ratio escalation only where cadence and blast radius warrant
  it.

### Failure visibility

- A background job must re-raise after logging, so the framework's own failure
  tracking and any paging path actually fire. Logging alone is not enough.
- A loop over many items isolates a per-item exception into its own counted
  bucket. Never drop it, and never fold it into a legitimate skip.
- A systemic fault — a broken session, a dead connection — still aborts loudly
  rather than being swallowed once per item.
- A handler that enqueues downstream work and acknowledges success must not
  treat "enqueued" and "processed" as the same fact.

WARNING: Per-item isolation is only safe when the loop body holds no external
reservation partway through, such as a budget hold or an in-flight lock.
Catching broadly across a reservation without a matching release is a silent
leak, not a fix.

### Blast-radius caps

Cap the fraction of entities one run may mutate. Require a second,
independently sourced signal before a destructive action. Prefer a cap that
refuses and pages over one that truncates silently.

### Reservoirs

Give every source a drain and every drain a source. Retention needs an owner
and a schedule. A depleting reservoir needs an alarm on its level, not on its
consumption.

### Occupancy

Holding time carries more slack than arrival rate, so cap it deliberately
instead of inheriting it. A timeout is the limit on how long one occupant may
hold a slot, which makes an unset or generous timeout a capacity decision taken
by default. Release a reservation before slow work that does not need to hold
it. Where one path must not starve another, give them separate pools rather
than one pool sized for the sum — the bulkhead shape, which trades some
efficiency for the guarantee that exhaustion stays local.

## §4 Preflight

Before shipping a change, answer these. An unanswerable question is the
finding.

- What is N for anything this touches, and what is the product of N, cost, and
  frequency?
- Does any new check return a verdict that can hide its own failure?
- Does any new constant have a recorded basis?
- Does anything new accumulate or deplete?
- Does anything new hold a finite resource, and for how long when the slowest
  thing it depends on is slow?
- Can one run of anything new mutate an unbounded number of entities?
- Does any new failure mode reach a human?
- Does this move usage closer to an external ceiling?
