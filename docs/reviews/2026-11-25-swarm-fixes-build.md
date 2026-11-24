# Swarm coordination fixes, wave 1: code review rounds

Run `swarm-fixes`, three worktree lanes from `4cc9cbc`, built to
`docs/notes/2026-11-24-swarm-coordination-fixes-spec.md`. Critical stakes. One
reviewer (`fable`) read the delivered scope whole and its seams.

Covers: 4cc9cbc..66bbdc2
Covers: 4cc9cbc..1aa6dff
Covers: e374d2e..fd73850
Covers: 762099d..d31404e
Covers: bb217bf..c6a2916

## Round 1 (controller `0da6bc0`, gates `e374d2e`, sweep `ceaca5e`)

`CONFORMANCE: no`. 8 `P1`, 15 `P2`, 2 ambiguities, 2 handoffs. No `P0`.
The reviewer read every controller and gates file but, of the sweep lane, only
`worktree_sweep.py` and `worktree_runs.py`; `worktree_heal.py`,
`worktree_removal.py`, `worktree_records.py`, `session-end.sh`,
`session-start.sh` and the `teardown-gate.sh` diff were not covered, so a fix
there re-enters review in round 2. During the round the reviewer's scratch
script created branch `r1/one` and its worktree in the real checkout and
removed both; `git status` and `git worktree list` were clean after.

| # | Sev | Lane | Finding | Disposition |
|---|---|---|---|---|
| 1 | P1 | composition | The controller records the source branch as `run["source"]`, the sweep reads `run["base_branch"]`; the sweep's test sets the key by hand | Adopted (lead checked both branches): the sweep reads `source`; its test starts the run from a checkout on `mvp/roadmap` |
| 2 | P1 | composition | Merged, `test-workloop.sh` (gate reads a lane brief as plain) and `test-session-end.sh` (`status` of a closed run exits 0) fail the run's verify | Adopted: (a) by finding 3; (b) the sweep asserts on the live state file |
| 3 | P1 | gates | The gate infers a run's state file from the brief's repository, so a run whose state is elsewhere reads as a plain writer (spec Unit 3.2 said the header names the state file) | Adopted (lead checked: the brief file carries `--state <path>`): the gate reads the state path from the brief file, inferring only when it is absent |
| 4 | P1 | composition | A parked run (no worktree, unfinished) is closed by `unowned_runs` at the next start, stranding its wip ref | Adopted: a run with a parked lane or a wip ref is held and named with `resume` |
| 5 | P2 | composition | The sweep closes a finished run through `abandon`, so `check` reports it abandoned unfinished | Adopted: the sweep closes a finished run with `teardown` |
| 6 | P2 | composition | A live session's fan-out run is closed by another session's start and split across `.closed/` names | Breadcrumb |
| 7 | P1 | controller | `land` reads the checked-out branch before verify and fast-forwards whatever is checked out after (reproduced: `main` moved to staging-only commits) | Adopted: re-read the branch before the merge and refuse on a mismatch, or move the source ref with an expected old value |
| 8 | P1 | controller | Saving a worktree holding a nested Git repository records a gitlink only; the files are lost on removal (reproduced) | Adopted: keep and name the worktree, as `lost_files` does |
| 9 | P1 | controller | `resume` restores through a text-mode patch: CRLF endings lost, non-UTF-8 text crashes and strands the ref (reproduced) | Adopted: `git restore --source=<ref> --worktree`, delete the ref only after success, restore a lane whose worktree exists while its ref remains |
| 10 | P2 | controller | `git add -A` fails on a sparse lane's untracked file outside its cone | Adopted: `--sparse` |
| 11 | P2 | controller | `review` of a lane submitted by the old controller raises KeyError on `start` | Adopted: fall back to `start_point` |
| 12 | P2 | controller | `source_branch` for an older run is unstable and `integration_problems` bypasses it | Adopted |
| 13 | P2 | controller | A landed run whose release failed cannot rerun `land` | Adopted: a landed run reruns only the close |
| 14 | P2 | controller | `release_lane` ignores the removal's result; a reviewed lane's wip ref outlives the run unnamed | Adopted |
| 15 | P2 | gates + controller | `--rul` abbreviation and `python3 -X dev` spellings pass `workloop-authority.sh` (reproduced) | Adopted: `allow_abbrev=False` in the controller; prefix match and interpreter options in the hook |
| 16 | P2 | gates | `git stash -- list` from a cell passes as a read (reproduced) | Adopted |
| 17 | P2 | gates | A foreign writer row with no judgeable transcript is kept forever | Breadcrumb |
| 18 | P2 | gates | R7's refusal advises `EnterWorktree`, which does not change the checkout the gate reads | Adopted: name the remedies that pass (a lane brief, a `WORKSPACE:` line) |
| 19 | P2 | gates | Two hooks clearing one stale lock can both hold it | Breadcrumb |
| 20 | P2 | sweep | `worktree_sweep.py remove` acts on any worktree, live agents included; a lane's `--save` writes `saved/<name>` | Adopted: refuse a run with a live agent; a lane's save routes to `park` |
| 21 | P2 | sweep | An unlisted recorded folder raises StopIteration mid-check after the stamp | Adopted |
| 22 | P2 | gates | README still judges the idle heal against the default branch | Adopted |
| 23 | P1 | all | Units 4.1–4.3, 5.1 and the decision-record edits are in no lane | Declined: they are wave 2 by plan (a `signals` run after this one lands) and the lead writes `decisions.md` after landing; neither was in this run's lane briefs |

