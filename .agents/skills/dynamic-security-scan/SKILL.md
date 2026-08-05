---
name: dynamic-security-scan
description: >
  Performs an authorized, non-destructive dynamic security scan of an exact localhost or
  allowlisted staging target through the native security-mcp tools. Use for "dynamic security
  scan", "DAST", "scan localhost", "scan staging", or an explicitly authorized live-target
  security assessment. It validates the target before scanning, analyzes returned evidence without
  inventing findings, and reports coverage gaps without storing credentials.
---

# Dynamic Security Scan

Use this skill only for a dynamic scan. Use `security-audit` or `pentesting` for source-only work.

## Authorization Gate

Before any MCP call, state the authorized scope in the conversation:

- Exact target URL and permitted environment.
- Operator authorization to test that target now.
- Non-destructive test limit and approved scan depth.
- Whether the operator supplied credentials. Do not repeat tokens, cookies, or headers.

Ask for the missing authorization. Do not infer it from repository access, a hostname, or a user role.

## Run the Scan

1. Call `validate_target` with the exact target URL.
2. If it returns `allowed: false`, stop. Report only the validation reason and the missing authorization or configuration that the operator must supply. Do not call `security_scan`, follow redirects, or make another request to that target.
3. If it returns `allowed: true`, retain its normalized URL and classification. Call `security_scan` once with that normalized URL, an approved `quick`, `standard`, or `deep` scan type, and only operator-supplied credentials. Never enable a server-side prompt loop.
4. Call `list_security_prompts`. Select prompts that match the returned attack surface and scan scope.
5. Reason over the returned evidence yourself. A finding must cite evidence from the scan result, identify the endpoint or surface, set severity and confidence, describe impact, and give a remediation. Do not infer a vulnerability from an untested route. Mark uncertain observations as low confidence. Do not claim a class is clean unless the scan evidence covers it.

Do not use `run_prompt_loop` or `generate_report`. Keep raw scan results in the conversation context only. Do not write reports, progress files, or credentials to disk.

## Report

Return structured output in this order:

1. **Scope:** normalized URL, validation classification, scan type, and non-destructive limit. Never show credentials.
2. **Coverage:** scanned endpoints or surfaces, completed check classes, request-failure counts, and each blocked or untested class.
3. **Findings:** highest severity first. Include title, severity, confidence, category, evidence, impact, and remediation. State `No verified findings` when evidence supports none.
4. **Next action:** the one highest-value remediation or the exact operator action that unblocks coverage.

Do not create a report solely to preserve output. The calling agent owns structured reporting and follow-up reasoning.

## Completion Conditions

Complete only when all conditions hold:

- The caller recorded explicit authorization and exact scope.
- `validate_target` allowed the exact scan URL before the only scan call.
- The scan completed, or the result names the concrete failure.
- The prompt registry was considered against returned evidence.
- Every published finding has evidence and confidence.
- The report states coverage, gaps, and whether any credentials were supplied without disclosing them.

The scan does not prove that the target is secure. It proves only the returned tool coverage and the evidence reviewed in this run.
