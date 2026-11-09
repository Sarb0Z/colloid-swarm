---
applyTo: '**/*.test.*,**/*.spec.*,**/*_spec.*,**/*_test.*,**/test_*.py,**/test-*,**/tests/**,**/test/**,**/spec/**,**/__tests__/**'
paths:
  - '**/*.test.*'
  - '**/*.spec.*'
  - '**/*_spec.*'
  - '**/*_test.*'
  - '**/test_*.py'
  - '**/test-*'
  - '**/tests/**'
  - '**/test/**'
  - '**/spec/**'
  - '**/__tests__/**'
---

# Testing Rules

This rule governs test code in every stack. A stack pack's own testing lines
add to it.

## Business Invariants
- Expected values come from an independent source of truth: a known-good literal, a worked example, the spec. An assertion that recomputes the expected value the way the code does (`expect(add(a, b)).toBe(a + b)`) passes by construction and can never disagree with the code.
- Test behaviour through the public interface, so a refactor that keeps behaviour keeps the test green. Assert on an operation's outcome, never on which internal methods ran. The tell of an implementation-coupled test: it breaks when you refactor and behaviour has not changed.
- Mock at system boundaries (network, database, clock, filesystem), never between internal functions. Verify through the interface, not through a side channel such as querying the database the code just wrote.
- A test that never fails is as useless as one that always fails. Before calling a new test done, invert one condition it covers (drop a negation, swap `&&` for `||`), run it, see it fail, then restore the file from a copy. A mutation that stays green means a test case is missing.
- Prefer a self-contained test that reads like a specification over shared helpers the reader must trace. In tests, descriptive repetition beats DRY.
- Avoid a snapshot test unless every change to the snapshot gets reviewed; an unreviewed snapshot is a tautology recorded once.

## Abnormal Cases and Rationale
- `**/test-*` and `**/test/**` also match a few non-test paths, such as a `test-data/` fixture folder. Loading this rule there costs a few lines of context and changes nothing.
- The adapted lines come from mattpocock/skills `tdd` and addyosmani/agent-skills `test-engineer`, `test-driven-development` and `code-review-and-quality`; `.agents/licenses/mattpocock-skills-MIT.md` and `.agents/licenses/addyosmani-agent-skills-MIT.md` record the sources.

## Out of Scope
- Which seams to test and the order of slices are planning decisions; the Build workflow in the root `AGENTS.md` owns them, because this rule loads only once a test file is open.
- Test runners, commands and framework syntax belong to the stack packs.
