---
date: 2026-08-13
subject: Prior art for two candidate scalability-audit laws — concurrency occupancy (Little's Law) and metastable failure; what is citable, what is folklore, and why the second law was held
kind: research
source: see `## Sources` — each line carries the URL and how deeply it was read
---

# Occupancy and metastable failure

Two failure classes were proposed for `scalability-audit`. Occupancy shipped as
Law 5. Metastable failure was held, for a reason recorded below that is worth
re-reading before anyone proposes it again.

## Scope note

**Solid.** The metastable-failure citations and definitions. Little's Law's
statement, generality and limits.

**Thin.** Anything resting on Nygard's *Release It!* or on Dean & Barroso —
neither was read directly. The knee debunking rests on one source. Claims about
what the Google SRE Book does *not* contain are scoped to the two chapters
read, not to the book.

Read depth per source lives in `## Sources`, one line each. It is not repeated
here or in the claim rows, so there is one copy to keep true.

## Occupancy — shipped

| Claim | Grade |
|---|---|
| Little's Law is `L = λW`, proved in Little, "A Proof for the Queuing Formula: L = λW", *Operations Research* 9(3):383–387, 1961; restated in the 2011 50th-anniversary paper | `[P]` |
| It holds for any arrival process, any service distribution, any queueing discipline | `[P]` |
| It yields long-run means only — nothing about variance or the tail. Its stationarity precondition breaks under bursts, deploys and ramps | `[P]` theory; `[S]` for the practitioner framing of why that matters to a pool (Slimmon) |
| The "70–80% utilization knee" is folklore. Ley tested ten competing definitions against the M/M/1 formula: most land at 0%, 50% or 100%; only two land near 70%, and both need an arbitrary quality threshold to get there | `[P]` — single-source; a rigorous internal derivation, but uncorroborated |
| Response time = service time / (1 − utilization) diverges as utilization → 1 | `[P]` |
| The bulkhead pattern — partition pools per dependency so exhaustion in one does not cascade — originates with Nygard, *Release It!*, 1st ed. 2007 | `[S]` |
| Gregg's USE method asks utilization / saturation / errors per resource, scoped to system resources rather than per-request logical occupancy | `[P]` |
| It is nonetheless the nearest existing detection-question shape to occupancy | `[A]` — our judgement, resting on the USE row above and on the negative search below |
| Gunther's Universal Scalability Law shares Little's three quantities (concurrency, throughput, response time) and fits contention and coherency coefficients from load-test data | `[P]` |
| That makes it a capacity-ceiling tool rather than a code-review question | `[A]` — our reading of the method above |
| No established practitioner term exists for "trace one request, list what it holds at once, find the smallest link". Searched: *critical resource path*, *weakest-link concurrency*, *resource holding chain*, *concurrency budget*, plus the bulkhead lead | `[?] no primary` |
| `critical resource path` is a false friend: the phrase belongs to project-management critical-path scheduling | `[A]` — noticed during that search, not separately sourced |

## Metastable failure — held, and why

The class is real and well-sourced. What it lacks is the one thing every law in
the skill must carry.

| Claim | Grade |
|---|---|
| Bronson, Aghayev, Charapko, Zhu, "Metastable Failures in Distributed Systems", HotOS '21, pp. 221–227, DOI 10.1145/3458336.3465286 | `[P]` |
| The follow-up is Huang et al., "Metastable Failures in the Wild", USENIX OSDI '22 — 22 incidents across 11 organizations | `[P]` |
| No CACM version of that follow-up exists; "CACM" is a common misrecollection of it | `[?] no primary` |
| Isaacs, Alvaro, Majumdar, Muniswamy-Reddy, Salamati, Soudjani, "Analyzing Metastable Failures", HotOS '25, DOI 10.1145/3713082.3730380 | `[P]` |
| The root cause is the **sustaining feedback loop, not the trigger** — many triggers reach the same trapped state | `[P]` verbatim, HotOS '21 |
| The **vulnerable state is not an overloaded state**. A system "can run for months or years in the vulnerable state and then get stuck in a metastable state without any increase in load"; many production systems run there deliberately because it is far more efficient | `[P]` verbatim, HotOS '21 |
| Leaving a metastable state "requires a strong corrective push, such as rebooting the system or dramatically reducing the load". Failures that self-resolve once the trigger clears are explicitly *not* metastable | `[P]` verbatim, HotOS '21 |
| Two-axis taxonomy: two trigger types (load-spike, capacity-decreasing) × two amplification mechanisms (workload amplification, capacity-degradation amplification) | `[P]` OSDI '22 |
| Sustaining mechanism — retry storms | `[P]` HotOS '21 §2.1, worked in detail; named again in OSDI '22 |
| Sustaining mechanism — look-aside cache emptiness after a flush | `[P]` HotOS '21 §2.2; reproduced experimentally in OSDI '22 §5 |
| Sustaining mechanism — connection-pool MRU policy under congestion | `[P]` HotOS '21 §2.4, "Link Imbalance" |
| Sustaining mechanism — slow error handling consuming the resource already short | `[P]` HotOS '21 §2.3 |
| Sustaining mechanism — GC and thrash spirals, framed as capacity-degradation amplification | `[P]` OSDI '22 §4, the Twitter incident |
| Load-balancer herding is **not** named as a metastability mechanism in HotOS '21 or OSDI '22 | `[?] no primary` — HotOS '25 not checked for this term |
| "Queue of timed-out work" is **not** a named category in HotOS '21 or OSDI '22. The mechanism is real — it is why HotOS '21 recommends LIFO scheduling — but the term is not theirs | `[?] no primary` — same coverage as the row above |

Remedies, all citable at mechanism level. None of their illustrative numbers
may travel into the skill.

| Remedy | Source | Grade |
|---|---|---|
| Retry budgets; criticality-based load shedding | Google SRE Book ch. 21, *Handling Overload* (Forero Cuervo), 2016 | `[P]` |
| Exponential backoff with jitter | Brooker, AWS Architecture Blog, 2015 | `[P]` |
| Circuit breakers | Nygard, *Release It!*, 2007 — cited by HotOS '21 itself | `[S]` |
| Deadline propagation; hedged requests | Dean & Barroso, "The Tail at Scale", *CACM* 56(2), 2013 | `[S]` |
| Deprioritizing retried work; LIFO scheduling under overload | HotOS '21 §3 | `[P]` |

**The blocker.** No ex-ante, source-code-answerable detection question exists.
The field says so about itself three times across four years `[P]`:

- HotOS '21: "A systematic approach for building systems that are robust
  against unknown metastable failures remains an open problem."
- OSDI '22 derives a real threshold (`Cstable`) from measured amplification
  factors — but obtains them by peak-load and stress testing, not by reading
  code.
- HotOS '25: "our gains in recognition and reproduction have not yet
  transferred to analysis and prediction." Their method needs a continuous-time
  Markov chain plus a discrete-event simulator, parameterized per config.

The distinction that decided the hold is not measurement — Laws 1, 2, 5 and 9
among them require a measured value the source cannot supply. It is that for
those laws the *structure* of the question is identifiable from source: you can
see the loop, the constant, the resource, the outbound dependency, and know
what to go measure. For metastable failure neither the structure nor the value
is identifiable from source, because the sustaining loop is an emergent
property of components that each look correct. That is what HotOS '25 is
conceding. Shipping the law would have meant authoring an unbacked heuristic
and placing it beside nine backed ones. `[A]` — the reasoning is ours; the
open-problem statements it rests on are `[P]` above.

## Sources

Each line: what it is, and how deeply it was read. This is the only place read
depth is recorded.

- https://doi.org/10.1287/opre.9.3.383 — Little (1961), the original `L = λW` proof. Canonical record, **not read**: INFORMS 403s an unauthenticated fetch. Its content is taken from the 2011 retrospective below
- https://people.cs.umass.edu/~emery/classes/cmpsci691st/readings/OS/Littles-Law-50-Years-Later.pdf — Little's 2011 retrospective. **Read** for the law's statement and assumptions (stationarity, finiteness, stability)
- https://blog.danslimmon.com/2022/06/07/using-littles-law-to-scale-applications/ — Slimmon, 2022. **Read**; worked application to worker-thread sizing, and the explicit statement that the law gives averages only
- https://www.cmg.org/2023/06/does-the-knee/ — Ley, "Does the Knee in a Queuing Curve Exist or is it just a Myth?", CMG *MeasureIT* 7.07 (orig. 2009). **Read**; the ten-definition test against M/M/1
- https://www.brendangregg.com/USEmethod/use-linux.html — Gregg, the USE method. **Read** for the triad and its scope
- https://www.perfdynamics.com/Manifesto/USLscalability.html — Gunther on the Universal Scalability Law. **Read** for the parameters and how they are obtained
- Nygard, *Release It!*, Pragmatic Bookshelf, 1st ed. 2007 — **not read**; book form. Attribution for the bulkhead and circuit-breaker patterns comes from HotOS '21's bibliography, corroborated for edition and date by https://pragprog.com/titles/mnee2/release-it-second-edition/ (2nd ed., 2018) and by https://en.wikipedia.org/wiki/Bulkhead_pattern (tertiary)
- https://sigops.org/s/conferences/hotos/2021/papers/hotos21-s11-bronson.pdf — HotOS '21. **Read in full**; definitions quoted verbatim. Source for trigger / sustaining-effect / vulnerable-state, the four case studies (§2.1–2.4), the remedies in §3, and the open-problem statement
- https://dl.acm.org/doi/10.1145/3458336.3465286 — ACM DL record. **Checked** for venue, DOI and pages only
- https://www.usenix.org/system/files/osdi22-huang-lexiang.pdf — OSDI '22. **Read** for the two-axis taxonomy, the §4 Twitter GC incident, the §5 experimental reproductions, and the §3.5 `Cstable` formalization with its load-test methodology; **grepped** for specific mechanism terms
- https://www.usenix.org/conference/osdi22/presentation/huang-lexiang — USENIX record. **Checked** for venue and authorship only
- https://sigops.org/s/conferences/hotos/2025/papers/hotos25-106.pdf — HotOS '25. **Read** for the open-problem statement and the CTMC/simulation toolchain; not swept for mechanism terminology
- https://sre.google/sre-book/handling-overload/ — Google SRE Book ch. 21. **Read**; retry budgets, adaptive throttling, criticality-based shedding
- https://sre.google/sre-book/addressing-cascading-failures/ — Google SRE Book ch. 22. **Read**; queueing and resource exhaustion as a cascade cause. The book's dedicated capacity-planning chapters were **not** opened, which bounds every claim here about what the SRE Book lacks
- https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/ — Brooker, 2015. **Read**
- https://research.google/pubs/the-tail-at-scale/ — Dean & Barroso, *CACM* 56(2), 2013. **Not read**; ACM returned HTTP 403. Venue, date and the mechanism summary come from Google's publication page
