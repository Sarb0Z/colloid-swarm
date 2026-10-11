---
name: market-researcher
description: Market and competitor research whose output someone will build on — feature teardowns, pricing, market sizing, prior art, and whether a mechanic works in practice. Looks past the segment to whoever implements a mechanic best in any industry, and sweeps peer-reviewed literature, not only competitor pages. Mines recurring complaints for unfilled gaps, works out why each stays unfixed, and infers a competitor's architecture from what it cannot repair. Grades every claim by source quality and marks each widely repeated number that has no primary source. Use when scoping a feature or product: what competitors ship and where they fall short, how other products solve a problem, market size and growth, what users request or churn over, how the space is priced, where the unmet gaps are, or what prior art says before an architecture decision. Trigger phrases: market research, competitor analysis, competitive landscape, market size, TAM, pricing analysis, market gap, blue ocean, is there demand for this, prior art.
---

# Market researcher

Research whose output someone will build on. Its characteristic failure is not an empty result but a fluent, complete-looking report whose numbers came from one content farm quoting another.

**Provenance is part of the claim.** An ungraded number is not a weaker finding but a different kind of object, and the report must name which kind it holds.

This is the long-form sweep. A single external fact in the middle of an ordinary turn belongs to `search-and-cite`, which draws the line between a quick inline lookup and a delegated cell; this skill begins on the far side of that line. Throughout, "the project" is the team commissioning the research.

<!-- colloid-only -->
**Every delegated researcher receives exactly one genome.** Claude Code and Codex inject it through `SubagentStart`; Kimi's start event is observation-only, so prepend one generated stamp to the Kimi dispatch prompt. Never combine both.
<!-- /colloid-only -->

## Workflow

Copy this checklist and track progress:

```
Research progress:
- [ ] 1. State our constraints and classify each one
- [ ] 2. List targets — in-segment competitors + best-in-class analogues
- [ ] 3. Tier 1 sweep: what they say (mechanics, numbers)
- [ ] 4. Tier 2 sweep: what they measured (effect sizes)
- [ ] 5. Tier 3 sweep: what the literature says (mechanism, failure modes)
- [ ] 6. Tier 4 sweep: what users say (gaps, drivers, switching triggers)
- [ ] 7. Market structure: size and its basis, pricing bands, underserved segments
- [ ] 8. Chase every [S] claim to its primary source
- [ ] 9. Write up: graded claims, named gaps, folklore flagged
- [ ] 10. Close with what transfers, what does not, and which constraints moved
- [ ] 11. File the report in `.agents/knowledge/research/`
```

**Read `.agents/knowledge/index.md` first.** Earlier sweeps are filed there, one dated line each. Open every entry whose subject overlaps this brief: it supplies a starting target list and the gaps the last pass could not close, and it spares the sweep the full price of rediscovering what the store already holds.

Treat a filed entry as evidence with an expiry, never as a settled fact. Prices, tiers, and thresholds move, so re-verify anything load-bearing that is more than a few months old, and file the new reading rather than editing the old one. An entry the market has moved past is itself a finding: name the drift in the write-up.

### 1. State the project's constraints

Before looking at anything, write down what binds the project: team size, the infrastructure it has and lacks, what the data model already commits to, what is gated or paid, its policy positions, and what it has deliberately chosen not to build.

**Constraints are a research input, not a filter applied to the results.** They change the question — *"how does this mechanic work"* and *"how does this mechanic work without push notifications"* return different sources, and only the second is usable. They change what "best" means too: the best implementation for a team with a data science function is not the best one for this project. Ask who solved the problem **under constraints like the project's**; the scrappier answer usually fits better than the market leader's.

Then classify each, because most stated constraints are not the binding kind:

| Kind | Test | What to do |
|---|---|---|
| **Hard** | Physics, platform policy, money that does not exist | Design around it |
| **Assumed** | "We can't do X" — has anyone checked? | Verify before designing around it |
| **Expiring** | True now, dissolving on a known timeline | Design for after, ship for now |
| **Self-imposed** | A choice the project made and could unmake | Revisitable — but price the reversal |
| **Capacity** | The team does not know how, or has no time | A scope or learning question, not an architecture one |

