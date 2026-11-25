#!/usr/bin/env python3
"""Claude Code's own records of its agents, read from disk.

Claude Code 2.1.322 keeps, in each config folder (`$CLAUDE_CONFIG_DIR`, `~/.claude*`):

    projects/<project>/<session>.jsonl                        the session's transcript
    projects/<project>/<session>/subagents/agent-<id>.jsonl   an agent's transcript
    projects/<project>/<session>/subagents/agent-<id>.meta.json

and the records of which sessions run, which agent_sessions.py reads. Config folders may share one `projects/` by symlink, and a project folder may
be a symlink to another, so each folder is read once by its real path. None of
these formats is documented (issues #94872, #100824): a field this module needs
and does not find raises RecordError naming the file and the field.
"""

from __future__ import annotations

import html
import json
import os
import re
from datetime import datetime
from pathlib import Path
from typing import Any

WINDOW_SECONDS = 7 * 86400
CHUNK = 1 << 14
# How far back from an agent's newest record its SubagentHandback call is looked for.
HANDBACK_REACH = 16
# The bytes that mark a line as possibly carrying a hand-back call, so a transcript is not decoded line by line.
HANDBACK_CALL = b'"name":"SubagentHandback"'
EDIT_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")
EDIT_CALLS = tuple(b'"name":"%s"' % name.encode() for name in EDIT_TOOLS)
# Session transcript lines that may carry a verdict: a notification, or an Agent call's result.
NOTE = b"<task-notification>"
AGENT_RESULT = b'"agentId":"'
# A command the agent started in the background: a call that sets `run_in_background`, as both
# interactive and headless sessions write it, or a foreground call that outlived its timeout and
# was moved to the background, which only an interactive session records, as the result's
# `toolUseResult.backgroundTaskId`.
BACKGROUND_STARTS = (b'"run_in_background":true', b'"backgroundTaskId":')
TASK_ID = re.compile(r"<task-id>([^<]+)</task-id>")
TAG = re.compile(r"<(status|summary)>(.*?)</\1>", re.S)


class RecordError(ValueError):
    """A record lacks a field the reader needs, so Claude Code's format has changed."""


def need(record: dict, key: str, where) -> Any:
    if record.get(key) in (None, ""):
        raise RecordError(f"{where} has no {key}")
    return record[key]


def _epoch(stamp: str, where) -> float:
    try:
        return datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError) as error:
        raise RecordError(f"{where} has an unreadable timestamp {stamp!r}") from error


def config_dirs(home: Path, configured: str) -> list[Path]:
    """`$CLAUDE_CONFIG_DIR`, then every `~/.claude*` folder."""
    return ([Path(configured)] if configured else []) + sorted(p for p in home.glob(".claude*") if p.is_dir())


def real_folders(paths) -> list[Path]:
    """The existing folders among `paths`, each once by its real path."""
    seen: list[Path] = []
    for path in paths:
        real = Path(os.path.realpath(path))
        if real not in seen and real.is_dir():
            seen.append(real)
    return seen


def _projects(stores: list[Path]) -> list[Path]:
    """Every project folder once, by the same path every time: one reached through a symlink
    is the same device and inode as its target, which a real folder of the name is read as."""
    seen, found = set(), []
    for store in stores:
        with os.scandir(store) as entries:
            ordered = sorted(entries, key=lambda entry: (entry.is_symlink(), entry.name))
        for entry in ordered:
            if entry.is_dir():
                stat = entry.stat()
                if (stat.st_dev, stat.st_ino) not in seen:
                    seen.add((stat.st_dev, stat.st_ino))
                    found.append(Path(entry.path))
    return found


def _session_folders(stores: list[Path]):
    """(session folder, parent transcript) for every session that has a `subagents/` folder."""
    for project in _projects(stores):
        with os.scandir(project) as entries:
            for entry in entries:
                if entry.is_dir(follow_symlinks=False) and os.path.isdir(os.path.join(entry.path, "subagents")):
                    yield Path(entry.path), project / f"{entry.name}.jsonl"


