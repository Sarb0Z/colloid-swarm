# Finding gaps competitors have not filled

## Contents
- Where to look — the seven corpora, and what each is good for
- Filtering the corpus — the biases that manufacture fake gaps
- Why it is unfixed — the eight causes, and which are openings
- Reading architecture from what they cannot fix — inferring their constraints, and testing the inference
- The cross-competitor test — universal complaint versus isolated one
- Before calling a gap open — the four confirmations
- Output — the table, and the grading rule

Recurring complaint → **why it is unfixed** → whether we can fill it.

The middle step is the whole technique. Reading reviews gets you a list of complaints; anyone can do that, including the competitor. The question that pays is why an obvious, repeatedly-voiced problem has survived contact with a team that reads its own reviews.

**Start from the base rate: an unfilled gap is more often a moat than an opportunity.** If a complaint is loud, old, and universal, the prior is that someone competent tried and hit something. Find out what, before planning around it.

## Where to look

| Source | Good for |
|---|---|
| App Store / Play reviews, sorted **most recent** | Volume, frequency, version-specific breakage |
| Reddit (product subs, category subs) | Higher-quality articulation than store reviews; unfiltered comparisons |
| Their own community forum / Discord / support site | Staff replies stating *why* something is not built |
| Changelog + public roadmap | Whether it is already fixed or perpetually "planned" |
| Their support docs | A doc describing a workaround is an acknowledged, unfixed gap |
| G2 / Capterra / Trustpilot | B2B; longer reviews, explicit switching reasons |
| YouTube review comments, X replies | Complaints from people who never open a store listing |

## Filtering the corpus

Review data is biased in specific, correctable ways. Correct for them or the "gap" is an artifact.

- **Sort by recent, not helpful.** The most-upvoted 1-star is often years and several releases old.
- **Mine 3-star reviews hardest.** Users who like the product and articulate one precise limitation. One-star is disproportionately "crashed, want refund" and billing rage — real, but rarely a product gap.
- **Expect review gating.** Many apps prompt satisfied users to review, inflating the average and concentrating the negatives into a narrow, angry band. Do not read the star distribution as a satisfaction survey.
- **Volume, not anecdote.** *"Appears in roughly 40% of the last 200 one- and two-star reviews"* is a finding. *"Two people mentioned this"* is not. Count.
- **Watch for astroturf.** Bursts of similar phrasing or timing, especially around a competitor's launch.
- **Separate breakage from design.** "Sync broke in 4.2" is a bug that will be fixed next release. "Sync has never worked across platforms" is a gap.

## Why it is unfixed

Assign a cause and find evidence for it. Grade the cause `[P]`/`[S]`/`[?]` like any other claim — this is where invented explanations creep in most easily, because a plausible story is always available.

| Cause | Signal | Opportunity for us? |
|---|---|---|
| **Already fixed** | Changelog entry; recent reviews stop mentioning it | No — stale corpus. Check this first. |
| **Deliberate tradeoff** | Staff or founders explain the reasoning publicly | Only if we weight that tradeoff differently, and can say why |
| **Business-model conflict** | The complaint *is* the paywall, or the ads, or the upsell | Yes, if our model differs. One of the strongest classes. |
| **Architectural cost** | Long-standing, acknowledged, "on the roadmap" for years | Maybe — greenfield is a real advantage here |
| **Platform constraint** | OS, store policy, or a partner API forbids it | No. Verify rather than assume; policies change. |
| **Wrong segment complaining** | The complainers are not who they sell to | No — unless they are exactly who *we* sell to |
| **Genuinely hard** | No product in the category has solved it | Usually a trap. Requires strong evidence to believe otherwise. |
| **Not noticed / deprioritised** | Small team, no public acknowledgement anywhere | Yes — and rarer than it looks |

## Reading architecture from what they cannot fix

The complaints a team has *not* fixed are a shadow of its architecture. A competent team reading its own reviews fixes what it can reach cheaply; what survives for years crosses a boundary that is expensive to move. Those boundaries are inferable, and they pay twice — they map where the competitor is rigid, and they flag which decisions we cannot defer either.

Apply this only to the **architectural cost** and **genuinely hard** rows above. Inferring a data model from what is actually a pricing decision builds the wrong thing.

### The move

Ask: **what would have to be true about their system for this to still be broken?**

Then generate several answers, not one. A persistent complaint usually has three or four plausible structural causes, and the interesting work is separating them with evidence — not picking the first that fits. If only one explanation comes to mind, that is a sign of not having thought about it long enough. When the obvious explanation is suspect and the fan-out is worth its cost, vary the framing per researcher and run them blind, so the selection lands on evidence rather than on whichever story was drafted first.
<!-- colloid-only -->

