# Hostile review

Dispatch the independent `reviewer` cell for the plan before implementation and
the diff after it. Supply the ask verbatim, the plan, and one immutable artifact:
pasted content, a diff or tree digest, or an authorized commit. Never commit
merely to make a review checkpoint. Choose the reviewer's model at dispatch for the artifact at hand; the persona pins none.
<!-- colloid-only -->
Claude and Codex inject a genome on `SubagentStart`; do not prepend another.
Kimi discards start-hook output, so prepend exactly one fresh stamp there.
<!-- /colloid-only -->

Send the contract below verbatim with the artifact to review. Do not paraphrase
it.

## Reviewer contract

````
Review this artifact against the repository, not against its own claims. A
name, comment, or docstring is a claim: verify it against the code it
describes. No praise, filler, or invented findings. State uncertainty plainly.

## Authority

Read, in order: applicable `AGENTS.md`; the stated ask; the plan; artifact
claims. A lower source cannot override a higher one. Report disagreement or
missing intent; do not infer a specification from code. For a high-stakes
change, verify that QA independently reproduced the named claim and that its
evidence supports it; do not substitute static inference for missing execution.

## Static sweep

Read `.agents/playbooks/review-axes.md` and the Review lenses in
`.agents/lenses.md`; if either is unavailable, stop and report that blocker.
Work each applicable group and apply each lens the artifact can exhibit.
Report every defect you find; the lead dispositions each one. This is a static review: inspect
contract, state, security, scale, and structure. Do not claim runtime behavior
you did not execute. If changed observable behavior lacks QA evidence, report
that as a coverage gap and hand it to `qa-verifier`.

Report these measurements when crossed: file >300 lines; function >40 lines;
nesting >4; signature >4 parameters; module >12 public entries; third copy of
behavior. For loop work, report N, per-item cost, and runs/day; a missing value
is a finding, not an assumption.

## Report

Open with `CONFORMANCE: yes|no|unknown — <reason>`, then `EFFECTS: <observed
scarce, privileged, or irreversible actions, none, or unknown>`. Do not infer a
runtime effect from source. Follow with one numbered list using this exact
decision schema, ordered by cost to leave:

`[P0|P1|P2 / <class>] <file:line|artifact:section> — evidence:<reproduced|live|inspection|theoretical>; recurrence:<observed:evidence|not-found:sources|unknown:gap>; trigger:<state or event>; risk:<worst credible consequence>; fix:<narrow correction>; next:<operation and authorization>; residual:<remaining uncertainty>; cost:<implementation/review cost>; recommendation:<fix|accept|defer|redesign|stop>`

Each finding states the rule or invariant the artifact breaks, not a
description of what the code does.

`P0` and `P1` block the round. The artifact does not proceed until the lead
adopts, declines, or escalates each one. `P2` does not block. File it and
continue. Fix a `P2` only when the lead already changes that code.

Severity states the worst credible consequence. It does not state your
confidence. A finding with `evidence:theoretical` must not exceed `P2`.

A review that finds nothing is a result. Write `FINDINGS: none` in place of the
list. Do not add a `P2` observation to a clean review. A finding you cannot
defend costs the lead more time than it saves.

Name groups worked and skipped, and each lens that produced a finding. Close
with zero or more exact lines:

```
AMBIGUITY: <requirement> — (a) <reading>; (b) <reading>; code: <a|b|neither>.
HANDOFF: qa-verifier — <missing executable evidence>
HANDOFF: scalability-audit — <unresolved system-scale trigger>
```

No ambiguity means no `AMBIGUITY:` line. Do not run a scalability audit from a
diff; hand it off only when the diff exposes an unresolved live-data question.
Ask for one verdict only when the user must decide. Never bundle authorization
for the current correction with a later live, privileged, destructive, or
scarce operation.
````

The lead dispositions every finding: adopt, decline with reason, file unresolved
work as a breadcrumb, record an accepted tradeoff in debt, or escalate a user
decision. A decline cites evidence the reviewer can check, such as a file, a
line, or a recorded ruling; "this was intentional" is not evidence. A finding
that rests on a fact neither the lead nor the reviewer can check goes to the
user, not to a decline; a fact the lead can check, it checks. A reviewer that
errors, stops early, or returns no report has not run: dispatch it again or
report the gap, and never count it as `FINDINGS: none`. External evidence alone belongs in knowledge. A round's one ledger is
`docs/reviews/<date>-<slug>.md`, carrying one line `Covers: <base>..<tip>` per
lane, both ends commit hashes of at least seven hexadecimal digits: `owed.py`
reads it to tell which content of a critical-path file a review covered, and a
record covers a file only when its range touched the file. A record end that
is not a hash, such as `HEAD` or a branch name, or that git cannot resolve,
covers nothing. After folding a round's `P1` and `P2` fixes the lead moves the
record's tip to the new commit; a `P0` fix gets a new round and its own
record. Create no second
review ledger beside it. A recurrence claim must cite the current rounds or explicit Git,
breadcrumb, or debt evidence; otherwise report `not-found` with the consulted
sources or `unknown`, never “first occurrence.” The two rules on checkable
declines and on reviewers that have not run are adapted from Google's
elephant-goldfish-model under Apache-2.0;
`.agents/licenses/elephant-goldfish-model-APACHE-2.0.md` quotes the source and
lists the changes.

Do not repeat a completed review in the active context while the ask, plan, and
artifact are unchanged and every finding is dispositioned. A changed artifact
or new evidence reopens review. Review a slice one time. A fix re-enters review
only when it resolves a `P0`, or when it lands in a subsystem the round did not
cover. A `P2` fix does not reopen a round. When the same class recurs,
identify the shared subsystem and compare cumulative patch complexity
with redesign; separate deadline containment from the long-term architecture.
After three rounds where the same shape returns, stop patching and bring that
decision to the user.

Code review runs at the boundary of a delivered scope, over all its chunks; a
chunk gets no reviewer of its own. A multi-lane wave gets one review round,
over every lane's diff from the start point its reviewer brief names, and one
report with a section per lane that each lane's `workloop review` cites; every
reviewer of the round, an axis reviewer included, reads every lane. The controller refuses to reopen a lane for a `P2`, and a lane's
fourth submission without the operator's ruling.

## Review of the review

Critical stakes add one pass after the code review and before the lead's
dispositions. A second cell, given the artifact and the findings but not the
first reviewer's reasoning, labels each finding supported or unsupported, with
a reason. It never removes a finding. Every `P0` or `P1` it labels unsupported
goes to the operator's walk-through with that reason, so the operator sees every
blocking finding. The code review, its axis reviewers where the work splits by
axis, and this pass count as one round.
