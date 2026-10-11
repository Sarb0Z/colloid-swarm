---
name: dynamic-security-scan
description: >
  Performs an authorized, non-destructive dynamic security scan of an exact localhost or
  allowlisted staging target through the native security-mcp tools. Use for "dynamic security
  scan", "DAST", "scan localhost", "scan staging", or an explicitly authorized live-target
  security assessment. It validates the target before scanning, analyzes returned evidence without
  inventing findings, and reports coverage gaps without storing credentials.
---

# Dynamic security scan

Use this skill only for a dynamic scan; source-only work belongs to `security-audit` or `pentesting`.

## Authorization gate

Before any MCP call, state the authorized scope in the conversation:

- Exact target URL and permitted environment.
- Operator authorization to test that target now.
- Non-destructive test limit and approved scan depth.
- Whether the operator supplied credentials. Do not repeat tokens, cookies, or headers.

Ask for missing authorization; never infer it from repository access, a hostname, or a user role.

## The scan

1. Call `validate_target` with the exact target URL.
2. On `allowed: false`, stop. Report only the validation reason and the missing authorization or configuration the operator must supply. Do not call `security_scan`, follow redirects, or make another request to that target.
3. On `allowed: true`, retain its normalized URL and classification, and call `security_scan` once with that normalized URL, an approved `quick`, `standard`, or `deep` scan type, and only operator-supplied credentials. Never enable a server-side prompt loop.
4. Call `list_security_prompts` and select prompts matching the returned attack surface and scan scope.
5. Reason over the returned evidence yourself. A finding must cite evidence from the scan result, identify the endpoint or surface, set severity and confidence, describe impact, and give a remediation. Do not infer a vulnerability from an untested route. Mark uncertain observations low confidence. Do not call a class clean unless the scan evidence covers it — the scanner marks IDOR, BOLA, BFLA, privilege escalation, and tenant isolation untested.

Do not use `run_prompt_loop` or `generate_report`. Keep raw scan results in the conversation context only; write no report, progress file, or credential to disk.

## Report

Return structured output, in order:

1. **Scope:** normalized URL, validation classification, scan type, and non-destructive limit. Never show credentials.
2. **Coverage:** scanned endpoints or surfaces, completed check classes, request-failure counts, and each blocked or untested class.
3. **Findings:** highest severity first, with title, severity, confidence, category, evidence, impact, and remediation. State `No verified findings` when evidence supports none.
4. **Next action:** the one highest-value remediation or the exact operator action that unblocks coverage.

Do not create a report solely to preserve output; the calling agent owns structured reporting and follow-up reasoning.

## Completion conditions

Complete only when every condition holds:

- The calling agent recorded explicit authorization and exact scope.
- `validate_target` allowed the exact scan URL before the only scan call.
- The scan completed, or the result names the concrete failure.
- The prompt registry was weighed against the returned evidence.
- Every published finding has evidence and confidence.
- The report states coverage, gaps, and whether any credentials were supplied without disclosing them.

The scan proves not that the target is secure, only the returned tool coverage and the evidence this run reviewed.
