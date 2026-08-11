# Review harness

Run the shipped hostile-review contract against real code with the whole
repository present. Check that it flags conformance and finds real defects.

## Why this exists

`fixtures/review-episodes/` holds 41 adjudicated findings, but each fixture
gives the reviewer a diff only. The reference findings were written with full
repository access over several rounds. A reviewer with a diff cannot reach what
the reference author reached, so recall floors and the corpus cannot rank
anything.

This harness reconstructs the repository as the original reviewer saw it. The
difference is large. Reviewers here cite files three hops outside the diff.

## What it measures

The contract makes one line mandatory: a conformance statement before the
findings. `bin/score.py` reports whether each run produced it. That column is
the reason the harness runs.

Recall against the reference is reported too, as a descriptive column only.

CAUTION: Recall measures agreement with one earlier reviewer. It cannot
separate "found fewer defects" from "found different defects". Treat a low
number as a question, never as a verdict.

## Results so far

Eight runs across two fixtures, sonnet, one constant genome. Their reports are
`results/phase0/`, keyed by `results/phase0/blind-key.tsv`.

`runs.tsv` is the ledger `bin/run-review.sh` appends to, and it starts after
phase 0 — the eight runs above are not in it and cannot be backfilled honestly,
because no record holds the contract hash and base commit each one ran against.
Its two rows are runs that were materialised and never graded, which is what
`pending` says. Read `runs.tsv` for what the harness has measured since phase 0,
and this section for phase 0 itself.

- 4 of 8 runs opened with a conformance statement. A fifth stated one after a
  paragraph of process narration, which the mandatory line now rules out. Three
  of the four misses were on `cleanstack-web-disconnect-r1`. Re-measure after
  the next batch.

  NOTE: `score.py` detects the conformance line by keyword. That is crude and
  it disagrees with a careful read at the margin. Hand-check the column while
  the sample is this small.
- Recall was 1 of 12 on the best-documented fixture, below the diff-only
  baseline of 3.00. The unmatched findings were real. One run found that
  `clear_and_delete_domains` swallows `SoftTimeLimitExceeded` in a broad
  `except`, where `backend/database.py:114` and
  `backend/workers/dns_health_worker.py:1049` re-raise it on purpose.
- All four `cleanstack-web-disconnect-r1` runs found that `.btn--danger` is
  undefined, so the destructive confirm button renders as the primary action.
  That defect is absent from the 8-entry reference.

Raw reports are in `results/phase0/`.

## Run one review

```sh
bin/extract-contract.sh                          # sync contract.md with the shipped file
bin/run-review.sh <fixture> <replicate>          # materialise, print the prompt
# dispatch a subagent with that prompt; save its returned text to report.md
bin/build-reference.py ../../fixtures/review-episodes/<fixture>/ground-truth.md ref/<fixture>.md
bin/prepare-grading.py <fixture>                 # anonymise into a grading dir
# dispatch a grader with TASK.md; save its tables to grades.tsv
bin/score.py <fixture>
```

Scenario trees live under `$REVIEW_HARNESS_WORK`, default `$TMPDIR/rvw`. They
are not committed.

## Human evaluation

Automated scoring measures a proxy. The operator is the ground truth: they act
on the findings. So the primary evaluation is a blind human pick.

Present the reviews of one change side by side, labels shuffled, contract
identity held in `results/*/blind-key.tsv`. The operator picks the review they
would rather receive and states one line on why.

Record every verdict in `judgements.tsv` as `set, pick, criterion, note`. The
`criterion` column is the valuable one. "B is better" teaches nothing; "named
the failing constraint instead of a canned string" is a rule that transfers.

CAUTION: Do not rely on mining session transcripts for these verdicts later.
Write the row when the judgement is made. Accumulated rows become the
calibration set for a preference judge, which is a different and more tractable
thing than a correctness oracle.

Keep batches small. Each report runs 1000 to 1500 words, so three of them is
real attention. Four sets that agree carry more weight than twelve rushed ones.

## Materialisation

DANGER: Never extract the tree at `commit_sha`. Four of the five artifacts are
working-tree snapshots taken at the moment of review dispatch. The commit that
followed folded the review fixes in. Its tree holds repaired code for the exact
defects the reviewer must find.

`run-review.sh` extracts at `base_sha` and applies the artifact. All three
`diff` artifacts apply clean. Both `file` artifacts have a target path that
exists at the base.

`fixtures-extra/` holds files an artifact carries as raw text instead of diff
hunks. `git apply` drops those silently, which removes real files from the
review and leaves a malformed tail in the diff.

Run directories are named by a hash. A reviewer reads its own working path, so
a path holding the fixture name tells it what it is reviewing. `index.tsv`
keeps the map, outside the tree.

## The reviewer prompt

The prompt must forbid `ReportFindings` and any other tool that emits findings.
Reviewers route findings there when it is available, which truncates the
returned report and makes finding counts unusable. Two of the first eight runs
were lost this way.

The prompt must also ask for text, not a file. A report the harness has to go
find is one that can be missing, half-written, or written where the grader does
not look; the returned text is the artifact.

## Intent files

`intents/<fixture>.md` reproduces what the original reviewer received, minus
the fixture machinery: session names, transcript line markers, `Review type:`
labels, and anything naming `ground-truth.md`.

WARNING: Do not strip defect vocabulary from these. The reference findings were
produced by a reviewer who read the original dispatch prompt.
`ms-domain-delete-fk-race` carries a list of binding requirements from an
earlier plan review, and several reference findings answer that list directly.
Removing it gives the reviewer less than the reference author had.

## Fixtures

`sources.tsv` maps each fixture to its repository, base commit, and apply mode.

`ms-unit0-quarantine-plan` has no tree. It is a plan document built on a stale
premise. No commit reproduces that on demand.

`muscle-app-rebrand-videos` is a 32-file rebrand, mostly documentation, and its
artifact edits `breadcrumbs.md` and `debt-log.md`. Those may name defects. Use
it last.

## Controls

- **Genome.** One persona, held constant, drawn with `--seed` into
  `genome.txt`. The current pick is EXTREMOPHILE: its text is posture, not a
  technical topic. MYCELIUM names FKs and dependencies, TARDIGRADE suppresses
  accessibility, QUASAR and SUPERNOVA bias toward rewrites.
- **Model.** One model for all runs. Record it.
- **No execution.** The reviewer reads. It does not build or test.
