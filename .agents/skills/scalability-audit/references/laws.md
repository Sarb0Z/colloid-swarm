# The nine scalability laws

The full mechanism behind each law in `SKILL.md`'s compact table: why the
failure happens, not just how to detect it.

## Contents

- [Law 1 — Cost follows N, not intent](#law-1--cost-follows-n-not-intent)
- [Law 2 — The system moves; the numbers do not](#law-2--the-system-moves-the-numbers-do-not)
- [Law 3 — Two states cannot carry three outcomes](#law-3--two-states-cannot-carry-three-outcomes)
- [Law 4 — Every reservoir needs a source and a drain](#law-4--every-reservoir-needs-a-source-and-a-drain)
- [Law 5 — Occupancy is arrival rate times holding time](#law-5--occupancy-is-arrival-rate-times-holding-time)
- [Law 6 — Blast radius is nobody's property](#law-6--blast-radius-is-nobodys-property)
- [Law 7 — Correlation is the multiplier](#law-7--correlation-is-the-multiplier)
- [Law 8 — A signal that cannot escape does not exist](#law-8--a-signal-that-cannot-escape-does-not-exist)
- [Law 9 — The binding constraint is usually someone else's](#law-9--the-binding-constraint-is-usually-someone-elses)

### Law 1 — Cost follows N, not intent

Code is written for the case in front of you, and it is correct. It is then
reused for the fleet by wrapping it in a loop, which is also correct. Neither
step prices the result. The loop inherits the body's cost and multiplies it by
whatever N happens to be that day.

Cadence obeys the same law. True cost is cost per run times runs per day. A
five-minute beat is 288 runs a day. Both numbers get chosen from intuition, not
arithmetic.

**Detection.** For any operation, state N today, cost per item, and frequency.
Multiply. If you cannot state the product, you have not designed it. Split cost
per item into the part paid once per connection or session and the part paid
per item. Work priced as though setup were free is priced wrong the moment
every item pays for it again.

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

### Law 5 — Occupancy is arrival rate times holding time

A finite resource is not spent by how often you use it. It is spent by how long
each use lasts. Arrival rate and holding time set occupancy between them, so a
resource sized against arrival rate alone saturates the first time holding time
moves — a slower dependency, a longer timeout, a retry that waits before it
gives up.

Law 4 asks whether a reservoir fills or empties. This one asks how many
occupants sit in it at once while the level stays flat. A pool pinned at its
limit with a healthy source, a healthy drain and a steady level is not idle
capacity; it is a queue nobody measured. Holding time is also the term that
moves under stress, and it is the term nobody sizes against.

The arithmetic is Little's Law, and it is unusually general: it holds for any
arrival pattern, any service-time distribution, any queueing discipline. It
gives long-run averages only. It says nothing about variance or the tail, and
its assumption of a steady state is exactly what a burst, a deploy or a ramp
breaks. A resource that passes on the mean can still exhaust on the peak.

**Detection.** For every finite resource, state arrival rate and mean holding
time. Multiply. Compare the product against the resource's size. Then ask what
holding time becomes when the slowest dependency on that path is slow, because
that is the number that moves. A resource whose holding time nobody can state
is sized by accident. Do not adopt a fixed utilization threshold as the pass
line: the knee in the queueing curve is not a portable number, and a system
that has one does not have it where folklore puts it.

### Law 6 — Blast radius is nobody's property

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

### Law 7 — Correlation is the multiplier

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

### Law 8 — A signal that cannot escape does not exist

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

### Law 9 — The binding constraint is usually someone else's

Past a certain size the limit that stops you is not in your code. It is a
provider's rate cap, a protocol's field length, a quota, a concurrency ceiling,
a licence. These are invisible in development because a single-item test never
approaches them, and they get discovered by crossing them in production.

They do not scale with spending or cleverness, and several are hard walls
rather than slopes. You do not degrade; you fail.

**Detection.** Register every external dependency with its documented ceiling,
current usage, and what happens at 100 percent. Convert each into distance: how
many units of growth until you arrive?
