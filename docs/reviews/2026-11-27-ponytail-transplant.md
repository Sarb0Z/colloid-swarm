# Review: ponytail transplant plan

Covers: 2e6c1df..8ad8af1

Round 1, plan review, by a Fable `reviewer` cell with the reviewer contract
verbatim. Artifact: `docs/notes/2026-11-27-ponytail-transplant-plan.md` at
`2e6c1df`. Verdict: `CONFORMANCE: no`, 10 `P1` and 8 `P2`, no `P0`.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | B3's closing line reaches reviewer and lane cells through `style-inject.sh`, against decision `unattended-gates-closing-line` | adopted: both sentences bind to the final message to the operator, and a report with a fixed form closes by that form; acceptance 6 added |
| 2 | P1 | The B1 and B2 fixtures touch money, which is Critical, so a session that obeys the contract stops before editing | adopted: the fixtures carry no money, authentication or data loss; callers sit in other files; tools and a time limit are stated |
| 3 | P1 | B3 has no exit when nothing was skipped, and it collides with `needs_confirmation:` lines | adopted: "none when nothing was skipped"; the line comes before any `needs_confirmation:` line; acceptance 4 has a real unverifiable part, and acceptance 5 is a no-op control |
| 4 | P1 | B2's ladder orders hand-written code over a dependency, against Craft's frameworks-and-generators rule | adopted: a rung for a maintained dependency or generator added through the package manager |
| 5 | P1 | B4 adds a second form beside Conduct's `Decision N of M` | adopted: B4 binds the walk-through to `Decision N of M` |
| 6 | P1 | B1's new sentence strands "that run" and orders the fix before the gate | adopted: the search goes after the exit sentence; the fix clause moves to "Then run Build…", with a route for callers that must differ; regression acceptance 2 added |
| 7 | P1 | F1 and F3 were false for TypeScript: `check_reports.py:51` already reports new errors outside the edited files | adopted after the lead re-read `post-edit-check.sh:350-357` and `check_reports.py:38-52`: Unit A is Python-only, and its advisory no longer claims what the type checkers miss in TypeScript |
| 8 | P1 | Unit A's design: 24% of definitions share a name, methods match, and bundles count as definitions | adopted: top-level definitions only, `.py` only, a stale import is always kept, a call only when no tracked file defines the name, and a `callers_check` toggle; acceptance 3 and 4 rewritten |
| 9 | P1 | The acceptance does not say what happens when the control equals the arm, B2 grades an unstated requirement, and the runs cover Opus only | adopted: a new B2 fixture with a helper to reuse, the negative-quantity criterion dropped, Sonnet arms for B1 and B2; the landing rule goes to the operator as Decision 2 |
| 10 | P1 | Unit A edits a gate hook's file listed in `owed.critical_paths` and was classed Standard | adopted: Unit A is Critical, and its toggle is read in write mode, not the shared prelude |
| 11 | P2 | B1 takes the open Stop-hook-or-drop choice without naming it | adopted: Decision 3 |
| 12 | P2 | The "lazy" slogan, a second wording of Errors fail loudly, no route for callers outside a lane | adopted: slogan cut; Errors fail loudly named, not restated; "report any outside your paths" added |
| 13 | P2 | Unit A's N, timeouts, cap order and misses unstated | adopted: one `git grep` per run, a 5-second timeout reported on stderr, the cap before the search, the misses listed |
| 14 | P2 | Unit A also changes the demo embeds and needs the full suite | adopted: embed, inventory, showcase and `.agents/suite.sh` close both units; the rule gets its own module |
| 15 | P2 | The findings table lacked its commit, a re-opened list, constraints and open questions | adopted |
| 16 | P2 | The byte budget leaves 171 bytes | accepted: a per-line allowance is stated |
| 17 | P2 | A save to the output style goes live machine-wide at once | adopted: drafts only in fixtures, one change after acceptance, revert by `git checkout`; the bullet sits after the approval bullets |
| 18 | P2 | `post-edit-check.sh` and its test are over 300 lines | accepted: the rule's logic lives in its own Python module |

## Unit A code review

Covers: f321b9c..9b16058

