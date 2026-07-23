---
applyTo: '.agents/skills/security-scan/**,.claude/skills/security-scan/**'
paths:
  - '.agents/skills/security-scan/**'
  - '.claude/skills/security-scan/**'
---

# Security-Scan Skill Rules

## Business Invariants
- The scan must hard-block the commit on any high-confidence secret match (exit 2). No exceptions without explicit in-chat user confirmation.
- The dependency check must stay advisory: warn, never block. CI and dedicated dependency tooling own that gate.
- The exit code is the contract a pre-commit hook keys on. Code 2 must stop the commit; code 1 lets it through.

## Abnormal Cases and Rationale
- Scan staged content only (`git diff --cached`), never the working tree. Do not re-flag secrets the developer already cleared.

## Out of Scope
- Do not restate `SKILL.md` usage instructions. This file governs edits to the skill.
