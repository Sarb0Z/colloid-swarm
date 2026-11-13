#!/usr/bin/env python3
"""Agents that wait on the operator: a permission prompt, or a blocked background session.

Usage: agent_waits.py record <repo>      a PermissionRequest payload on stdin;
                                          its project_dir, when set, wins

An agent stuck on a permission prompt is alive and silent: its transcript ends
on the `tool_use` with no result, as a running command's does, and nothing
Claude Code writes names it. Only the `PermissionRequest` hook payload does
(`agent_id`, `agent_type`, `tool_name`, `tool_input`, `session_id`), as the
prompt opens. `record`, run by `hooks/policy/agent-waits.sh`, keeps one entry
per waiting agent in `.agents/.readout/.agent-waits`, a JSON object replaced
atomically under an `fcntl` lock on `.agent-waits.lock`. A payload with no
`agent_id` is the lead's own prompt, in front of the operator already, and is
not kept.

Answering fires no hook of its own, and an approved command writes nothing to
the transcript until it ends. A wait closes when its session's registry entry
leaves `waiting` after the request (the operator answered), when the agent
writes a message record newer than the request, when its session ends, or
when a process that started after the request runs the session (a `claude
--resume` under the same id). `open_waits` judges that and drops the closed
entries under the same lock.

A background session (`claude --bg`) waits with its job reading blocked
(`blocked`) and its `needs` saying what for; `job_lines` names each one whose
session runs in this checkout.
"""

from __future__ import annotations

import fcntl
import json
import os
import sys
import tempfile
import time
from pathlib import Path
from typing import Callable

import agent_records as ar
import agent_sessions as sessions
from readout import CONTROL

FILE = Path(".readout") / ".agent-waits"
HEAD = "WAITING ON YOU"
# Longer commands are cut here, so one heredoc cannot fill the lead's context.
SHOWN_CHARS = 200
# What a tool's call is about, in the order looked for in its input.
SUBJECTS = ("command", "file_path", "notebook_path", "url", "pattern", "description", "prompt")


def clean(text: str, limit: int = SHOWN_CHARS) -> str:
    text = " ".join(CONTROL.sub(" ", text).replace('"', "'").split())
    return text if len(text) <= limit else text[:limit - 1] + "…"


def subject(tool_input) -> str:
    """The command, path or description the tool was called with."""
    if not isinstance(tool_input, dict):
        return ""
    for key in SUBJECTS:
        value = tool_input.get(key)
        if isinstance(value, str) and value.strip():
            return value
    return json.dumps(tool_input, separators=(",", ":"))


def agent_transcript(transcript: str, agent_id: str) -> str:
    """The agent's own transcript: the payload names its session's, `<project>/<session>.jsonl`,
    beside which the agent's sits under `<session>/subagents/`."""
    path = Path(transcript)
    if path.name == f"agent-{agent_id}.jsonl":
        return str(path)
    return str(path.with_suffix("") / "subagents" / f"agent-{agent_id}.jsonl")


