# Review: the research workflows

Plan review, code review, disprove pass and QA of the Research workflow and its two tools, Critical
stakes (the router row, the playbooks and `.agents/hooks/lib/agent_records.py` are contract and hook
files). Plan and its dispositions: `docs/notes/2026-11-25-research-workflow-plan.md`.

Covers: 38595b7..607b23d

Artifact reviewed: the Research row and playbooks (`AGENTS.md`, `.agents/playbooks/workflow-research.md`,
`research-project.md`, `review-axes-results.md`), `workloop.py save-reply` (`.agents/workloop_cells.py`,
`.agents/hooks/lib/agent_records.py`, `.agents/test-save-reply.py`) and the `research-claims` skill. The
commits are `d1cb496`, `dc9f379`, `ac93f62` and `4f12004` as delivered, and the fixes `6b88902`,
`e49b6bc`, `a5fb70e`, `4b850c7` and the commit that holds the contract fixes below. The cells' reports
are kept word for word in `.agents/worktrees/.closed/science-workflows/.workloop/replies/` (code review
sha256 `45f68447…`, QA `f562d666…`, disprove pass `4f4aac6e…`).

## Plan review

One `reviewer` cell on `opus` read the plan before any code: nine `P1` and nine `P2` findings, all
dispositioned in the plan's "Review of this plan" (adopted, with one conflict resolved by dropping a
stakes clause that contradicted the root rule).

## Code review: `CONFORMANCE: no`, `EFFECTS: none`, three `P1` and fourteen `P2`

| # | Finding | Disposition | Evidence after the fix |
|---|---|---|---|
| 1 | P1. `save-reply` saved a turn the agent ended to wait on its own background command as the final report | Adopted: `final_report` asks `_waiting` before it takes plain answer text | Test case `c9`; replacing the check with `False` turns it red; the disprove pass reproduced the defect on `953447b` |
| 2 | P1. The Delegate row told read-only cells to write `papers_needed.csv` | Adopted: a cell names each paper in its reply, the lead adds the rows | Disprove pass: the gate denied Write, Edit and NotebookEdit at every target |
| 3 | P1. The playbook called the project folder a product folder, which the grant never covers for a git repository | Adopted: a separate repository, and a writer cell opens with `WORKSPACE: <path>` | Disprove pass: no grant for any write inside a sibling repository, whether it sits beside the checkout or around it |
| 4 | P2. The Research stakes clause contradicts "never the destination of its output"; Disposable conflicted with the root definition | Adopted: the root sentence says "except where a workflow row sets its own"; Disposable means scratch only | Routing probes on the final text (below) |
| 5 | P2. A digit group or a decimal comma passed as a whole number (`5` in `5,000`) | Adopted | Cases `separated.csv`; removing the lookbehind turns one red |
| 6 | P2. Prose lint false negatives: one `literal` exempted the whole line; `$5.50 and $3.20` read as math; `2.5x`; `.05` | Adopted, all four | Case `narrow.Rmd` |
| 7 | P2. A final answer split over several records kept only the last block | Adopted: the text blocks of every record of the newest message | Case `c10`; mutation red |
| 8 | P2. The default file name repeats per round; a closed run moves the path `status` prints; a missing checkout was recreated | Partly adopted: the name carries the agent's id, the playbook saves into the project with `--to`, a missing checkout is refused. Not changed: `status` still prints a moved path for a closed run | Cases `c1-a2.txt`, `deleted-checkout`; the residual is a breadcrumb |
| 9 | P2. A fixed `.partial` name collides; a corrupt line raised; an empty rejected hand-back blocked the real one | Adopted, with one decline: `agent_effects.write_atomic` takes text and the report is bytes, so the command writes through its own unique temporary file | Cases `c11`, `c12`, `c13`, no temporary file left |
| 10 | P2. `save_as` named a path inside the paper folder; paper-fetch treats it as an inbox | Adopted: `data/raw/papers/<key>.pdf` | Read against `scripts/paper-fetch/README.md` |
| 11 | P2. Names that do not resolve: `claims.py` without a path, `just`, the paper-fetch tool, the results axes in the dispatch | Adopted: full paths, `make reproduce`, `scripts/paper-fetch/papers.py`, the axes named in the dispatch | Read |
| 12 | P2. The skill's model ledger row held an ellipsis its own checker rejects | Adopted | Skill text; case in `test-claims.py` |
| 13 | P2. A charter key "left out takes the value shown" for a placeholder; "tools create nothing" | Adopted | Read |
| 14 | P2. Line numbers shift after a quote that spans lines | Adopted: the row's start line | Case `multiline.csv` |
| 15 | P2. Three invisible characters written literally in `source_text.py` | Adopted: written by code point | A case reads the file |
| 16 | P2. `agent_records.py` is 360 lines; the config-folder lookup has four copies | Deferred: breadcrumb | — |
| 17 | P2. The plan's Status line said the contract was unapplied | Adopted | Read |

