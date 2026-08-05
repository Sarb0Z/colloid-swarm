---
name: market-researcher
description: Market and competitor research whose output someone will build on — feature teardowns, pricing, market sizing, prior art, and whether a mechanic works in practice. Looks past the segment to whoever implements a mechanic best in any industry, and sweeps peer-reviewed literature, not just competitor pages. Mines recurring complaints to find unfilled gaps, works out why each is unfixed, and infers a competitor architecture from what they cannot repair. Grades every claim by source quality and flags widely-repeated numbers with no primary source. Use when scoping a feature or product: what competitors ship and where they fall short, how other products solve a problem, market size and growth, what users request or churn over, how the space is priced, where the unmet gaps are, or what prior art says before an architecture decision. Trigger phrases: market research, competitor analysis, competitive landscape, market size, TAM, pricing analysis, market gap, blue ocean, is there demand for this, prior art.
---

# Market researcher

Research whose output someone will build on. The failure mode is not "found
nothing" — it is a fluent, complete-looking report whose numbers came from a
content farm quoting another content farm.

**Provenance is part of the claim.** An ungraded number is not a weaker finding;
it is a different kind of object, and the report must say which one it is
holding.

This is the long-form sweep. For a single external fact in the middle of an
ordinary turn, use `search-and-cite` instead — that skill draws the line between
a quick inline lookup and a delegated cell, and this one assumes you have
already crossed it.

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
```

### 1. State our constraints

Write down what actually binds us before looking at anything: team size,
infrastructure we have and lack, what the data model already commits to, what is
gated or paid, policy positions, and what we have deliberately chosen not to
build.

**Constraints are a research input, not a filter applied to the results.** They
change the question — *"how does this mechanic work"* and *"how does this
mechanic work without push notifications"* return different sources, and only the
second is usable. They also change what "best" means: the best implementation for
a team with a data science function is not the best one for us. Ask who solved
this **under constraints like ours**; the scrappier answer usually fits better
than the market leader's.

Then classify each, because most stated constraints are not the kind that binds:

| Kind | Test | What to do |
|---|---|---|
| **Hard** | Physics, platform policy, money that does not exist | Design around it |
| **Assumed** | "We can't do X" — has anyone actually checked? | Verify before designing around it |
| **Expiring** | True now, dissolving on a known timeline | Design for after, ship for now |
| **Self-imposed** | A choice we made and could unmake | Revisitable — but price the reversal |
| **Capacity** | We do not know how, or have no time | A scope or learning question, not an architecture one |

Research is how you find out which kind each one is. A constraint that survives a
deliberate search for counterexamples is real; one that dissolves on contact was
quietly costing us options. Search for both — someone shipping this under our
constraint, and someone for whom the constraint has already expired.

**The symmetry that matters:** a constraint binding us and not them explains why
their solution will not transfer. A constraint binding them and not us is an
opening (see [finding-gaps.md](finding-gaps.md)). Most of the strategy lives in
that difference, so state both sides explicitly rather than only ours.

### 2. List targets

Two axes. They answer different questions, and using only one is the most common
way this research goes wrong.

**In-segment competitors** — what the market expects, pricing, table stakes, and
where the gaps are. For *facts about the category*, one verified datapoint from a
product in the exact category outweighs a pile of material from a household name
in a different one. Include the **indirect** ones: the spreadsheet, the agency,
and the adjacent tool people use instead are competitors that never appear on a
comparison page, and they hold the honest answer to "what do they do today". Note
each target's position — leader, challenger, or niche — because it changes how to
read their choices. A leader's pricing defends a base; a challenger's buys share.

**Best-in-class by mechanic, any domain** — how to design the thing well.
Competitors copy each other, so a segment converges on a local optimum. Decompose
the feature to its abstract mechanic and find whoever does that best regardless
of industry — reverse bidding is solved by freelance marketplaces and by freight
brokers and construction tendering, and the unlike pair teaches more than either
alone. See [finding-analogues.md](finding-analogues.md).

Searching only in-segment produces a product that matches its competitors and
beats nobody. Searching only cross-domain produces a mechanic that is elegant and
ignores what the market already demands.

### 3–6. Sweep four tiers

| Tier | Source | Yields |
|---|---|---|
| 1. What they say | Docs, help centre, official blog, pricing page | Exact thresholds, tiers, caps, prices |
| 2. What they measured | Published experiments, engineering posts, earnings calls | Effect sizes, adoption numbers |
| 3. What the literature says | Peer-reviewed work on the underlying mechanism | Failure modes nobody in the space advertises |
| 4. What users say | Store reviews, Reddit, support forums, changelogs | Unfilled gaps and the constraints behind them; why users stay, and why they switch |

Budget for tiers 3 and 4. Tier 3 is where the finding lives that contradicts what
every competitor page implies. Tier 4 is where the openings are — and where a
recurring complaint that survives for years reveals an architectural boundary the
competitor cannot move.

**Tier 4 has its own method: see [finding-gaps.md](finding-gaps.md).** Recurring
complaint → why it is unfixed → whether we can fill it. The middle step is the one
that pays, and skipping it turns a moat into a roadmap.

#### Tier 3 questions that pay

Every competitor shipping a mechanic is evidence that it is popular, not that it
works. Ask the literature:

- **Does it work for everyone, or does the average hide a harmed subgroup?**
  Aggregate effects routinely conceal opposite-signed subgroup effects, and the
  people a feature helps most are often not the people it is aimed at. Always
  look for results broken out by baseline engagement, experience, or intensity —
  this is the single highest-yield question in the tier.
- **How big is the effect, honestly?** "Statistically significant" and "worth
  building" are different claims. Get the number and judge it.
- **Does it decay?** Many engagement effects fade within weeks of onboarding. A
  result measured at two weeks and a result measured at six months are different
  findings.
- **What is the documented failure mode?** Anything widely shipped has one; the
  vendors will not be the ones to publish it.

These are what turn "competitors all have X" into a decision about whether *we*
should.

#### Why they stay, and why they leave

Tier 4's other half. Complaints tell you what is broken; they do not tell you
what is load-bearing. Both halves come from the same corpus and most sweeps
collect only the negative one.

- **Satisfaction drivers** — what users praise unprompted, and what they say they
  would not give up. This is the category's real table stakes, which is rarely
  the same list as its marketed features. Anything here is something we must
  match or consciously decide to lose.
- **Switching triggers** — what made someone actually move, in their own words.
  The strongest signal in competitive research, because it is revealed preference
  rather than a stated wish. Search for migration posts, "moved from X to Y", and
  the comparison threads users write for each other.
- **Churn reasons** — why they left and did *not* arrive anywhere. Different from
  switching: it usually means the category failed them, not the product, and it
  bounds how much of the market is actually addressable.

A requested feature and a switching trigger are different objects. Feature
requests are cheap to voice and routinely go unused when shipped; a switching
trigger already cost someone the effort of migrating. When the two disagree,
weight the trigger and say so.

### 7. Market structure

Size, price, and segments. All three ride the same tiers and the same grading,
and all three are where an unsourced number does the most damage.

#### Sizing the market

Market size, growth rate, and segment breakdown ride the same tiers, but they are
the **most folklore-prone class of claim in this skill** — a single paid industry
report gets summarised by a dozen blogs, and the summaries cite each other until
the number looks like consensus. Treat every headline TAM as `[?]` until the
primary is open.

| Want | Go to | Grade reality |
|---|---|---|
| Market size, CAGR | The report's own methodology page or press release; regulator and statistics-office data | The blog quoting a paywalled report is `[S]` at best, and often `[?]` |
| Segment breakdown | Public filings and earnings decks of listed players | `[P]`, and usually the only honest segment numbers available |
| Growth direction | Funding rounds, job-posting volume, new entrants | Directional evidence, never a size figure |

State the **basis and the geography** of any size number. Basis: top-down from an
analyst's total, or bottom-up from price × observable users — the two disagree
routinely, and a report that does not say which it used cannot be checked.
Geography: "$4.2B market" is a different claim for global, US, and EMEA, and the
folklore chain this section exists to break routinely launders one into another.
A figure with neither is uncheckable twice over. Where the primary is paywalled,
that is a finding: *"figure traces to a paid report; methodology not public"* is
worth more than repeating the number.

#### Reading the pricing structure

Tier 1 collects the numbers off the pricing page. The structure behind them is
the finding.

- **The list price is not the paid price.** Annual discounts, promotional rates,
  and negotiated enterprise deals all sit below the published figure, and in B2B
  the published figure may be fiction. Treat a pricing page as `[P]` for *what
  they advertise* and `[?]` for *what anyone actually pays*.
- **The paywall boundary is a statement of belief.** What sits in the free tier
  is their acquisition strategy; the first thing behind the wall is what they
  believe is worth money. That boundary moves more than prices do — track where
  it has moved.
- **Model distribution is a category convention.** Count how many competitors
  price per seat, per usage, flat, or hybrid. A convention is what buyers are
  set up to approve; deviating from it is a real cost, and it needs a reason
  stronger than "ours is fairer".
- **Bands, not points.** Where does the category cluster at the low, mid, and
  premium ends, and what capability marks each jump? A recommendation is a band
  plus the differentiator that justifies sitting where it sits.

A positioning recommendation that names a price without naming what makes it
defensible is not a finding.

#### Underserved segments and "blue ocean"

Segment-level gaps, as distinct from the feature-level ones in
[finding-gaps.md](finding-gaps.md) — and the same base rate applies, harder. **An
unserved segment is usually unserved because it does not pay.** A market with no
competitors is far more often no market than an open one.

Separate two things the phrase "blue ocean" runs together:

| | Signal | Verdict |
|---|---|---|
| **Underserved** | They pay today, for a tool built for someone else, and complain about the fit | The real opportunity class |
| **Unserved** | Nobody sells to them; no adjacent spend visible | Usually not a market. Prove demand before believing it. |

The evidence that separates them is **existing spend and existing workarounds**.
A segment cobbling together a spreadsheet and two tools has already told you the
budget exists and the job is real. A segment doing nothing has told you nothing.
Look for: adjacent tools they already buy, agencies or consultants serving them
manually, and templates or scripts they share with each other — the last is the
strongest, because someone built it without being paid.

Report an opportunity as: who they are, what they do today instead, what they
already spend, and what evidence says they would move. Missing the third and
fourth turns the section back into the wish-list this skill exists to avoid.

### 8. Chase secondary claims

Grade every claim inline. This single habit forces a provenance check per claim
instead of blending everything into equal-authority prose.

| Mark | Means |
|---|---|
| `[P]` | Primary: official docs, company blog, filing, peer-reviewed paper, the API reference itself |
| `[S]` | Credible secondary: a reporter or practitioner who cites their source |
| `[?]` | Unverified. **Do not build on.** Always say which kind: `[?] unchecked` — nobody looked yet; or `[?] no primary` — someone looked and none exists |

The two kinds of `[?]` are opposite objects and one mark hides the difference:
`unchecked` is unfinished work, while `no primary` is a completed search with a
negative result — the very finding this skill exists to produce. Collapsing them
is how a real result gets re-opened as a to-do, or worse, quietly re-added.

**Provenance is not confidence.** The researcher contract already returns
`conf: high|med|low`, which tracks corroboration; this mark tracks where the claim
came from. They are different axes and both belong on the line. A number repeated
by six independent secondaries with no primary behind it is high-agreement
folklore — high `conf`, still `[?]`, and the most dangerous shape a finding takes.

If everything comes out `[S]`, the sweep is not finished. Open the source each
`[S]` claims to quote. Either it says what was claimed — promote to `[P]` — or it
does not, which is a finding:

> ⚠️ "Leagues → +25% lesson completion" is uncited folklore. The company blog
> confirms completions rose but publishes no percentage. Do not use it.

**A widely-repeated number with no primary source is a result, not a dead end.**
Name it so nobody re-adds it later.

### 9. Write up

Structure (adapt sections to the subject):

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

Under a heading with nothing beneath it, the default pull is to write plausible
prose. A visible gap is cheap; a papered-over gap costs whatever gets built on it.

### 10. Close with transfer analysis

Opinionated, concrete about structural differences between their context and ours.
This is the deliverable — a data dump is not. Say what to copy, what to invert,
and what to ignore.

**The further a source sits from our segment, the more this section has to
carry.** An in-segment finding mostly transfers by default; a cross-domain
mechanic transfers only where the structural dimensions match, and inverts where
they do not. Work through the mismatches named in
[finding-analogues.md](finding-analogues.md) rather than asserting the analogy
holds.

**Report back on the constraints from step 1.** For each one, say what the
research did to it: confirmed as hard, dissolved by a counterexample, found to be
expiring on a known timeline, or untested. A constraint that turned out not to
bind is often the most valuable finding in the report, because it reopens options
that were already written off — and a recommendation that quietly assumes a
constraint away must say so out loud.

**Correct the brief.** If the request named a source, person, or premise that does
not check out, say so plainly. Research that only confirms its own framing is
worth nothing.

## Delegating

Scope first:

- **Bounded question, one known target** — do it inline. No cell.
- **3–6 targets** — one researcher, prioritised list, single time-box.
- **Broad sweep** — one researcher per target, **capped at eight**. Split by
  **target**, never by dimension: sources cluster by organisation, so a
  per-dimension split makes every researcher re-find the same pages. Past eight,
  prioritise the target list rather than widening the fan — each cell runs
  unmetered searches, and a sweep nobody reads costs the same as one that lands.
<!-- colloid-only -->

Researchers are cells like any other — stamp each with a genome and dispatch:

```sh
.agents/genome.sh mycelium --register none      # single sweep: trace every source
.agents/genome.sh --count 4 --register none     # fan-out: N distinct stamps
```

**Mycelium** is the natural genome for a single sweep — it traces provenance three
hops out and is hard to surprise. For a fan-out, `--count N` draws distinct
stamps so the targets are not all read through the same lens.

`--register none` is load-bearing on both lines. `--register` defaults to
`panspermia`, which instructs a cell to *"dream weirder"* and prefer wild
conjecture over a safe answer — the exact opposite of a contract whose first rule
is never to assert what it did not read in a source this run.
<!-- /colloid-only -->

**Delegation is an accelerant, not a dependency.** Where the engine exposes a
subagent mechanism, use it; where it does not, work the targets in sequence in
this session against the same contract. The method does not change — only whether
the sweeps run concurrently in isolated context.

| Engine | Dispatch |
|---|---|
| Claude Code | `Task(subagent_type='researcher', prompt='[brief]')` — pins the cell to Sonnet instead of the parent model |
| Kimi CLI | the `Agent` tool; prepend `.agents/personas/researcher.md` to the prompt |
| Codex, or any engine with no subagent primitive | apply `.agents/personas/researcher.md` yourself, then work each target in sequence |
<!-- colloid-only -->

Every dispatch carries its stamp ahead of the brief — under Claude Code,
`prompt='[stamp] + [brief]'`. Kimi CLI also exposes `AgentSwarm`, which fits the
broad-sweep fan-out better than one `Agent` call per target.
<!-- /colloid-only -->

`.agents/personas/researcher.md` is the engine-neutral contract and already
carries the escalation ladder, the corroboration rules, and the
`CLAIMS / SOURCES / GAPS` return shape — the brief does not restate them. It
carries the market-research-specific part: see
[brief-template.md](brief-template.md), plus [finding-gaps.md](finding-gaps.md)
when the target includes a gap sweep.

**Synthesis never delegates.** Researchers return graded findings; the caller
writes the transfer analysis.

## Failure modes

**A cell that stalls waiting for a hand-off.** A researcher that decomposes its
job and waits for input that is never coming waits forever and delivers nothing.
The cell contract already forbids it from dispatching, so the recovery is the
orchestrator's: **resume the stalled cell with the instruction it is missing —
*"you are the only agent on this; compile from your own work"* — rather than
restarting it.** A restart discards everything it had already found. Fan-out
makes this more likely, not less, because a stall is easy to miss among cells
that returned.

**Laundering secondary into primary.** A blog citing "their data" is `[S]`. It
becomes `[P]` on opening their post and seeing the number.

**Equal weight to unequal sources.** Rendering a meta-analysis and a listicle in
the same voice is the most damaging thing a report can do.

**Answering the brief's framing instead of the question.** If the brief assumes a
daily mechanic and the evidence says weekly, lead with that.

**Freshness drift.** Thresholds, prices, and tiers change. Prefer the primary page
over any summary of it, and note what was read directly.

**Treating a size figure as a fact.** See *Sizing the market* — the headline
number is the least verified thing in most reports.
