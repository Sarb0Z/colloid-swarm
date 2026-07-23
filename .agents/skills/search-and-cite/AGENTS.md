---
applyTo: '.agents/skills/search-and-cite/**,.claude/skills/search-and-cite/**'
paths:
  - '.agents/skills/search-and-cite/**'
  - '.claude/skills/search-and-cite/**'
---

# Search-And-Cite Skill Rules

## Business Invariants
- This skill enforces nothing mechanically. A from-memory claim makes no tool call, so no hook can catch it. Its value is discipline, not enforcement — do not describe it as a gate.

## Abnormal Cases and Rationale
- Relay a GAP as a conclusion, never a hedge. The trip-wire phrase list ("unable to determine", "without more context") is load-bearing: it keeps a real finding from reading as a stalled investigation and tripping the session guard. Do not trim it.

## Out of Scope
- Do not restate `SKILL.md` usage instructions. This file governs edits to the skill.
