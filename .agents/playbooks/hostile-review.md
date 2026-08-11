# Hostile review

Dispatch the independent `reviewer` cell for the plan before implementation and
the diff after it. Supply the ask verbatim, the plan, and the artifact. Use the
heavy tier for the runtime.
<!-- colloid-only -->
Under Claude do not prepend a genome because the hook injects one. Other
engines prepend exactly one fresh stamp.
<!-- /colloid-only -->

Send the contract below verbatim with the artifact to review. Do not paraphrase
it.

## Reviewer contract

````
Review this artifact against the repository, not against its own claims. No
praise, filler, or invented findings. State uncertainty plainly.

## Authority

Read, in order: applicable `AGENTS.md`; the stated ask; the plan; artifact
claims. A lower source cannot override a higher one. Report disagreement or
missing intent; do not infer a specification from code. For a high-stakes
change, verify that QA independently reproduced the named claim and that its
evidence supports it; do not substitute static inference for missing execution.

## Static sweep

Read `.agents/playbooks/review-axes.md`; if it is unavailable, stop and report
that blocker. Work each applicable group. This is a static review: inspect
contract, state, security, scale, and structure. Do not claim runtime behavior
you did not execute. If changed observable behavior lacks QA evidence, report
that as a coverage gap and hand it to `qa-verifier`.

Report these measurements when crossed: file >300 lines; function >40 lines;
nesting >4; signature >4 parameters; module >12 public entries; third copy of
behavior. For loop work, report N, per-item cost, and runs/day; a missing value
is a finding, not an assumption.

## Report

Open with `CONFORMANCE: yes|no|unknown — <reason>`. Then one numbered list,
each item `file:line — defect; consequence; fix`, ordered by cost to leave.
Name groups worked and skipped. Close with zero or more exact lines:

```
AMBIGUITY: <requirement> — (a) <reading>; (b) <reading>; code: <a|b|neither>.
HANDOFF: qa-verifier — <missing executable evidence>
HANDOFF: scalability-audit — <unresolved system-scale trigger>
```

No ambiguity means no `AMBIGUITY:` line. Do not run a scalability audit from a
diff; hand it off only when the diff exposes an unresolved live-data question.
````

Disposition every finding: adopt, decline with reason, file as a breadcrumb or
debt, or escalate a user decision. Fixes receive re-review. After three rounds
where the same shape returns, stop patching and bring the architecture decision
to the user.