Research is what settles each one's kind. A constraint that survives a deliberate search for counterexamples is real; one that dissolves on contact was quietly costing the project options. Search for both: someone shipping this under the project's constraint, and someone for whom the constraint has already expired.

**The symmetry that matters:** a constraint that binds the project and not a competitor explains why the competitor's solution will not transfer; a constraint that binds the competitor and not the project is an opening (see [finding-gaps.md](finding-gaps.md)). Most of the strategy lives in that difference, so state both sides explicitly, not the project's alone.

### 2. List targets

Two axes, answering different questions; working only one of them is the commonest way this research goes wrong.

**In-segment competitors** — what the market expects, pricing, table stakes, and where the gaps are. For *facts about the category*, one verified datapoint from a product in the exact category outweighs a pile of material from a household name in a different one. Include the **indirect** competitors: the spreadsheet, the agency, and the adjacent tool people use instead never appear on a comparison page, yet they hold the honest answer to "what do they do today". Record each target's position — leader, challenger, or niche — because position changes how its choices read: a leader's pricing defends a base; a challenger's buys share.

**Best-in-class by mechanic, any domain** — how to design the mechanic well. Competitors copy each other, so a segment converges on a local optimum. Decompose the feature to its abstract mechanic and find whoever does that best regardless of industry: reverse bidding is solved by freelance marketplaces and by freight brokers and construction tendering, and the unlike pair teaches more than either alone. See [finding-analogues.md](finding-analogues.md).

A search confined to the segment produces a product that matches its competitors and beats nobody; a search confined to other domains produces a mechanic that is elegant and ignores what the market already demands.

### 3–6. Sweep four tiers

| Tier | Source | Yields |
|---|---|---|
| 1. What they say | Docs, help centre, official blog, pricing page | Exact thresholds, tiers, caps, prices |
| 2. What they measured | Published experiments, engineering posts, earnings calls | Effect sizes, adoption numbers |
| 3. What the literature says | Peer-reviewed work on the underlying mechanism | Failure modes nobody in the space advertises |
| 4. What users say | Store reviews, Reddit, support forums, changelogs | Unfilled gaps and the constraints behind them; why users stay, and why they switch |

Budget for tiers 3 and 4. Tier 3 holds the finding that contradicts what every competitor page implies. Tier 4 holds the openings, and there a recurring complaint that survives for years reveals an architectural boundary the competitor cannot move.

**Tier 4 has its own method: see [finding-gaps.md](finding-gaps.md).** Recurring complaint, then why it is unfixed, then whether the project can fill it. The middle step is the one that pays; skipping it turns a moat into a roadmap.

#### Tier 3 questions that pay

Every competitor shipping a mechanic is evidence that it is popular, not that it works. Put four questions to the literature:

- **Does it work for everyone, or does the average hide a harmed subgroup?** Aggregate effects routinely conceal opposite-signed subgroup effects, and the people a feature helps most are often not the people it is aimed at. Always look for results broken out by baseline engagement, experience, or intensity; this is the single highest-yield question in the tier.
- **How large is the effect?** "Statistically significant" and "worth building" are different claims. Get the number and judge it.
- **Does it decay?** Many engagement effects fade within weeks of onboarding; a result measured at two weeks and one measured at six months are different findings.
- **What is the documented failure mode?** Anything widely shipped has one, and the vendors are not the ones who publish it.

These turn "competitors all have X" into a decision about whether the project should.

#### Why they stay, and why they leave

The other half of tier 4. Complaints say what is broken, not what is load-bearing; both halves come from the same corpus, and most sweeps collect only the negative one.

- **Satisfaction drivers** — what users praise unprompted, and what they say they would not give up. This is the category's real table stakes, rarely the same list as its marketed features, and everything on it the project must match or consciously decide to lose.
- **Switching triggers** — what made someone move, in their own words. The strongest signal in competitive research, because it is revealed preference rather than a stated wish. Search for migration posts, "moved from X to Y", and the comparison threads users write for each other.
- **Churn reasons** — why users left and arrived *nowhere*. Unlike switching, churn usually means the category failed them rather than the product, and it bounds how much of the market is addressable at all.

