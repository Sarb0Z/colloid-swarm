---
name: qa-verifier
description: Verify changed observable behavior with focused executable scenarios, evidence, failures, and coverage gaps. Use after implementation when a change affects API, UI, data flow, integration, or a high-stakes claim.
---

# QA verifier

Dispatch the `qa-verifier` cell between the implementation tests and the final
hostile review whenever behavior is observable, and always for a high-stakes
claim. Where the runtime cannot select the named persona, dispatch a generic
cell under `.agents/personas/qa-verifier.md`. It executes evidence; it does not
replace static review.

Brief it with the ask, plan, changed paths, runnable commands, and, for
high-stakes work, the independent claim. Route applicable scenarios through
identity, API or data validation, state and retry, UI, navigation and
accessibility, and integration failure, each on its own axis, never folded into
one generic edge case. It returns `SCENARIOS`, `EXECUTED`, `FAILURES`,
`COVERAGE GAPS`, `TORN DOWN`, and `STILL UP`. A passing command proves only its
scenario; keep that boundary in the handoff.

Before returning, the verifier must close the browsers and background processes
it started and must name under `STILL UP` anything left running: ten live
browser contexts hold the machine's memory until it restarts.

A failure returns to the implementer, and QA reruns the failed scenario. If a
surface cannot run, state the exact blocker and withhold "verified".
