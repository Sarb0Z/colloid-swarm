#!/usr/bin/env python3
"""Dead agents that touched this checkout, read from Claude Code's own records.

Usage: agent_deaths.py show <repo> [<session>]    every line, none cut

workloop-inbox.py calls `report` at every Claude Code session start and lead
prompt, through agent_effects.py, which wires in the clock, `ps`, Git and the
cache's write. It reads every agent whose transcript changed in the last 7 days
(agent_records.py), and every agent it showed before however old, and gives
each one verdict (agent_verdicts.py). A dead agent (failed or lost) of this
checkout that left something is shown, one line each (agent_leftovers.py),
until it is resumed, leaves nothing, or that death is dismissed
(agent_dismissals.py); the others are counted in one line.

What it read is cached in `.agents/.readout/.agent-deaths-cache`, replaced
atomically: an agent whose transcript is unchanged costs a stat, a completed
one nothing more, a session's transcript is read on from where the last read
stopped, and an agent whose edits were all committed asks Git nothing until
it works again. A read that cannot judge an agent the last read judged dead,
because it cannot tell live sessions or Git gave no answer, keeps that verdict
while the agent has written nothing since.
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import agent_dismissals
import agent_leftovers as al
import agent_records as ar
import agent_sessions as sessions
import agent_verdicts as av

# The cached state of an agent of another checkout, which is given no verdict here.
ELSEWHERE = "elsewhere"
SHOWN_MAX = 5
CACHE = Path(".readout") / ".agent-deaths-cache"
SHOW = "python3 .agents/hooks/lib/agent_deaths.py show"
# The reader's own code, by content: a cache another version wrote is judged again (`_load`).
RULES = hashlib.sha256(b"".join(Path(__file__).with_name(f"{name}.py").read_bytes() for name in (
    "agent_deaths", "agent_records", "agent_verdicts", "agent_leftovers", "agent_sessions"))).hexdigest()[:16]


@dataclass(frozen=True)
class Effects:
    now: float
    home: Path
    config_dir: str
    proc_start: Callable[[int], str | None]
    git: Callable[..., str | None]
    write: Callable[[Path, str], None]  # replaces the file's text atomically


@dataclass
class Report:
    verdicts: dict = field(default_factory=dict)
    lines: list = field(default_factory=list)
    shown: list = field(default_factory=list)  # the agent of each line, in order
    dead: dict = field(default_factory=dict)  # this checkout's dead agents, shown or counted: id -> cause
    problems: list = field(default_factory=list)

    def block(self, limit: int | None, at_start: bool) -> str:
        """The lines, `limit` at most, then the count of those that left nothing (at a start, or
        beside a line), then what kept the reader from judging."""
        shown = self.lines if limit is None or len(self.lines) <= limit else self.lines[:limit] + [
            f"AGENT DIED: and {len(self.lines) - limit} more; every line: {SHOW}"]
        quiet = len(self.dead) - len(self.lines)
        counted = quiet and (at_start or self.lines)
        tally = [f"{quiet} agent{'s' if quiet != 1 else ''} that left nothing died this week."] if counted else []
        return "\n".join(shown + tally + self.problems)


def _refresh(old: dict | None, transcript: str, session: str, stat: list) -> dict:
    """The agent's facts, read again where its transcript changed. While it may still be
    running its meta.json is read again too: `finished` may land after the last record."""
    path = Path(transcript)
    if old and old["file"] == stat:
        return dict(old, meta=ar.read_meta(path)) if old["state"] in ("running", "unknown") else old
    return {"transcript": transcript, "session": session, "file": stat, "meta": ar.read_meta(path),
            "ends": ar.how_it_ends(path), "edits": old["edits"] if old else [], "edits_at": old["edits_at"] if old else 0}


def _with_edits(info: dict) -> dict:
    """The agent's edited paths, read on from where the last read stopped, when its transcript grew."""
    if info["edits_at"] == info["file"][0]:
        return info
    paths, reached = ar.edits_since(Path(info["transcript"]), info["edits_at"])
    return dict(info, edits=sorted({*info["edits"], *paths}), edits_at=reached)


