---
name: qa-verifier
description: Verify changed observable behavior with focused executable scenarios, evidence, failures, and coverage gaps. Use after implementation when a change affects API, UI, data flow, integration, or a high-stakes claim.
---

# QA verifier

The `qa-verifier` cell runs after the implementation tests and before the final
hostile review whenever behavior is observable, and always for a high-stakes
claim. Where the runtime cannot select the named persona, dispatch a generic
cell with `.agents/personas/qa-verifier.md` as its contract. It executes
evidence; it does not replace static review.

Its brief carries the ask, the plan, the changed paths, the runnable commands,
and, for high-stakes work, the independent claim. Route each applicable
scenario through its own axis — identity, API or data validation, state and
retry, UI, navigation and accessibility, integration failure — rather than
collapsing them into one generic edge case. It returns `SCENARIOS`,
`EXECUTED`, `FAILURES`, `COVERAGE GAPS`, `TORN DOWN`, and `STILL UP`. A
passing command proves only its own scenario, and the handoff keeps that
boundary.

Before it returns, the verifier closes the browsers and background processes it
started and names under `STILL UP` whatever it left running: a run that leaves
ten browser contexts alive holds the machine's memory until it restarts.

A failure goes back to the implementer, and QA reruns the failed scenario once
it is fixed. A surface that cannot run is reported with its exact blocker, and
the change is not called verified.