def mtime_ns(path) -> int:
    try:
        return os.stat(path).st_mtime_ns
    except FileNotFoundError:
        return 0


def recent_agents(stores: list[Path], cached: dict, running: set, now: float) -> tuple[dict, dict]:
    """Agents whose transcript changed in the window: {id: [transcript, session, size, mtime_ns]},
    and the session cache for the next read.

    Only a running session writes its agents' files, and a session that runs
    again writes its own transcript, so a session no registry entry names now
    or named at the last read, whose transcript and `subagents/` folder are as
    that read saw them, keeps the cached sizes and times without a stat per agent."""
    found, sessions = {}, {}
    oldest = (now - WINDOW_SECONDS) * 1e9
    for folder, parent in _session_folders(stores):
        key = [mtime_ns(parent), mtime_ns(folder / "subagents"), folder.name in running]
        known = cached.get(str(folder))
        if known and known["key"] == key and not key[2]:
            agents = {aid: stat for aid, stat in known["agents"].items() if stat[1] >= oldest}
        else:
            agents = {}
            with os.scandir(folder / "subagents") as entries:
                for entry in entries:
                    name = entry.name
                    if name.startswith("agent-") and name.endswith(".jsonl"):
                        stat = entry.stat()
                        if stat.st_mtime_ns >= oldest:
                            agents[name[6:-6]] = [stat.st_size, stat.st_mtime_ns]
        sessions[str(folder)] = {"key": key, "agents": agents}
        for aid, (size, mtime) in agents.items():
            found[aid] = [str(folder / "subagents" / f"agent-{aid}.jsonl"), folder.name, size, mtime]
    return found, sessions


def read_meta(transcript: Path) -> dict:
    path = transcript.with_name(transcript.name[:-len(".jsonl")] + ".meta.json")
    data = json.loads(path.read_text())
    background = need(data, "requestShape", path) == "background"
    # A foreground agent's verdict is found by the id of the call that started it.
    tool_use_id = data.get("toolUseId") if background else need(data, "toolUseId", path)
    return {"description": need(data, "description", path), "type": need(data, "agentType", path),
            "background": background, "finished": bool(data.get("finished")), "tool_use_id": tool_use_id or ""}


def _newest_messages(path: Path):
    """The transcript's user and assistant records, newest first, read back from its end. The text
    after the last newline is a record Claude Code is still writing, or nothing, and is skipped."""
    with open(path, "rb") as stream:
        position = stream.seek(0, os.SEEK_END)
        rest, unfinished = b"", True
        while position > 0:
            step = min(CHUNK, position)
            position -= step
            stream.seek(position)
            lines = (stream.read(step) + rest).split(b"\n")
            rest = lines.pop(0) if position > 0 else b""
            # The first time any line is left, the last one is the text after the file's last newline.
            if unfinished and lines:
                unfinished = False
                lines.pop()
            for line in reversed(lines):
                if b'"type":"user"' in line or b'"type":"assistant"' in line:
                    record = json.loads(line)
                    if record.get("type") in ("user", "assistant"):
                        yield record


def _blocks(record: dict) -> list[dict]:
    content = (record.get("message") or {}).get("content")
    return [block for block in content if isinstance(block, dict)] if isinstance(content, list) else []


def _waiting(path: Path) -> bool:
    """Whether the agent's final turn, the records after its newest user record that is not a
    tool result, started a background command (a `tool_use` whose input sets
    `run_in_background`, or a tool result carrying `toolUseResult.backgroundTaskId`): it ended
    that turn to wait on the command, so its answer is no completion. Only a transcript that
    holds such a marker anywhere is read back."""
    with open(path, "rb") as stream:
        text = stream.read()
    if not any(marker in text for marker in BACKGROUND_STARTS):
        return False
    for record in _newest_messages(path):
        blocks = _blocks(record)
        if record["type"] == "assistant":
            if any(b.get("type") == "tool_use" and (b.get("input") or {}).get("run_in_background") is True for b in blocks):
                return True
        elif any(b.get("type") == "tool_result" for b in blocks):
            outcome = record.get("toolUseResult")
            if isinstance(outcome, dict) and outcome.get("backgroundTaskId"):
                return True
        else:
            return False
    return False


