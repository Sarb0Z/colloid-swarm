---
applyTo: 'README.md,docs/**/*.md,docs/**/*.mdx,docs/**/*.rst,docs/**/*.txt'
paths:
  - 'README.md'
  - 'docs/**/*.md'
  - 'docs/**/*.mdx'
  - 'docs/**/*.rst'
  - 'docs/**/*.txt'
---

# Documentation Rules

This rule governs product documentation: the README and the files under `docs/`.

## Business Invariants
- All documentation is written in ASD-STE100 Simplified Technical English, whose rules carry short sentences, active voice, and the imperative mood.
- The vocabulary is the approved vocabulary: one term per concept, no synonym drift, and a project-specific name introduced once and reused verbatim.
- Modals are explicit: "must" states a requirement, "should" a recommendation, "may" a permission, and the three never blend.

## Abnormal Cases and Rationale
- Naming the standard carries most of its rules on its own; approved vocabulary and explicit modals do not survive that abbreviation, because they are what drifts.

## Out of Scope
- The scaffold and harness are not documentation. This rule does not govern `AGENTS.md` or `CLAUDE.md` contracts at any depth, `.agents/**`, `.claude/**`, `.codex/**`, `.kimi/**`, `.github/instructions/**`, `docs/handoff/**`, or `docs/reviews/**`. The globs above cannot exclude them, because path matching has no negation here, so this line carries the exclusion.
- The tombstone rule is not restated here: the root `AGENTS.md` owns what documentation may say about its own history.
