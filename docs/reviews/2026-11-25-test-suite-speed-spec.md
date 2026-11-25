# Review: the test-suite speed plan

Artifact: `docs/notes/2026-11-25-test-suite-speed-spec.md`, a plan; no code,
so no `Covers:` range. Stakes: critical.

## Round 1

Reviewer: hostile-review cell (fan-out `fanout-7782b7a5-…`, cell
`toolu_01cbcsq8hvo7ev1lghcc32yf`), static plus probes in a scratch clone.
Conformance: no. 6 P1, 11 P2.

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | A bash runner's `&` starts checks with SIGINT/SIGQUIT ignored; `test-suite-runner.sh` fails "an interrupt must end suite.sh" | Adopt: lead reproduced it (serial rc 130; `&` prints `child-not-interrupted`). Runner in Python, signals reset per check; acceptance 3, 4 |
| 2 | P1 | A 900 s verify default applies to every repository running the controller | Adopt: default stays 1,800 s; old acceptance 12 dropped |
| 3 | P1 | Ceilings beside list lines break `lint-suite.py`'s `CHECK` pattern; CI runs per-check steps, not `check-all.sh` | Adopt: lead confirmed `lint-suite.py:57,80`. List format unchanged; exceptions in `check-budget.json`; CI out of this unit (breadcrumb); acceptance 12 |
| 4 | P1 | Per-check CPU ceiling does not gate the bar: waits cost no CPU, splits reset it, no hung-check limit | Adopt: per-check wall-clock limit, total budget, timed-out state; acceptance 7, 8 |
| 5 | P1 | Wall-clock rows go flaky under `-j 8`; "assert the process stopped" weakens rows whose bound is the behaviour | Adopt: env-set bounds still asserted plus one production-default row (M4, acceptance 11); five runs in a row (acceptance 1) |
| 6 | P1 | At load 70, 1,482 CPU-s takes ~30 min whatever `-j`; acceptance at "load under 8" cannot be observed | Escalate: Decision 1; arithmetic in "What ten minutes takes" |
| 7 | P2 | Findings 6, 7, 10 labelled observed are inferences | Adopt: relabelled (rows 8, 9); scrapling cause open (M2) |
| 8 | P2 | Lazy-import saving measured on `--help`; launch count unsupported | Adopt: row 6 corrected (59 ms, not 585); M1 profiles CPU by process kind; acceptance on `--help` dropped |
| 9 | P2 | `ok` count is 160, not 159 | Adopt: lead confirmed 160 on log 11; acceptance 10 counts from the base commit |
| 10 | P2 | Sections of `test-workloop.sh` share state; the split is not along seams | Adopt: map shared state before any split (change 3) |
| 11 | P2 | A timing table at the end pushes `FAILED:` out of `run_verify`'s 40-line tail | Adopt: table to a file; `FAILED:` last and matching `FAILURE_LINE`; acceptance 5 |
| 12 | P2 | CPU per check: orphan escape, measurement tool, E-cores, sys inflation | Adopt: `os.wait4` per check; M3 measures load sensitivity before Decision 2 |
| 13 | P2 | A closed port-0 probe races under parallel checks | Adopt: hold the port bound without listening (change 3) |
| 14 | P2 | A 61 CPU-s fixture burns a minute per runner test | Adopt: 0.5 CPU-s fixture ceiling (acceptance 6) |
| 15 | P2 | Ceilings measured here ship to satellites | Adopt: no `check-budget.json`, no budget (acceptance 13) |
| 16 | P2 | Per-check logs inside the tree trip `suite.sh` or dirty a lane | Adopt: logs in `mktemp -d` outside the tree (acceptance 9) |
| 17 | P2 | A 60 CPU-s ceiling is not derived from the bar | Adopt: values derived after M1-M3 and measured runs |

HANDOFF (qa-verifier, measurements): taken as change 0, M1-M4.
AMBIGUITY (load for the bar): Decision 1.

Round 2 is due on the revised plan once the operator rules on Decisions 1-3.
