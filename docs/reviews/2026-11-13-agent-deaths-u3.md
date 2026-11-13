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

Covers: 03fc3d9..b0b9a6c

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
