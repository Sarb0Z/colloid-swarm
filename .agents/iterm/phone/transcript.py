#!/usr/bin/env python3
"""Read a Claude Code transcript for one tool call: whether it still waits, and how it ended.

The permission hook has no id for its call (the `PermissionRequest` payload
carries the tool's name and input only), so it finds the call here by name and
input, and then learns from the same file how the call ended. `phone_link.py`
reads the file again before it tells the phone what happened.

Which file: the session's transcript, or for a subagent's call
`<session>/subagents/agent-<agent id>.jsonl` beside it. A subagent's call and
its result are written there only (`call_file`).

What Claude Code 2.1.325 writes, each read from the transcript of a real
session: the probe sessions of
`.agents/knowledge/research/2026-11-17-permission-request-hook-timing.md`, and
three headless runs of 2026-11-18 (a hook's allow, a hook's deny, no decision):

  a turn starts        a `user` row whose content is a string: the operator's
                       prompt, or a meta row Claude Code writes with it
  the pending call     an `assistant` row whose content holds
                       `{"type": "tool_use", "id", "name", "input"}`
  a hook decided       an `attachment` row `{"type": "hook_permission_decision",
                       "decision": "allow"|"deny", "toolUseID", "hookEvent":
                       "PermissionRequest"}`, written before the result, then the
                       result row with `permissionDecision.source` `hook`
  allowed at the Mac   the result row alone, `permissionDecision.source`
                       `user_temporary`
  No or Esc at the Mac the result row with `is_error`, no `permissionDecision`,
                       then a `user` row `[Request interrupted by user for tool use]`
  no dialog, no hook   the result row with `is_error` and `permissionDecision`
                       `{"decision": "reject", "source": "config"}`

`Ending.by` is `hook` for the first, `mac` for the two at the dialog and `other`
for the rest; `decision` is `allow` or `deny`.

A line that is not JSON is passed over without a report: the file belongs to
another program that may be in the middle of a line, and only whole lines are
read, so a later read sees the row once it is complete.
"""

from __future__ import annotations

import hashlib
import json
import os
from datetime import datetime
from typing import NamedTuple

ROWS = 200
CHUNK = 1 << 20
INTERRUPT = "[Request interrupted by user"
# Rows are parsed only when they can hold one of these; a transcript also holds
# request copies of hundreds of kilobytes that the reader has no use for.
# A `user` row also marks where a turn starts, when its content is the operator's prompt.
WANTED = (b'"tool_use"', b'"tool_result"', b'"hook_permission_decision"', INTERRUPT.encode(), b'"user"')


class Ending(NamedTuple):
    by: str  # "hook", "mac" or "other"
    decision: str  # "allow" or "deny"


def call_digest(name, tool_input) -> str:
    """A digest of a call's tool name and input: the service matches a call by it and so
    never holds the input itself."""
    canonical = json.dumps([name, tool_input], sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


def call_file(transcript_path: str, agent_id) -> str:
    """The file that holds a call: the session's transcript, or the agent's own file."""
    if not agent_id:
        return transcript_path
    session_folder = transcript_path[:-len(".jsonl")] if transcript_path.endswith(".jsonl") else transcript_path
    return os.path.join(session_folder, "subagents", f"agent-{agent_id}.jsonl")


def _rows(lines) -> list:
    rows = []
    for line in lines:
        if not any(mark in line for mark in WANTED):
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict):
            rows.append(row)
    return rows


def tail(path: str, rows: int = ROWS) -> tuple[list, int]:
    """(the last `rows` whole lines of the file that can hold a call, the offset after them).
    No file is no rows at offset 0: an agent's file appears with its first row."""
    try:
        stream = open(path, "rb")
    except FileNotFoundError:
        return [], 0
    with stream:
        start = stream.seek(0, os.SEEK_END)
        chunks, newlines = [], 0
        # One line more than asked: the first line of the first chunk may be cut.
        while start > 0 and newlines <= rows:
            step = min(CHUNK, start)
            start -= step
            stream.seek(start)
            chunks.append(stream.read(step))
            newlines += chunks[-1].count(b"\n")
    data = b"".join(reversed(chunks))
    end = data.rfind(b"\n") + 1
    lines = data[:end].split(b"\n")[:-1]
    if start > 0:
        lines = lines[1:]
    return _rows(lines[-rows:]), start + end


