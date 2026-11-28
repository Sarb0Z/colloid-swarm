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

Live QA at `971afcf`, same method, on a named branch. Passed: no error line at
launch, after `/clear` or in the whole scrollback; `qa-branch` in row 1;
`/clear` clean with only the new id's files; tests `pass` after
`bash .agents/test-statusline.sh`, unchanged after the same run piped into
`tail`, `stale` after a `.py` edit; idle 60 s with no git, `python3` or
`readout.py`; both buttons. Failed: the person's own line still drew below the
prompt from launch to the first turn, in four captures over 8 s. Claude Code's
first statusLine run precedes `session.start`, and its output stands until the
next run. Adopted: the relay waits up to 1.5 s for the band's marker when the
band is installed, and records `<id>.nomod` when none comes, so later runs for
that id hand over at once. Callers showed nothing on the band after a blank-line
edit, which removes no name: correct by acceptance 7.

Round 3, code review of the fixes `380b9fa..971afcf`, by an Opus `reviewer`
cell with the reviewer contract. Verdict: `CONFORMANCE: no`, 1 `P1` and 8
`P2`, no `P0`. Result: reopen.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | `pytest -q  # confirm it's green` then `git status` reads as a pass: `pieces` in `task.ts` ignores `#` comments, so the apostrophe opens a quote that swallows the rest | adopted: a `#` starting a word outside quotes ends at the newline; an unclosed quote is no test run |
| 2 | P2 | The early marker lands before the switch is read, so a switched-off repository shows no line at launch | adopted: the marker follows the switch and the folder checks; the relay's wait then records `.nomod`, and the person's line shows from launch |
| 3 | P2 | An aborted opening has no bounded retry: neither band nor line shows while openings keep aborting, with a process start per draw | adopted: three attempts on a timer, 250 ms then 500 ms; after the last, the marker is removed and the failure reported once |
| 4 | P2 | `readGit`, `readReadouts` and `checkCallers` report an engine abort as a fault | adopted: they rethrow aborts |
| 5 | P2 | The early marker writes through a symlinked folder before the ownership check | adopted with finding 2: `! -L`, `mkdir -p -m 700` and `-O` pass before any write. The writer's residual that the folder could be created world-readable is false: `$.fs.write` makes parents 0700 and files 0600 on 2.1.325; the relay adds `umask 077` |
| 6 | P2 | A failure of the git that names the session's top level leaves an old callers count | adopted: `callers ?` |
| 7 | P2 | `time pytest`, `env X=1 pytest`, `(cd app && pytest)`, `pytest;` and `npm run test:unit` leave the state unchanged | adopted: launchers, one enclosing pair of parentheses, a trailing `;` or newline and package-script tests count |
| 8 | P2 | `session.end` can remove before the early marker's write lands, leaving a stray `.on` | adopted: it awaits the ending id's marker write |
| 9 | P2 | `pieces` 48 lines, `open` 46, `register.tsx` 581 | deferred with round 2 finding 8 |

AMBIGUITY (acceptance 5 "the person's own status line shows": from launch, or
from the first run after the switch is read): settled by the lead as from
launch, through finding 2 and the relay's wait.

Live QA at `99e36e9`, same method, on a named branch with a readout folder.
All scenarios passed. Launch, captured every 0.5 s for 6 s before any prompt:
the band above the prompt, no person's line below it, no `threw`, `aborted` or
`error` in the scrollback; the relay folder mode 700 and the `.json` mode 600.
`/clear`: clean, only the new id's files. Row 4: `tests pass` after
`bash .agents/test-statusline.sh`; unchanged after `bash -c 'exit 1' # it's a
test`; `tests fail` after a failing `.agents/test-*.sh`; `3 callers open` after
renaming the definition of `real_folders` in `agent_records.py`. Idle 60 s: no
git, `python3` or `readout.py`. Switched off: no band, the person's line below
the prompt about 1.5 s after the banner. Not covered: a freshly created relay
folder, since another session's file was in it. A rename whose callers all use
`module.name(` shows no callers segment, as `removed-callers.py` documents. The
lead's own launch capture at `99e36e9` showed the same frame.

