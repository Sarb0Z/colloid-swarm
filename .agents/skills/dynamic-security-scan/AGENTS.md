---
applyTo: '.agents/skills/dynamic-security-scan/**,.claude/skills/dynamic-security-scan/**'
paths:
  - '.agents/skills/dynamic-security-scan/**'
  - '.claude/skills/dynamic-security-scan/**'
---

# Dynamic-Security-Scan Skill Rules

## Business Invariants
- Require a recorded authorized scope before a scan. The scan target must be exact, and it must be validated before the scan tool call.
- A rejected target is terminal for that target. Do not retry it, rewrite it, or send any request outside the validation tool.
- Preserve the calling agent as the reasoning engine. Use only evidence returned by the scan and prompt registry.
- Do not place tokens, cookies, authorization headers, or raw credentials in findings, artifacts, logs, or conversation output.

## Abnormal Cases and Rationale
- A blocked or incomplete coverage class is a result. State the gap and its effect; do not mark it clean.

## Out of Scope
- Do not add source-only review procedures. The `security-audit` and `pentesting` skills own static analysis.
