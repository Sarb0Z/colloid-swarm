# Agent deaths U3: code review round 1

Unit U3 of `docs/handoff/2026-11-13-agent-deaths.md`, run `agent-deaths-u3`,
one worktree lane `u3-linux`: `.agents/linux-check.sh` runs the death reader's
and the touched hook tests in an `ubuntu:24.04` container and the reader's
`procStart` self-check against that container's `ps` (Acceptance 11 and 14).
One reviewer (opus) read the file whole and its seams with `suite.sh`'s copy,
the test-file lints, the processes playbook, the workloop's Docker labels, the
reader's self-check path and the tests' host assumptions, under the verbatim
contract; Critical stakes, as part of a plan that changes guard hooks and
contracts.

Covers: 62291ca604ba..27942ac8a463

## Findings

| # | Sev | Finding | Evidence |
|---|---|---|---|
| 1 | P2 | The mismatch half of the self-check passes on any "cannot tell live sessions on this host" line, which the reader also prints when no registry entry names its session; with no `set -e`, a `date` that fails leaves `off` empty and the half still passes (`linux-check.sh:115-121`, `agent_sessions.py:103-108`) | inspection |
| 2 | P2 | The probe takes both `procStart` values from the reader's own `ps` rule milliseconds apart, so it cannot see the rule fail over time: on Linux `ps` derives `lstart` from `/proc/stat` `btime`, which a clock step moves, so a session older than the step reads `ended` and its running agents `lost` to a reader started after it, and the reader of a session older than the step stays on `cannot tell` (`agent_sessions.py:94-95`, `agent_effects.py:32-36`) | theoretical |
| 3 | P2 | The tests run as root in the container, where a mode-0 file still opens, so `test-agent-deaths.sh:637-640` ("an unchanged transcript was opened again") cannot fail there; the only permission-dependent assertion of the eight | reproduced: `id -u` 0, a `chmod 0` file read |
| 4 | P2 | A test name that does not exist, or a container lost mid-run, exits 1 like a failing test, against the header's exit 2 for setup failures (`linux-check.sh:84-92`) | reproduced: `linux-check.sh test-no-such.sh` exit 1 |
| 5 | P2 | The image is reused whenever its tag exists, so an edit to the Dockerfile text never reaches a machine that built the image before (`linux-check.sh:52-63`) | inspection |
| 6 | P2 | The image and container carry `colloid.run=linux-check`, the workloop's run label, which the teardown of a run named `linux-check` would reap; inside a lane the script sets no `colloid.run`/`colloid.lane` from `COLLOID_RUN`/`COLLOID_LANE`, so a SIGKILLed run's container stays up to an hour (`linux-check.sh:54,65`, `workloop_docker.py:57-72`) | inspection |
| 7 | P2 | Two comments say more than the code: the copy is "as suite.sh copies them", where the script commits the files as one fresh root commit; the ownership check needs no identity (`linux-check.sh:8-10,49-51`) | inspection |
| 8 | P2 | The header describes the default list as "the hook tests the agent-deaths work touches", history in a file the export ships to satellites (`linux-check.sh:7`, `export-scaffold.py:20-44`) | inspection |
| 9 | P2 | A passing test's output is dropped, so its `note:` lines go, such as `test-session-start.sh:708`'s skipped mis-cased rows on the container's case-sensitive file system (`linux-check.sh:85-91`) | inspection |

AMBIGUITY: whether `linux-check.sh` ships to satellites; settled as (b), it
ships: the export drops no hook test, so a satellite carries the eight tests
it runs, and the header describes the list by what it covers.

## QA

One QA cell (sonnet) at `b0b9a6c`, from the lane worktree.

| Scenario | Observed | Result |
|---|---|---|
| Cold first run, after `docker rmi colloid-linux-check:ubuntu-24.04` | the "building" line, 8 PASS, `PASS procStart self-check`, exit 0, 187 s | pass |
| Cached rerun | no build line and no image events under `docker events --filter type=image`, same output, exit 0, 191 s | pass |
| One named test | `test-readout.sh` and the self-check pass, exit 0 | pass |
| A failing test, in a scratch copy | `FAIL test-readout.sh`, its output indented, `linux-check: 1 failed: test-readout.sh`, exit 1 | pass |
| A reader that never notices a mismatch (`agent_sessions.py:95` compared as `True`), in a scratch copy | `FAIL procStart self-check`, exit 1 | pass |
| No `docker` on PATH; `DOCKER_HOST=unix:///nonexistent.sock` | "docker is not installed or not on PATH", exit 2; "the docker daemon is not reachable (on Colima: colima start)", exit 2 | pass |
| SIGINT and SIGTERM 40 s in, 4 tests done | exit 130 and 143; no container labelled `colloid.run=linux-check` left | pass |
| An uncommitted edit that breaks `readout.py`, in a scratch copy | `test-readout.sh` fails in the container with the edit's message | pass |

The reviewer's own full run: 8 PASS and the self-check, exit 0, 3:07. Not
run: an Ubuntu server host (Decision 4 (a)); the network was not blocked for
the cached rerun.