def _candidates(cache: dict, dirs: list[Path], running: set, now: float) -> dict:
    """{id: [transcript, session, size, mtime_ns]}: the window's agents, and the ones shown before."""
    found, cache["sessions"] = ar.recent_agents(ar.real_folders(d / "projects" for d in dirs), cache["sessions"], running, now)
    for agent_id in cache["shown"]:
        info = cache["agents"].get(agent_id)
        if agent_id not in found and info and "transcript" in info:
            try:
                stat = os.stat(info["transcript"])
            except FileNotFoundError:
                continue
            found[agent_id] = [info["transcript"], info["session"], stat.st_size, stat.st_mtime_ns]
    return found


@dataclass
class Reading:
    """What one read judges against: the agents holding a lane or cell here (`held`), this
    checkout's places, the session transcripts' verdicts, the live sessions, the time, and the
    stopped background sessions with their jobs."""
    held: dict
    places: al.Places
    parents: av.Parents
    hosts: sessions.Hosts
    now: float
    jobs: dict


def _judge_one(agent_id: str, old: dict | None, file: list, at: Reading) -> tuple[dict, av.Verdict | None]:
    """The agent's cache entry and verdict; no verdict for an agent of another checkout, or one
    Git could not place, which is cached `unknown` so the next read places it again.
    Whether it is this checkout's is settled before its session transcript is read, so another
    project's long transcript costs nothing here. A completed or stopped agent is cached as its
    verdict alone; that and another checkout's agent hold until its transcript changes."""
    transcript, session, size, mtime = file
    stat = [size, mtime]
    if old and old["file"] == stat and (agent_id not in at.held or old.get("state") != ELSEWHERE):
        if "settled" in old:
            return old, av.Verdict(old["settled"])
        if old["state"] == ELSEWHERE:
            return old, None
    info = _refresh(None if old and "settled" in old else old, transcript, session, stat)
    if av.completed(info):
        return {"file": stat, "settled": "completed"}, av.Verdict("completed")
    if agent_id not in at.held:
        info = _with_edits(info)
        belongs = al.belongs(agent_id, info, at.places, at.held)
        if not belongs:
            return dict(info, state=ELSEWHERE if belongs is False else "unknown"), None
    verdict = av.judge(agent_id, info, at.parents, at.hosts, at.now, at.jobs)
    entry = {"file": stat, "settled": verdict.state} if verdict.state in av.SETTLED else dict(info, state=verdict.state)
    return entry, verdict


def _carried(cached: list | None, verdict: av.Verdict | None, entry: dict) -> av.Verdict | None:
    """The last read's verdict on a dead agent this read could not judge, while the agent has
    written nothing since that verdict."""
    if cached is None or (verdict is not None and verdict.state != "unknown") or entry.get("state") != "unknown":
        return verdict
    newest = entry["ends"]["newest"]
    return av.Verdict(*cached) if newest is None or newest <= cached[2] else verdict


def _judge_all(cache: dict, found: dict, at: Reading, problems: list) -> dict:
    """The verdict on every candidate of this checkout, and on every agent holding a lane or cell
    here. An agent that cannot be read keeps its last entry, and its session's verdicts stay."""
    agents, verdicts, unread = {}, {}, set()
    for agent_id, file in found.items():
        old = cache["agents"].get(agent_id)
        try:
            agents[agent_id], verdict = _judge_one(agent_id, old, file, at)
        except (OSError, ValueError) as error:
            problems.append(f"agent deaths: agent {agent_id} could not be read: {error}")
            unread.add(av.parent({"transcript": file[0], "session": file[1]}))
            if old:
                agents[agent_id] = old
            continue
        if verdict := _carried(cache["judged"].get(agent_id), verdict, agents[agent_id]):
            verdicts[agent_id] = verdict
    cache["agents"] = agents
    tracked = {aid: info for aid, info in agents.items() if info.get("state", ELSEWHERE) != ELSEWHERE}
    cache["parents"] = at.parents.keep(tracked, unread)
    return verdicts


def _show_dead(repo: Path, cache: dict, verdicts: dict, at: Reading, report: Report) -> None:
    dismissals = agent_dismissals.dismissed(repo / ".agents")
    judged = {aid: [v.state, v.cause, v.at, v.job] for aid, v in verdicts.items() if v.state in av.SHOWN}
    dead = [aid for aid in judged if not agent_dismissals.covers(dismissals, aid, verdicts[aid].at)]
    committed, own = {}, at.hosts.own
    for agent_id in sorted(dead, key=lambda aid: -verdicts[aid].at):
        info = cache["agents"][agent_id] = _with_edits(cache["agents"][agent_id])
        report.dead[agent_id] = verdicts[agent_id].cause
        # Edits found all committed stay so until the agent works again.
        edits = [] if cache["committed"].get(agent_id) == info["file"] else al.edits_left(info, at.places)
        if not edits:
            committed[agent_id] = info["file"]
        if clauses := al.leftovers(agent_id, info, edits, at.held, own):
            report.shown.append(agent_id)
            report.lines.append(al.line(agent_id, info, verdicts[agent_id], clauses, own, at.hosts.state(info["session"])))
    cache.update(shown=report.shown, judged=judged, committed=committed, places=at.places.known)


