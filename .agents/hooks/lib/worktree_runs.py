#!/usr/bin/env python3
"""The workloop runs a session sweep reads and closes (worktree_sweep.py calls these).

A run closes only through `workloop.py abandon`, which keeps its record
(`abandon`). Nothing of a run is removed, flagged or closed while one of its
agents may still be working (`live_agents`, spec Unit 1.6). A run whose
worktrees hold ignored files that would not come back keeps them
(`lost_files`, ruling 28).
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import time
from pathlib import Path

_spec = importlib.util.spec_from_file_location("worktree_heal", Path(__file__).with_name("worktree_heal.py"))
hl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hl)
rm, wr = hl.rm, hl.wr
# The controller's timestamp parse, as the lead's digest reads it.
_spec = importlib.util.spec_from_file_location("workloop_size", Path(__file__).with_name("workloop_size.py"))
ws = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ws)
_spec = importlib.util.spec_from_file_location("agent_records", Path(__file__).with_name("agent_records.py"))
ar = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ar)

# A lead-less read-only fan-out whose cells all went out this long ago is closed (ruling 35).
HOLD_SECONDS = 24 * 3600
STATE = Path(".agents/.workloop-state.json")
# The death reader's cache (agent_deaths.py), and its rule that an agent whose transcript, or its
# session's, changed this recently may still run (agent_verdicts.QUIET_SECONDS).
DEATHS_CACHE = Path(".agents/.readout/.agent-deaths-cache")
QUIET_SECONDS = 600
LIVE_STATES = ("running", "waiting", "unknown")


def runs_of(state: str) -> tuple[dict, str | None]:
    """The state file's runs, or why they cannot be read. An absent file holds no run;
    one that does not parse reads as unreadable, never as empty, so no run is lost to it."""
    path = Path(state)
    if not path.is_file():
        return {}, None
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        return {}, f"its state file {state} is unreadable ({error})"
    runs = data.get("runs") if isinstance(data, dict) else None
    return (runs, None) if isinstance(runs, dict) else ({}, f"its state file {state} holds no runs table")


def unfinished(entry: dict, workloop: Path) -> str | None:
    """Why `workloop.py check --recorded` refuses the run; None once it passes or the run is gone.
    The recorded form judges from results already recorded: a sweep never runs a composed test."""
    name, state = entry.get("run"), entry.get("state") or ""
    runs, error = runs_of(state)
    if error:
        return error
    if name not in runs:
        return None
    result = subprocess.run([sys.executable, str(workloop), "--state", state, "check", name, "--recorded"],
                            text=True, capture_output=True, env=wr.clean_env())
    lines = (result.stderr or result.stdout).strip().splitlines()
    return (lines[-1].removeprefix("workloop: ") if lines else f"check exited {result.returncode}") \
        if result.returncode else None


def abandon(name: str, state: str, workloop: Path, why: str) -> tuple[bool, str]:
    """Close a run through `workloop.py abandon`, which keeps its record; (closed, the line)."""
    result = subprocess.run([sys.executable, str(workloop), "--state", state, "abandon", name],
                            text=True, capture_output=True, env=wr.clean_env(), cwd=Path(state).parent)
    if result.returncode:
        return False, f"kept workloop run {name}: abandon failed: {(result.stderr or result.stdout).strip()}"
    return True, f"closed workloop run {name}: {why}; {result.stdout.strip()}"


def lost_files(path: Path) -> str | None:
    """Why removing the worktree would delete ignored files that would not come back, as the
    heal judges them (rulings 25, 28 and 30); None when nothing would be lost."""
    found = hl.unrebuildable(path)
    if isinstance(found, str) or not found:
        return found or None
    shown = ", ".join(found[:3]) + (f" and {len(found) - 3} more" if len(found) > 3 else "")
    return f"it holds ignored files that would not come back ({shown}); see `git -C {path} status --ignored`"


def workspaces(run: dict) -> list[str]:
    """The run's worktrees: its worktree lanes and its integration. A main lane
    (`place` = "main") works in the checkout itself, which is nobody's to remove or judge."""
    return [s for s in [lane.get("workspace") for lane in (run.get("lanes") or {}).values() if lane.get("place") != "main"]
            + [(run.get("integration") or {}).get("workspace"), (run.get("verified") or {}).get("workspace")] if s]


def transcript_of(agent_id: str) -> Path | None:
    """An agent's transcript the death reader has not cached, found in Claude Code's stores."""
    for store in ar.real_folders(d / "projects" for d in ar.config_dirs(Path.home(), os.environ.get("CLAUDE_CONFIG_DIR", ""))):
        found = next(store.glob(f"*/*/subagents/agent-{agent_id}.jsonl"), None)
        if found:
            return found
    return None


