#!/usr/bin/env python3
"""Close or keep a session's workloop runs (worktree_sweep.py calls these).

A finished run, one `workloop.py check` passes, closes: its worktrees' unsaved
work is committed to `saved/<name>` and the run ends with `abandon`. Any other
run waits HOLD_SECONDS for its conversation's resume (ruling 26). A run whose
worktrees hold ignored files that would not come back stays, as such a
worktree stays from the heal (ruling 28).
"""

from __future__ import annotations

import fcntl
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

_spec = importlib.util.spec_from_file_location("worktree_heal", Path(__file__).with_name("worktree_heal.py"))
hl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hl)
rm, wr = hl.rm, hl.wr

# An unfinished run waits this long after its session ends for the conversation's resume.
HOLD_SECONDS = 24 * 3600
STATE = Path(".agents/.workloop-state.json")


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
    """Why `workloop.py check` refuses the run; None once it passes or the run is gone."""
    name, state = entry.get("run"), entry.get("state") or ""
    runs, error = runs_of(state)
    if error:
        return error
    if name not in runs:
        return None
    result = subprocess.run([sys.executable, str(workloop), "--state", state, "check", name],
                            text=True, capture_output=True, env=wr.clean_env())
    lines = (result.stderr or result.stdout).strip().splitlines()
    return (lines[-1].removeprefix("workloop: ") if lines else f"check exited {result.returncode}") \
        if result.returncode else None


def waits(entry: dict, reason: str, since: float, now: float) -> bool:
    """Stamp an unfinished run's hold; True while it waits. A session end stamps afresh;
    a sweep stamps a run with no stamp (its session was killed) or one older than the
    last resume (`since`), and never refreshes a standing one."""
    held = entry.get("held")
    if reason or not isinstance(held, (int, float)) or held < since:
        entry["held"] = held = int(now)
    return now - held < HOLD_SECONDS


def close_run(remover, entry: dict, workloop: Path) -> bool:
    """Save a run's worktrees and close it with `abandon`; False when it must stay."""
    name, state = entry.get("run"), entry.get("state") or ""
    runs, error = runs_of(state)
    if error:
        remover.lines.append(f"kept workloop run {name}: {error}")
        return False
    run = runs.get(name)
    if run is None:
        return True
    spaces = [Path(s).resolve() for s in workspaces(run)]
    present = [path for path in spaces if path.is_dir()]
    repo = wr.main_checkout(run.get("repo") or "/nonexistent")
    # Git still lists a workspace that is not on disk (an unmounted volume):
    # abandon's prune would drop it, so the run stays.
    away = next((f"git lists {e['path']} but it is not on disk" for e in (wr.worktrees(repo) if repo else [])
                 if e["path"] in spaces and not e["path"].is_dir()), None)
    refusal = away or next((f"{path}: {r[1]}" for path in present for r in [remover.blocked(path)] if r), None) \
        or next((f"{path}: {loss}" for path in present for loss in [lost_files(path)] if loss), None)
    saved = []
    for path in [] if refusal else [path for path in present if rm.dirty(path)]:
        branch, error = rm.save(path, remover.label)
        refusal = f"{path}: its unsaved work could not be committed ({error})" if error else None
        if refusal:
            break
        saved.append(f"{path} -> {branch}")
    if refusal:
        remover.lines.append(f"kept workloop run {name}: {refusal}")
        return False
    os.chdir(Path(state).parent)
    result = subprocess.run([sys.executable, str(workloop), "--state", state, "abandon", name],
                            text=True, capture_output=True, env=wr.clean_env())
    remover.lines.append(f"kept workloop run {name}: abandon failed: {(result.stderr or result.stdout).strip()}"
                         if result.returncode else f"closed workloop run {name}: {result.stdout.strip()}"
                         + ("; unsaved work: " + ", ".join(saved) if saved else ""))
    return not result.returncode


def lost_files(path: Path) -> str | None:
    """Why removing the worktree would delete ignored files that would not come back, as the
    heal judges them (rulings 25, 28 and 30); None when nothing would be lost."""
    found = hl.unrebuildable(path)
    if isinstance(found, str) or not found:
        return found or None
    shown = ", ".join(found[:3]) + (f" and {len(found) - 3} more" if len(found) > 3 else "")
    return f"it holds ignored files that would not come back ({shown}); see `git -C {path} status --ignored`"


def workspaces(run: dict) -> list[str]:
    return [s for s in [lane.get("workspace") for lane in (run.get("lanes") or {}).values()]
            + [(run.get("integration") or {}).get("workspace")] if s]


def drop_run(state: Path, name: str) -> None:
    """Delete one run from the state file under the controller's own lock, as `workloop_state.Store` writes it."""
    with open(f"{state}.lock", "a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = json.loads(state.read_text())
        data["runs"].pop(name, None)
        scratch = state.with_name(f"{state.name}.{os.getpid()}")
        scratch.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
        os.replace(scratch, state)


def unowned_runs(main: Path, leads: set) -> list[str]:
    """Close a run no record leads once git lists none of its workspaces (a missing path
    may be an unmounted disk); a run with no lanes or no repository stays. Name the rest."""
    state, names, lines = main / STATE, [], []
    for name, run in sorted(wr.runs_in(str(state)).items()):
        if name in leads:
            continue
        repo = wr.main_checkout(run.get("repo") or "/nonexistent")
        listed = {str(e["path"]) for e in wr.worktrees(repo)} if repo else set()
        if run.get("lanes") and repo and not any(str(Path(s).resolve()) in listed for s in workspaces(run)):
            drop_run(state, name)
            lines.append(f"closed workloop run {name}: git lists none of its worktrees")
        else:
            names.append(name)
    if names:
        lines.append("Workloop runs no session recorded as their lead, left alone with their worktrees: " + ", ".join(names))
    return lines