Round 4, code review of `971afcf..99e36e9`, by an Opus `reviewer` cell with the
reviewer contract. Verdict: `CONFORMANCE: no`, 8 `P2`, no `P0` or `P1`.
Result: accept; the P2 fixes trail in a follow-up lane.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | P2 | A dangling-link relay folder or a failed `mkdir` makes the relay wait about 1.6 s on every refresh, since no `.nomod` can be written | adopted, trails: create the folder before the wait, and wait only when it is ours |
| 2 | P2 | `umask 077` covers the person's own status line command, so files it creates change mode | adopted, trails: 077 only around the relay's own writes |
| 3 | P2 | `refreshInBackground` and `poll` report an engine abort visibly | adopted, trails: aborts skip the report |
| 4 | P2 | The switched-off path deletes the relay's `.nomod`, so a slow opening causes a second wait | adopted, trails: it removes only `.on` and `.json` |
| 5 | P2 | The abort retry timer cannot be cancelled when the session ends or clears | adopted, trails: the handle is kept and cancelled |
| 6 | P2 | A backslash-newline continuation hides a runner | adopted, trails |
| 7 | P2 | `npm run testdata:seed` counts as a test runner | adopted, trails: a test script name is `test` or `test` followed by `:`, `.` or `-` |
| 8 | P2 | `register.tsx` 628 lines, `pieces` 65 | deferred with round 3 finding 9 |

Live QA of the `band-trail` lane at `4fea3a8`, same method. All scenarios
passed: the launch frame with nothing below the prompt, `/clear`, idle 60 s
over the whole process tree with no git, `python3` or `readout.py`, and the
person's line about 1.5 s after launch with the band switched off.

Round 5, code review of the `band-trail` lane `2b7f606..4fea3a8`, by an Opus
`reviewer` cell with the reviewer contract. Verdict: `CONFORMANCE: no`, 4 `P2`,
no `P0` or `P1`; round 4 findings 1 to 7 closed. Result: accept; findings 1, 3
and 4 trail as one commit by the lead.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | P2 | A failed opening still removes `<id>.nomod`, so the relay waits a second time for that id | adopted, trails: the failure path removes only `.on` and `.json` |
| 2 | P2 | `claude plugin validate` reports type errors as warnings and passes, and `test-mods.sh` discards them, so a type error in any mod passes the gate | confirmed by a probe: an injected `TS2322` passes plain validate; `--strict` also fails on the icon warning, so it is no fix as it stands. The band's own test file already carries 7 type errors the gate never showed. Goes to the operator: a gate change |
| 3 | P2 | No relay test starts with the folder absent, so dropping the `umask 077` around `mkdir` would pass | adopted, trails: a case with no folder asserts mode 0700 and a written `.nomod` |
| 4 | P2 | The relay's `mkdir` without `-p` refuses a not-yet-created `TMPDIR`, where the band's `mkdir -p` succeeds | adopted, trails: `mkdir -p` |

The writer edited `register.tsx` with a script instead of the edit tool; the
reviewer found the formatting consistent and no post-edit check that would have
run on the file.

Round 6, review of the mod type check the operator approved for round 5
finding 2 (`8984b93`, `b56d736`), by a Sonnet `reviewer` cell with the reviewer
contract, which ran `test-mods.sh` twice. Verdict: `CONFORMANCE: yes`, 3 `P2`,
no `P0` or `P1`. The retyped fakes keep both pass and fail paths, and validate
type-checks a fresh checkout with no `.claude-plugin/types`.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | P2 | `.agents/claude/README.md` does not say validate's `error TS` lines fail a mod, and says the declarations are written "each time it loads a mod" as if the check needed them | adopted: both sentences rewritten |
| 2 | P2 | The probe accepts any failure as proof and discards the report; `compgen … \| head` can abort silently under `pipefail` | adopted: the probe requires the `error TS` lines, prints the report when they are missing, and takes the file from a glob array |
| 3 | P2 | The probe plants its error only in a test file, so losing the check on shipped hooks code would pass | adopted: it plants one in the hooks module named by `hooks.json` and one in a test file, and requires both reported |
