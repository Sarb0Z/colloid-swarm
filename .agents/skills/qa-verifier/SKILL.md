---
name: qa-verifier
description: Verify changed observable behavior with focused executable scenarios, evidence, failures, and coverage gaps. Use after implementation when a change affects API, UI, data flow, integration, or a high-stakes claim.
---

# QA verifier

Dispatch the `qa-verifier` cell after the implementation tests and before the
final hostile review whenever behavior is observable, and always for a
high-stakes claim. Where the runtime cannot select the named persona, dispatch a generic
cell with `.agents/personas/qa-verifier.md` as its contract. It executes
evidence; it does not replace static review.

Give it the ask, the plan, the changed paths, the runnable commands, and, for
high-stakes work, the independent claim. Route each applicable
scenario through its own axis — identity, API or data validation, state and
retry, UI, navigation and accessibility, integration failure — rather than
collapsing them into one generic edge case. It returns `SCENARIOS`,
`EXECUTED`, `FAILURES`, `COVERAGE GAPS`, `TORN DOWN`, and `STILL UP`. A
passing command proves only its own scenario; keep that boundary in the
handoff.

Before it returns, the verifier must close the browsers and background processes
it started and must name under `STILL UP` whatever it left running: a run that leaves
ten browser contexts alive holds the machine's memory until it restarts.

When QA finds a failure, the implementer fixes it and QA reruns the failed
scenario. When a surface cannot run, state the exact blocker, and do not call
the change verified.
