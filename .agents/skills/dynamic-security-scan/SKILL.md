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

Use this skill only for a dynamic scan; use `security-audit` or `pentesting` for source-only work.

## Authorization gate

Before any MCP call, state the authorized scope in the conversation:

- The exact target URL and the permitted environment.
- The operator's authorization to test that target now.
- The non-destructive test limit and the approved scan depth.
- Whether the operator supplied credentials. Do not repeat the tokens, cookies, or headers.

Ask for the missing authorization; do not infer it from repository access, a hostname, or a user role.

## The scan

1. Call `validate_target` with the exact target URL.
2. On `allowed: false`, stop. Report only the validation reason and the missing authorization or configuration the operator must supply. Do not call `security_scan`, follow redirects, or make another request to that target.
3. On `allowed: true`, retain the returned normalized URL and classification, and call `security_scan` once with that normalized URL, an approved `quick`, `standard`, or `deep` scan type, and only operator-supplied credentials. Never enable a server-side prompt loop.
4. Call `list_security_prompts` and select the prompts that match the returned attack surface and scan scope.
5. Reason over the returned evidence yourself. A finding must cite evidence from the scan result, identify the endpoint or surface, set severity and confidence, describe impact, and give a remediation. Do not infer a vulnerability from an untested route. Mark an uncertain observation as low confidence. Do not call a class clean unless the scan evidence covers it.

Do not use `run_prompt_loop` or `generate_report`. Keep raw scan results in the conversation context only, and write no report, progress file, or credential to disk.

## Report

Return structured output in this order:

1. **Scope:** normalized URL, validation classification, scan type, and non-destructive limit. Never show credentials.
2. **Coverage:** scanned endpoints or surfaces, completed check classes, request-failure counts, and each blocked or untested class.
3. **Findings:** highest severity first, each with title, severity, confidence, category, evidence, impact, and remediation. State `No verified findings` when the evidence supports none.
4. **Next action:** the one highest-value remediation, or the exact operator action that unblocks coverage.

Do not create a report solely to preserve output: the calling agent owns structured reporting and the reasoning that follows.

## Completion conditions

The scan is complete only when every condition holds:

- The calling agent recorded explicit authorization and exact scope.
- `validate_target` allowed the exact scan URL before the only scan call.
- The scan completed, or the result names the concrete failure.
- The prompt registry was weighed against the returned evidence.
- Every published finding carries evidence and confidence.
- The report states coverage, gaps, and whether credentials were supplied, without disclosing them.

A scan proves nothing about whether the target is secure — only the coverage the tools returned and the evidence reviewed in this run.
