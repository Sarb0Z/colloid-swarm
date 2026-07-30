---
name: scalability-audit
description: Find where a growing system breaks before it breaks. Eight failure laws with detection questions, an eight-step audit across the whole system, and the remedy shapes that hold. Use for a scalability audit, scale review, capacity review, blast-radius review, reservoir or retention review, or when asking what breaks next as N grows.
---

# Scalability Audit

Predict where a growing system breaks, then find the breaks you have not hit
yet.

The laws below explain failures a system has already had. The audit in §2 finds
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
| Looking for the next incident | §2 |
| Explaining why something broke | §1 |
| Fixing one you found | §3 |

A hostile review flags the axis. This skill runs the sweep. Do not run both on
the same diff — the review covers a change, this covers a system.

## §1 The eight laws

### Law 1 — Cost follows N, not intent

Code is written for the case in front of you, and it is correct. It is then
reused for the fleet by wrapping it in a loop, which is also correct. Neither
step prices the result. The loop inherits the body's cost and multiplies it by
whatever N happens to be that day.

Cadence obeys the same law. True cost is cost per run times runs per day. A
five-minute beat is 288 runs a day. Both numbers get chosen from intuition, not
arithmetic.

**Detection.** For any operation, state N today, cost per item, and frequency.
Multiply. If you cannot state the product, you have not designed it.

### Law 2 — The system moves; the numbers do not

Every constant is a fossil of the moment someone chose it. Thresholds, caps,
retention windows, batch sizes, cadences, timeouts — each was calibrated
against a snapshot, and each stays fixed while the snapshot rots.

The subtler half is denominator drift. A control that reads a slice of traffic
was calibrated against that slice's share of the whole. The share moves without
telling the control, which then goes quietly blind instead of failing loudly.

**Detection.** For every constant that gates behaviour, ask what N was when it
was chosen and what N is now. For every ratio, ask what fraction of the system
its denominator covers today.

### Law 3 — Two states cannot carry three outcomes

Any check against something that can fail has three outcomes, not two: genuine
yes, genuine no, and the check did not complete. A boolean or an empty list
holds two. The third collapses into the falsy one, which is almost always the
reassuring one — clean, not listed, no record, absent.

The system then acts on a verdict nobody rendered. This is the most expensive
class, because the failure is silent and the action taken is often destructive.

**Detection.** For every function returning a verdict, ask whether it can tell
"no" from "I could not tell". Follow the `except` clauses. A bare
`except Exception: return False` is the signature.

### Law 4 — Every reservoir needs a source and a drain

Anything that accumulates or depletes is a reservoir: table rows, log files,
open alerts, queue depth, held locks, budget reservations, connection slots, a
pool of recipients.

A source with no drain grows until it hits a physical limit. A drain with no
source empties until the feature depending on it quietly stops working. Both
are the same oversight: the feature is the flow one way, and the other way is
nobody's job. The depleting case is worse, because a shrinking reservoir
usually has no alarm — the system keeps running on an unrepresentative pool and
reports success while doing it.

**Detection.** List every store. For each, name the source, the drain, and the
steady state they imply. A missing answer is a scheduled incident.

### Law 5 — Blast radius is nobody's property

Automated remediation gets designed one entity at a time, and that logic is
correct. It is then scaled by iteration. No line in that path asks what
fraction of the fleet one run is about to mutate, because the question belongs
to no single entity.

Combine with Law 3 and you get the defining incident shape: a shared signal
fails, every entity independently evaluates to bad, and the loop faithfully
applies a destructive action to all of them.

**Detection.** For every automated mutation, ask the maximum number of entities
one run can change. If the answer is all of them, it needs a per-run cap and a
second corroborating signal. Duration limits are not blast-radius limits.

### Law 6 — Correlation is the multiplier

Independent failures average out. Correlated failures sum. Any dimension held
constant across the fleet turns one incident into a fleet-wide one — and the
dimensions that matter are the ones your dependency or your adversary clusters
on, not the ones you think of as your architecture.

One proxy in front of every outbound call, one resolver, one credential, one
region, one template. Each is shared fate wearing the costume of a shared
resource.

**Detection.** Draw what is shared across N. For each shared thing, ask how
many entities go down with it. Provisioning that optimises for unit cost —
cheapest supplier, same template, least-loaded host — manufactures correlation
as a side effect, because uncorrelated identity is nobody's owned metric.

### Law 7 — A signal that cannot escape does not exist

A failure logged but not raised, counted but not paged, or returned in a
payload nobody inspects is indistinguishable from success. Error handling gets
written to keep the worker alive rather than to inform an operator, and the
cheapest shape that achieves that passes review, because no test and no
dashboard asserts a failure count.

The corollary governs batches. One bad item must not destroy the batch, and it
must also not vanish.

**Detection.** For each failure mode, trace the path from exception to human.
If the trace ends at a log line, a return value, or a 200 response, the failure
is invisible. Ask how long a fully broken component would run before anyone
noticed.

### Law 8 — The binding constraint is usually someone else's

Past a certain size the limit that stops you is not in your code. It is a
provider's rate cap, a protocol's field length, a quota, a concurrency ceiling,
a licence. These are invisible in development because a single-item test never
approaches them, and they get discovered by crossing them in production.

They do not scale with spending or cleverness, and several are hard walls
rather than slopes. You do not degrade; you fail.

**Detection.** Register every external dependency with its documented ceiling,
current usage, and what happens at 100 percent. Convert each into distance: how
many units of growth until you arrive?

## §2 The audit

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
5. **Blast-radius census.** Every automated mutation, with the maximum
   entities one run can change, and whether a cap and a corroborating signal
   exist.
6. **Correlation map.** Every resource shared across N, with the count of
   entities that fail with it.
7. **Boundary register.** Every external ceiling, with current usage, distance
   to the wall, and whether the wall degrades or fails.
8. **Signal trace.** Every failure mode, with the path from exception to human,
   and the time a fully broken component would run unnoticed.

### Turning findings into tripwires

A finding you cannot detect again is a finding you will re-earn. For each one,
add the cheapest thing that would have caught it: an assertion, a counter, a
query in a dashboard, a scheduled check. Prefer a tripwire that fails toward
alerting.

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

## §4 Preflight

Before shipping a change, answer these. An unanswerable question is the
finding.

- What is N for anything this touches, and what is the product of N, cost, and
  frequency?
- Does any new check return a verdict that can hide its own failure?
- Does any new constant have a recorded basis?
- Does anything new accumulate or deplete?
- Can one run of anything new mutate an unbounded number of entities?
- Does any new failure mode reach a human?
- Does this move usage closer to an external ceiling?

## Output

Report findings as a numbered list, ordered by product at 10x, not by how
interesting they are. For each: the law it violates, the location, the
arithmetic or census entry that proves it, the distance to the wall, and the
cheapest tripwire that would catch it again.

State which audit steps you ran and which you could not. A sweep that silently
skipped steps reads as coverage it does not have.
