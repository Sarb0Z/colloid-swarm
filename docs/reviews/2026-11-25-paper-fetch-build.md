# Review: the paper-fetch build

Code review and QA of the delivered scope, Standard stakes. Plan and its own review:
`docs/notes/2026-11-25-paper-fetch-plan.md`, `docs/reviews/2026-11-25-paper-fetch-plan.md`.

Covers: 8cedea2..d04bee8

Artifact reviewed: commits `8cedea2..95137cc` (the tool under `scripts/paper-fetch/`, the one-line
change to `.agents/lint-suite.py`, one CI step, one `check-all.sh` line), plus `20dc2a2` in the
cabg project (a README pointer). One `reviewer` cell on `opus` read the scope whole. One
`qa-verifier` cell ran the tool against the acceptance, briefed with the ask and the acceptance and
not the diff. The fixes are `d04bee8`.

## Code review: `CONFORMANCE: no`, `EFFECTS: none`, one P1 and eleven P2

| # | Finding | Disposition | Evidence after the fix |
|---|---|---|---|
| 1 | P1. A relative or symlinked `--root` crashes `fetch` on the first paper with no inbox file, when the manifest has `save_as`. This is the project README's own command. | Adopted. The root is resolved once in `cli._open_project`. | Two new tests (cwd with `--root .`, and a symlinked root). The README command, run from a scratch copy of the real manifest, ends all 28 papers `awaiting-inbox`. Removing `.resolve()` makes three tests fail. |
| 2 | P2. An unexpected exception outside the plugin blocks aborts the run with a traceback and no ledger row. | Adopted. Each paper's handling sits in a boundary that records `failed` with the error type and goes on; the same in `push`. A malformed or non-ASCII address, an unsupported encoding or an undecodable body is a permanent transport error and is not retried. | Tests: a source returning `5`, a non-ASCII address, a `plan` returning `None`. |
| 3 | P2. (a) A converter crash leaves the paper `failed`, so the next run downloads it again. (b) `--force` on a converted paper whose re-attempt fails drops it to `blocked` or `failed`. | (a) Adopted: a crash records `fetched`, and the next run converts without a download. (b) Declined: `--force` means redo, and a failed redo records its failure. The README says so, and a test shows `fulltext.md` is not removed. The reviewer allowed this reading. | Test for (a): no second request. Test for (b). |
| 4 | P2. A `Backoff` header over 120 s raises before the response reaches its caller, so a good download or a successful write is lost. | Adopted. The pause is stored; the next request to that host stops the run. | New test. Restoring the old raise makes it fail. |
| 5 | P2. A sink that wrote remotely but also wrote in the paper folder, or returned a non-string id, is recorded `failed`, so the next push writes again. The folder check compared names only. | Adopted, with one change: the check compares name, size and modification time, not SHA-256, because hashing a 64 MB PDF twice per paper costs more than it buys. The paper is recorded `pushed` with a warning. A sink that returns no dict is `failed`. | Four new tests. Disabling the folder check makes two fail. |
| 6 | P2. `failed`, `blocked` and `awaiting-inbox` papers are retried every run in manifest order and can use up the 25-per-host cap before untried papers. | Adopted rather than deferred: papers with no state go first. | New test, strengthened after a mutation survived it (the first version set up the tried paper last in the manifest, so ordering made no difference). |
| 7 | P2. Ownership of a file rests on the free-text `source` column: a plugin named `hand` breaks it, and a kill between the file write and the row makes the tool's own file read as hand-saved. | (a) Adopted: `hand` and `inbox` are reserved names. (b) Declined: no `converting` state for a window a few milliseconds wide. The README states the recovery: delete `fulltext.md` and rerun. | Tests for the reserved names. |
| 8 | P2. Docstrings and the README state guarantees the tool cannot enforce (a plugin cannot open a connection; two runs never double the rate; every address is printed). A dry run takes no lock and skips the hand-file check. | Adopted. They now read as plugin obligations. The dry run runs the hand-file check and is documented as lock-free and real. `sys.dont_write_bytecode` stops `__pycache__` in plugin folders. | README, `polite.py`, `ledger.py`; a dry-run test. |
| 9 | P2. Inbox papers count toward `--limit`, and the fallback to a full attempt does not. | Adopted. Only a paper that reaches a source counts, in a real and a dry run. | Two tests. |
| 10 | P2. A server's unsupported encoding or undecodable gzip is retried three times. | Adopted (with finding 2). | Tests in `test_transport.py` and `test_polite.py`. |
| 11 | P2. Ten `# noqa` comments break the repository's rule against suppression comments. | Adopted. All ten are removed. | `rg noqa scripts/paper-fetch` finds none. |
| 12 | P2. README errors: `converted` and `fetched` described wrongly; the sink template's `idempotent=True` text says the opposite; the name scrub misses `PASSWORD` and `AUTH`. | Adopted. The scrub now covers `PASS`, `AUTH` and `CREDENTIAL`. | A scrub test. |

Measurements the reviewer reported: `test_fetch.py` at 397 lines is now three files of 245 lines or
fewer. The `--only` filter's third copy is one function (`select`). Signatures over four parameters
(`_handle`, `_save_original`, `Http.request`, `Ledger.append`) and the two modules over twelve public
entries (`polite.py`, `cli.py`) are left: the first are internal, `Http.request` is the plugin
interface, and the modules' public entries are mostly exception classes and option constants.

The reviewer's QA handoff: run the project README's commands as written, run Q5 with a fixture
source and converter, and run the suite lint. Done after the fixes (below).

Ambiguity the reviewer raised: none.

## QA: 22 of 22 acceptance items pass on `95137cc`

The QA cell ran the suite (125 tests), then each scenario against a local server and fake plugins in
its own scratch folder, and removed every process and file it made. It found:

- **A defect:** `fetch --dry-run --limit N` ignored `--limit`. Fixed with finding 9.
- `status` accepted a `save_as` that leaves the project while `fetch` refused it. Fixed: every command
  validates every `save_as` when it opens the project.
- A push stopped by a host cap printed `done: nothing to do`. Fixed: a stopped run's last line is
  `stopped early: …`.
- Loading plugins under `python3 -I` wrote `__pycache__` into the plugin folder. Fixed.
- A short read timeout (a server silent for about 3 s reported as timed out). Not reproduced: a server
  that waits 5 s before it answers succeeds in 5.7 s, and the timeout is 30 s. The QA cell's server
  was probably single-threaded.
- A secret in a query parameter named other than the listed ones is not redacted. As documented.

Not tested by QA: real network sources, real converters, a `kill -9` inside the few-millisecond window
(the equivalent state, a file with no row, was handled).

## Evidence after the fixes

- 144 tests pass on Python 3.14 (CI) and 3.15.
- Four of the fixes (the resolved root, the untried-first order, the `Backoff` delivery, the sink
  folder check) and eleven behaviours from the first build were each broken on purpose, and each made
  the suite fail.
- The project README's command, run from a scratch copy: `done: awaiting-inbox 28`.
- `python3 .agents/lint-suite.py`: 72 checks, script and CI agree, on the committed files and on the
  working tree.
- Q1 and Q5 of the plan's acceptance ran against the real project and a scratch copy before the fixes
  and passed. Q5 ran with an inbox `.md`; a converter-written `fulltext.md` read by the project's
  checker was shown by the QA cell (item 4).
