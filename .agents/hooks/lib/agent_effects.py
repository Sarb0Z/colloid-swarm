"""The death and wait readers' real effects, and the ways in that wire them.

agent_deaths.py judges from parameters; this module supplies the clock, the
home folder, `ps`, Git and the cache's atomic write, for the hooks
(`read_in_hook`, called by workloop-inbox.py), for `workloop.py dismiss`
(`death_at`), and for `agent_deaths.py show`, which reads the workloop runs as
the hooks do. agent_waits.py's agents waiting on the operator are read the
same way, for the hooks (`waiting_in_hook`) and for `workloop.py watch`
(`waiting`).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import agent_deaths as ad
import agent_records as ar
import agent_sessions as sessions
import agent_verdicts as av
import agent_waits as aw
from workloop_size import GitBudget

STATE = Path(".agents") / ".workloop-state.json"


def proc_start(pid: int) -> str | None:
    """The process's start as Claude Code's registry records it, or None when no such process runs."""
    env = dict(os.environ, LC_ALL="C", TZ="UTC")
    result = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True, env=env, timeout=5)
    return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else None


def write_atomic(path: Path, text: str) -> None:
    handle, temporary = tempfile.mkstemp(prefix=f"{path.name}.", dir=path.parent)
    try:
        with os.fdopen(handle, "w") as stream:
            stream.write(text)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def real(git) -> ad.Effects:
    return ad.Effects(now=time.time(), home=Path.home(), config_dir=os.environ.get("CLAUDE_CONFIG_DIR", ""),
                      proc_start=proc_start, git=git, write=write_atomic)


def runs_at(state: Path) -> dict:
    """The runs not torn down in a workloop state file; none when there is no file. A file that
    does not parse raises ValueError, so a command never reads it as holding no run."""
    try:
        data = json.loads(state.read_text())
    except FileNotFoundError:
        return {}
    runs = data.get("runs") if isinstance(data, dict) else None
    if not isinstance(runs, dict):
        raise ValueError(f"{state} holds no runs table")
    return {name: run for name, run in runs.items() if not run.get("torn_down")}


def read_in_hook(repo: Path, session: str, runs: dict, git) -> ad.Report:
    """`report` with the real effects, for a hook that must not block: a reader that fails says
    so on stderr and in the block, and the hook goes on."""
    try:
        return ad.report(repo, session, runs, real(git))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"agent deaths: the reader failed: {error}", file=sys.stderr)
        return ad.Report(problems=[f"agent deaths: the reader failed ({error}), so no dead agent is listed"])


def liveness(entries: list[dict]):
    """`live(session)`: True while a registry entry names it with its process's start, False
    otherwise, and None for every session while no entry passes that test, since then the test
    itself may not hold on this host; and `entry(session)`, that running entry or None."""
    hosts = sessions.Hosts(entries, "", proc_start)

    def live(session: str) -> bool | None:
        if hosts.live(session):
            return True
        return False if any(hosts.live(entry["session"]) for entry in entries) else None
    return live, hosts.live


def waiting(agents_dir: Path) -> tuple[dict, list[str], list[str]]:
    """The agents waiting on the operator in the checkout whose `.agents` folder is `agents_dir`:
    the open permission waits {agent id: wait}, every WAITING ON YOU line, the blocked background
    sessions' after the agents', and a problem line for each record that could not be read."""
    dirs = ar.config_dirs(Path.home(), os.environ.get("CLAUDE_CONFIG_DIR", ""))
    entries, problems = sessions.registry(dirs)
    live, entry = liveness(entries)
    waits = aw.open_waits(agents_dir, live, entry)
    jobs, unreadable = sessions.jobs(dirs)
    return waits, aw.agent_lines(waits) + aw.job_lines(jobs, agents_dir.parent, live), problems + unreadable


def waiting_in_hook(agents_dir: Path) -> str:
    """`waiting`'s lines for a hook that must not block: a read that fails says so on stderr and
    in the block, and the hook goes on. Its problem lines are left out: the death reader, run
    in the same hook, reads the same registry and job files and names each unreadable one."""
    try:
        _, lines, _ = waiting(agents_dir)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"agent waits: the reader failed: {error}", file=sys.stderr)
        return f"agent waits: the reader failed ({error}), so no agent waiting on you is listed"
    return "\n".join(lines)


def death_at(state: Path, agent_id: str, git) -> float | None:
    """When the agent's newest death of the checkout holding the workloop state file `state` was
    judged, or None when it is no dead agent of that checkout. A read outside any session judges
    no agent lost by liveness; it keeps the verdicts the last session read gave."""
    verdict = ad.report(state.parent.parent, "", runs_at(state), real(git)).verdicts.get(agent_id)
    return verdict.at if verdict and verdict.state in av.SHOWN else None


def show(argv: list[str]) -> None:
    if len(argv) not in (2, 3) or argv[0] != "show":
        sys.exit(f"usage: {ad.SHOW} <repo> [<session>]")
    repo = Path(argv[1]).resolve()
    try:
        runs = runs_at(repo / STATE)
    except ValueError as error:
        sys.exit(f"agent deaths: {error}")
    text = ad.report(repo, argv[2] if len(argv) == 3 else "", runs, real(GitBudget().out)).block(None, True)
    if text:
        print(text)