def report(repo: Path, session: str, runs: dict, effects: Effects) -> Report:
    """Every verdict, and the lines for this checkout's dead agents; nothing outside a Git checkout."""
    result = Report()
    if not (repo / ".git").exists():
        return result
    cache = _load(repo / ".agents" / CACHE)
    dirs = ar.config_dirs(effects.home, effects.config_dir)
    entries, problems = sessions.registry(dirs)
    jobs, unreadable = sessions.stopped_jobs(dirs)
    hosts = sessions.Hosts(entries, session, effects.proc_start)
    hosts.trusted()
    found = _candidates(cache, dirs, {entry["session"] for entry in entries}, effects.now)
    at = Reading(al.run_agents(runs), al.Places(repo, effects.git, cache["places"]), av.Parents(cache["parents"]),
                 hosts, effects.now, jobs)
    result.verdicts = _judge_all(cache, found, at, problems)
    _show_dead(repo, cache, result.verdicts, at, result)
    problems += unreadable
    if at.places.unanswered:
        problems.append(f"agent deaths: Git gave no answer to {', '.join(sorted(at.places.unanswered))}, "
                        "so what rests on it is read again next time")
    if hosts.why:
        problems.insert(0, f"agent deaths: cannot tell live sessions on this host ({hosts.why})")
    result.problems = problems
    # A read outside any session judges no agent lost, so it would drop newly lost agents from the cache.
    if session:
        _save(repo / ".agents" / CACHE, cache, effects.write)
    return result


def judged_dead(repo: Path) -> dict[str, av.Verdict]:
    """The verdicts of the agents the last read judged failed, lost or parked and no dismissal
    covers, from the cache alone: the statusline reads this at every refresh and runs no reader.
    A missing cache gives {}; a cache or dismissal file that cannot be read raises, for the
    caller to show."""
    try:
        judged = json.loads((repo / ".agents" / CACHE).read_bytes())["judged"]
    except FileNotFoundError:
        return {}
    dismissals = agent_dismissals.dismissed(repo / ".agents")
    verdicts = {aid: av.Verdict(state, cause, at, job) for aid, (state, cause, at, job) in judged.items()}
    return {aid: v for aid, v in verdicts.items() if not agent_dismissals.covers(dismissals, aid, v.at)}


def _load(path: Path) -> dict:
    """The cache, or an empty one. A cache written by other reader code keeps only the agents it
    showed, as transcripts to read again, and its verdicts: every entry it settled was judged by
    rules this code may not share, and would hold until the agent's transcript changed."""
    empty = {"rules": RULES, "sessions": {}, "agents": {}, "parents": {}, "shown": [], "judged": {}, "committed": {}, "places": {}}
    try:
        data = json.loads(path.read_bytes())
        if not isinstance(data, dict):
            raise ValueError("it holds no JSON object")
    except FileNotFoundError:
        return empty
    except ValueError as error:
        print(f"agent deaths: {path} is unreadable ({error}); reading every agent afresh", file=sys.stderr)
        return empty
    if data.get("rules") == RULES:
        return {key: data.get(key, value) for key, value in empty.items()}
    agents = data.get("agents", {})
    shown = [aid for aid in data.get("shown", []) if "transcript" in agents.get(aid, {})]
    return dict(empty, shown=shown, judged=data.get("judged", {}),
                agents={aid: {"transcript": agents[aid]["transcript"], "session": agents[aid]["session"], "file": None,
                              "edits": [], "edits_at": 0} for aid in shown})


def _save(path: Path, cache: dict, write: Callable[[Path, str], None]) -> None:
    if not path.exists() and not (cache["sessions"] or cache["agents"]):
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    write(path, json.dumps(cache, separators=(",", ":")))


if __name__ == "__main__":
    import agent_effects
    agent_effects.show(sys.argv[1:])
