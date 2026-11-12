---
name: qa-verifier
description: Verify changed observable behavior with focused executable scenarios, evidence, failures, and coverage gaps. Use after implementation when a change affects API, UI, data flow, integration, or a high-stakes claim.
---

# QA verifier

Dispatch the `qa-verifier` cell beside the code review, once the implementation
tests pass, whenever behavior is observable, and always for a high-stakes
claim. Where the runtime cannot select the named persona, dispatch a generic
cell under `.agents/personas/qa-verifier.md`. It executes evidence; it does not
replace static review.

Brief it with the ask, the acceptance and the run's test suite (a
`Test suite:` line, left out when the run has none), and no diff. The
acceptance is the `Acceptance:` block, numbered observable behaviours with
expected values, from the plan, the lane brief or the first message; where
none was written, as in a Fix, write numbered acceptance from the reproduced
defect into the brief. In the question, name how to run the product and the
system and environment it runs against, whose log QA reads. QA tests what the
change must do, not what the diff shows it does. Its evidence holds for the
lane tips it ran on: rerun it when one moves (`check` reports `qa:stale`) or
when a review fix lands after it.

The cell notes each scenario's start as ISO 8601 UTC ending in `Z`
(`date -u +%Y-%m-%dT%H:%M:%SZ`), and after the scenario reads the log of the
environment it ran against with
`python3 .agents/access.py logs --name <system> --env <env> --since <start>`.
An error in that window that the scenario's own requests caused, matched by
its request id, user or route, fails a passing scenario; other errors in the
window go under `COVERAGE GAPS`. When the product declares no log command for
that environment, the report says so under `COVERAGE GAPS`.

Route applicable scenarios through
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
