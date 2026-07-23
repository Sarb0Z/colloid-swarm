---
applyTo: '.agents/skills/security-audit/**,.claude/skills/security-audit/**'
paths:
  - '.agents/skills/security-audit/**'
  - '.claude/skills/security-audit/**'
---

# Security-Audit Skill Rules

## Business Invariants
- A detection rule must give a true signal or none. A rule that reads "safe" over a real leak — e.g. "a bare `find()` cannot leak `passwordHash`" when base columns load by default — is worse than no rule. False confidence is the failure mode.
- Scope each rule to the exact case it holds for. An over-broad rule that fires on legitimate patterns trains the reader to ignore the whole class.

## Abnormal Cases and Rationale
- The references reason over source (SAST). Runtime attack classes (cache-deception, live BOLA/OTP probing) are documented for recognition only. This skill does not drive a live target — a separate tool owns dynamic testing. Do not add active-probe procedures here.

## Out of Scope
- Do not restate `SKILL.md` usage instructions. This file governs edits to the skill.
