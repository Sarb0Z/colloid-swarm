#!/usr/bin/env python3
"""The phone link's record of what it did: events, phone messages and errors.

The log records. It never decides an action: `phone_link.py` reads the live
state an action depends on (a transcript, the process table) and writes here
what it then did.

`<state>` is `~/.local/state/phone-link`, or `$PHONE_LINK_STATE`, mode 0700.
Every file in it has mode 0600.

  events.jsonl    One JSON line per event, and the whole event again at each
                  change; the last line of an id is its state. `Events.start`
                  drops events created more than 30 days ago and closes each
                  permission event still open, because no hook waits for it
                  after a restart.
  messages.jsonl  One line per phone message that passed the Note to Self and
                  device filters: its Signal timestamp and what the link did
                  with it, so a message delivered twice acts once. No text.
  errors.log      One line per failure, with its time.

An event (version 1) holds `v`, `id`, `machine`, `kind`, `session`, `turn`,
`row`, `call`, `created`, `deadline`, `text`, `detail`, `attachments`, `source`,
`state` and `answer`; the spec (`docs/notes/2026-11-17-phone-link-spec.md`,
"Events") says what each carries. A permission event's `detail` is `{tool,
preview}`, masked: the raw tool input never reaches this module.

`TRANSITIONS` is the closed table of state changes, and `Events.move` refuses
any other.
"""

from __future__ import annotations

import json
import os
import secrets
import time
from datetime import datetime, timezone
from pathlib import Path

VERSION = 1
MACHINE = "mac"
MACHINE_LETTER = "m"
# Lowercase letters without `l`, which reads as 1 or I on a phone.
ID_LETTERS = "abcdefghijkmnopqrstuvwxyz"
KEEP_SECONDS = 30 * 24 * 3600

TRANSITIONS = {
    "permission": {"open": frozenset({"answered", "settled_at_mac", "expired", "closed"})},
}


def state_dir(environ) -> Path:
    return Path(environ.get("PHONE_LINK_STATE") or Path(environ["HOME"]) / ".local/state/phone-link")


def prepare(folder: Path) -> None:
    """Make `folder` and set mode 0700, whatever the umask or its mode before."""
    folder.mkdir(parents=True, exist_ok=True)
    os.chmod(folder, 0o700)


