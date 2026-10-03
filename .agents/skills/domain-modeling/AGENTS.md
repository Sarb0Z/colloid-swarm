---
applyTo: '.agents/skills/domain-modeling/**,.claude/skills/domain-modeling/**'
paths:
  - '.agents/skills/domain-modeling/**'
  - '.claude/skills/domain-modeling/**'
---

# Domain-Modeling Skill Rules

## Business Invariants
- This skill is MIT-licensed third-party content. `.agents/licenses/mattpocock-skills-MIT.md` holds its notice, its source commit and every difference from the source. Keep that file while this skill remains, and record each local edit in it.
- `SKILL.md` and its format files follow upstream. To change them, prefer an update from upstream that records the new commit. A local fork must be recorded before it lands.

## Abnormal Cases and Rationale
- This skill records a decision in `.agents/decisions.md`, not in an ADR under `docs/adr/`. The operator ruled on 2026-10-03 that decisions stay in that one store, so upstream's ADR instructions and `ADR-FORMAT.md` are a recorded fork. Keep the fork when you update from upstream, and keep upstream's three tests for when a decision earns an entry.

## Out of Scope
- Do not restate `SKILL.md` usage instructions. This file governs edits to the skill.
