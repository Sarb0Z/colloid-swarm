# Swarm coordination fixes spec: plan review rounds

Plan `docs/notes/2026-11-24-swarm-coordination-fixes-spec.md`, before any
implementation. Critical stakes. One reviewer per round, a fresh `reviewer`
cell on `opus` that read the plan whole against the repository, the decisions
it touches and the root contract. No code exists yet, so this record carries no
`Covers:` line.

No round found a `P0`, and round 1 covered every subsystem its fixes touch, so
the folded fixes do not reopen review (`hostile-review.md`). The disprove pass
is for code review; the plan's code facts the dispositions rest on (findings 1,
4, 7, 12) were re-read by the lead at `caf42cf`.

## Round 1 (`4952984`)

`CONFORMANCE: no`. 8 `P1`, 13 `P2`, 3 ambiguities, 1 handoff.

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | Claim at first `submit` breaks every one-writer run (`claim` sets the main lane's start, `submit` refuses HEAD equal to it) and drops the install, `depends_on`, lease and peer-delivery checks `claim` holds | Adopted: `init --lane --worker` claims the main lane; worktree lanes keep `claim` (Unit 2.3, D5) |
| 2 | P1 | `land` had nothing to merge on a one-writer run, whose verify runs only in `check` | Adopted: `land` runs verify at the accepted tip there and refuses on failure; acceptance 5, 16 |
| 3 | P1 | A `wip:` commit on the lane branch puts half-done or secret-bearing work in review and on the base branch, and moves reviewed tips | Adopted (redesign): saved work goes to `refs/workloop/<run>/<lane>/wip`, never the lane branch, and `resume` restores it as uncommitted changes; acceptance 6, 7 |
| 4 | P1 | "A worktree is a cache" invited deleting `lost_files`, the only guard on ignored `.env` and local data | Adopted: `lost_files` stays on every removal path; the "dissolves" claim narrowed; acceptance 8, 24 |
| 5 | P1 | D7(a)'s "nothing refused" contradicts the gate's deny at one live writer and `writers-gated-per-checkout`; lock, turn and sweep scopes unstated | Adopted: D7 restated as three options with the refusal named; lock scope and state files stated (Unit 3.1); acceptance 11 waits for the ruling |
| 6 | P1 | `--agent main` is a free string, so a cell could still lift the round cap or widen its paths | Adopted: a `PreToolUse` rule refuses those commands from a payload with `agent_id`; acceptance 19 |
| 7 | P1 | Counting reopen verdicts changes `hostile-review.md:123-124` and `one-review-round-per-wave` unnamed | Adopted: named in Unit 2.5; decision D10; acceptance 20 |
| 8 | P1 | Guard changes without acceptance rows; acceptance 17 had no expected value; 12 assumed P3 | Adopted: rows 3–33 cover every unit; 24 deterministic; 15 conditional on P3 |
| 9 | P2 | No base-branch field or migration; main lanes; review start never recorded | Adopted: field at `init`, read for older runs at first use, worktree lanes only, start recorded at `submit` and bound to the accept (Unit 2.1) |
| 10 | P2 | `land` loops on every base move; merge-commit clause unreachable; checkout branch and Ship class unstated | Adopted: `land` re-integrates and verifies under the run's lock in one command, fast-forward only, precondition and Ship class stated |
| 11 | P2 | The implicit run had no lifecycle; `PreToolUse` records denied dispatches; notifications are no hook; `SubagentStart` lacks the prompt | Adopted: `PostToolUse` recording, a `fanout-<session>` record with states, header dispatches excluded, `SubagentStop` plus death-reader return, probe P6 |
| 12 | P2 | A written policy lacks `+x`, so the lockout stays | Adopted: the adapter runs a present non-executable policy through `bash`; acceptance 21 |
| 13 | P2 | Mapping hooks to the main checkout recreates F18 for a lane that adds a hook | Adopted: map only when the main checkout has the policy; acceptance 22 |
| 14 | P2 | `asyncRewake` is per registration; write and check race; a timeout reads as a pass | Adopted: split registration, check waits for write in a cell, timeout reports "check unavailable" |
| 15 | P2 | `session-start.sh` cannot track cells out; the `it2` edit lands outside the repository | Adopted: the writers gate starts and stops `caffeinate`; a repository script sets the timeout |
| 16 | P2 | READ-ONLY cells cannot write scratch; conflict with the disprove pass's `$TMPDIR` | Declined in part: READ-ONLY cells keep returning results as replies (the gate's refusal is their definition); scratch is for writing and QA cells and the lead; the disprove pass's throwaway worktrees stay under `$TMPDIR` as `hostile-review.md:133-135` says |
| 17 | P2 | New refusals break promise #4; the 20 GB floor had no basis | Adopted: promise #4 lists each refusal; floor 10 GB beyond the source's install size, with the measured 37 GB free and 32–38 GB claims-app lanes stated |
| 18 | P2 | Unit 6 listed 7 of the satellites; delivery-web's merge and stash rules and tax-appeals-app's commit-only-when-asked unaddressed | Adopted: full list with exclusions by decision; per-satellite notes |
| 19 | P2 | Sweep paths that delete run entries, the run folder holding worktrees, deleted merged branches, marker cleanup, state-file growth | Adopted: each stated in Units 1.2, 1.4, 1.8 |
| 20 | P2 | F17 false: the host already tells a reviewer cell its launcher's messages direct its work | Adopted: F17 corrected; Unit 4.3 waits on probe P7 |
| 21 | P2 | No cost bounds on the new hot-path work | Adopted: "Cost on hot paths" section |
| — | — | Files over 300 lines would grow | Adopted: `workloop_land.py` and `workloop_resume.py` |

Ambiguities, all resolved in the spec: Unit 3.1 is D7's three options; Unit
2.6 keeps refusing uncommitted owned files (reading b); Unit 2.4 records only
read-only dispatches outside any run (reading b).

Handoff `qa-verifier` (the reproductions behind F1, F4–F6, F8 and F12 live in
the findings cells' replies, not a committed script): accepted as stated in the
spec's Findings preamble; the build's QA reruns them as acceptance 1, 2, 6, 10
and 20.
