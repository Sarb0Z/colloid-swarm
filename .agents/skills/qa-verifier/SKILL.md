---
name: qa-verifier
description: Verify changed observable behavior with focused executable scenarios, evidence, failures, and coverage gaps. Use after implementation when a change affects API, UI, data flow, integration, or a high-stakes claim.
---

# QA verifier

Use the `qa-verifier` subagent after implementation tests and before final
hostile review when behavior is observable; always use it for a high-stakes
claim. When the runtime cannot select the named persona, dispatch a generic
cell with `.agents/personas/qa-verifier.md` as its contract. It executes
evidence. It does not replace static review.

Give it the ask, plan, changed paths, runnable commands, and the independent
claim for high-stakes work. Route applicable scenarios through identity, API or
data validation, state/retry, UI/navigation/accessibility, and integration
failure; do not collapse them into one generic edge case. It returns
`SCENARIOS`, `EXECUTED`, `FAILURES`, and `COVERAGE GAPS`. A passing command
proves only its scenario; preserve that boundary in the handoff.

If QA finds a failure, the implementer fixes it and QA re-runs the failed
scenario. If a surface cannot run, state the exact blocker; do not call the
change verified.