The two ambiguities resolved: the Delegate row's reading is (b), and Standard QA runs when the report
states an estimate. The reviewer's QA handoff was run (below).

## Disprove pass

A `sonnet` QA cell tried to reproduce findings 1 to 3 from a clone at `953447b`, outside the checkout.
All three came back `confirmed`, each with the command and its output. The existing
`test-parallel-writers.sh` row passed in the same run.

## QA: acceptance 1 to 11 of the plan

An independent `qa-verifier` cell reproduced lines 1 to 10; line 11 it could not find, and the lead ran
it: `source_text.py` under `python3 -I` from another folder prints the page text with exit 0, and the
claims tests run `claims.py` that way. Line 6 used the real transcripts of this run: the six saved
reports match the acceptance counts and hash prefixes. The cell also found:

- every refusal exits 1, not 2, so the plan says 1;
- a symlinked text file inside a source folder was followed out of the sources folder: fixed;
- a hand-back with a non-text message, a missing ledger, a missing report, a non-UTF-8 report and a
  missing `--sources` folder gave tracebacks: each is now a named error with exit 1;
- `1.0` matches the `1.0` of `-1.0` because a hyphen is a boundary: the skill says to write the sign;
- indented code is read as prose, and several text blocks of one answer join with a newline: accepted.

Not verified by QA: the "every folder searched" text with several config folders (a test case covers
it now), and no system log was read because no system was involved.

## Experiments on the Research workflow

**Results review axes, with the answer key out of reach.** Four reviewer cells read a scratch copy of the
other session's report and results, not its repository. Two used `review-axes-results.md` and two the old
`review-axes.md`. A separate cell graded them blind against the original review's 31 defects. The plan
fixed the pass line before the run: each axes reviewer finds at least 8 of 12 chosen defects, and the
means differ by at least 3. **That line was not met.** The two with the new axes found 5 and 6 of the 12,
the two with the old found 3 and 3: a lead of 2.5. Against all 31 defects: 9 and 12 against 4 and 4. No
reviewer found D5, D10, D12, D17 or D25, so 8 was out of reach: two need the source papers, two need a
rerun of the R model with warnings on. The 12 were chosen without checking that a reviewer could see
them. The result is that the axes find about twice as many defects, not that they reach a fixed count.

**Routing on the final text.** The CABG prompt of the other session opens with
`Workflow: Research · Stakes: Critical` in 3 of 3 fresh sessions on the landed text (one Opus, two
Sonnet), 2 of 2 Sonnet sessions on the final text, and 2 of 2 on Fable 5.2, whose first call is a Read
of `workflow-research.md`. The present contract (before the row) gave `Spec · Standard` and
`Write · Standard` in two Sonnet runs. A market-research prompt routes to Spec (Standard once,
Disposable once on the final text; the present contract gave Disposable) and a feature prompt to Build
at Standard, so neighbouring routes did not move.

## Checks

`lint-contract.py` reports 23,142 of 24,000 bytes. `lint-skills.sh` reports 22 skills clean. Both new
tests are in `check-all.sh` and `ci.yml`, and `lint-suite.py` agrees. The full suite
(`.agents/suite.sh`) runs on the tree that holds this record; `suite.sh` stores the tree it passed on,
which `owed.py` reads.