A requested feature and a switching trigger are different objects. Feature requests are cheap to voice and routinely go unused once shipped; a switching trigger has already cost someone the effort of migrating. Where the two disagree, weight the trigger and say so.

### 7. Market structure

Size, price, and segments. All three ride the same tiers and the same grading, and in all three an unsourced number does its greatest damage.

#### Sizing the market

Market size, growth rate, and segment breakdown ride the same tiers but are the **most folklore-prone class of claim in this skill**: a single paid industry report is summarised by a dozen blogs, and the summaries cite each other until the number looks like consensus. Treat every headline TAM as `[?]` until the primary is open.

| Want | Go to | Grade reality |
|---|---|---|
| Market size, CAGR | The report's own methodology page or press release; regulator and statistics-office data | The blog quoting a paywalled report is `[S]` at best, and often `[?]` |
| Segment breakdown | Public filings and earnings decks of listed players | `[P]`, and usually the only honest segment numbers available |
| Growth direction | Funding rounds, job-posting volume, new entrants | Directional evidence, never a size figure |

State the **basis and the geography** of every size number. The basis is top-down from an analyst's total or bottom-up from price × observable users; the two disagree routinely, and a report that does not say which it used cannot be verified. Geography matters because "$4.2B market" is a different claim for global, US, and EMEA, and the folklore chain this section exists to break routinely launders one into another. A figure with neither is unverifiable twice over. A paywalled primary is itself a finding: *"figure traces to a paid report; methodology not public"* is worth more than repeating the number.

#### Reading the pricing structure

Tier 1 collects the numbers off the pricing page; the structure behind them is the finding.

- **The list price is not the paid price.** Annual discounts, promotional rates, and negotiated enterprise deals all sit below the published figure, and in B2B the published figure may be fiction. Treat a pricing page as `[P]` for *what they advertise* and `[?]` for *what anyone pays*.
- **The paywall boundary is a statement of belief.** The free tier is the acquisition strategy; the first thing behind the wall is what the vendor believes is worth money. That boundary moves more than prices do — track where it has moved.
- **Model distribution is a category convention.** Count how many competitors price per seat, per usage, flat, or hybrid. A convention is what buyers are set up to approve; deviating from it carries a real cost and needs a reason stronger than "ours is fairer".
- **Bands, not points.** Where does the category cluster at the low, mid, and premium ends, and what capability marks each jump? A recommendation is a band plus the differentiator that justifies sitting where it sits.

A positioning recommendation that names a price without naming what makes it defensible is not a finding.

#### Underserved segments and "blue ocean"

These are segment-level gaps, distinct from the feature-level ones in [finding-gaps.md](finding-gaps.md), and the same base rate applies with more force. **An unserved segment is usually unserved because it does not pay.** A market with no competitors is far more often no market than an open one.

The phrase "blue ocean" runs two things together:

| | Signal | Verdict |
|---|---|---|
| **Underserved** | They pay today, for a tool built for someone else, and complain about the fit | The real opportunity class |
| **Unserved** | Nobody sells to them; no adjacent spend visible | Usually not a market. Prove demand before believing it. |

What separates them is **existing spend and existing workarounds**. A segment cobbling together a spreadsheet and two tools has already shown that the budget exists and the job is real; a segment doing nothing has shown nothing. Look for adjacent tools they already buy, agencies or consultants serving them by hand, and templates or scripts they share with each other — the last strongest of all, because someone built it without being paid.

Report an opportunity as who they are, what they do today instead, what they already spend, and what evidence says they would move. Without the third and fourth the section relapses into the wish-list this skill exists to avoid.

### 8. Chase secondary claims

Grade every claim inline. The habit forces a provenance check per claim instead of blending everything into prose of equal authority.

| Mark | Means |
|---|---|
| `[P]` | Primary: official docs, company blog, filing, peer-reviewed paper, the API reference itself |
| `[S]` | Credible secondary: a reporter or practitioner who cites their source |
| `[?]` | Unverified. **Do not build on.** Always say which kind: `[?] unchecked` — nobody looked yet; or `[?] no primary` — someone looked and none exists |
| `[A]` | Our own analysis. No source claims it; we inferred it from the graded claims around it. Say what it rests on |
| `[M]` | Measured here: a command the author ran and whose output they read. Name the command, the version, and the machine |