Round 1 fixes: controller `66bbdc2`, gates `1aa6dff`, sweep `575b259`, each
row red without its fix. QA round 2 on the composed tips: row 26 in full, rows
6, 7, 25, the parked-run hold across a session start, and the reviewer's
reproductions r1, r3, r3b, r4 and `probe.py` all refused or correct;
`test-workloop.sh` and `test-session-end.sh` pass composed. A staged new file
comes back untracked after park and resume (content intact): breadcrumb.

Ambiguities: Unit 3.2 resolved by finding 3; Unit 1.1 — work `abandon` saves
is for recovery by hand once the run is closed (reading b), stated in the
skill.

## Round 2 (sweep `575b259`, the files round 1 did not read)

`CONFORMANCE: no`. 4 `P1`, 9 `P2`, all but 8, 12 and 13 reproduced in scratch
repositories. No `P0`.

| # | Sev | Finding | Disposition |
|---|---|---|---|
| R2-1 | P1 | "Save and remove" on a clean detached worktree loses its commits | Adopted: write `saved/<name>` at HEAD when HEAD is outside every ref |
| R2-2 | P1 | An unfinished run's empty or just-claimed lane reads as merged after `/clear`; worktree and branch removed | Adopted (ambiguity resolved by the lead under R1: an unfinished run is not done): remove nothing of an unfinished run; flag lanes holding work |
| R2-3 | P1 | Every lock naming the cleared process counts as ended, so a live isolated cell's worktree is removed; `--discard` ignores locks | Adopted: void only the ended session's lock; a running agent's lock holds; discard refuses an unended lock |
| R2-4 | P1 | Discard deletes the branch and unmerged commits unannounced | Ruled by the operator on 2026-11-25: discard removes the worktree with its uncommitted, untracked and ignored files and keeps the branch; the answer names the branch and its commits in no other ref |
| R2-5 | P2 | Stale ledgers judged by worktree records, so a running session's ledger is deleted | Adopted: judge by transcript age |
| R2-6 | P2 | Isolated cells' worktrees record no source branch | Adopted |
| R2-7 | P2 | Start points other than a bare branch name record the wrong source | Adopted: `rev-parse --symbolic-full-name`, heads and remotes only; `-b<name>` |
| R2-8 | P2 | `teardown-gate.sh:687` still promises save-at-session-end | Adopted |
| R2-9 | P2 | Save fails on a sparse worktree's untracked file outside its cone | Adopted: `--sparse` |
| R2-10 | P2 | Blocked worktrees repeat a bare `kept` line every hour; `keep` does not silence it | Adopted |
| R2-11 | P2 | The hourly check walks and runs `status` before reading `keep` | Adopted: read `keep` and the reachability test first |
| R2-12 | P2 | Three copies of the merged test, already diverging | Breadcrumb |
| R2-13 | P2 | Four comments no longer match the code | Adopted |

