"""How each agent ended: one verdict per agent, from Claude Code's records.

The first rule that applies decides:

  1. Claude Code's own: the newest notification on the agent in its session's
     transcript, or a foreground agent's `Agent` call result, when no older
     than the agent's newest user or assistant record. `completed`; `killed`
     is stopped on purpose and never shown; `failed <cause>`; `stopped`, or a
     failure saying the session ended, is `lost`. An agent the session marks
     failed after an earlier failed or stopped verdict "failed again after a
     resume". Two notifications are no verdict: one with no status (a
     background session restarted the agent, which works again), and a
     `completed` one saying the agent "is waiting on its own background work".
  2. Its own files: `completed` when `meta.json` says finished and its newest
     record answers its SubagentHandback call or is a final answer given with
     no background command of its own running (agent_records.waiting), which
     is tested first and reads no session transcript; `failed <error class>`
     when finished on an API error record.
  3. Liveness, for the rest: `running` while its session is live and its
     newest record is later than that process's start; `lost` once either
     fails and both transcripts have been quiet for 10 minutes, `running`
     within them. A session is live when a registry entry names it and
     `LC_ALL=C TZ=UTC ps -o lstart= -p <pid>`, trimmed, equals its
     `procStart`, which rejects an entry a killed process left. That test is
     trusted only once it passes for the reader's own session; until then no
     agent is judged by it (`unknown`). An agent that would read lost whose
     session is a background session its supervisor holds stopped is
     `parked`: `claude respawn <job id>` restarts it with its agents.

`stoppedByUser` in `meta.json` decides nothing: a quit session sets it too.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

import agent_records as ar

DEAD = ("failed", "lost")
SHOWN = (*DEAD, "parked")
SETTLED = ("completed", "stopped")
QUIET_SECONDS = 600
STATUSES = {"completed": "completed", "killed": "stopped", "failed": "failed", "stopped": "lost"}
SESSION_ENDED = re.compile(r"previous session ended|No completion record")
ERROR_TYPE = re.compile(r"\(error type (\w+)")
WAITING = "is waiting on its own background work"


@dataclass(frozen=True)
class Verdict:
    state: str  # completed, stopped, failed, lost, parked, running or unknown
    cause: str = ""
    at: float = 0.0
    job: str = ""  # a parked agent's background session job, which `claude respawn` takes


class Hosts:
    """Which sessions run now, trusted once the reader's own session passes the same test."""

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


class Parents:
    """Claude Code's verdicts per session transcript, each kind read on from where the cache
    stopped: notifications on background agents (`notes`), and `Agent` call results
    (`results`), which are read only once a foreground agent needs one."""

    KINDS = {"notes": ar.notes_since, "results": ar.results_since}

    def __init__(self, cached: dict) -> None:
        self.cached, self.read = cached, set()

    def data(self, path: str, kind: str) -> dict:
        data = self.cached.setdefault(path, {})
        if (path, kind) in self.read:
            return data.get(kind, {})
        self.read.add((path, kind))
        at, found = data.get(f"{kind}_at", 0), data.get(kind, {})
        try:
            items, reached = self.KINDS[kind](Path(path), at)
        except FileNotFoundError:
            return found
        if reached < at:
            found = {}
        for key, *verdict in items:
            if kind == "notes":
                found.setdefault(key, []).append(verdict)
            else:
                found[key] = verdict
        data[kind], data[f"{kind}_at"] = found, reached
        return found

    def told(self, agent_id: str, info: dict) -> tuple | None:
        """(time, status, summary, after a resume) of the newest verdict on the agent, or None."""
        if info["meta"]["background"]:
            notes = sorted(note for note in self.data(parent(info), "notes").get(agent_id) or []
                           if note[1] and not (note[1] == "completed" and WAITING in note[2]))
            again = any(status in ("failed", "stopped") for _, status, _ in notes[:-1])
            return (*notes[-1], again) if notes else None
        result = self.data(parent(info), "results").get(info["meta"]["tool_use_id"])
        return (*result, "", False) if result else None

    def keep(self, agents: dict) -> dict:
        """The cached verdicts on the agents still tracked, by session transcript."""
        kept = {}
        for path, data in self.cached.items():
            mine = {aid: info for aid, info in agents.items() if parent(info) == path}
            if mine:
                uses = {info["meta"]["tool_use_id"] for info in mine.values()}
                kept[path] = {key: value for key, value in data.items() if key.endswith("_at")}
                kept[path]["notes"] = {aid: notes for aid, notes in data.get("notes", {}).items() if aid in mine}
                kept[path]["results"] = {use: result for use, result in data.get("results", {}).items() if use in uses}
        return kept


def parent(info: dict) -> str:
    """The transcript of the agent's session: `<project>/<session>.jsonl` beside its folder."""
    return str(Path(info["transcript"]).parents[2] / f"{info['session']}.jsonl")


def completed(info: dict) -> bool:
    return info["meta"]["finished"] and info["ends"]["end"] in ("answer", "handback")


def shorten(summary: str) -> str:
    """The cause a notification's summary gives: its error type, a stall, else its first clause."""
    if found := ERROR_TYPE.search(summary):
        return found.group(1)
    if "stalled" in summary:
        return "stalled"
    text = re.sub(r'^Agent ".*?" failed: ', "", summary).split(" (")[0].strip().rstrip(".")
    return text[:60] or "no reason given"


def from_told(told: tuple, info: dict, agent_id: str) -> Verdict:
    at, status, summary, again = told
    if status not in STATUSES:
        raise ar.RecordError(f"{parent(info)}: the verdict on agent {agent_id} has an unknown status {status!r}")
    state = STATUSES[status]
    if state == "lost" or (state == "failed" and SESSION_ENDED.search(summary)):
        return Verdict("lost", "session ended", at)
    if state != "failed":
        return Verdict(state, "", at)
    ends = info["ends"]
    cause = ends["error"] if ends["end"] == "api-error" else shorten(summary)
    return Verdict("failed", f"failed again after a resume ({cause})" if again else cause, at)


def judge(agent_id: str, info: dict, parents: Parents, hosts: Hosts, now: float, jobs: dict) -> Verdict:
    """The agent's verdict; `jobs` maps each session a background supervisor holds stopped to its job."""
    if completed(info):
        return Verdict("completed")
    told = parents.told(agent_id, info)
    newest = info["ends"]["newest"]
    if told and (newest is None or told[0] >= newest):
        return from_told(told, info, agent_id)
    if info["meta"]["finished"] and info["ends"]["end"] == "api-error":
        return Verdict("failed", info["ends"]["error"], newest)
    if not hosts.trusted():
        return Verdict("unknown")
    entry = hosts.live(info["session"])
    if entry and (newest is None or newest > entry["started_at"]):
        return Verdict("running")
    if now - max(info["file"][1] / 1e9, ar.mtime_ns(parent(info)) / 1e9) < QUIET_SECONDS:
        return Verdict("running")
    if info["session"] in jobs:
        return Verdict("parked", "background session stopped", newest or 0.0, jobs[info["session"]])
    return Verdict("lost", "session restarted" if entry else "session ended", newest or 0.0)
