---
applyTo: '.agents/skills/market-researcher/**,.claude/skills/market-researcher/**'
paths:
  - '.agents/skills/market-researcher/**'
  - '.claude/skills/market-researcher/**'
---

# Market-Researcher Skill Rules

## Business Invariants
- This is a documentation-only prompt skill — no runtime entry point. Do not re-add a `skill.ts` or a "Runtime Implementation" section; that was plugin-wrapper cruft pointing at a file that never existed.
- `brief-template.md` must not restate what `.agents/personas/researcher.md` already carries (escalation ladder, corroboration rules, source dating, honesty clause, `CLAIMS / SOURCES / GAPS` shape). Two copies drift, and the brief is the copy nobody updates. It carries only the market-research-specific additions.
- `[P]`/`[S]`/`[?]` is a provenance axis and does not replace the researcher contract's `conf:`. Both ride on the claim line. Collapsing them loses the high-agreement-folklore case, which is the one this skill exists to catch.
- A `[?]` must always say which kind it is — `unchecked` or `no primary`. They are opposite objects: unfinished work versus a completed negative result. One mark for both is how a real finding gets re-opened as a to-do.
- Every trigger phrase in the `description` must have a method behind it in the body, **and a step in the workflow checklist that reaches it**. "Blue ocean" once advertised a capability the body did not carry, and later sat in the body with no checklist step routing to it. When trimming or adding, check all three.
- Tier 4 covers both halves of the user signal. Complaints alone produce a gap list with no sense of what is load-bearing; satisfaction drivers and switching triggers are what say which gaps matter.
- `description` must stay within **1024 characters** and third person — cross-vendor field validation, not a guideline. Both `name` and `description` are pre-loaded metadata and both feed skill selection, but the description carries the trigger load. Measure after editing; it has been over once.
- `name` stays noun-form. Gerund form is documented house style, but noun phrases are an explicit "acceptable alternative", and the same guidance lists "inconsistent patterns within your skill collection" under Avoid — the sibling skills are noun-form, so switching this one alone would create the inconsistency, not fix one.
- Reference depth stays **one level**: `SKILL.md` to a sibling, never sibling to sibling. Nested references get partially read.

## Abnormal Cases and Rationale
- The starting-hypotheses table in `finding-gaps.md` is priming, not a lookup table, and says so. Keep the rules above it that make a row a candidate needing independent evidence. Presenting it as answers is how an unevidenced architectural story ships as a finding.
- `finding-analogues.md` deliberately keeps concrete cross-domain examples (streaks, reverse bidding, object recognition). They teach the decomposition move in a way abstract phrasing does not. Do not sand them into generic nouns.
- Each mechanic in `finding-analogues.md` carries two deliberately dissimilar implementers, and the named brands stay. Replacing a named brand with a generic category label has been measured to make category stereotyping **worse**, not better: the name is what anchors a model to that entity's actual, non-prototypical attributes, and removing it leaves the bare category prototype to fill the gap. Pairing widens the candidate field; abstraction does not.
- The pairing is a partial correction, not a fix. Defixation by contrasting exemplars gives real but modest gains, so a residual pull toward the illustrated domains must be assumed to survive it. That is why `finding-analogues.md` also tells the reader to audit the spread of the *output*; do not delete that check on the grounds that the examples are already diverse.
- Decomposition to the abstract mechanic must stay ordered **before** the search. It is the structure-abduction step that stops surface resemblance from driving candidate selection, which is the documented default failure mode in machine analogy-making. Reordering it into a later "refinement" step removes the guard.
- The delegation table is engine-conditional by design. Delegation is an accelerant, and no dispatch syntax is portable: Claude Code has `Task`, Kimi has `Agent`, and some engines have no callable primitive at all. Do not hard-code one engine's call as the only path.
- Cross-domain examples carry no borrowed figures. A frequency or effect number lifted from another project's research arrives here unsourced and would ship as fact under a skill whose whole point is provenance.

## Out of Scope
- Do not restate `SKILL.md` usage instructions. This file governs edits to the skill.
