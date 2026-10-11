---
name: scalability-audit
description: Find where a growing system breaks before it breaks. Nine failure laws with detection questions, a nine-step audit across the whole system, and the remedy shapes that hold. Use for a scalability audit, scale review, capacity review, blast-radius review, reservoir or retention review, pool saturation or concurrency review, or when asking what breaks next as N grows.
---

# Scalability audit

Predict where a growing system breaks, then find the breaks it has not yet hit.

The laws in §2 explain the failures a system has already had; the audit in §1
finds the ones it has not. The audit needs no foreknowledge of the failure,
which is the whole reason to run it.

These laws come from mining 28 sessions and 181 findings in one production
system into 10 recurring failure classes, each re-verified against live code.
The laws generalise; the evidence does not travel, so this skill reproduces no
other system's numbers, and the auditor gathers this system's own along the way.

## When to use this

| Situation | Read |
| --- | --- |
| Shipping a change today | §4 |
| Looking for the next incident | §1 |
| Explaining why something broke | §2 |
| Fixing one you found | §3 |

A hostile review flags the axis; this skill runs the sweep. The two never run on
the same diff: the review covers a change, this covers a system.

## §1 The audit

A fixed procedure over the whole system, every step worked. Each step produces
an artefact, and a step with nothing to show was not run.

1. **Inventory every N.** List every quantity that grows — entities, rows,
   users, jobs, files — with today's value and where it is measured.
2. **Build the 10x table.** One row per operation: N, cost per item,
   frequency, product today, product at 10x. Sort by the 10x column.
3. **Date every constant.** Every threshold, cap, window, batch size, cadence,
   and timeout, with its value, when it was chosen, and what N was then.
4. **Reservoir census.** Every store, with its source, its drain, and its
   implied steady state. Mark a missing drain and a missing source separately.
5. **Simultaneous-hold census.** Trace one request end to end and list every
   finite resource it holds at once: pools, slots, locks, reservations,
   sockets, and any external ceiling it waits on while those holds are open.
   Record the smallest link — that one, not the sum, is the path's real
   concurrency limit. Run the census on the most expensive path as well as the
   common one.
6. **Blast-radius census.** Every automated mutation of state, with the maximum
   number of entities one run can change, and whether a cap and a corroborating
   signal exist.
7. **Correlation map.** Every resource shared across N, with the count of
   entities that fail with it.
8. **Boundary register.** Every external ceiling, with current usage, distance
   to the wall, and whether the wall degrades or fails.
9. **Signal trace.** Every failure mode, with the path from exception to human,
   and how long a fully broken component would run unnoticed.

### Turning findings into tripwires

A finding that cannot be detected again is a finding re-earned. For each one,
add the cheapest detector that would have caught it — an assertion, a counter,
a dashboard query, a scheduled check — and prefer a tripwire that fails toward
alerting.

## Output

Findings are a numbered list, ordered by product at 10x, not by how interesting
they are. Each carries the law it violates, the location, the arithmetic or
census entry that proves it, the distance to the wall, and the cheapest tripwire
that would catch it again.

State which audit steps ran and which could not. A sweep that skipped steps in
silence reads as coverage it does not have.

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

Wrap an unreliable external signal so that the verdict and the failure are
separate fields.

- The helper that queries the source swallows nothing wholesale: it catches only
  the exceptions that mean a genuine negative and lets the rest propagate.
- The public function one layer up owns the catch-all and puts the failure in a
  field the caller reads independently of the verdict. The verdict field is
  never overloaded.
- A check that errored never downgrades good existing state, and a write failure
  never downgrades a previously good read.
- Alerting is sized to the check: a log line by default, a strike counter or a
  batch failure-ratio escalation only where cadence and blast radius warrant it.

### Failure visibility

- A background job re-raises after logging, so the framework's own failure
  tracking and any paging path fire; logging alone is not enough.
- A loop over many items isolates a per-item exception into its own counted
  bucket — never dropped, never folded into a legitimate skip.
- A systemic fault — a broken session, a dead connection — still aborts loudly
  rather than being swallowed once per item.
- A handler that enqueues downstream work and acknowledges success never treats
  "enqueued" and "processed" as the same fact.

Per-item isolation is safe only when the loop body holds no external
reservation partway through, such as a budget hold or an in-flight lock: a broad
catch across a reservation without a matching release is a silent leak, not a
fix.

### Blast-radius caps

Cap the fraction of entities one run may mutate, and require a second,
independently sourced signal before a destructive action. A cap that refuses and
pages is preferred to one that truncates in silence.

### Reservoirs

Every source gets a drain and every drain a source. Retention needs an owner and
a schedule. A depleting reservoir needs an alarm on its level, not on its
consumption.

### Occupancy

Holding time carries more slack than arrival rate, so cap it deliberately rather
than inheriting it. A timeout bounds how long one occupant may hold a slot,
which makes an unset or generous timeout a capacity decision taken by default.
Release a reservation before slow work that does not need to hold it. Where one
path must not starve another, give each its own pool rather than one pool sized
for the sum — the bulkhead shape, which trades some efficiency for the guarantee
that exhaustion stays local.

## §4 Preflight

Before shipping a change, answer these; a question that cannot be answered is
the finding.

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
