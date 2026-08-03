# Researcher brief template

Fill the angle brackets and append to the genome stamp. Every rule below earned its place by having been omitted once.

**What this brief does not restate.** The researcher cell already carries the escalation ladder, the two-independent-sources rule for load-bearing claims, source dating, the honesty clause, and the `CLAIMS / SOURCES / GAPS` return shape — see `.agents/personas/researcher.md`, baked into `.claude/agents/researcher.md`. Repeating them here dilutes the brief and lets the two copies drift. What follows is only the market-research-specific part.

```
Research <question>. I need <mechanics with real numbers / effect sizes /
current behaviour>, not marketing copy.

Cover, in priority order:
1. <direct competitors — products in our exact category, first>
2. <the reference example everyone cites, if any>
3. <the underlying literature, spec, or primary documentation>

For each: <the specific dimensions — exact thresholds, limits, pricing, tiers,
cohort sizes, whatever the decision turns on>.

Collect both halves of the user signal, not just the negative one: what users
refuse to give up, and what made switchers actually move, alongside what they
complain about. Where a feature request and a switching trigger disagree,
weight the trigger and say so.

Our constraints — treat these as part of the question, not a filter to apply
at the end:
- <team size / capacity>
- <infrastructure we have and lack>
- <what the data model or platform already commits us to>
- <policy positions and deliberate non-goals>

Ask the constraint-shaped version of each question ("how does this work
WITHOUT <X>"), and prefer sources who solved it under similar constraints
over the market leader. For every constraint above, look for a counterexample
— someone shipping this despite it, or someone for whom it has expired.
Report each constraint as confirmed, dissolved, expiring, or untested.

In addition to your standard return shape:
- Mark every claim [P] primary / [S] secondary / [?] unverified, alongside
  its conf. Provenance and confidence are different axes: a number six
  secondaries agree on with no primary behind it is high-conf folklore,
  and must ship as [?].
- Chase [S] claims to the primary source. If a widely-quoted number has no
  primary source, say so explicitly — that is a finding, not a gap.
- Include what the evidence says AGAINST this approach.
- Flag anything in this brief that turns out to be a false lead.

Close with: "What transfers to <our context> and what doesn't" — opinionated,
concrete about the structural differences between their situation and ours.

Time-box: <N>. Deliver what you have at the limit — a partial cited report
beats a late complete one.
```

## Why each rule is there

| Rule | Without it |
|---|---|
| Grade provenance, not just confidence | Marketing copy and peer-reviewed findings render in the same authoritative voice, and agreement gets mistaken for evidence |
| Chase `[S]` to primary | Folklore numbers propagate into design docs as justification |
| Folklore is a finding, not a gap | A named dead number stays dead; an unnamed one gets re-added next quarter |
| Evidence against | The report confirms the brief's framing and surfaces nothing new |
| Flag false leads | A wrong premise in the brief silently shapes every conclusion |
| Our constraints, stated | Findings come back generically applicable, and nobody checks whether the constraint that ruled an option out is even real |
| Constraint disposition | "Untested" and "confirmed hard" look identical in a report that does not distinguish them |
| Time-box | Unbounded sweeps stall past the point of usefulness |
