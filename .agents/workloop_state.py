"""The workloop state file and the reads every command makes of it.

`Store` and `ReadStore` hold the state file's lock. `.agents/hooks/lib/worktree_runs.py`
and `.agents/hooks/lib/agent_activity.py` write the same file under the same
`<state>.lock` file and `flock` protocol, so
the lock's name and the file's JSON layout (version 1, indented, sorted keys)
stay as they are here.
"""

from __future__ import annotations

import calendar
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import workloop_git as wg

ROOT = Path(__file__).resolve().parent.parent
# The hooks and the controller measure an agent's silence by the same function.
sys.path.insert(0, str(ROOT / ".agents/hooks/lib"))
import agent_activity  # noqa: E402
import agent_silence  # noqa: E402
DEFAULT_STATE = ROOT / ".agents/.workloop-state.json"
NAME = re.compile(r"[a-z0-9][a-z0-9_-]*")


def fail(message: str) -> None:
    raise SystemExit(f"workloop: {message}")


def now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def parse_stamp(value: str) -> float:
    return float(calendar.timegm(time.strptime(value, "%Y-%m-%dT%H:%M:%SZ")))


def state_path(value: str | None) -> Path:
    if value:
        return Path(value).resolve()
    # A lane worker running the copy of this script inside its worktree would
    # otherwise create a second, empty state file there and coordinate with
    # nobody. The brief passes --state absolute; this catches the case where
    # the brief was not followed.
    if wg.is_linked_worktree(ROOT):
        fail(f"{ROOT} is a linked worktree; pass --state with the run's absolute state path")
    return DEFAULT_STATE


def valid_name(kind: str, value: str) -> None:
    # Run and lane names become compose project names and docker labels;
    # compose lowercases and strips what it does not accept, and a name it
    # rewrote would never match the one the controller reaps by.
    if not NAME.fullmatch(value):
        fail(f"{kind} name {value!r} must be lowercase letters, digits, '-' or '_', starting with a letter or digit")


def event_id(run: str, action: str, lane: str, detail: str) -> str:
    raw = "\0".join((run, action, lane, detail, now(), str(time.time_ns())))
    return hashlib.sha256(raw.encode()).hexdigest()[:16]


class Store:
    def __init__(self, path: Path):
        self.path = path
        self.lock_path = path.with_suffix(path.suffix + ".lock")

    def __enter__(self) -> dict:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.lock = self.lock_path.open("a+")
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        if not self.path.exists():
            self.data = {"version": 1, "runs": {}}
        else:
            try:
                self.data = json.loads(self.path.read_text())
            except json.JSONDecodeError as exc:
                fail(f"state is invalid JSON: {exc}")
        if self.data.get("version") != 1 or not isinstance(self.data.get("runs"), dict):
            fail("state has an unsupported schema")
        return self.data

    def __exit__(self, *_: object) -> None:
        fd, temporary = tempfile.mkstemp(prefix=self.path.name + ".", dir=self.path.parent)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(self.data, stream, indent=2, sort_keys=True)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
            fcntl.flock(self.lock, fcntl.LOCK_UN)
            self.lock.close()


class ReadStore:
    """Shared-locked state reader that never touches the ledger or lock file."""
    def __init__(self, path: Path): self.path = path
    def __enter__(self) -> dict:
        if not self.path.is_file(): fail("state file does not exist")
        lock_path = self.path.with_suffix(self.path.suffix + ".lock")
        if not lock_path.is_file(): fail("state lock is missing; use a mutating workloop command to recover it")
        self.lock = lock_path.open("r")
        fcntl.flock(self.lock, fcntl.LOCK_SH)
        self.data = json.loads(self.path.read_text())
        if self.data.get("version") != 1 or not isinstance(self.data.get("runs"), dict): fail("state has an unsupported schema")
        return self.data
    def __exit__(self, *_: object) -> None:
        fcntl.flock(self.lock, fcntl.LOCK_UN); self.lock.close()


