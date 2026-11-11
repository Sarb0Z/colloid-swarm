#!/usr/bin/env python3
"""Stamp a background agent's last sign of life into the workloop state.

Usage: agent_activity.py <state-path> <seen-dir> <session> <event> <agent-id> <transcript-path>

The inbox hook runs this between a subagent's tool calls. The agent reports
nothing: the stamp is the time and a few words of its last tool call, read from
its own transcript, so an agent that is stuck or silent still shows an age.

A lane is bound by its claim. A cell is bound by the brief header in the first
record of its transcript, `<dirname(transcript-path)>/<session>/subagents/agent-<agent-id>.jsonl`:
`WORKLOOP CELL BRIEF — <run>/<name>` on its first line, or on its second after
`READ-ONLY`. The stamp lands on `activity_at` and `activity` of the lane or
cell, at most once a minute per agent (<seen-dir>/.activity-<session>-<agent>),
under the state file's lock and in the layout `workloop_state.Store` writes. It then
refreshes the repository-wide `workloop` readout (`readout.py`): agents out and the
oldest silence, empty when none is out; the lead's prompt refreshes it too.
"""

from __future__ import annotations

import calendar
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

INTERVAL_SECONDS = 60
ACTION_MAX = 70
READOUT_STALE_SECONDS = 600
TAIL_BYTES = 65536
CELL_HEADER = re.compile(r"WORKLOOP CELL BRIEF — (\S+)/(\S+)")
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")
# The input field that says most about a tool call, in order of preference.
DETAIL_KEYS = ("description", "file_path", "command", "pattern", "path", "url", "query", "prompt")


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
        if found and (index == 0 or lines[0].startswith("READ-ONLY")):
            return found.group(1), found.group(2)
    return None


def summary(call: dict) -> str:
    detail = ""
    tool_input = call.get("input") if isinstance(call.get("input"), dict) else {}
    for key in DETAIL_KEYS:
        value = tool_input.get(key)
        if isinstance(value, str) and value.strip():
            detail = os.path.basename(value) if key == "file_path" else value
            break
    text = CONTROL.sub(" ", f"{call.get('name', 'tool')} {detail}").strip()
    return text if len(text) <= ACTION_MAX else text[:ACTION_MAX - 1] + "…"


def last_action(path: Path) -> str:
    """The agent's most recent tool call, from the tail of its transcript; '' before its first."""
    with path.open("rb") as source:
        source.seek(0, os.SEEK_END)
        source.seek(max(0, source.tell() - TAIL_BYTES))
        tail = source.read().decode("utf-8", errors="replace")
    for raw in reversed(tail.splitlines()):
        try:
            record = json.loads(raw)
        except ValueError:
            continue  # a partial line at the tail's start or the transcript's write edge
        content = record.get("message", {}).get("content") if isinstance(record, dict) else None
        if record.get("type") == "assistant" and isinstance(content, list):
            for part in reversed(content):
                if isinstance(part, dict) and part.get("type") == "tool_use":
                    return summary(part)
    return ""


def due(ledger: Path, now: float) -> bool:
    try:
        return now - float(ledger.read_text()) >= INTERVAL_SECONDS
    except (OSError, ValueError):
        return True


def stamp_state(state: Path, agent_id: str, cell: tuple[str, str] | None, action: str) -> bool:
    """Write the stamp on the agent's lane or cell; False when the state names neither."""
    with open(f"{state}.lock", "a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
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


def stamp_seconds(value: str) -> float:
    return float(calendar.timegm(time.strptime(value, "%Y-%m-%dT%H:%M:%SZ")))


def agents_out(data: dict, at: float) -> list[tuple[str, str, int, str]]:
    """Each active lane and cell out in a live run: name, role, seconds silent, last action.
    Silence is measured as `workloop_state.silence` does: from the newest of the stamp, a heartbeat and going out."""
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
    return [(label, role, int(at - max(stamp_seconds(agent[key]) for key in ("activity_at", "heartbeat_at", since) if agent.get(key))),
             agent.get("activity") or "-") for label, role, agent, since in found if agent.get(since)]


def write_readout(state: Path, repo: Path, at: float) -> None:
    """The repository-wide `workloop` readout: agents out and the oldest silence; empty when none is out."""
    out = agents_out(json.loads(state.read_text()), at)
    strip = f"{len(out)} agent{'s' if len(out) != 1 else ''} out, oldest silent {max(quiet for _, _, quiet, _ in out) // 60}m" if out else ""
    note = "\n".join(f"{label} ({role}) silent {quiet // 60}m: {action}" for label, role, quiet, action in sorted(out, key=lambda item: -item[2])) if out else ""
    subprocess.run([sys.executable, str(Path(__file__).with_name("readout.py")), "write", "workloop", "--strip", strip, "--note", note,
                    "--stale-after", str(READOUT_STALE_SECONDS), "--repo", str(repo)], check=True)


def main() -> None:
    state, seen_dir, session, event, agent_id, transcript_path = sys.argv[1:7]
    if not agent_id:
        # The lead's prompt refreshes the readout, so it clears once the last agent is back.
        if event == "UserPromptSubmit":
            write_readout(Path(state), Path(seen_dir).parent, time.time())
        return
    if event not in ("SubagentStart", "PostToolBatch"):
        return
    ledger = Path(seen_dir) / f".activity-{clean(session)}-{clean(agent_id)}"
    now = time.time()
    if not due(ledger, now):
        return
    cell, action = None, ""
    if transcript_path:
        path = transcript(transcript_path, session, agent_id)
        try:
            cell, action = cell_binding(path), last_action(path)
        except (OSError, ValueError) as error:
            # The file is written after SubagentStart, so only a later miss is a fault.
            if event != "SubagentStart":
                print(f"agent_activity: {path} cannot be read ({error}); {agent_id} is stamped with its time only", file=sys.stderr)
    if stamp_state(Path(state), agent_id, cell, action):
        ledger.write_text(f"{now}\n")
        write_readout(Path(state), Path(seen_dir).parent, now)


if __name__ == "__main__":
    main()
