---
applyTo: '.agents/skills/qa-verifier/**,.claude/skills/qa-verifier/**'
paths:
  - '.agents/skills/qa-verifier/**'
  - '.claude/skills/qa-verifier/**'
---

# QA verifier skill rules

- Keep the skill limited to dynamic verification. Static conformance,
  architecture, security reasoning, and scalability remain hostile review.
- Do not add a test-writing fallback. The verifier reports a missing regression
  test; the implementer owns the product change and its test.
