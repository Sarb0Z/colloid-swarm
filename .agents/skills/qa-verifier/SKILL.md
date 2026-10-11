---
name: qa-verifier
description: Verify changed observable behavior with focused executable scenarios, evidence, failures, and coverage gaps. Use after implementation when a change affects API, UI, data flow, integration, or a high-stakes claim.
---

# QA verifier

Dispatch the `qa-verifier` cell after the implementation tests and before the
final hostile review whenever behavior is observable, and always for a
high-stakes claim. Where the runtime cannot select the named persona, dispatch
a generic cell with `.agents/personas/qa-verifier.md` as its contract. It
executes evidence; it does not replace static review. The implementer's green
suite is the implementer's claim, and this cell exists to observe it from
outside.

Give it the ask, the plan, the changed paths, the runnable commands, and, for
high-stakes work, the independent claim. Route applicable scenarios through
identity, API or data validation, state and retry, UI, navigation and
accessibility, and integration failure; do not collapse them into one generic
edge case, which tests whichever axis came to mind first and passes the rest
by silence. It returns `SCENARIOS`, `EXECUTED`, `FAILURES`, `COVERAGE GAPS`,
`TORN DOWN`, and `STILL UP`. A passing command proves only its scenario;
preserve that boundary in the handoff, or the next reader mistakes one green
line for a verified change.

The verifier must close the browsers and background processes it started
before it returns, and must name anything it left running under `STILL UP`.
Verification is short and its resources outlive it: a run that leaves ten
browser contexts alive holds the machine's memory until it restarts.

If QA finds a failure, the implementer fixes it and QA reruns the failed
scenario. If a surface cannot run, state the exact blocker; do not call the
change verified. An unrun scenario is a gap, never a pass.
