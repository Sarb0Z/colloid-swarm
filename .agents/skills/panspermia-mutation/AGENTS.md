---
applyTo: '.agents/skills/panspermia-mutation/**,.claude/skills/panspermia-mutation/**'
paths:
  - '.agents/skills/panspermia-mutation/**'
  - '.claude/skills/panspermia-mutation/**'
---

# Panspermia-Mutation Skill Rules

## Business Invariants
- The skill depends on the genome/mutagen layer (`genome.sh`, `mutagen.sh`, `genomes.md`). It is colloid-only and cannot run in a satellite, which strips that layer. Do not adapt it for satellite use.
- The selection step is load-bearing. This is variation *and* selection: an edit that drops the blind run or the fitness pick reduces it to a plain parallel dispatch, which the tool already does natively — the skill then has no reason to exist.

## Abnormal Cases and Rationale
- None recorded yet.

## Out of Scope
- Do not restate `SKILL.md` usage instructions. This file governs edits to the skill.
