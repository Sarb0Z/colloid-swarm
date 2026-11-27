# Review: status band plan

Round 1, plan review, by an Opus `reviewer` cell with the reviewer contract.
Artifact: `docs/notes/2026-11-28-status-band-plan.md` (an ignored local plan),
sha256 `cf891861cd5e0c10…` before and after the review. Verdict:
`CONFORMANCE: no`, 3 `P1` and 6 `P2`, no `P0`. The brief's contract block first
held a placeholder; a follow-up message named the contract's location before
the cell began, and the report follows that contract.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | The relay file and marker in `.agents/.readout/` collide with `readout.py`, which reads every `*.json` there as a readout (each would show `unreadable` and never be pruned), `prune` would delete the marker after 7 days, and the folder would then exist everywhere, so the reader starts in every repository | adopted: both live in a per-user runtime folder keyed by session id, `${TMPDIR:-/tmp}/colloid-status-$USER/`; acceptance 3 pins that no readout folder means no reader start |
| 2 | P1 | `/clear` changes the session id with no `session.start`, so the marker goes stale and the person's own line returns | adopted: the band checks `$.session.id()` on every draw and writes a missing marker; `session.end` removes only the ending id's; acceptance 8 covers `/clear` |
| 3 | P1 | The acceptance block cannot show "everything from the strip": one fixture covered two segments, and six pinned cases were missing | adopted: golden captures of the current strip, one fixture per segment and value class, committed before any change; every pinned case is ported into acceptance 3 and 4 |
| 4 | P2 | The relay and the band resolve different repositories | adopted through finding 1: neither resolves one to find the other |
| 5 | P2 | Timers start git and `python3` while idle, against the ruling's stated cost | adopted: git and the reader run only on a relay change or a tool call; the idle timer is an in-process stat; cost stated; acceptance 9 samples `ps` while idle |
| 6 | P2 | A failed `removed-callers.py` would read as zero callers, and the count's unit is undefined | adopted: `--json` output with a non-zero status on failure, `callers ?` on failure, the unit is call and import sites |
| 7 | P2 | The relay builds a path from an unvalidated `session_id` | adopted: ids outside `[A-Za-z0-9_-]` delegate and write nothing; acceptance 4 |
| 8 | P2 | F8 changed two variables at once | adopted: F8 restated as observed — interactive sessions require trust before any loading, `-p` draws no band — and dropped from the relay's rationale |
| 9 | P2 | Where the band does not load and the person has no user line, nothing shows | accepted and stated in the plan: the strip switched off behaved the same |

AMBIGUITY ("everything from the strip": segments only, or also its
behaviour): settled by the lead as both, from the operator's "keep
everything we designed".

Round 2, code review of the `band` lane at `380b9fa`, by an Opus `reviewer`
cell with the reviewer contract. Verdict: `CONFORMANCE: no`, 1 `P1` and 7
`P2`, no `P0`. Result: reopen.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | Row 4's tests readout takes the exit status of any Bash call naming a runner word anywhere: `pytest \| tail` with a failure shows `tests pass`, a background run passes at once, `uv pip install pytest` sets a state, and this repository's own runners (`.agents/suite.sh`, `bash .agents/test-*.sh`, `check-all.sh`, `claude plugin test`) match nothing | adopted: a runner counts only in command position; a pipeline whose last stage is not the runner, and a background run, leave the state unchanged; this repository's runners are added; tests for each case |
| 2 | P2 | git reruns only when the relay names another folder, so a commit from another terminal or a MultiEdit leaves the dirty count and ahead/behind stale until the next prompt, where the strip reran git on every statusLine run | adopted: a relay change reruns git at most once per 5 s; idle stays process-free, since the relay changes only while the engine draws |
| 3 | P2 | In a worktree session `removed-callers.py` gets the main checkout as its project, finds no file at HEAD, and reads as no callers | adopted: it gets the git top level of the session's own folder |
| 4 | P2 | The marker is written on the first draw, after the slow opening, so the relay's first run prints the person's own line | adopted: QA observed it at launch (round 2 QA, 8b); the marker is written in `session.start` before any process runs |
| 5 | P2 | A `config.json` that does not parse turns the default-on band off, where `config.py` falls back to the default and the strip stayed on | adopted: the band follows `config.py`'s word and reports the stderr once |
| 6 | P2 | `CLAUDE_PROFILE=@corp` cuts to an empty label and draws no badge | adopted: an empty cut falls back to the folder name |
| 7 | P2 | Decision `status-band-as-mod` still names `.agents/.readout/` for the relay file | adopted by the lead: the decision names `${TMPDIR:-/tmp}/colloid-status-$USER/` |
| 8 | P2 | `register.tsx` is 489 lines and `stripRows` about 105 | deferred to a breadcrumb: split when the band is next touched |

AMBIGUITY ("everything the strip did": the listed behaviours, or also its
refresh moments): settled by the lead as both, through finding 2.

Live QA at `380b9fa`, by a Haiku session in tmux on a trusted scratch clone.
Passed: the band above the prompt, rows 1 to 3; no user line after the first
turn and after `/clear`; the relay files in `$TMPDIR/colloid-status-mac/`, the
engine and the shell agreeing on the folder; `/clear` replacing the old id's
files; no git, `python3` or `readout.py` under the session in 60 one-second
`ps` samples while idle; both buttons. Failed: the person's own line drew below
the prompt until the first turn (finding 4), and one
`status-band: ui.render hook skipped: threw … $.process.run(/bin/sh) aborted`
line printed at launch before the band drew, adopted as a fix: no draw waits
on a process, so the opening runs outside the render hook. Not exercised: row 4
live and a named branch.