def iso(epoch: float) -> str:
    return datetime.fromtimestamp(int(epoch), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def epoch_of(text: str) -> float:
    return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()


def _append(path: Path, line: str) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    with os.fdopen(descriptor, "a", encoding="utf-8") as stream:
        os.fchmod(descriptor, 0o600)
        stream.write(line + "\n")


def _rewrite(path: Path, lines: list) -> None:
    temporary = path.with_name(f".{path.name}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        os.fchmod(descriptor, 0o600)
        stream.writelines(line + "\n" for line in lines)
    os.replace(temporary, path)


def _time_of(record: dict, key: str):
    """The epoch of the ISO time under `key`, or None when the record holds none that reads."""
    try:
        return epoch_of(record[key])
    except (KeyError, TypeError, ValueError):
        return None


def _records(path: Path, is_record) -> tuple[list, int]:
    """(the lines of `path` that `is_record` accepts, in order; how many other lines it holds).
    No file is no records. A line cut short by a crash is one of the others."""
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return [], 0
    records, unreadable = [], 0
    for line in text.splitlines():
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except ValueError:
            record = None
        if isinstance(record, dict) and is_record(record):
            records.append(record)
        else:
            unreadable += 1
    return records, unreadable


def _is_event(record: dict) -> bool:
    return (all(isinstance(record.get(key), str) for key in ("id", "kind", "state"))
            and _time_of(record, "created") is not None)


def _is_message(record: dict) -> bool:
    return isinstance(record.get("ts"), int) and _time_of(record, "at") is not None


class Errors:
    """errors.log: `write(text)` appends one line with its time."""

    def __init__(self, path: Path, clock=time.time):
        self.path, self.clock = path, clock

    def write(self, text: str) -> None:
        _append(self.path, f"{iso(self.clock())} {' '.join(text.split())}")


class Events:
    """events.jsonl. `events` maps each id to its last line."""

    def __init__(self, path: Path, errors: Errors, choose=secrets.choice):
        self.path, self.errors, self.choose = path, errors, choose
        self.events: dict = {}

    def start(self, now: float) -> list:
        """Load the file, drop the events older than 30 days, and close each open permission
        event. Returns the events it closed."""
        records, unreadable = _records(self.path, _is_event)
        if unreadable:
            self.errors.write(f"{self.path.name}: dropped {unreadable} line(s) that were not an event")
        old = {r["id"] for r in records if now - _time_of(r, "created") > KEEP_SECONDS}
        kept = [r for r in records if r["id"] not in old]
        if len(kept) != len(records) or unreadable:
            _rewrite(self.path, [json.dumps(r, ensure_ascii=False) for r in kept])
        self.events = {r["id"]: r for r in kept}
        closed = [self.move(event["id"], "closed", {"via": "none", "text": "phone-link restarted", "at": iso(now)})
                  for event in list(self.events.values())
                  if event.get("kind") == "permission" and event.get("state") == "open"]
        return closed

    def _new_id(self) -> str:
        while True:
            found = MACHINE_LETTER + "-" + "".join(self.choose(ID_LETTERS) for _ in range(5))
            if found not in self.events:
                return found

    def _write(self, event: dict) -> dict:
        self.events[event["id"]] = event
        _append(self.path, json.dumps(event, ensure_ascii=False))
        return event

    def open_permission(self, *, session: dict, turn, call, tool: str, preview: str,
                        deadline: float, now: float) -> dict:
        return self._write({
            "v": VERSION, "id": self._new_id(), "machine": MACHINE, "kind": "permission",
            "session": session, "turn": turn, "row": None, "call": call,
            "created": iso(now), "deadline": iso(deadline), "text": None,
            "detail": {"tool": tool, "preview": preview}, "attachments": [], "source": None,
            "state": "open", "answer": None,
        })

    def amend(self, event_id: str, **fields) -> dict:
        """The event again with `fields` changed; its state stays, so use `move` for that."""
        if "state" in fields or "answer" in fields:
            raise ValueError("amend does not change an event's state; use move")
        return self._write({**self.events[event_id], **fields})

    def move(self, event_id: str, state: str, answer: dict) -> dict:
        """The event in its new state, when TRANSITIONS allows the change from its present one."""
        event = self.events[event_id]
        allowed = TRANSITIONS.get(event["kind"], {}).get(event["state"], frozenset())
        if state not in allowed:
            raise ValueError(f"event {event_id} ({event['kind']}) cannot go from {event['state']} to {state}")
        return self._write({**event, "state": state, "answer": answer})


class Messages:
    """messages.jsonl: which Signal timestamps the link has already acted on."""

    def __init__(self, path: Path, errors: Errors):
        self.path, self.errors = path, errors
        self.results: dict = {}

    def start(self, now: float) -> None:
        records, unreadable = _records(self.path, _is_message)
        if unreadable:
            self.errors.write(f"{self.path.name}: dropped {unreadable} line(s) that were not a message record")
        kept = [r for r in records if now - _time_of(r, "at") <= KEEP_SECONDS]
        if len(kept) != len(records) or unreadable:
            _rewrite(self.path, [json.dumps(r) for r in kept])
        self.results = {r["ts"]: r.get("result") for r in kept}

    def seen(self, timestamp: int) -> bool:
        return timestamp in self.results

    def record(self, timestamp: int, result: str, now: float) -> None:
        self.results[timestamp] = result
        _append(self.path, json.dumps({"ts": timestamp, "at": iso(now), "result": result}))