def _load(path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
    except FileNotFoundError:
        return {}
    except ValueError as error:
        raise ValueError(f"{path} is unreadable ({error}); delete it, and the next prompt is recorded afresh") from error
    if not isinstance(data, dict):
        raise ValueError(f"{path} holds no JSON object; delete it, and the next prompt is recorded afresh")
    return data


def _rewrite(agents_dir: Path, change: Callable[[dict], dict]) -> None:
    """Apply `change` to the waits under the lock, and replace the file whole."""
    path = agents_dir / FILE
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path.with_name(path.name + ".lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        waits = change(_load(path))
        handle, temporary = tempfile.mkstemp(prefix=f"{path.name}.", dir=path.parent)
        try:
            with os.fdopen(handle, "w") as stream:
                json.dump(waits, stream, separators=(",", ":"))
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)


def record(agents_dir: Path, payload: dict, now: float) -> bool:
    """Keep the wait a PermissionRequest payload opens; False for the lead's own prompt."""
    agent_id = payload.get("agent_id")
    if not isinstance(agent_id, str) or not agent_id.strip():
        return False
    for key in ("session_id", "transcript_path", "tool_name"):
        if not isinstance(payload.get(key), str) or not payload[key]:
            raise ValueError(f"the PermissionRequest payload carries no {key}")
    wait = {"session": payload["session_id"], "type": payload.get("agent_type") or "",
            "tool": payload["tool_name"], "subject": subject(payload.get("tool_input")), "at": now,
            "transcript": agent_transcript(payload["transcript_path"], agent_id)}
    _rewrite(agents_dir, lambda waits: dict(waits, **{agent_id: wait}))
    return True


def _closed(wait: dict, live: Callable[[str], bool | None], entry: Callable[[str], dict | None]) -> bool:
    """Whether the prompt was answered or the agent wrote past it, or its session ended. A
    transcript that is gone went with its session."""
    if live(wait["session"]) is False:
        return True
    running = entry(wait["session"])
    if running:
        # A session resumed under the same id since the request is a new process: the prompt went with the old one.
        if running["started_at"] > wait["at"]:
            return True
        # The session leaves `waiting` when the prompt is answered or denied, before an approved command ends.
        status_at = running.get("status_at")
        if running.get("status") not in (None, "waiting") and status_at is not None and status_at > wait["at"]:
            return True
    try:
        newest = ar.how_it_ends(Path(wait["transcript"]))["newest"]
    except FileNotFoundError:
        return True
    return newest is not None and newest > wait["at"]


def open_waits(agents_dir: Path, live: Callable[[str], bool | None], entry: Callable[[str], dict | None]) -> dict[str, dict]:
    """The waits still open, {agent id: wait}; the closed ones are dropped from the file.
    `live(session)` is True or False, or None when liveness cannot be told on this host;
    `entry(session)` is the session's registry entry while it runs, else None."""
    waits = _load(agents_dir / FILE)
    closed = {agent_id: wait["at"] for agent_id, wait in waits.items() if _closed(wait, live, entry)}
    if closed:
        # A wait the hook replaced since this read is a new prompt, and stays.
        _rewrite(agents_dir, lambda now: {aid: w for aid, w in now.items() if closed.get(aid) != w["at"]})
    return {agent_id: wait for agent_id, wait in waits.items() if agent_id not in closed}


def _description(wait: dict) -> str:
    try:
        return ar.read_meta(Path(wait["transcript"]))["description"]
    except (OSError, ValueError) as error:
        print(f"agent waits: {wait['transcript']}'s meta.json could not be read ({error}); its type stands in", file=sys.stderr)
        return wait["type"] or "an agent"


def agent_lines(waits: dict[str, dict]) -> list[str]:
    """One line per waiting agent, oldest wait first."""
    return [f'{HEAD}: "{clean(_description(wait))}" ({agent_id}) {clean(wait["tool"])}: {clean(wait["subject"])}'
            for agent_id, wait in sorted(waits.items(), key=lambda item: item[1]["at"])]


def _inside(path: str, repo: Path) -> bool:
    return Path(os.path.realpath(path)).is_relative_to(Path(os.path.realpath(repo)))


def blocked(job: dict) -> bool:
    """Whether a background session waits on the operator: 2.1.322 holds one on a permission
    prompt at `state: "working"`, `tempo: "blocked"`; earlier versions wrote `state: "blocked"`."""
    return job.get("state") == "blocked" or job.get("tempo") == "blocked"


def job_lines(jobs: dict[str, dict], repo: Path, live: Callable[[str], bool | None]) -> list[str]:
    """One line per blocked background session that runs now in this checkout or a worktree
    under it. A job reads blocked long after its session is gone, so a job none of whose
    sessions runs is not shown, and none is while liveness cannot be told."""
    lines = []
    for job_id, job in sorted(jobs.items()):
        places = [job[key] for key in ("cwd", "worktreePath") if isinstance(job.get(key), str) and job[key]]
        if not blocked(job) or not any(_inside(place, repo) for place in places) \
                or not any(live(s) for s in sessions.job_sessions(job)):
            continue
        needs = job.get("needs") or job.get("detail") or "an answer"
        lines.append(f'{HEAD}: "{clean(str(job.get("name") or job_id))}" ({job_id}) {clean(str(needs))}; claude attach {job_id}')
    return lines


def main(argv: list[str]) -> None:
    if len(argv) != 2 or argv[0] != "record":
        sys.exit("usage: agent_waits.py record <repo>  (a PermissionRequest payload on stdin; its project_dir wins)")
    payload = json.load(sys.stdin)
    if not isinstance(payload, dict):
        raise ValueError("the PermissionRequest payload is no JSON object")
    record(Path(payload.get("project_dir") or argv[1]) / ".agents", payload, time.time())


if __name__ == "__main__":
    main(sys.argv[1:])
