# Agent deaths U5: code review round 1

Unit U5 of `docs/handoff/2026-11-13-agent-deaths.md`, run `agent-deaths-u5`,
one writer lane `u5-start` in a worktree: each worktree-record stamp keeps its
`host` text and gains a `start` that no time zone, locale or clock step
changes (Linux boot id and `/proc` ticks, compared exactly; macOS epoch
seconds, within 5 s), with one start rule in `process_start.py` for the sweep,
the Claude Code lock check and the death reader. One reviewer (opus) read the
scope whole and its seams with the heal pass, the inbox hook, `owed.py`, the
teardown gate, the export and the public tree, under the verbatim contract;
Critical stakes, since a session read as ended has its idle worktrees removed
and the unit touches a gate hook.

Covers: d4a53e9..28bb742

## Findings

| # | Sev | Finding | Evidence |
|---|---|---|---|
| 1 | P1 | Hooks from before U5 still run in older worktrees and in satellites (W13). Their `close` writes what stays back as `dict(e, host=resumed(path) or stamp)`, which replaces `host` and keeps the entry's own `start`. When the session resumed while that sweep held its claim, the last entry pairs the new live process's `host` with the old process's `start`; U5's `last_host` takes both, `stamp_state` answers gone, and the next U5 sweep removes the live session's worktree (`worktree_records.py:142-151, 187-190`; d4a53e9 `worktree_sweep.py:94`) | reproduced: scratch clone at 28bb742 with the d4a53e9 lib; real pre-U5 `close` and `finish`, the resume injected as a U5 `rehost` entry; pre-U5 `kept …/U-w: its session resumed during this sweep`, last line `{"host": [96007, "Fri Nov 13 17:34:30 2026"], "start": {"epoch": 1700000000}, …}`, U5 `stamp_state` `gone`, U5 sweep `removed …/U-w; branch w deleted, HEAD contains it` while the holder still ran |
| 2 | P2 | A claim kept because its stamp cannot be told (`.*.jsonl.*-*`) does not match `*.jsonl`, so the worktrees named only in it count as unrecorded and the heal pass judges them; heal removes only a 24-hour idle, clean, merged worktree with no live lock and no process inside, so no work is lost, but it can remove a folder of a session the sweep could not judge (`worktree_sweep.py:48-49, 250-254`) | inspection |
| 3 | P2 | Errors escape `process_start.read`'s three answers: `PermissionError` on `/proc/<pid>/stat` (`hidepid`), `subprocess.TimeoutExpired` from the new 5 s `ps` timeout, `FileNotFoundError` with no `ps`; in `over` the sweep then aborts with a traceback before later records and the heal, and at the teardown gate `stamp()` leaves the worktree unrecorded (`process_start.py:59-61, 90-93`) | theoretical |
| 4 | P2 | `.agents/README.md:391-392` names the modules that hold worktree teardown's rules and not `process_start.py`, which now decides when a record's session has ended | inspection |
| 5 | P2 | `worktree_records.py` grew from 305 to 331 lines against the plan's "its 305 lines do not grow" (adopted plan-review P2 10): the loader, `stamp`, `stamp_state` and `last_host`; no function over 40 lines, nesting 4 or less, 4 parameters or fewer; R9 of `docs/reviews/2026-10-14-workloop-u5.md` flagged the file's size before | inspection |

The reviewer's answers to the writer's flagged choices: the kept claim loses
no work (finding 2); the JSON key order follows `sort_keys=True`, and no
production reader greps record text; `lsof` run from `/` changes only lsof's
own row and its Linux helper's, never a worktree's, and on macOS nothing.
Residual it did not probe: the U5 `upgrade` and `rehost` appends share the
older append race.

## QA

One QA cell (sonnet) at `28bb742`, every scenario in scratch clones under
`$TMPDIR/agent-death-probe/qa-u5/`, holders its own `sleep` processes.

