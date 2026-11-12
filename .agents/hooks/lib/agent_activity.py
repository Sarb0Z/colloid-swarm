#!/usr/bin/env python3
"""Stamp a background agent's last sign of life into the workloop state.

Usage: agent_activity.py <state-path> <agents-dir> <session> <event> <agent-id> <transcript-path>
The normalized hook payload arrives on stdin; a batch's last tool call is its
`tool_name` and `tool_input`.

The inbox hook runs this between a subagent's tool calls. The agent reports
nothing: the stamp is the time and a few words of its last tool call, taken from
the hook payload, so an agent that is stuck or silent still shows an age.

A lane is bound by its claim. A cell is bound by the brief header in the first
record of its transcript, `<dirname(transcript-path)>/<session>/subagents/agent-<agent-id>.jsonl`:
`WORKLOOP CELL BRIEF — <run>/<name>` on its first line, or on its second after a
`READ-ONLY`, `NOTES-ONLY` or `WORKSPACE: <path>` line; the transcript is read for
nothing else, and only when no lane is claimed by the agent. The stamp lands on
`activity_at` and `activity` of the lane or cell, and a bound cell takes the
agent's id as `agent_id`, by which the death reader (agent_deaths.py) finds it.
It lands at most once a minute per agent (<agents-dir>/.readout/.activity-<session>-<agent>,
the gitignored folder the readout's own files live in; a batch that bound to
nothing writes it too, so an unbound agent costs one lookup a minute), under the
state file's lock and in the layout `workloop_state.Store` writes. It then
refreshes the repository-wide `workloop` readout (`readout.py`): agents out and
the oldest silence, empty when none is out; the lead's prompt refreshes it too.

The state lock is taken without blocking and retried for about a second; a hook
that must not block reports on stderr and exits 0 when it cannot get it.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path

from agent_silence import silence, stamped

INTERVAL_SECONDS = 60
ACTION_MAX = 70
READOUT_STALE_SECONDS = 600
LOCK_TRIES = 20
LOCK_WAIT = 0.05
CELL_HEADER = re.compile(r"WORKLOOP CELL BRIEF — (\S+)/(\S+)")
# The first prompt lines the delegation guide lets precede the header (.agents/claude/delegation.md).
MARKER_LINE = re.compile(r"(READ-ONLY|NOTES-ONLY)\b|WORKSPACE:\s*\S")
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")
# The input field that says most about a tool call, in order of preference.
DETAIL_KEYS = ("description", "file_path", "command", "pattern", "path", "url", "query", "prompt")


class LockBusy(RuntimeError):
    """Another process holds the state lock past the retry window."""


@contextmanager
def state_lock(state: Path, mode: int):
    """The state file's lock, taken without blocking and retried briefly."""
    with open(f"{state}.lock", "a+") as lock:
        for _ in range(LOCK_TRIES):
            try:
                fcntl.flock(lock, mode | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                time.sleep(LOCK_WAIT)
        else:
            raise LockBusy(f"{state}.lock is held by another process")
        yield


def clean(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]", "", value)


def transcript(transcript_path: str, session: str, agent_id: str) -> Path:
    return Path(transcript_path).parent / session / "subagents" / f"agent-{agent_id}.jsonl"


def first_text(path: Path) -> str:
    """The text of the transcript's first record, or '' when it holds none."""
    with path.open(encoding="utf-8") as source:
        line = source.readline()
    content = json.loads(line).get("message", {}).get("content", "") if line.strip() else ""
    if isinstance(content, list):
        content = "\n".join(part.get("text", "") for part in content if isinstance(part, dict))
    return content if isinstance(content, str) else ""


def cell_binding(path: Path) -> tuple[str, str] | None:
    """The run and cell the transcript's brief header names, or None."""
    lines = first_text(path).splitlines()
    for index in (0, 1):
        found = CELL_HEADER.fullmatch(lines[index].strip()) if index < len(lines) else None
        if found and (index == 0 or MARKER_LINE.match(lines[0].strip())):
            return found.group(1), found.group(2)
    return None


def summary(tool_name: str, tool_input: dict) -> str:
    """The tool and the one input field that says most about the call; '' when the payload names no tool."""
    if not tool_name:
        return ""
    detail = ""
    for key in DETAIL_KEYS:
        value = tool_input.get(key)
        if isinstance(value, str) and value.strip():
            detail = os.path.basename(value) if key == "file_path" else value
            break
    text = CONTROL.sub(" ", f"{tool_name} {detail}").strip()
    return text if len(text) <= ACTION_MAX else text[:ACTION_MAX - 1] + "…"


def due(ledger: Path, now: float) -> bool:
    try:
        return now - float(ledger.read_text()) >= INTERVAL_SECONDS
    except (OSError, ValueError):
        return True


def holds_lane(state: Path, agent_id: str) -> bool:
    """Whether a live run's active lane is claimed by the agent."""
    with state_lock(state, fcntl.LOCK_SH):
        data = json.loads(state.read_text())
    return any(lane.get("claimed_by") == agent_id and lane.get("state") == "active"
               for run in data.get("runs", {}).values() if not run.get("torn_down")
               for lane in run.get("lanes", {}).values())


def stamp_state(state: Path, agent_id: str, cell: tuple[str, str] | None, action: str) -> bool:
    """Write the stamp on the agent's lane or cell; False when the state names neither."""
    with state_lock(state, fcntl.LOCK_EX):
        data = json.loads(state.read_text())
        target = None
        for run in data.get("runs", {}).values():
            if run.get("torn_down"):
                continue
            target = next((lane for lane in run.get("lanes", {}).values()
                           if lane.get("claimed_by") == agent_id and lane.get("state") == "active"), None)
            if target:
                break
        if target is None and cell:
            found = (data.get("runs", {}).get(cell[0]) or {}).get("cells", {}).get(cell[1])
            target = found if found and found.get("state") == "out" else None
            if target is not None:
                # The death reader finds the cell's agent by this id.
                target["agent_id"] = agent_id
        if target is None:
            return False
        target["activity_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        if action:
            target["activity"] = action
        fd, temporary = tempfile.mkstemp(prefix=state.name + ".", dir=state.parent)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(data, stream, indent=2, sort_keys=True)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, state)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    return True


def agents_out(data: dict, at: float) -> list[tuple[str, str, int | None, str]]:
    """Each active lane and cell out in a live run: name, role, seconds silent, last action.
    Silence is `agent_silence.silence`; it is None for an agent with no stamp and no heartbeat,
    which has shown nothing since it went out."""
    found = []
    for run_name, run in data.get("runs", {}).items():
        if run.get("torn_down"):
            continue
        for name, lane in run.get("lanes", {}).items():
            if lane.get("state") == "active":
                found.append((f"{run_name}/{name}", lane.get("worker", "worker"), lane, "claimed_at"))
        for name, cell in (run.get("cells") or {}).items():
            if cell.get("state") == "out":
                found.append((f"{run_name}/{name}", cell.get("role", "cell"), cell, "out_since"))
    return [(label, role, int(seconds) if stamped(agent) else None, agent.get("activity") or "-")
            for label, role, agent, since in found
            if (seconds := silence(agent, since, at)) is not None]


def write_readout(state: Path, repo: Path, at: float) -> None:
    """The repository-wide `workloop` readout: agents out and the oldest silence; empty when none is out."""
    out = agents_out(json.loads(state.read_text()), at)
    heard = sorted((agent for agent in out if agent[2] is not None), key=lambda agent: -agent[2])
    unstamped = [agent for agent in out if agent[2] is None]
    # The oldest silence is judged over agents that stamped; an unstamped one is counted apart.
    parts = [f"{len(out)} agent{'s' if len(out) != 1 else ''} out"]
    if heard:
        parts.append(f"oldest silent {heard[0][2] // 60}m")
    if unstamped:
        parts.append(f"{len(unstamped)} unstamped")
    strip = ", ".join(parts) if out else ""
    note = "\n".join([f"{label} ({role}) silent {quiet // 60}m: {action}" for label, role, quiet, action in heard]
                     + [f"{label} ({role}) unstamped" for label, role, _, _ in unstamped])
    subprocess.run([sys.executable, str(Path(__file__).with_name("readout.py")), "write", "workloop", "--strip", strip, "--note", note,
                    "--stale-after", str(READOUT_STALE_SECONDS), "--repo", str(repo)], check=True)


def stamp_agent(state: Path, agents_dir: Path, session: str, event: str, agent_id: str, transcript_path: str, action: str) -> None:
    ledger = agents_dir / ".readout" / f".activity-{clean(session)}-{clean(agent_id)}"
    now = time.time()
    if not due(ledger, now):
        return
    cell = None
    if transcript_path and not holds_lane(state, agent_id):
        path = transcript(transcript_path, session, agent_id)
        try:
            cell = cell_binding(path)
        except (OSError, ValueError) as error:
            # The file is written after SubagentStart, so only a later miss is a fault.
            if event != "SubagentStart":
                print(f"agent_activity: {path} cannot be read ({error}); {agent_id} is not stamped", file=sys.stderr)
    stamped_now = stamp_state(state, agent_id, cell, action)
    # A batch that bound to nothing is remembered too, so a stranger costs one lookup a minute.
    if stamped_now or event == "PostToolBatch":
        ledger.parent.mkdir(parents=True, exist_ok=True)
        ledger.write_text(f"{now}\n")
    if stamped_now:
        write_readout(state, agents_dir.parent, now)


def main() -> None:
    state, agents_dir, session, event, agent_id, transcript_path = sys.argv[1:7]
    if not agent_id:
        # The lead's prompt refreshes the readout, so it clears once the last agent is back.
        if event == "UserPromptSubmit":
            write_readout(Path(state), Path(agents_dir).parent, time.time())
        return
    if event not in ("SubagentStart", "PostToolBatch"):
        return
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        payload = {}
    tool_input = payload.get("tool_input") if isinstance(payload, dict) else None
    action = summary(str(payload.get("tool_name") or "") if isinstance(payload, dict) else "", tool_input if isinstance(tool_input, dict) else {})
    try:
        stamp_agent(Path(state), Path(agents_dir), session, event, agent_id, transcript_path, action)
    except LockBusy as error:
        print(f"agent_activity: {agent_id} is not stamped this time: {error}", file=sys.stderr)


if __name__ == "__main__":
    main()
