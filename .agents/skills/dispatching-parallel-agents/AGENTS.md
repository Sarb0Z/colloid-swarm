---
applyTo: '.agents/skills/dispatching-parallel-agents/**,.claude/skills/dispatching-parallel-agents/**'
paths:
  - '.agents/skills/dispatching-parallel-agents/**'
  - '.claude/skills/dispatching-parallel-agents/**'
---

# Dispatching-Parallel-Agents Skill Rules

## Business Invariants
- The genome-stamp step is colloid-only machinery. Keep it here, but a satellite copy of this skill must strip it — no satellite ships `genome.sh` or `genome-guard`.

## Abnormal Cases and Rationale
- A dispatched agent must not inherit the parent session's context or history. An edit that weakens the "construct exactly what the agent needs" contract breaks the isolation the skill exists to provide.

## Out of Scope
- Do not restate `SKILL.md` usage instructions. This file governs edits to the skill.