## Dispositions

The controller files a `P2` and accepts the lane; the fixes below go to one
follow-up writer lane after the lane lands.

| # | Disposition |
|---|---|
| 1 | Fix. The mismatch half requires `ps gives` and the offset value in the reader's line, and fails when the offset is empty or equals the `ps` value. |
| 2 | Fix, after reproducing it: in a container with `SYS_TIME`, a clock step moves a running process's `lstart`. The reader matches a registry entry whose `procStart` lies within a few seconds of `ps`, a named constant: a reused pid belongs to a process started after its session ended, so its start differs from the recorded one by at least the session's lifetime. A step larger than the constant stays a breadcrumb, and the plan's Test seams says what the container misses. |
| 3 | Fix. The tests run as a normal user in the container. |
| 4 | Fix. An unknown test name exits 2 before the container starts; a lost container exits 2. |
| 5 | Fix. The tag carries a hash of the Dockerfile text. |
| 6 | Fix. A label of the script's own, plus `colloid.run` and `colloid.lane` from `COLLOID_RUN` and `COLLOID_LANE` when set. |
| 7 | Fix. The comments state what the code does. |
| 8 | Fix. The header describes the list by what it covers. |
| 9 | Fix. A passing test's `note:` and `SKIP` lines are printed. |

# Follow-up lane: code review round 1

Run `agent-deaths-u3b`, one worktree lane `u3b-fixes`: Dispositions 1-9
above, and one defect the lead found live during the run (below). One
reviewer (opus) read the scope whole and its seams under the verbatim
contract; one QA cell (sonnet) ran eight scenarios beside it.

Covers: 775ca53292e8..582f7d408d18

## The defect found live

The lane's writer ran `linux-check.sh` as a foreground Bash call. Claude Code
moved the call to the background after 180 s: its `tool_use` carries no
`run_in_background`, and its tool result record carries
`toolUseResult.backgroundTaskId`. The writer then ended its turn with text
while the command ran. The reader judged it `completed` (rule 2, an answer),
and the inbox hook's `active_note` reaped the lane's labelled container: the
run printed `the container was lost during test-workloop.sh`, exit 2.
`how_it_ends` on the writer's transcript cut at that moment
(`$TMPDIR/agent-death-probe/autobg/agent-cut.jsonl`) gives `answer` at
51add4e and `waiting` at 378920d; the whole transcript gives `handback`.

The reviewer counted the marker in the real transcripts: 671 agent
transcripts carry `"backgroundTaskId":"`, 635 of them background agents and
none foreground; all 849 such results are Bash, 540 with
`run_in_background: true` and 309 moved to the background.

## Disposition 2 reproduction

The writer stepped a `--cap-add SYS_TIME` container's clock and read a running
process's start:

| Reading | `ps -o lstart=` | `/proc/stat` btime |
|---|---|---|
| Before | Fri Nov 13 10:36:05 2026 | 1794357955 |
| After `date -s '+2 seconds'` | Fri Nov 13 10:36:07 2026 | 1794357957 |
| After `date -s '-2 seconds'` | Fri Nov 13 10:36:05 2026 | 1794357955 |

QA read a registry entry with `Hosts` on a stepped clock, the entry's
`procStart` taken from `ps` at 11:02:48:

| Clock | `ps` lstart | `Hosts` state |
|---|---|---|
| Baseline | 11:02:48 | live |
| +3 s | 11:02:51 | live |
| +10 s | 11:02:58 | ended |
| Back to the original | 11:02:48 | live |

The clock is the Colima VM's, shared by every container; each step was undone
in the same `docker exec`.

## Findings

