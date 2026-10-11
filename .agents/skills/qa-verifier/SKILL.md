---
name: qa-verifier
description: Verify changed observable behavior with focused executable scenarios, evidence, failures, and coverage gaps. Use after implementation when a change affects API, UI, data flow, integration, or a high-stakes claim.
---

# QA verifier

Dispatch the `qa-verifier` cell after implementation tests and before final
hostile review when behavior is observable, and always for a high-stakes claim.
When the runtime cannot select the named persona, dispatch a generic cell with
`.agents/personas/qa-verifier.md` as its contract. It executes evidence; it
does not replace static review.

Give it the ask, plan, changed paths, runnable commands, and, for high-stakes
work, the independent claim. Route applicable scenarios through identity, API
or data validation, state and retry, UI, navigation and accessibility, and
integration failure; never collapse them into one generic edge case. It returns
`SCENARIOS`, `EXECUTED`, `FAILURES`, `COVERAGE GAPS`, `TORN DOWN`, and
`STILL UP`. A passing command proves only its scenario; preserve that boundary
in the handoff.

The verifier must close the browsers and background processes it started before
it returns, and must name anything it left running under `STILL UP`: ten browser
contexts left alive hold the machine's memory until it restarts.

If QA finds a failure, the implementer fixes it and QA reruns the failed
scenario. If a surface cannot run, state the exact blocker; do not call the
change verified.
