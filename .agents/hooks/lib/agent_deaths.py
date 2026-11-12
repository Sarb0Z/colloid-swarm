#!/usr/bin/env python3
"""Dead agents that touched this checkout, read from Claude Code's own records.

Usage: agent_deaths.py show <repo> [<session>]    every line, none cut

workloop-inbox.py calls `report` at every Claude Code session start and lead
prompt. It reads every agent whose transcript changed in the last 7 days
(agent_records.py), and every agent it showed before however old, and gives
each one verdict (agent_verdicts.py). A dead agent (failed or lost) of this
checkout that left something is shown, one line each (agent_leftovers.py),
until it is resumed, leaves nothing, or is dismissed (agent_dismissals.py);
the others are counted in one line.

What it read is cached in `.agents/.readout/.agent-deaths-cache`, replaced
atomically: an agent whose transcript is unchanged costs a stat, a completed
one nothing more, a session's transcript is read on from where the last read
stopped, and an agent whose edits were all committed asks Git nothing until
it works again. `cached_dead` gives the last read's dead agents without
reading again.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
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


@dataclass(frozen=True)
class Effects:
    now: float
    home: Path
    config_dir: str
    proc_start: Callable[[int], str | None]
    git: Callable[..., str | None]


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


def refresh(old: dict | None, transcript: str, session: str, stat: list) -> dict:
    """The agent's facts, read again where its transcript changed. While it may still be
    running its meta.json is read again too: `finished` may land after the last record."""
    path = Path(transcript)
    if old and old["file"] == stat:
        return dict(old, meta=ar.read_meta(path)) if old["state"] in ("running", "unknown") else old
    return {"transcript": transcript, "session": session, "file": stat, "meta": ar.read_meta(path),
            "ends": ar.how_it_ends(path), "edits": old["edits"] if old else [], "edits_at": old["edits_at"] if old else 0}


def with_edits(info: dict) -> dict:
    """The agent's edited paths, read on from where the last read stopped, when its transcript grew."""
    if info["edits_at"] == info["file"][0]:
        return info
    paths, reached = ar.edits_since(Path(info["transcript"]), info["edits_at"])
    return dict(info, edits=sorted({*info["edits"], *paths}), edits_at=reached)


def candidates(cache: dict, dirs: list[Path], running: set, now: float) -> dict:
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


def judge_one(agent_id: str, old: dict | None, file: list, at: Reading) -> tuple[dict, av.Verdict | None]:
    """The agent's cache entry and verdict; no verdict for an agent of another checkout.
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
    info = refresh(None if old and "settled" in old else old, transcript, session, stat)
    if av.completed(info):
        return {"file": stat, "settled": "completed"}, av.Verdict("completed")
    if agent_id not in at.held:
        info = with_edits(info)
        if not al.belongs(agent_id, info, at.places, at.held):
            return dict(info, state=ELSEWHERE), None
    verdict = av.judge(agent_id, info, at.parents, at.hosts, at.now, at.jobs)
    entry = {"file": stat, "settled": verdict.state} if verdict.state in av.SETTLED else dict(info, state=verdict.state)
    return entry, verdict


def judge_all(cache: dict, found: dict, at: Reading, problems: list) -> dict:
    """The verdict on every candidate of this checkout, and on every agent holding a lane or cell here."""
    agents, verdicts = {}, {}
    for agent_id, file in found.items():
        try:
            agents[agent_id], verdict = judge_one(agent_id, cache["agents"].get(agent_id), file, at)
        except (OSError, ValueError) as error:
            problems.append(f"agent deaths: agent {agent_id} could not be read: {error}")
            continue
        if verdict:
            verdicts[agent_id] = verdict
    cache["agents"] = agents
    cache["parents"] = at.parents.keep({aid: info for aid, info in agents.items() if info.get("state", ELSEWHERE) != ELSEWHERE})
    return verdicts


def show_dead(repo: Path, cache: dict, verdicts: dict, at: Reading, report: Report) -> None:
    dismissed = agent_dismissals.dismissed(repo / ".agents")
    dead = [aid for aid, verdict in verdicts.items() if verdict.state in av.SHOWN and aid not in dismissed]
    committed, own = {}, at.hosts.own
    for agent_id in sorted(dead, key=lambda aid: -verdicts[aid].at):
        info = cache["agents"][agent_id] = with_edits(cache["agents"][agent_id])
        report.dead[agent_id] = verdicts[agent_id].cause
        # Edits found all committed stay so until the agent works again.
        edits = [] if cache["committed"].get(agent_id) == info["file"] else al.edits_left(info, at.places)
        if not edits:
            committed[agent_id] = info["file"]
        if clauses := al.leftovers(agent_id, info, edits, at.held, own):
            report.shown.append(agent_id)
            report.lines.append(al.line(agent_id, info, verdicts[agent_id], clauses, own, at.hosts.state(info["session"])))
    cache.update(shown=report.shown, dead=report.dead, committed=committed, places=at.places.known)


def report(repo: Path, session: str, runs: dict, effects: Effects) -> Report:
    """Every verdict, and the lines for this checkout's dead agents; nothing outside a Git checkout."""
    result = Report()
    if not (repo / ".git").exists():
        return result
    cache = load(repo / ".agents" / CACHE)
    dirs = ar.config_dirs(effects.home, effects.config_dir)
    entries, problems = sessions.registry(dirs)
    jobs, unreadable = sessions.stopped_jobs(dirs)
    hosts = sessions.Hosts(entries, session, effects.proc_start)
    hosts.trusted()
    found = candidates(cache, dirs, {entry["session"] for entry in entries}, effects.now)
    at = Reading(al.run_agents(runs), al.Places(repo, effects.git, cache["places"]), av.Parents(cache["parents"]),
                 hosts, effects.now, jobs)
    result.verdicts = judge_all(cache, found, at, problems)
    show_dead(repo, cache, result.verdicts, at, result)
    problems += unreadable
    if hosts.why:
        problems.insert(0, f"agent deaths: cannot tell live sessions on this host ({hosts.why})")
    result.problems = problems
    # A read outside any session judges no agent lost, so it would drop lost agents from the cache.
    if session:
        save(repo / ".agents" / CACHE, cache)
    return result