def live_agents(main: Path, run: dict, now: float) -> list[str]:
    """The run's agents still out (cells out, active lanes' writers) that may still be working:
    the death reader's cached verdict is running, waiting or unknown on an unchanged transcript,
    or the transcript changed within QUIET_SECONDS. A start pays one stat per such agent."""
    ids = [cell.get("agent_id") for cell in (run.get("cells") or {}).values() if cell.get("state") == "out"]
    ids += [lane.get("claimed_by") for lane in (run.get("lanes") or {}).values() if lane.get("state") == "active"]
    ids = [agent_id for agent_id in ids if agent_id]
    if not ids:
        return []
    try:
        cache = json.loads((main / DEATHS_CACHE).read_text()).get("agents", {})
    except FileNotFoundError:
        cache = {}
    except (OSError, ValueError, AttributeError) as error:
        wr.warn(f"{main / DEATHS_CACHE} is unreadable ({error}); each agent is judged by its transcript's age")
        cache = {}
    live = []
    for agent_id in ids:
        info = cache.get(agent_id) if isinstance(cache.get(agent_id), dict) else {}
        transcript = Path(info["transcript"]) if isinstance(info.get("transcript"), str) else transcript_of(agent_id)
        try:
            stat = os.stat(transcript) if transcript else None
        except FileNotFoundError:
            stat = None
        if stat is None:
            continue
        unchanged = info.get("file") == [stat.st_size, stat.st_mtime_ns]
        if now - stat.st_mtime < QUIET_SECONDS or (unchanged and info.get("state") in LIVE_STATES):
            live.append(agent_id)
    return live


def fanout_closed(run: dict, now: float) -> str | None:
    """Why a lead-less read-only fan-out (no `--verify`, so cells only) is closed: every cell
    is back, or every cell still out went out before the hold, since no cell outlives its
    session (ruling 35); None for any other run, or while a cell may still return."""
    # debt: fanout-rule-copies -- completion_problems and the digest's cell notes read this rule too.
    cells = run.get("cells") or {}
    if run.get("verify") or run.get("lanes") or not cells:
        return None
    out = [cell for cell in cells.values() if cell.get("state") == "out"]
    if not out:
        return "every cell is back"
    sent = [ws.stamp(cell.get("out_since")) for cell in out]
    if all(at is not None and now - at >= HOLD_SECONDS for at in sent):
        return f"its cells went out over {HOLD_SECONDS // 3600} hours ago"
    return None


def unowned_runs(main: Path, leads: set, workloop: Path) -> list[str]:
    """Close, through `abandon`, a run no record leads once git lists none of its worktrees (a
    missing path may be an unmounted disk), or once it is a fan-out whose cells are back or past
    the hold; a run with lanes and no repository or no worktree (a one-writer run, whose lane
    works in the checkout), and a run an agent may still be working for, stays. Name the rest."""
    state, names, lines, now = main / STATE, [], [], time.time()
    for name, run in sorted(wr.runs_in(str(state)).items()):
        if name in leads:
            continue
        repo = wr.run_checkout(run.get("repo") or "/nonexistent")
        listed = {str(e["path"]) for e in wr.worktrees(repo)} if repo else set()
        spaces = workspaces(run)
        if live_agents(main, run, now):
            names.append(name)
            continue
        away = [str(e["path"]) for e in wr.worktrees(repo) if not e["path"].is_dir()] if repo else []
        if run.get("lanes") and repo and spaces and not any(str(Path(s).resolve()) in listed for s in spaces):
            # abandon prunes git's worktree list repository-wide, which would forget a worktree
            # on an unmounted disk; such a run waits until that disk is back.
            if away:
                lines.append(f"kept workloop run {name}: git lists none of its worktrees, but closing it would make git "
                             f"forget {away[0]}, which is not on disk")
                names.append(name)
                continue
            why = "git lists none of its worktrees"
        # Judged again on a fresh read just before the close: a cell added since keeps the run.
        elif fanout_closed(run, now) and (fresh := runs_of(str(state))[0].get(name)) is not None:
            why = fanout_closed(fresh, now)
        else:
            why = None
        if why is None:
            names.append(name)
            continue
        closed, line = abandon(name, str(state), workloop, why)
        lines.append(line)
        if not closed:
            names.append(name)
    if names:
        lines.append("Workloop runs no session recorded as their lead, left alone with their worktrees: " + ", ".join(names))
    return lines