The `panspermia-mutation` skill is built for exactly this fan-out.
<!-- /colloid-only -->

### Starting hypotheses — not a lookup table

The pairings below are **priming, not answers**. Each is one common cause among several for its complaint, drawn mostly from mobile and SaaS CRUD products; in another domain, or another architecture, the same symptom means something else entirely.

Rules for using this table:

- A row generates a **candidate**, never a finding. It ships only with independent evidence from the checks below.
- Generate rival explanations before testing. The table gives one; the complaint usually admits more.
- **If evidence contradicts the table, the table is wrong.** It is a memory aid, not a source.
- If nothing here fits, reason from the question above and ignore it. A forced fit is worse than no hypothesis.

| Persistent complaint | One possible constraint | Why that would survive |
|---|---|---|
| Loses data with no signal; unusable offline | Server-authoritative writes, no local write path or outbox | Retrofitting offline-first touches every write and needs conflict resolution — one of the hardest mobile migrations there is |
| Changes on one device do not reach another | Last-write-wins, or single-device state reconciled after the fact | Multi-device was bolted onto a single-device model; fixing it means a real sync protocol |
| Cannot edit or delete a past entry | Append-only records, or cached aggregates with no recompute path | The derived totals would all have to be rebuilt |
| Crawls after a year of use | Full-collection loads, client-side filtering, no pagination | Data layer designed at small N; fixing it is a rewrite of every list surface |
| Search does not find things | Substring match on the client, no index | Real search is new infrastructure, not a code change |
| Feature exists on iOS but not Android (or web) | Separate codebases, no shared core | Parity costs double forever; they will always be slow here |
| Timezone and date-boundary bugs | Local dates stored without zone, or UTC without user context | Existing rows are ambiguous, so the fix needs a backfill that cannot be fully correct |
| No undo, no history | Mutable-in-place state, no event log | Undo means adding an event-sourced layer under a live system |
| Billing breaks when switching platform | Entitlement tied to store receipts, no server-side model | Requires moving the source of truth off the store |
| Cannot export data | Denormalised or vendor-entangled storage — **or deliberate lock-in** | Check the taxonomy before assuming architecture |

### Fix velocity maps the seams

What they ship fast versus what lingers is as informative as the complaints themselves. Fast fixes sit near the surface — copy, UI, small features. Anything that lingers crosses a boundary. Track which *categories* move quickly and which never do, and the rigid edges of their system draw themselves.

### Testing the hypothesis

Architecture inference is speculation until it is evidenced. Cheap checks:

- **API responses**, where inspectable — the data model is right there
- **Job postings** — stack, and sometimes an explicit migration ("help us move off X")
- **Engineering blog posts and conference talks** — occasionally they just tell you
- **Status page incident history** — what breaks together is coupled
- **Support docs stating limits** ("maximum 500 items") — implementation constraints surfaced as policy
- **Changelog velocity per area** — see above

Grade the conclusion. An architectural story with no evidence is `[?]`, however well it explains the symptom — a good explanation that nothing checked is the most dangerous output of this method, because it is confident, specific, and actionable.

Report the rival explanations that survived alongside the favoured one. "Most likely X, though Y is not excluded" is a more useful finding than a false single answer, and it tells the reader what evidence would settle it.

### The payoff

**Their unfixable list is our decide-before-we-ship list.** The properties they could not retrofit — offline writes, a sync protocol, an event log, a zone-aware date model — are properties we will not be able to retrofit either. Competitor pain is therefore not just a feature opportunity; it is a priority ordering for the decisions that have to be made while the schema is still soft.

## The cross-competitor test

Check whether the complaint appears against every competitor or just one.

- **Universal** → a category-level constraint. Default to *genuinely hard* or *platform constraint* until something proves otherwise. This is the trap case, and it is the one that feels most like an opportunity because the gap looks enormous.
- **Isolated to one product** → their specific failure, and the best class of opportunity. Ask what the others do differently; the answer is usually the design you want.

## Before calling a gap open

Confirm all four:

1. Changelog and release notes do not fix it.
2. Public roadmap does not have it shipping imminently.
3. The most recent reviews still raise it.
4. No support doc quietly documents a workaround.

## Output

| Gap | Evidence | Affects | Why unfixed | Opportunity | Cost to fill |
|---|---|---|---|---|---|
| One line | Frequency + source | Which competitors | Cause + grade | Real / trap / conditional | Rough |

Every "why unfixed" carries evidence or is marked `[?]` as a hypothesis. An ungraded causal story is the most dangerous object this method can produce: it is confident, it is actionable, and nothing checked it.