| Acceptance | Observed | Result |
|---|---|---|
| 18 | Worktrees recorded under `TZ=Asia/Karachi` stay through sweeps under `TZ=America/New_York` and under `TZ=UTC LC_ALL=de_DE.UTF-8` (which changed `ps` to `Fr. 13 Nov. 12:26:40 2026`); at d4a53e9 the New York sweep printed `removed …/w18a; branch w18a deleted` and the same for `w18b`. That sweep removed both, so the d4a53e9 locale half has no run of its own; the writer's red-first locale row covers it | pass |
| 19 | macOS `process_start.state` at ±3 s `live`, ±6 s `gone`; `claude_lock_ended` False at ±3 s, True at ±6 s. Linux, run by the lead in the Linux-check image: same start `live`, ticks + 1 `gone`, another boot id `gone`, a finished pid `gone`, a macOS-form start `cannot tell` with one stderr line | pass |
| 20 | A text-only stamp of a live pid stays and its record gains `{"host": […same text…], "start": {"epoch": 1794572854}, "type": "host"}`; of a killed pid, `removed …/w20` | pass |
| 21 | macOS `"host": [34427, "Fri Nov 13 17:26:50 2026"], "start": {"epoch": 1794572810}`; Linux `"start": {"boot": "9a69bd16-…", "ticks": 21451463}` | pass |
| 22 | The 9be9158 sweep over a 28bb742 record of a live pid: exit 0, no output, record and worktree stay | pass |
| 23 | With the Linux clock held +10 s, the 28bb742 sweep keeps the record, twice. The d4a53e9 full sweep was not observed: Colima's VM clock returned to the host's within about 0.4 s in 8 of 8 tries, before the old sweep read the stamp. Inside a held step the d4a53e9 `alive` read the record gone and the 28bb742 `stamp_state` read it live, three runs | pass, d4a53e9 full sweep a gap |
| 24 | A fake `ps` printing `not a date`: exit 0, both records and worktrees stay, one stderr line per pid: `process start: cannot tell whether pid 34427 still runs: ps gives 'not a date' for its start, which does not parse` | pass |
| 25 | `linux-check.sh`: nine tests PASS with `test-session-end.sh`, `PASS procStart self-check`, exit 0. A first run failed the self-check while QA stepped the shared clock for 23, and the reviewer's first run failed `test-agent-waits.sh` in the same window; both reran clean | pass |

## Dispositions

| # | Disposition |
|---|---|
| 1 | Fix, reopening the lane. A stamp whose `start` reads gone but whose `host` text equals that pid's `ps -o lstart=` exactly, in the caller's locale and zone, reads live: equal text is never a false live, and it is the text branch the debt entry `worktree-records-local-stamps` already carries. The sweep then appends a host entry with the pid's own `start`, as for a text-only stamp, so the first sweep that sees the pair mends it. A test row writes the pair the reproduction produced and is red at 28bb742. QA reruns the reviewer's reproduction with the real d4a53e9 `close`. |
| 2 | Fix: worktree entries of kept claim files count as recorded; one assertion in the existing garbled-claim row. |
| 3 | Fix, since the module is this unit's own and unlanded and a sweep that aborts mid-run is the failure this plan exists for. All three errors read cannot tell with one stderr line naming the pid and the cause; `PermissionError` too, rather than gone as the reviewer offered, because a session's own process whose `/proc` entry cannot be read must not lose its worktrees. The death reader's handling of a failing `ps` stays as it was before this lane. |
| 4 | Fix, by the lead on main after the lane lands, with a sentence on when a process counts as gone. |
| 5 | Decline. `hostile-review.md:41` makes 300 lines a measurement to report, not a limit; R9 split the file by responsibility into recording, removal and sweep, and the four functions write and read a record's own stamp, which is recording's; no function crosses 40 lines. The plan's prediction missed because `stamp` and `stamp_state` are new code, not code the loader replaced. |
