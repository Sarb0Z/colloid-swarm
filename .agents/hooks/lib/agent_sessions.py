"""Which Claude Code sessions run now, from Claude Code's own records.

Each config folder (agent_records.config_dirs) holds `sessions/<pid>.json`, one
per running session, with its `sessionId`, `procStart` and `startedAt` (epoch
ms); a clean exit removes it, a kill leaves it. Claude Code computes
`procStart` as `ps -o lstart= -p <pid>` under `LC_ALL=C TZ=UTC`, trimmed, on
every platform but Windows. A background session's supervisor keeps
`jobs/<job id>/state.json` with its `state`, `sessionId` and `resumeSessionId`.
"""

from __future__ import annotations

import json
from pathlib import Path

from agent_records import need, real_folders


def registry(dirs: list[Path]) -> tuple[list[dict], list[str]]:
    """Every session registry entry, and a problem line for each unreadable one."""
    entries, problems = [], []
    for folder in real_folders(d / "sessions" for d in dirs):
        for path in sorted(folder.glob("*.json")):
            try:
                data = json.loads(path.read_text())
                entries.append({"pid": int(need(data, "pid", path)), "session": need(data, "sessionId", path),
                                "proc_start": need(data, "procStart", path),
                                "started_at": float(need(data, "startedAt", path)) / 1000})
            except FileNotFoundError:
                continue  # its session exited while this read the folder
            except (ValueError, TypeError) as error:
                problems.append(f"agent deaths: {path} could not be read: {error}")
    return entries, problems


def stopped_jobs(dirs: list[Path]) -> tuple[dict[str, str], list[str]]:
    """The background sessions their supervisor holds stopped, {session id: job id}: each job
    whose `state` is `stopped`, by its `sessionId` and `resumeSessionId`; and a problem line
    for each unreadable job."""
    found, problems = {}, []
    for folder in real_folders(d / "jobs" for d in dirs):
        for path in sorted(folder.glob("*/state.json")):
            try:
                data = json.loads(path.read_text())
                if need(data, "state", path) == "stopped":
                    found.update({data[key]: path.parent.name for key in ("sessionId", "resumeSessionId") if data.get(key)})
            except FileNotFoundError:
                continue
            except (ValueError, TypeError) as error:
                problems.append(f"agent deaths: {path} could not be read: {error}")
    return found, problems


class Hosts:
    """Which sessions run now: a session is live when a registry entry names it and its
    process's start, from `proc_start(pid)`, equals the entry's `procStart`, which rejects an
    entry a killed process left. The test is trusted once it passes for the reader's own
    session (`trusted`)."""

    def __init__(self, entries: list[dict], own: str, proc_start) -> None:
        self.entries, self.own, self.proc_start, self.seen = entries, own, proc_start, {}
        self.why: str | None = None
        self.checked = False

    def started(self, entry: dict) -> str | None:
        if entry["pid"] not in self.seen:
            self.seen[entry["pid"]] = self.proc_start(entry["pid"])
        return self.seen[entry["pid"]]

    def live(self, session: str) -> dict | None:
        return next((e for e in self.entries if e["session"] == session and self.started(e) == e["proc_start"]), None)

    def trusted(self) -> bool:
        """Whether the liveness test held for the reader's own session; `why` says why not,
        and is empty for a reader that runs in no session."""
        if not self.checked:
            self.checked = True
            mine = [e for e in self.entries if e["session"] == self.own]
            if not self.own:
                self.why = ""
            elif not mine:
                self.why = f"no session registry entry names this session, {self.own}"
            elif not self.live(self.own):
                self.why = f"ps gives {self.started(mine[0])!r} for pid {mine[0]['pid']}, its registry entry {mine[0]['proc_start']!r}"
        return self.why is None

    def state(self, session: str) -> str:
        return ("live" if self.live(session) else "ended") if self.trusted() else "unknown"
