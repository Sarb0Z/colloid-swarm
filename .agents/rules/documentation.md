---
applyTo: '**/*.md,**/*.mdx,**/*.rst,**/*.txt'
paths:
  - '**/*.md'
  - '**/*.mdx'
  - '**/*.rst'
  - '**/*.txt'
---

# Documentation Rules

## Business Invariants
- Write all documentation in ASD-STE100 Simplified Technical English. The standard carries short sentences, active voice, and the imperative mood.
- Use approved vocabulary. One term per concept, no synonym drift. Introduce a project-specific name once, then reuse it verbatim.
- Use explicit modals. "Must" states a requirement, "should" states a recommendation, "may" states a permission. Never blend them.

## Abnormal Cases and Rationale
- Naming the standard carries most of its rules on its own. Approved vocabulary and explicit modals do not survive that abbreviation, because they are what drifts.

## Out of Scope
- Do not restate the tombstone rule here. The root `AGENTS.md` owns what documentation may say about its own history.