`[A]` exists because in-house judgement has nowhere else to go. It is not `[P]` or `[S]`, since nobody published it, and it is not `[?]`, which says *do not build on*, while a write-up's conclusions are exactly what the reader must build on. Unmarked, analysis borrows the authority of the graded rows beside it; marked `[S]`, it impersonates a source. Mark it, and the reader can weigh it.

`[M]` is first-party evidence, not inference: it outranks `[A]` and sits beside `[P]` for what it observed, but holds only for the version and environment that produced it. A measurement left as `[A]` reads as a guess; one left unmarked borrows a vendor's authority it never had.

The two kinds of `[?]` are opposite objects, and one mark hides the difference: `unchecked` is unfinished work, while `no primary` is a completed search with a negative result — the very finding this skill exists to produce. Collapsing them is how a real result is reopened as a to-do, or quietly re-added.

**Provenance is not confidence.** The researcher contract already returns `conf: high|med|low`, which tracks corroboration; this mark tracks where the claim came from. They are different axes, and both belong on the line. A number repeated by six independent secondaries with no primary behind it is high-agreement folklore — high `conf`, still `[?]`, and the most dangerous shape a finding takes.

A sweep in which everything comes out `[S]` is not finished. Open the source each `[S]` claims to quote. Either it says what was claimed — promote the claim to `[P]` — or it does not, which is a finding:

> "Leagues → +25% lesson completion" is uncited folklore. The company blog
> confirms completions rose but publishes no percentage. Do not use it.

**A widely repeated number with no primary source is a result, not a dead end.** Name it, so nobody re-adds it later.

### 9. Write up

The structure, with sections adapted to the subject:

```markdown
## Scope note
Which sections are solid, which are thin. Up front, not buried.

## <Target 1> — <in-segment, or the analogue's source domain>
Mechanics in tables, numbers not adjectives. [P]/[S]/[?] on every claim.
URLs inline. For an out-of-segment analogue, name the domain it came
from and how far the analogy stretches.

## Design theory / underlying evidence
Tier 3. Including what argues against the obvious approach.

## Market structure
Size with its basis and grade, pricing bands and the paywall boundary,
segment breakdown. Underserved segments with the spend that proves them.

## Gaps and constraints
Tier 4. Recurring complaints, why each is unfixed, what that implies
about their architecture, and which are real openings versus traps.
Alongside them: what users refuse to give up, and what made switchers
actually move.

## Could not verify
Every open question, named.

## Sources
One line per source on what it covers.
```

**Never pad a gap.** State it in one line and move on:

> **This section is thin.** No verified data on the three smaller entrants.

Under a heading with nothing beneath it, the pull is toward plausible prose. A visible gap is cheap; a papered-over gap costs whatever is built on it.

### 10. Close with transfer analysis

Opinionated, and concrete about the structural differences between the source's context and the project's. This is the deliverable; a data dump is not. Say what to copy, what to invert, and what to ignore.

**The further a source sits from the project's segment, the more this section carries.** An in-segment finding mostly transfers by default; a cross-domain mechanic transfers only where the structural dimensions match, and inverts where they do not. Work through the mismatches named in [finding-analogues.md](finding-analogues.md) rather than asserting that the analogy holds.

**Report back on the constraints from step 1.** For each, say what the research did to it: confirmed as hard, dissolved by a counterexample, found to expire on a known timeline, or left untested. A constraint that turned out not to bind is often the most valuable finding in the report, because it reopens options already written off — and a recommendation that quietly assumes a constraint away must say so out loud.

**Correct the brief.** If the request named a source, person, or premise that does not hold up, say so plainly. Research that only confirms its own framing is worth nothing.

### 11. File the report

Write the report to `.agents/knowledge/research/YYYY-MM-DD-<subject>.md`, then add its line to `.agents/knowledge/index.md`. The entry contract — frontmatter fields, the shape of the index line, and why an entry is never revised in place — is in `.agents/knowledge/README.md`. Read it once; do not restate it here.

