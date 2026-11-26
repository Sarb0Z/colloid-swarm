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

The reviewer's two `AMBIGUITY:` lines go to the operator: the landing rule
(Decision 2) and Unit A's stakes, which the lead settled at Critical as the
higher level. Its `HANDOFF: qa-verifier` is the fresh-session acceptance,
which runs after the operator's OK on the plan.
