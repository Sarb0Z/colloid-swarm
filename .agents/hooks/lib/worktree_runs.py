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
import shutil
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
    """Why `workloop.py check --recorded` refuses the run; None once it passes or the run is gone.
    The recorded form judges from results already recorded: a session end never runs a composed test."""
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
    repo = wr.run_checkout(run.get("repo") or "/nonexistent")
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
    """The run's worktrees: its worktree lanes and its integration. A main lane
    (`place` = "main") works in the checkout itself, which is nobody's to remove or judge."""
    return [s for s in [lane.get("workspace") for lane in (run.get("lanes") or {}).values() if lane.get("place") != "main"]
            + [(run.get("integration") or {}).get("workspace"), (run.get("verified") or {}).get("workspace")] if s]


def drop_run(state: Path, name: str, why) -> str | None:
    """Delete one run from the state file under the controller's own lock, as `workloop_state.Store`
    writes it, when `why(run)`, judged on the run as read under that lock, still names a reason.
    Returns the reason; None when the run is gone or changed since it was judged, and stays."""
    with open(f"{state}.lock", "a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = json.loads(state.read_text())
        run = data["runs"].get(name)
        reason = why(run) if run is not None else None
        if reason is None:
            return None
        del data["runs"][name]
        scratch = state.with_name(f"{state.name}.{os.getpid()}")
        scratch.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
        os.replace(scratch, state)
    return reason


def remove_briefs(run: dict, name: str) -> str | None:
    """Remove a closed run's briefs and its folder once empty, as `teardown` does; why not, or None."""
    folder = Path(run.get("repo") or "/nonexistent") / wr.RECORDS.parent / name
    try:
        if (folder / ".workloop").is_dir():
            shutil.rmtree(folder / ".workloop")
        if folder.is_dir() and not any(folder.iterdir()):
            folder.rmdir()
    except OSError as error:
        return f"its briefs in {folder} could not be removed ({error})"
    return None


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


def unowned_runs(main: Path, leads: set) -> list[str]:
    """Close a run no record leads once git lists none of its worktrees (a missing path
    may be an unmounted disk), or once it is a fan-out whose cells are back or past the
    hold; a run with lanes and no repository or no worktree (a one-writer run, whose
    lane works in the checkout) stays. Name the rest."""
    state, names, lines, now = main / STATE, [], [], time.time()
    for name, run in sorted(wr.runs_in(str(state)).items()):
        if name in leads:
            continue
        repo = wr.run_checkout(run.get("repo") or "/nonexistent")
        listed = {str(e["path"]) for e in wr.worktrees(repo)} if repo else set()
        spaces = workspaces(run)
        if run.get("lanes") and repo and spaces and not any(str(Path(s).resolve()) in listed for s in spaces):
            drop_run(state, name, lambda _: "git lists none of its worktrees")
            lines.append(f"closed workloop run {name}: git lists none of its worktrees")
        # Judged again under the lock: a cell added since this read keeps the run.
        elif fanout_closed(run, now) and (closed := drop_run(state, name, lambda current: fanout_closed(current, now))):
            unremoved = remove_briefs(run, name)
            lines.append(f"closed workloop run {name}: {closed}" + (f"; {unremoved}" if unremoved else ""))
        else:
            names.append(name)
    if names:
        lines.append("Workloop runs no session recorded as their lead, left alone with their worktrees: " + ", ".join(names))
    return lines