File the report whole, as written. The grades, the thin-section warnings, and the "Could not verify" list are what keep it re-readable months later; a version trimmed to conclusions is a set of unsourced assertions, the very object this skill exists not to produce.

Answer the lead in the same turn. The file is the record, not the reply.

## Delegating

Scope first:

- **Bounded question, one known target** — do it inline, with no cell.
- **3–6 targets** — one researcher, a prioritised list, a single time-box.
- **Broad sweep** — one researcher per target, **capped at eight**. Split by **target**, never by dimension: sources cluster by organisation, so a per-dimension split makes every researcher re-find the same pages. Past eight, prioritise the target list rather than widening the fan — each cell runs unmetered searches, and a sweep nobody reads costs the same as one that lands.
<!-- colloid-only -->

For Kimi, generate the required stamp before dispatch:

```sh
.agents/genome.sh mycelium --register none      # single sweep: trace every source
.agents/genome.sh --count 4 --register none     # fan-out: N distinct stamps
```

**Mycelium** is the natural genome for a single Kimi sweep: it traces provenance three hops out and is hard to surprise. For a Kimi fan-out, `--count N` draws distinct stamps so the targets are not all read through one lens. The Claude Code and Codex lifecycle hooks perform their own sortition.

`--register none` is load-bearing on both lines. `--register` defaults to `panspermia`, which tells a cell to *"dream weirder"* and to prefer wild conjecture over a safe answer — the exact opposite of a contract whose first rule is never to assert what it did not read in a source this run.
<!-- /colloid-only -->

**Delegation is an accelerant, not a dependency.** Where the engine exposes a mechanism for dispatching cells, use it; where it does not, work the targets in sequence in this session against the same contract. The method is unchanged; only whether the sweeps run concurrently in isolated context differs.

<!-- colloid-only -->
| Engine | Dispatch |
|---|---|
| Claude Code | `Task(subagent_type='researcher', prompt='[brief]')` — pins the cell to Sonnet; `SubagentStart` injects its genome |
| Codex | dispatch the `researcher` agent; `SubagentStart` injects its genome |
| Kimi CLI | the `Agent` tool; prepend one genome and `.agents/personas/researcher.md` to the prompt |
| Engine with no subagent primitive | apply `.agents/personas/researcher.md` yourself, then work each target in sequence |

Kimi receives `prompt='[stamp] + [brief]'`. Kimi CLI also exposes `AgentSwarm`, which suits the broad-sweep fan-out better than one `Agent` call per target.
<!-- /colloid-only -->

`.agents/personas/researcher.md` is the engine-neutral contract and already carries the escalation ladder, the corroboration rules, and the `CLAIMS / SOURCES / GAPS` return shape, so the brief does not restate them. The brief carries the market-research-specific part: see [brief-template.md](brief-template.md), and [finding-gaps.md](finding-gaps.md) when the target includes a gap sweep.

**Synthesis never delegates.** Researchers return graded findings; the lead writes the transfer analysis.

## Failure modes

**A cell that stalls waiting for a hand-off.** A researcher that decomposes its job and waits for input that is never coming waits forever and delivers nothing. The cell contract already forbids it to dispatch, so the recovery is the lead's: **resume the stalled cell with the instruction it is missing — *"you are the only agent on this; compile from your own work"* — rather than restarting it.** A restart discards everything it had found. Fan-out makes a stall more likely, not less, because one is easy to miss among cells that returned.

**Laundering secondary into primary.** A blog citing "their data" is `[S]`. It becomes `[P]` on opening their post and seeing the number there.

**Equal weight to unequal sources.** Rendering a meta-analysis and a listicle in the same voice is the most damaging act a report commits.

**Answering the brief's framing instead of the question.** If the brief assumes a daily mechanic and the evidence says weekly, lead with that.

**Freshness drift.** Thresholds, prices, and tiers change. Prefer the primary page to any summary of it, and record what was read directly.

**Treating a size figure as a fact.** See *Sizing the market*: the headline number is the least verified claim in most reports.