Round 1, code review of the `callers-advisory` lane, by an Opus `reviewer`
cell through the workloop reviewer brief. `CONFORMANCE: unknown`, 6 `P2`, no
`P0` or `P1`, so no disprove pass. QA (independent cell) passed the seven
acceptance lines, with a negative control on the pre-change hook.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| A1 | P2 | A function moved with a re-export left behind (`from util import total_price` in `lib.py`) still counts as removed, so working importers are reported as broken | adopted: a name the working tree still binds at column 0 is not removed; a case added |
| A2 | P2 | A name removed from `pkg/__init__.py` never matches `from pkg import name` | adopted: an `__init__.py` file's module is its folder; a case added |
| A3 | P2 | With the project below the repository root, `git show HEAD:<rel>` fails silently and the advisory is off | adopted: `HEAD:./<rel>`, and any failure other than a missing file is printed on stderr |
| A4 | P2 | Cases 2, 4, 5 and 6 pass on a hook that prints nothing | adopted: each negative case carries a positive control in the same run |
| A5 | P2 | Names past the cap of 8 go unsearched with no notice when the first 8 have no hits | adopted: the dropped-names line prints whenever names were dropped (the reviewer's AMBIGUITY 2, reading a) |
| A6 | P2 | `git grep` output split on `:` and decoded strictly; a `:` or non-ASCII path, or non-UTF-8 source, raises and loses the whole advisory | adopted: `git grep -z` and decoding with replacement |

The reviewer's AMBIGUITY 1 (whether an untracked file's definition cancels a
call hit) is settled by acceptance line 3, which moves the function into a new
untracked `util.py`: untracked definitions count. The controller does not
reopen a lane for a `P2`, so the lane is accepted at `9b16058` and the six
fixes trail it in one commit that names it.

## Plan review ambiguities

The plan reviewer's two `AMBIGUITY:` lines went to the operator: the landing rule
(Decision 2) and Unit A's stakes, which the lead settled at Critical as the
higher level. Its `HANDOFF: qa-verifier` is the fresh-session acceptance,
which runs after the operator's OK on the plan.

## Unit B code review

Covers: f321b9c..ca3d3db

Round 1, code review of the landed contract text (`AGENTS.md` Fix and
Communication lines, the output-style bullet), by an Opus `reviewer` cell with
the reviewer contract verbatim. `CONFORMANCE: no`, 2 `P1` and 5 `P2`. Both
`P1` rest on inspection of the contract text itself, which the lead re-read, so
the disprove pass has nothing to run.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| B1 | P1 | The restored "before changing code" contradicts `.agents/AGENTS.md`'s "enforce a statement's timing with a hook, or drop the timing", the rule that removed it on 11-10 | adopted: that rule now names the exception and its evidence, worded without the carrier-only decision name because the kit leaves `decisions.md` out |
| B2 | P1 | The Fix paragraph as landed, and the regression case, were never run whole; the closing line ran in draft form | adopted: a QA rerun on the landed text (B1 on Opus and Sonnet, the regression on Opus, B3 with and without the output style) |
| B3 | P2 | The fix clause sits before "the most recent change is the first hypothesis" | declined on evidence: this order is the one the third wording was tested in (shared fix 4 of 4 against 1 of 8, red command first held on Opus); the rerun's regression case did not test this branch: its `export.py` truncates the file before writing, so both runs built a red test (one then fixed after it, as the Fix line orders); a fixture whose defect the code cannot show is filed in `breadcrumbs.md` |
| B4 | P2 | The trimmed Communication sentence dropped "and no risk stands" and "a contract or brief", so it reads differently from the output-style bullet | adopted: both phrases restored |
| B5 | P2 | "After the red command and before the first edit" has no exit when no red command exists or the fix is not to a function | declined: the sentence before it routes a defect with no red command to the `diagnosing-bugs` loop, and "before the first edit" without "after the red command" dropped red-first to 0 of 4 in the second wording's runs |
| B6 | P2 | The plan's status line and B1 section describe drafts, not the landed text | adopted |
| B7 | P2 | B1 is 284 bytes against its 120-byte allowance | accepted: the file is 23,694 bytes, under the plan's 23,900 and the 24,000 budget, because B2 and B4 did not land |

The reviewer's AMBIGUITY (whether B3 must also meet "2 of 2") follows the
operator's ruling 2, beating the control, which it does.
