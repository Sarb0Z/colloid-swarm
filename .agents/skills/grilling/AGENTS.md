---
applyTo: '.agents/skills/grilling/**,.claude/skills/grilling/**'
paths:
  - '.agents/skills/grilling/**'
  - '.claude/skills/grilling/**'
---

# Grilling Skill Rules

## Business Invariants
- This skill is MIT-licensed third-party content. `.agents/licenses/mattpocock-skills-MIT.md` holds its notice, its source commit and every difference from the source. Keep that file while this skill remains, and record each local edit in it.
- `SKILL.md` follows upstream. To change it, prefer an update from upstream that records the new commit. A local fork must be recorded before it lands.

## Abnormal Cases and Rationale
- A round asks every question on the frontier, each one with a recommended answer. This differs from the contract's one-focused-question rule on purpose: the operator starts this skill to be interviewed. Do not reduce a round to one question; where the question tool caps a call, the round spans several calls.
- A round goes through the host's question tool, not upstream's emoji-marked prose. The operator ruled on 2026-10-08 that rounds come as question-tool prompts carrying the full context and each option's consequence, with plain prose only where the host has no such tool, and that a question whose options are not exhaustive offers to explore more before the operator picks.

## Out of Scope
- Do not restate `SKILL.md` usage instructions. This file governs edits to the skill.