class Follow:
    """The whole lines a file gains after `offset`, read by `read()` as often as asked."""

    def __init__(self, path: str, offset: int):
        self.path, self.offset = path, offset

    def read(self) -> list:
        try:
            with open(self.path, "rb") as stream:
                stream.seek(self.offset)
                data = stream.read()
        except FileNotFoundError:
            return []
        end = data.rfind(b"\n") + 1
        self.offset += end
        return _rows(data[:end].split(b"\n"))


def _time(row: dict):
    """The row's time as epoch seconds, or None."""
    try:
        return datetime.fromisoformat(str(row.get("timestamp")).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _ending(row: dict, block: dict) -> Ending:
    decision = row.get("permissionDecision")
    if isinstance(decision, dict):
        source = str(decision.get("source"))
        by = "hook" if source == "hook" else "mac" if source.startswith("user") else "other"
        return Ending(by, "allow" if decision.get("decision") == "accept" else "deny")
    # Claude Code writes no decision record for the operator's No or Esc.
    return Ending("mac", "deny") if block.get("is_error") else Ending("other", "allow")


class Calls:
    """The tool calls of the rows added so far. `wanted` is the (name, input) of the call a
    hook looks for; `waiting()` then gives its candidates."""

    def __init__(self, wanted=None):
        self.wanted = wanted
        self.names: dict = {}
        self.digests: dict = {}  # call id -> call_digest of its name and input
        self.matching: list = []
        self.turn_start = 0  # the index in `matching` of the latest turn's first match
        self.results: dict = {}
        self.hook_decisions: dict = {}
        self.interrupts: list = []

    def add(self, rows) -> None:
        for row in rows:
            kind = row.get("type")
            if kind == "attachment":
                found = row.get("attachment")
                if (isinstance(found, dict) and found.get("type") == "hook_permission_decision"
                        and found.get("hookEvent") == "PermissionRequest"
                        and found.get("decision") in ("allow", "deny")):
                    self.hook_decisions[found.get("toolUseID")] = found["decision"]
                continue
            message = row.get("message")
            content = message.get("content") if isinstance(message, dict) else None
            if kind == "user" and isinstance(content, str):
                # The operator's prompt: the calls before it belong to an earlier turn.
                self.turn_start = len(self.matching)
                continue
            if kind not in ("assistant", "user") or not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict):
                    continue
                if kind == "assistant" and block.get("type") == "tool_use":
                    self.names[block.get("id")] = block.get("name")
                    self.digests[block.get("id")] = call_digest(block.get("name"), block.get("input"))
                    if self.wanted == (block.get("name"), block.get("input")):
                        self.matching.append(block.get("id"))
                elif kind == "user" and block.get("type") == "tool_result":
                    self.results[block.get("tool_use_id")] = _ending(row, block)
                elif kind == "user" and block.get("type") == "text" \
                        and str(block.get("text", "")).startswith(INTERRUPT):
                    self.interrupts.append(_time(row))

    def ending(self, call: str):
        """How the call ended, or None while it waits or runs. A hook's decision row counts at
        once: an allowed command may run for long before its result is written."""
        if call in self.hook_decisions:
            return Ending("hook", self.hook_decisions[call])
        return self.results.get(call)

    def ended(self) -> dict:
        """Every call that ended, with its ending."""
        return {call: self.ending(call) for call in {*self.results, *self.hook_decisions}}

    def waiting(self) -> list:
        """The ids of the wanted call's matches in the latest turn that have not ended, the
        earliest first: Claude Code shows one turn's dialogs in call order (the hook-timing
        note's probe 9), so of equal calls the earliest is the one a dialog shows."""
        return [call for call in self.matching[self.turn_start:] if self.ending(call) is None]

    def interrupted_since(self, epoch: float) -> bool:
        """Whether the operator interrupted a tool call at or after `epoch`."""
        return any(at is not None and at >= epoch for at in self.interrupts)