| # | Sev | Finding | Evidence |
|---|---|---|---|
| 1 | P1 | The image is built with the run's labels, so `colloid-linux-check:ubuntu-24.04-458851885` carries `colloid.run=agent-deaths-u3b` and `colloid.lane=u3b-fixes`, and every later container from it inherits them; a lane reap by those labels removes another run's container mid-run, against `workloop_docker.py`'s "never anything else" (`linux-check.sh:47-49,84`) | reproduced by the reviewer (`docker create` from the image, listed by the lane's label filter) and by QA (an env-less run's container carried both labels) |
| 2 | P2 | Disposition 2's plan rule, Test seams line, breadcrumb and reproduction record are not in the range | inspection |
| 3 | P2 | `worktree_records.alive` compares `lstart` as exact text, a second copy of the liveness rule; a Linux clock step makes the worktree sweep read a live session as gone (`worktree_records.py:129-131`, `worktree_sweep.py:70-71,83,102`, `workloop-inbox.py:172`) | theoretical |
| 4 | P2 | The self-check never shows the slack works on Linux `ps` output: its probe entries are exact or an hour off, so a format `LSTART_FORMAT` cannot parse would switch the slack off unseen (`linux-check.sh:118-150`) | inspection |
| 5 | P2 | A foreground worker whose Bash call is moved to the background and which then answers gets rule 1's `completed` from its `Agent` call result before `waiting` is read, so its lane is still reaped mid-command (`agent_verdicts.py:170-175`, `agent_records.py:191-194`) | theoretical; 0 foreground agents among the 671 transcripts |
| 6 | P2 | Each change to the Dockerfile text leaves another unused image of about 321 MB that nothing removes (`linux-check.sh:46,82-86`) | reproduced: `docker image ls` lists both tags |
| 7 | P2 | The header overclaims: `test-style-inject.sh` reads no process table, file mode, clock or git ownership; the image labels let no teardown reap anything, since `workloop_docker.owned` lists no images (`linux-check.sh:7-10,21-23`) | inspection |
| 8 | P2 | A container lost during the self-check exits 1, not 2 (`linux-check.sh:153-159`) | inspection |

Finding 3 extends past a clock step. `worktree_records.ps_row` reads
`lstart` in the session's own time zone, and one process's start reads
`11:06:59`, `16:06:59` and `06:06:59` under `TZ=UTC`, `Asia/Karachi` and
`America/New_York`. After a Mac's time zone changes, the sweep therefore
reads every session recorded before the change as gone; `worktree_removal.py`
saves a gone session's unsaved work to `saved/<name>` before it removes the
worktree. Records hold local-time text, so reading in UTC without a migration
would read every live session as gone once.

## QA

One QA cell (sonnet) at `2f9629b`.

| Scenario | Observed | Result |
|---|---|---|
| 1 Full run | 8 PASS, `PASS procStart self-check`, the indented `note:` line under `test-session-start.sh`, `linux-check: all passed`, exit 0, about 3.5 min | pass |
| 2 Labels | with `COLLOID_RUN=qa-label-probe COLLOID_LANE=probe`: all three labels; with neither set, the container carried `colloid.run=agent-deaths-u3b colloid.lane=u3b-fixes`, from the image | fail (finding 1) |
| 3 Dockerfile edit | `building colloid-linux-check:ubuntu-24.04-1025532827`; the unedited script built nothing | pass |
| 4 Setup exits | `no test named test-no-such.sh in .agents/`, exit 2, 0 Docker events; `docker rm -f` mid-run: `the container was lost during test-workloop.sh`, exit 2 | pass |
| 5 Normal user | with both cache checks in `agent_deaths.py` disabled, `FAIL: an unchanged transcript was opened again`, exit 1, on the host and in the container | pass |
| 6 Mismatch half | the mismatch reason replaced by the no-entry text: `FAIL procStart self-check`, exit 1 | pass |
| 7 Stepped clock | the `Hosts` table above | pass |
| 8 Moved to the background | cut `waiting`, whole `handback`, cut at 51add4e `answer`; `test-agent-deaths.sh` exit 0, twice | pass |

## Dispositions

| # | Disposition |
|---|---|
| 1 | Fix, reopening the lane. `LABEL colloid.tool=linux-check` goes in the Dockerfile text, so the tag changes; `colloid.run` and `colloid.lane` go on `docker run` only. QA reruns scenario 2. |
| 2 | Fix, by the lead on main after the lane lands. |
| 3 | Defer to the operator: the fix needs a migration of the recorded start texts, so it is a unit of its own. |
| 4 | Fix. A probe entry 3 s off `ps` must read live. |
| 5 | Defer. A breadcrumb names the one-session probe. |
| 6 | Fix. After a build, the other `colloid-linux-check:*` tags are removed; a failed removal prints one line on stderr. |
| 7 | Fix. |
| 8 | Fix. |

The operator ruled finding 3 into this delivery as U5 of the plan.

## Fixes

`e703c7a` carries Dispositions 1, 4, 6, 7 and 8, in `linux-check.sh` only.
The writer's full run built `colloid-linux-check:ubuntu-24.04-2548917560`,
whose labels are `colloid.tool=linux-check` alone, and removed the two older
images. The review contract gives a `P1` fix no new round; QA reran.

## QA round 2, at `e703c7a`

One QA cell (sonnet); every scenario through the script.

| Scenario | Observed | Result |
|---|---|---|
| Full run with `COLLOID_RUN=qa-label-probe COLLOID_LANE=probe` | the container carried all three labels, the image `colloid.tool` alone; 8 PASS, `PASS procStart self-check`, `linux-check: all passed`, exit 0 | pass |
| One test with neither variable set | the container carried `colloid.tool=linux-check` alone; exit 0 | pass |
| `START_SLACK_SECONDS = 0` in a scratch copy | `FAIL procStart self-check`, naming `procStart [Fri Nov 13 11:16:31 2026] 3 s after ps [Fri Nov 13 11:16:28 2026]`, exit 1 | pass |
| A Dockerfile edit, then a second with the first image in use | the first build left only its own tag; the second printed `could not remove the old image colloid-linux-check:ubuntu-24.04-2199238142` on stderr and exited 0 | pass |
| `docker rm -f` during the self-check (a `sleep 30` added to the probe) | `the container was lost during the procStart self-check`, exit 2 | pass |