def run_of(data: dict, name: str) -> dict:
    run = data["runs"].get(name)
    if run is None:
        fail(f"no run named {name!r}; create it with init")
    # base is a commit SHA and repo the checkout it was resolved in; every
    # worktree, merge, and staleness check below depends on both being fixed.
    if not wg.SHA.fullmatch(str(run.get("base", ""))) or not run.get("repo"):
        fail(f"run {name!r} predates pinned bases; re-init it (base must be a commit SHA with a repo)")
    return run


def lane_of(run: dict, name: str) -> dict:
    lane = run["lanes"].get(name)
    if lane is None:
        fail(f"run has no lane named {name!r}")
    return lane


def replayed(run: dict, supplied: str | None) -> bool:
    return bool(supplied and any(event["id"] == supplied for event in run["events"]))


def record(run_name: str, run: dict, action: str, lane: str = "", detail: str = "", supplied: str | None = None) -> None:
    key = supplied or event_id(run_name, action, lane, detail)
    run["events"].append({"id": key, "at": now(), "action": action, "lane": lane, "detail": detail})


def require_workspace(lane: dict) -> Path:
    return wg.worktree_root(Path(lane["workspace"]))


def shared_of(run: dict) -> list[str]:
    return run.get("shared", [])


def rebuild_of(run: dict) -> dict[str, str]:
    """Each rebuilt shared path and its command; a run from before `share --rebuild` holds none."""
    return run.get("rebuild", {})


def rebuild_steps(run: dict) -> list[tuple[str, str]]:
    """The rebuild commands in declaration order: the `shared` list's, since the state file sorts the map's keys."""
    rebuild = rebuild_of(run)
    return [(path, rebuild[path]) for path in shared_of(run) if path in rebuild]


def pending_messages(run: dict, lane: str) -> list[dict]:
    return [message for message in run["messages"] if message["to"] == lane and message["requires_ack"] and not message.get("acknowledged_at")]


def age_text(seconds: float) -> str:
    """A span in the coarsest unit that keeps it exact enough to read: 45s, 12m, 3h05m."""
    seconds = max(0, int(seconds))
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    return f"{seconds // 3600}h{seconds % 3600 // 60:02d}m"


def silence(agent: dict, since_key: str, at: float | None = None) -> tuple[float, float | None]:
    """Seconds out and seconds since the last sign of life, for a lane (`since_key` claimed_at)
    or a cell (out_since). A sign of life is the hook's stamp or a lane's own heartbeat; the
    silence is None for an agent that shows neither, which `unstamped` names."""
    at = time.time() if at is None else at
    quiet = agent_silence.silence(agent, since_key, at)
    if quiet is None:
        fail(f"agent has no usable {since_key}")
    return at - parse_stamp(agent[since_key]), quiet if agent_silence.stamped(agent) else None


last_sign = agent_silence.last_sign


def clock_text(value: float) -> str:
    """A time of day in UTC, `13:05Z`."""
    return time.strftime("%H:%MZ", time.gmtime(value))


def activity_columns(agent: dict, since_key: str) -> str:
    """The tab-separated tail `status` prints for an agent that is out: time out, silence in whole
    minutes, last action; `unstamped` in place of the silence for an agent with no stamp and no heartbeat."""
    out, quiet = silence(agent, since_key)
    heard = "unstamped" if quiet is None else f"silent {int(quiet) // 60}m"
    return f"\tout {age_text(out)}\t{heard}" + (f"\t{agent['activity']}" if agent.get("activity") else "")


def refresh_readout(state: Path, repo: str) -> None:
    """Rewrite the repository's `workloop` readout from the state, so it is true the moment a run's agents change."""
    try:
        agent_activity.write_readout(state, Path(repo), time.time())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"workloop: the workloop readout was not refreshed: {error}", file=sys.stderr)
