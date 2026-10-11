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

This skill is for a dynamic scan only; source-only work belongs to `security-audit` or `pentesting`.

## Authorization gate

Before any MCP call, the conversation states the authorized scope:

- The exact target URL and the permitted environment.
- The operator's authorization to test that target now.
- The non-destructive test limit and the approved scan depth.
- Whether the operator supplied credentials — never the tokens, cookies, or headers themselves.

Missing authorization is asked for, never inferred from repository access, a hostname, or a user role.

## The scan

1. Call `validate_target` with the exact target URL.
2. On `allowed: false`, stop. Report only the validation reason and the authorization or configuration the operator must supply: no `security_scan` call, no redirect followed, no further request to that target.
3. On `allowed: true`, keep the returned normalized URL and classification, and call `security_scan` once with that normalized URL, an approved `quick`, `standard`, or `deep` scan type, and only operator-supplied credentials. A server-side prompt loop is never enabled.
4. Call `list_security_prompts` and select the prompts that match the returned attack surface and scan scope.
5. The agent reasons over the returned evidence itself. A finding cites evidence from the scan result, names the endpoint or surface, sets severity and confidence, describes impact, and gives a remediation. An untested route implies no vulnerability; an uncertain observation is marked low confidence; a class is called clean only where the scan evidence covers it.

`run_prompt_loop` and `generate_report` stay unused. Raw scan results live in the conversation context only; reports, progress files, and credentials never reach the disk.

## Report

Structured output, in this order:

1. **Scope:** normalized URL, validation classification, scan type, and non-destructive limit. Credentials never appear.
2. **Coverage:** scanned endpoints or surfaces, completed check classes, request-failure counts, and each blocked or untested class.
3. **Findings:** highest severity first, each with title, severity, confidence, category, evidence, impact, and remediation. `No verified findings` when the evidence supports none.
4. **Next action:** the one highest-value remediation, or the exact operator action that unblocks coverage.

No report is created merely to preserve output: the agent running the scan owns structured reporting and the reasoning that follows.

## Completion conditions

The scan is complete only when every condition holds:

- The session recorded explicit authorization and exact scope.
- `validate_target` allowed the exact scan URL before the only scan call.
- The scan completed, or the result names the concrete failure.
- The prompt registry was weighed against the returned evidence.
- Every published finding carries evidence and confidence.
- The report states coverage, gaps, and whether credentials were supplied, without disclosing them.

A scan proves nothing about whether the target is secure — only the coverage the tools returned and the evidence reviewed in this run.
