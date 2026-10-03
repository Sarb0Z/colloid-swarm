# Inputs for the testing write-up

## Objective

The operator plans a write-up on the purpose of testing. It will govern how
agents write, change and delete tests and how verifier agents behave. This
document collects the material for it. It is not the write-up: the testing
rules stay out of `AGENTS.md` and the stack packs until the write-up lands.

## The operator's position, as stated on 2026-10-03

- "there's a balance between 'the testing suite is canonical and must never be
  changed' and 'the testing suite can be changed whenever it's convenient', and
  if there's a lot of test churn going on, it can be hard for you to tell if
  you've fallen into one of those failure modes"
- "we have in some cases kind of too many tests, we just want to actually pin
  them to behavior that's important and preferably have types define behavior
  where it makes more sense"
- "then we can go through expected behavior and when that changes, the
  refinement will know to update tests too"
- "currently test churn is so high that many of our repos are not in a healthy
  condition despite passing all tests"

## Incident

The operator's report: "I had a tester subagent which ran into issues, some
bugs, some not. Not only did it just tell it exactly what to do, it altered the
save game state to remove the obstacles". The session and the repository are not
recorded here.

The current contract has a gap at that point. `.agents/personas/qa-verifier.md`
says "Bash exists to execute tests and interactions, not to edit product source".
It says nothing about changing data, saved state, fixtures or seed rows to get
past an obstacle, and nothing that makes an obstacle a finding.

## Measured churn

These figures cover the last 60 days, to 2026-10-03, without merge commits. A
path counts as a test when it is under `test/`, `tests/`, `__tests__/`, `spec/`
or `e2e/`, or named `*.test.*`, `*.spec.*`, `*_test.*` or `test_*.py`. Source
lines include generated files and lockfiles, so the ratio is a rough measure.

| Repository | Commits | Commits touching tests | Test lines changed | Test lines per source line |
|---|---|---|---|---|
| Incura/clearclaim | 690 | 55.4% | 174,166 | 0.25 |
| Bitely/customer-delivery-web | 739 | 51.8% | 118,536 | 0.38 |
| TaxDrop/taxdrop-one-live | 170 | 73.5% | 19,544 | 0.11 |
| TaxDrop/taxdrop-db-savings-engine | 170 | 71.2% | 22,676 | 0.12 |
| Mailstation/mailstation | 217 | 34.6% | 18,774 | 0.07 |
| Meridian/meridian-profits-backend | 42 | 42.9% | 3,790 | 0.02 |
| Bitely/bitely-app | 90 | 23.3% | 13,957 | 0.04 |
| writing-coach | 141 | 20.6% | 7,888 | 0.02 |

The two TaxDrop repositories show the same commit count, so their histories may
overlap. This was not checked. A sharper measure for the write-up is the share
of test lines rewritten or deleted within a few weeks of being added, per
repository. That share separates rework from new coverage, and it was not
measured.

## Candidate rules from claudestd

These are from `zorbathut/claudestd` `CLAUDE-general.md`, commit `cc3e323` (CC0).
They are held here, not adopted:

- For a bug fix, or any feature whose tests can come first, write the tests
  first and see them fail.
- A failing test is not a veto. A test that pins behavior the change replaced
  on purpose is updated with the code. Fall back to a redesign only when the
  failure shows a real regression.
- Do not pin user-facing copy in tests. Assert relations instead: non-empty,
  distinct across states that must read differently, equal across states that
  must read the same. An exact match stays where the output is the contract
  (serialization, parsers, formatters) or where the test wrote the fixture.
- Write tests against the seam to defend: pure functions, state machines,
  parsers, classifiers. Do not retrofit unit tests around UI, rendering or
  process orchestration that has no seam. Say so, and rely on a manual smoke
  test.
- Integration tests with real dependencies are usually worth the slowness:
  mocks pass when the contract drifts. When mocking cannot be avoided, mock at
  the outermost boundary.
- A test goes in the commit that makes it meaningful, written against subjects
  that later commits do not change.
- Keep shared fakes and fixtures in one support directory and extend them. Mark
  slow tests that run real tools so the default suite stays fast.
- Run the full suite on every change. This conflicts with the decision
  `verification-placement`: narrow checks per change, the composed suite once.

## Rules in the repository that already touch testing

- Root `AGENTS.md`, Workflow step 4: "Tie every fix to observed evidence";
  "after two failed fixes, stop changing code, instrument". Step 5 runs
  `qa-verifier` when behavior is observable, and always for a high-stakes
  claim.
- Root `AGENTS.md`, "Tooling for agent development": encode a recurring defect
  class as a lint rule, a test or a CI check, instead of an instruction.
- `.agents/AGENTS.md`: "A hook policy ships with a direct firing test. Prefer
  testing observable behavior over mutation machinery that tests the test
  harness."
- `.agents/personas/qa-verifier.md` and `.agents/skills/qa-verifier/SKILL.md`:
  the verifier adds no test, does not edit product source, and reports
  environment failures as coverage gaps.
- `.agents/decisions.md` `verification-placement`.
- `.agents/rules/stack-typescript.md` and `stack-python.md`: external effects
  are passed as parameters so that tests can pass fakes. This is a design rule
  that serves testing.
- The playbook `.agents/playbooks/review-axes.md` and the hostile-review
  contract name a missing QA a coverage gap.

## Questions for the write-up

- How does an agent tell a test that pins important behavior from one that pins
  an implementation detail?
- Where should types define behavior instead of tests?
- What artifact holds expected behavior, and how does a change to it reach the
  tests?
- When may an agent change or delete a test, and what must the commit say?
- Which numbers make churn visible, and what threshold marks a repository as
  unhealthy?
- What may a verifier change while it verifies? What makes an obstacle a
  finding rather than something to remove?