def load(path: Path) -> dict:
    empty = {"sessions": {}, "agents": {}, "parents": {}, "shown": [], "dead": {}, "committed": {}, "places": {}}
    try:
        return {**empty, **json.loads(path.read_bytes())}
    except FileNotFoundError:
        return empty
    except ValueError as error:
        print(f"agent deaths: {path} is unreadable ({error}); reading every agent afresh", file=sys.stderr)
        return empty


def save(path: Path, cache: dict) -> None:
    if not path.exists() and not (cache["sessions"] or cache["agents"]):
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix=".agent-deaths.", dir=path.parent)
    try:
        with os.fdopen(handle, "w") as stream:
            stream.write(json.dumps(cache, separators=(",", ":")))
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_in_hook(repo: Path, session: str, runs: dict, git) -> Report:
    """`report` with the real effects, for a hook that must not block: a reader that fails says
    so on stderr and in the block, and the hook goes on."""
    try:
        return report(repo, session, runs, real_effects(git))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"agent deaths: the reader failed: {error}", file=sys.stderr)
        return Report(problems=[f"agent deaths: the reader failed ({error}), so no dead agent is listed"])


def cached_dead(agents_dir: Path) -> dict:
    """The dead agents of this checkout the last read found: id -> cause."""
    return load(agents_dir / CACHE)["dead"]


def known(repo: Path, agent_id: str, git) -> bool:
    """Whether the agent is a dead agent of this checkout, by the last read or by one now. A read
    outside any session judges no agent by liveness, so a lost agent is known only from the last
    read a session made."""
    return agent_id in cached_dead(repo / ".agents") or agent_id in report(repo, "", {}, real_effects(git)).dead


def proc_start(pid: int) -> str | None:
    """The process's start as Claude Code's registry records it, or None when no such process runs."""
    env = dict(os.environ, LC_ALL="C", TZ="UTC")
    result = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True, env=env, timeout=5)
    return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else None


def real_effects(git) -> Effects:
    return Effects(now=time.time(), home=Path.home(), config_dir=os.environ.get("CLAUDE_CONFIG_DIR", ""),
                   proc_start=proc_start, git=git)


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4) or sys.argv[1] != "show":
        sys.exit(f"usage: {SHOW} <repo> [<session>]")
    from workloop_size import GitBudget
    text = report(Path(sys.argv[2]).resolve(), sys.argv[3] if len(sys.argv) == 4 else "", {},
                  real_effects(GitBudget().out)).block(None, True)
    if text:
        print(text)
