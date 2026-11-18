#!/usr/bin/env python3
"""The Claude sessions the phone link knows: what the phone calls each, and whether it still runs.

A session enters the list with its first hook line, which carries the session
id, the `claude` process (pid and start) and the account's config folder.
`sessions.json` in the state folder keeps the list over a restart of the
service.

Handle. The name Claude Code gave the session in its registry file
(`<config folder>/sessions/<pid>.json`, field `name`) at the moment the session
is first registered: in lowercase, with every character other than `a-z`, `0-9`
and `-` changed to `-`. It stays for the session's life, so a later rename by
Claude Code does not move it. A handle that a listed session already has gets
`-2`, then `-3`. A session with no registry name (the file is absent, or names
another session) takes its project folder's name.

Liveness. `check()` runs one `ps` for the whole list and drops a session whose
pid is gone, whose process started at another time (the pid went to another
process), or whose registry file now names another session id. `ps` failing is
not an answer: the error goes to the caller and no session is dropped.

The list holds LIMIT sessions; `register` raises `Full` for one more.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "hooks" / "lib"))
import process_start  # noqa: E402

LIMIT = 50
PS_SECONDS = 5
# claude-tab-state and pane-run read `lstart` in this locale and zone, as Claude Code's registry does.
PS_ENV = {"LC_ALL": "C", "TZ": "UTC"}
LSTART_WORDS = 5


class Full(Exception):
    """The list already holds LIMIT sessions."""


def handle_of(name: str) -> str:
    return re.sub(r"[^a-z0-9-]", "-", name.lower())


def read_registry(config_dir: str, pid: int):
    """Claude Code's registry entry of the process, or None when it has none that reads."""
    try:
        entry = json.loads((Path(config_dir) / "sessions" / f"{pid}.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return entry if isinstance(entry, dict) else None


def _ps(fields: str, pids) -> list:
    """The words of each line `ps` prints for `pids`. A pid that does not run has no line."""
    out = subprocess.run(["ps", "-ww", "-o", fields, "-p", ",".join(str(pid) for pid in pids)],
                         capture_output=True, text=True, env={**os.environ, **PS_ENV}, timeout=PS_SECONDS)
    return [line.split() for line in out.stdout.splitlines() if line.strip()]


def process_starts(pids) -> dict:
    """pid -> the start `ps` gives it, for each of `pids` that runs, in one `ps` call."""
    return {int(words[0]): " ".join(words[1:1 + LSTART_WORDS]) for words in _ps("pid=,lstart=", pids)}


def claude_process(pid: int):
    """(pid, start) of the nearest `claude` process at or above `pid`, or None. A hook is a
    child of its session's Claude Code, sometimes below a shell that runs the hook command."""
    for _ in range(12):
        lines = _ps("ppid=,lstart=,comm=", [pid]) if pid > 1 else []
        if not lines:
            return None
        words = lines[0]
        command = " ".join(words[1 + LSTART_WORDS:])
        if os.path.basename(command) == "claude":
            return pid, " ".join(words[1:1 + LSTART_WORDS])
        pid = int(words[0])
    return None


class Sessions:
    def __init__(self, path: Path, starts=process_starts, registry=read_registry):
        self.path, self.starts, self.registry = path, starts, registry
        self.sessions: dict = {}

    def load(self) -> None:
        """Read sessions.json. No file is an empty list; one that does not read raises ValueError."""
        try:
            text = self.path.read_text(encoding="utf-8")
        except FileNotFoundError:
            return
        listed = json.loads(text)
        if not isinstance(listed, list) or not all(
                isinstance(s, dict) and isinstance(s.get("pid"), int)
                and all(isinstance(s.get(key), str) for key in ("id", "handle", "start", "config_dir"))
                for s in listed):
            raise ValueError(f"{self.path} is not a list of sessions")
        self.sessions = {session["id"]: session for session in listed}

    def _save(self) -> None:
        temporary = self.path.with_name(f".{self.path.name}.tmp")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            os.fchmod(descriptor, 0o600)
            json.dump(list(self.sessions.values()), stream)
        os.replace(temporary, self.path)

    def _handle(self, session: dict) -> str:
        entry = self.registry(session["config_dir"], session["pid"])
        named = entry and entry.get("sessionId") == session["id"] and isinstance(entry.get("name"), str)
        base = handle_of(entry["name"] if named and entry["name"].strip() else session["project"])
        taken = {listed["handle"] for listed in self.sessions.values()}
        handle, number = base, 1
        while handle in taken:
            number += 1
            handle = f"{base}-{number}"
        return handle

    def register(self, session: dict) -> dict:
        """The listed session for a hook line's `session` (id, pid, start, config_dir, cwd,
        project, account, transcript), added when it is new. A known session keeps its handle
        and takes the line's process, which changes when a session is resumed."""
        known = self.sessions.get(session["id"])
        if known is None and len(self.sessions) >= LIMIT:
            raise Full(f"{LIMIT} sessions are registered")
        listed = {**session, "handle": known["handle"] if known else self._handle(session)}
        if listed != known:
            self.sessions[session["id"]] = listed
            self._save()
        return listed

    def check(self) -> list:
        """Drop each session that no longer runs, and return those dropped."""
        if not self.sessions:
            return []
        starts = self.starts([session["pid"] for session in self.sessions.values()])
        dropped = []
        for session in list(self.sessions.values()):
            entry = self.registry(session["config_dir"], session["pid"])
            if (session["pid"] not in starts
                    or not process_start.same_start(session["start"], starts[session["pid"]])
                    or (entry is not None and entry.get("sessionId") != session["id"])):
                dropped.append(self.sessions.pop(session["id"]))
        if dropped:
            self._save()
        return dropped