def how_it_ends(path: Path) -> dict:
    """The agent's newest message record: when, in which folder, and whether it is a final answer,
    an answer given while its own background command runs (`waiting`), the result of its
    SubagentHandback call, an API error (with the error's class) or other."""
    records = _newest_messages(path)
    newest = next(records, None)
    if newest is None:
        return {"newest": None, "end": "other", "cwd": ""}
    where = f"{path}'s newest {newest['type']} record"
    found = {"newest": _epoch(need(newest, "timestamp", where), where), "cwd": need(newest, "cwd", where), "end": "other"}
    message = newest.get("message") or {}
    if newest.get("isApiErrorMessage"):
        found.update(end="api-error", error=newest.get("apiError") or need(newest, "error", where))
    elif newest["type"] == "assistant":
        if message.get("stop_reason") == "end_turn" and not any(b.get("type") == "tool_use" for b in _blocks(newest)):
            found["end"] = "waiting" if _waiting(path) else "answer"
    else:
        answered = {b.get("tool_use_id") for b in _blocks(newest) if b.get("type") == "tool_result"}
        for _, record in zip(range(HANDBACK_REACH), records):
            if any(b.get("type") == "tool_use" and b.get("id") in answered and b.get("name") == "SubagentHandback"
                   for b in _blocks(record)):
                found["end"] = "handback"
                break
    return found


def find_transcript(stores: list[Path], agent_id: str) -> Path | None:
    """The transcript of agent `agent_id` in the first session folder that holds one, or None."""
    name = f"agent-{agent_id}.jsonl"
    for folder, _ in _session_folders(stores):
        path = folder / "subagents" / name
        if path.is_file():
            return path
    return None


def _handbacks(path: Path) -> list[str]:
    """The message of every SubagentHandback call in the transcript, in the order the agent made them.
    A last line with no newline is a record Claude Code is still writing and is skipped."""
    messages = []
    with open(path, "rb") as stream:
        for number, line in enumerate(stream, start=1):
            if HANDBACK_CALL not in line or not line.endswith(b"\n"):
                continue
            record = json.loads(line)
            for block in _blocks(record) if record.get("type") == "assistant" else []:
                if block.get("type") == "tool_use" and block.get("name") == "SubagentHandback":
                    where = f"{path} line {number}'s SubagentHandback call"
                    message = need(block.get("input") or {}, "message", where)
                    if not isinstance(message, str):
                        raise RecordError(f"{where} has a message that is not text")
                    messages.append(message)
    return messages


def final_report(path: Path) -> tuple[str, int, str]:
    """(the agent's report, how many hand-backs it made, kind): its last hand-back, or, when it made
    none, the text of the plain answer that ended its run. RecordError when it has done neither."""
    messages = _handbacks(path)
    if messages:
        return messages[-1], len(messages), "hand-back"
    newest = next(_newest_messages(path), None)
    if newest is not None and newest["type"] == "assistant" and (newest.get("message") or {}).get("stop_reason") == "end_turn":
        blocks = _blocks(newest)
        text = "\n".join(block["text"] for block in blocks if block.get("type") == "text" and block.get("text"))
        if text and not any(block.get("type") == "tool_use" for block in blocks):
            return text, 0, "answer"
    raise RecordError(f"{path} has no SubagentHandback call and does not end in a plain answer: the agent has not finished")