Ambiguity "a worktree's branch is deleted once its source contains it" (code b)
stands under R1.

Round 2 fixes: sweep `fd73850`, one commit. Each of R2-1..R2-7, R2-9 and R2-10
has a row that fails with that fix alone undone; R2-8 has a text assertion,
R2-11 an indirect one, R2-13 is comments. On the way the lane found
`rev-list --exclude=refs/heads/<b>` excluded nothing (the option takes the name
under `refs/heads/`) and fixed it. The sweep keeps its wait on closing a
lead-less run while any worktree of the repository is off disk.

QA round 3 on sweep `fd73850` composed with gates `1aa6dff` and controller
`66bbdc2` (clean merges): nine scenarios in scratch repositories, one per
fixed behaviour (R2-1, R2-2, R2-3, R2-4 with the ruling, R2-5, R2-6, R2-7,
R2-9, R2-10), all pass; `test-session-end.sh`, `test-session-start.sh`,
`test-workloop.sh` and `test-workloop-inbox.sh` pass. A worktree started from
`origin/main` records `origin/main` as its source, a ref the merged test
resolves; its removal once merged there was not run end to end.

## Integrate and the follow-up on main

`integrate` composed the three accepted tips cleanly (`762099d`) and its
`check-all.sh` failed five checks. `lint-breadcrumbs.py` and
`port-public.py check` fail on `4cc9cbc` too; `demo/check-inventory.py` and
`port-public.py` wanted the generated showcase and starters refreshed. Two came
from the lanes: `test-export.sh` (comments in `test-workloop.sh` named the
carrier's spec and review files) and the iTerm `test-review-snapshot.sh`
(reproduced: the hourly check put every pane-review snapshot to the operator as
a dead session's work). The operator ruled to fast-forward `main` to
`762099d` and fix on `main` before `land` verifies there. A third surfaced on
`main`: `test-session-end.sh` failed `add-lane` under the disk floor at 9.4 GB
free (fixed in `21b1e4c`, the test setting its own floor).

The snapshot fix `d31404e` (review-snapshot records the commit it froze; a
snapshot still there, clean, counts as merged) was reviewed by `reviewer3`
(opus, critical): `CONFORMANCE: yes`, 4 `P2`, no reviewer-made work found
losable.

| # | Sev | Finding | Disposition |
|---|---|---|---|
| F-1 | P2 | After `/clear` the session's process runs on and a reviewer cell may still read the snapshot by absolute path, which the occupant check cannot see | Adopted (`c6a2916`): a snapshot stays unasked while the session's process lives |
| F-2 | P2 | The test would stay green with the stranded check skipped for snapshots | Adopted: rows for a commit reset back to the snapshot's commit and a snapshot moved off it; both mutations go red |
| F-3 | P2 | Precedence dropped `drop_branch`'s note from the snapshot's removal line | Adopted |
| F-4 | P2 | `settle` is 58 lines with 9 parameters | Breadcrumb |

Ambiguity "the snapshot's commit becomes the only copy once the checkout's
work is gone" (code a): a snapshot is a review artifact, not a save; reading
a stands. QA `qa4` on `d31404e`: an untouched snapshot is removed for a dirty
checkout and for a clean feature branch; a written, committed, reset or
ignored-file snapshot is put to the operator; a plain detached worktree is
still flagged; no ref is made. The snapshot suite and `test-session-end.sh`
pass on `c6a2916`.
