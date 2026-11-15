# iTerm2 console: code review of workloop run `iterm-console`

Plan `docs/notes/2026-11-15-iterm2-review-and-status-spec.md`, approved by
the operator on 2026-11-15. Each lane gets one reviewer beside QA; the
sidebar lane is critical and adds the disprove pass.

## Lane `diff` (unit 1, standard)

Covers: f108fb9..c8230be

One reviewer (sonnet) read the lane's diff; QA (sonnet) ran Acceptance 1-5
and probe P4 in headless Neovim with diffview-plus v0.39 over fixture
repositories.

QA: Acceptance 1 failed; 2, 3, 4 (no upstream and no remote), 5 and P4
passed, apart from the untracked files below. With the not-pushed base the
panel lists `a c1 c2 c3`, and git lists `a c1 c2 c3 untracked.txt`.

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | A commit base hides untracked files: diffview's `GitAdapter:show_untracked` returns false unless it compares the index with the working tree (`lua/diffview/vcs/adapters/git/init.lua:2536-2540`), and no flag overrides it. Reproduced by QA | Escalated: the operator's ruling "Not pushed, like reviews" promised the panel shows what a pane review reads. The operator ruled R20: a second tab with the uncommitted view when untracked files exist; the index is not touched |
| 2 | P1 | A typed base with `~ ^ { }` (for example `HEAD~2`, `@{u}`) is backslash-escaped, and diffview hands the backslash to `git rev-parse` | Adopted: escape only what diffview's tokenizer reads as syntax; tests and a real run with `HEAD~2` and `@{u}`; file names with `[`, `%`, `#` checked for real |
| 3 | P2 | `pane-base` reads only the `origin` remote; 1 of 87 repositories under `~/Projects` has only a remote named `server` | Filed in `breadcrumbs.md`: the lane does not otherwise change `pane-base` |
| 4 | P2 | `install.sh` refuses a dangling link left by a removed worktree | Declined: the runbook runs `install.sh` from the main checkout only, and Undo removes the links |
| 5 | P2 | No test runs `pane-diff` through the installed link; the usage branch and a mutation check were not run | Adopted: `pane-diff` and its tests change for finding 2 |
| 6 | P2 | The usage error exits without the key hold, and `pane-base`'s own reason is dropped | Adopted: same script |
| 7 | P2 | QA: `pane-diff @ -- <file>` also lists untracked files that are not the file | Accepted: diffview applies the path filter to tracked files only; the filtered view still opens on the file |

`c8230be` folds findings 1, 2, 5 and 6. Its tests run a real headless
diffview for `HEAD~2 -- a%b.txt` and for the second tab, and a mutation of
one condition per script fails 15, 18 and 3 tests. The lead read the diff.
Left as they are: a file name with a backslash does not open under
`-- <file>`; with one view the empty startup tab stays as tab 1, diffview's
own behaviour when started from a shell; `pane-diff` reads `pane-base`'s
hash as the last line of its combined output, which the tests exercise.

QA reran at `c8230be` with the operator's reading of Acceptance 1 (R20):
Acceptance 1-5, P4, typed bases `HEAD~2`, `@{u}` and `main^`, files named
`it's here.txt`, `a%b.txt`, `c#d.txt` and `e[1].txt`, the usage error, and a
run through an `install.sh` link in a temporary HOME all passed, and
`git status --porcelain` did not change. The colour scheme was checked at
`cf9367c` (`tokyonight-night`); `c8230be` does not change it.

## Lane `attention` (unit 2, critical)

Covers: f108fb9..d8805c5

One reviewer (opus) read the lane whole and its seams with iTerm2's own hook,
the death reader and the owed reader. QA (opus) ran Acceptance 6-13 and
probes P3 and P5 in a real iTerm2 3.7.7 tab: a Claude session on a scratch
checkout of `a9c2139`, read with `it2 session get-status` every 200 ms.

QA: Acceptance 6, 8, 9 (named), 10, 11 and 13 passed; 7 failed; 12 passed
for the policy alone, 44-49 ms in a tab and 15-17 ms outside. The registered
command, with the adapter's normalizer, takes 109-122 ms in a tab and
74-81 ms outside. P3: our status showed every time, read by get-status; the
operator confirms the sidebar by eye. P5: iTerm2's write wins (finding 1).
Runs a day: about 1,040 at most on the busiest weekday (492 Stop, 53 question
calls, up to 492 idle_prompt), over 466 transcripts.

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | At the question tool, `landed` accepts iTerm2's `working`, which every earlier tool event already left, so the hook writes at once (`iterm_attention.py:236-237`). iTerm2's own `waiting \| <question>` lands 1.77 s later and replaces `decide: <header>` | Adopted. QA reproduced it live (Acceptance 7, P5), which stands as the disprove pass. The writer's probe found a third writer: Claude Code writes `waiting \| answer: <question>` itself (spec E10), so the policy no longer writes at question time and its PreToolUse registration goes. Bypass mode could not be probed: sessions started from a cell are forced to default mode |
| 2 | P2 | At Stop and idle_prompt `landed` checks only the status class, so an earlier `done` counts as this event's write | Adopted, on the probe's evidence: at Stop and idle_prompt the policy waits for `done` with an empty detail, or `background`, the last native write at both events (spec E10). Matching iTerm2's message would land ours before Claude Code clears the detail |
| 3 | P2 | A death shows `error` at every later turn end until the agent is resumed or the death dismissed, and hides owed checks meanwhile | Escalated. The operator ruled R22: only at the end of the turn in which the death is found |
| 4 | P2 | The `<N> read-only cells died` branch cannot fire: `agent_leftovers.leftovers` names every death of the reading session (`agent_leftovers.py:178-181`); QA could not produce it either | Adopted: the branch and its tests go, and every death of the session is named |
| 5 | P2 | `GATE` accepts a line that opens with an inline-code `needs_confirmation:` token, such as prose about the marker | Adopted |
| 6 | P2 | An exception other than `OSError`, `ValueError` or `RuntimeError` ends the policy with stderr only, which nobody sees for an async hook | Adopted: the shell logs a non-zero exit, and the Optional module spec and loader raise |
| 7 | P2 | The failure log grows without bound under a lasting failure; `keychain-notice.sh:40` does the same | Filed in `breadcrumbs.md` for both logs |
| 8 | P2 | The suite fails on wall-clock bounds under 100 ms, and CI runs it | Adopted: the suite asserts that no interpreter starts and reports the time |
| 9 | P2 | Sizes over the measurement limits; `last_message` is a third copy of the transcript's last-text reader | The None guard is adopted under 6. Moving the reader into `turn-text.py` is filed in `breadcrumbs.md`: the file is outside the lane, which is at its widen limit |
| 10 | — | QA: whether Acceptance 12's 100 ms covers the policy or the registered command | The policy, as the acceptance names it; the hook is async, so no turn waits on it. The command's time is recorded above |
| 11 | — | QA: a `claude -p` started from a tab makes iTerm2's own hook overwrite the tab's status with the child's | Noted: iTerm2's behaviour; the parent's next Stop writes ours again |

`d8805c5` folds findings 1, 2, 4, 5, 6 and 8, the guard of 9, and R22 into
`a9c2139`. The lead read the code diff and ran the suite (`PASS:
iterm-attention`). The writer inverted ten of the new rules one at a time,
and each turned the suite red. A turn's start is its last prompt row, which
counts a task notification as a prompt (`turn-text.py` `typed_by_user`).
Deaths are recorded in `.agents/.readout/.iterm-deaths-<session>`, which
`readout.prune` removes once idle. QA reruns Acceptance 6-13 at `d8805c5`.