def _lines_from(path: Path, offset: int, markers: tuple[bytes, ...]) -> tuple[list[bytes], int]:
    """Complete lines written since `offset` that hold any of `markers`, in file order, and
    the offset reached. A transcript only grows; a file shorter than the offset is read
    again from its start, and the offset reached is then below the one given. A session
    transcript runs to tens of megabytes, so each marker is found in the whole text at
    once and only the lines holding one are cut out."""
    with open(path, "rb") as stream:
        if stream.seek(0, os.SEEK_END) < offset:
            offset = 0
        stream.seek(offset)
        data = stream.read()
    end = data.rfind(b"\n") + 1
    starts = set()
    for marker in markers:
        at = data.find(marker, 0, end)
        while at >= 0:
            starts.add(data.rfind(b"\n", 0, at) + 1)
            at = data.find(marker, data.find(b"\n", at), end)
    return [data[start:data.find(b"\n", start)] for start in sorted(starts)], offset + end


def _edit_paths(record: dict) -> list[str]:
    """Paths the edit calls of one record name."""
    paths = []
    for block in _blocks(record):
        target = block.get("input") or {}
        if block.get("type") == "tool_use" and block.get("name") in EDIT_TOOLS:
            value = target.get("file_path") or target.get("notebook_path")
            if isinstance(value, str) and value:
                paths.append(value)
    return paths


def edits_since(path: Path, offset: int) -> tuple[list[str], int]:
    """Paths the agent's Edit, Write, MultiEdit and NotebookEdit calls named since `offset`,
    in any record that holds such a call."""
    lines, reached = _lines_from(path, offset, EDIT_CALLS)
    return [value for line in lines for value in _edit_paths(json.loads(line))], reached


def timed_edits_since(path: Path, offset: int) -> tuple[list[tuple[str, float]], int]:
    """The edits the agent itself made since `offset`, each as (path, time of the record that
    made the call). Only an `assistant` record made a call; the `api-request-blob` records
    Claude Code keeps beside them copy earlier requests, carry no timestamp, and are skipped."""
    lines, reached = _lines_from(path, offset, EDIT_CALLS)
    edits = []
    for line in lines:
        record = json.loads(line)
        if record.get("type") == "assistant":
            where = f"{path}: an edit record"
            edits += [(value, _epoch(need(record, "timestamp", where), where)) for value in _edit_paths(record)]
    return edits, reached


def notes_since(path: Path, offset: int) -> tuple[list[list], int]:
    """A background agent's verdicts in a session transcript since `offset`: each is a
    `queue-operation` `enqueue` record whose content is a `<task-notification>` naming one
    or more `<task-id>`s, a `<status>` and a `<summary>`, as [agent id, time, status,
    summary]. A notification on another kind of task, such as a monitor's event, may
    carry no status; it is kept with an empty one."""
    notes = []
    lines, reached = _lines_from(path, offset, (NOTE,))
    for line in lines:
        record = json.loads(line)
        content = record.get("content")
        if record.get("type") == "queue-operation" and isinstance(content, str) and content.startswith(NOTE.decode()):
            where = f"{path}: a queue-operation record"
            # Text may follow the notification, such as a hook's reminder; only the notification counts.
            note = content.split("</task-notification>", 1)[0]
            tags = dict(TAG.findall(note))
            for aid in TASK_ID.findall(note):
                notes.append([aid, _epoch(need(record, "timestamp", where), where), tags.get("status", ""),
                              html.unescape(tags.get("summary", ""))])
    return notes, reached


def results_since(path: Path, offset: int) -> tuple[list[list], int]:
    """A foreground agent's verdicts in a session transcript since `offset`: each is its
    `Agent` call's result, a user record whose `toolUseResult` carries `agentId` and
    `status`, as [tool use id, time, status]. A headless session writes `toolUseResult` here,
    in its own transcript, though not in its agents' transcripts."""
    results = []
    lines, reached = _lines_from(path, offset, (AGENT_RESULT,))
    for line in lines:
        record = json.loads(line)
        result = record.get("toolUseResult")
        if record.get("type") == "user" and isinstance(result, dict) and result.get("agentId"):
            where = f"{path}: the result of agent {result['agentId']}"
            for block in _blocks(record):
                if block.get("type") == "tool_result":
                    results.append([need(block, "tool_use_id", where), _epoch(need(record, "timestamp", where), where),
                                    need(result, "status", where)])
    return results, reached
