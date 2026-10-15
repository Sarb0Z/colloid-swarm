#!/usr/bin/env python3
"""End a session's records at its end, and sweep the repository's at each start.

    worktree_sweep.py end <project> <session> <reason> <workloop.py>            (session-end.sh)
    worktree_sweep.py sweep <project> <session> <source> <workloop.py>          (session-start.sh)
    worktree_sweep.py list <project>          the kept verdicts earlier starts cached, dated

`sweep` (one per repository at a time) folds back what a killed run left,
ends the records of sessions whose process is gone, closes a run no record
leads once git lists none of its workspaces, and heals what older sessions
left (worktree_heal.py). It prints each line as it happens, so a failure
later keeps the report of what went. A compaction start (source `compact`)
removes no unrecorded worktree. WORKTREE_HEAL_SECONDS overrides how long into
the heal a start may still begin a removal.
"""

from __future__ import annotations

import fcntl
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

# Reasons after which the session's process exits; after /clear and /resume it
# goes on working, so its own folder still counts as occupied.
EXITS = {"prompt_input_exit", "other", "logout", "bypass_permissions_disabled"}
IDLE_SECONDS = 24 * 3600
PARKED_SECONDS = 600
STATE = Path(".agents/.workloop-state.json")


def reclaim(folder: Path) -> None:
    """Fold claim files whose claiming process died back into their record files."""
    for claim in folder.glob(".*.jsonl.*-*"):
        pid = claim.name.rsplit("-", 1)[-1]
        if pid.isdigit() and wr.ps_row(int(pid)) is None:
            with open(folder / claim.name[1:].rsplit(".", 1)[0], "a") as stream:
                stream.write(claim.read_text())
            claim.unlink()


def unpark(main: Path) -> None:
    trash = rm.trash_dir(main)
    for bin_ in trash.iterdir() if trash.is_dir() else []:
        manifest = bin_ / "manifest.json"
        if time.time() - bin_.stat().st_mtime < PARKED_SECONDS:
            continue
        worktree = json.loads(manifest.read_text())["worktree"] if manifest.is_file() else ""
        if worktree and Path(worktree).is_dir():
            rm.restore(bin_)
        else:
            rm.purge([bin_])


def over(entries: list[dict], path: Path) -> bool:
    """The session's process is gone (a file with no host: untouched for 24 hours)."""
    stamp = wr.last_host(entries)
    return not wr.alive(stamp) if stamp else time.time() - path.stat().st_mtime > IDLE_SECONDS


def close(path: Path, reason: str, workloop: Path) -> list[str]:
    """End one session's records: claim the file, remove, write back what stays."""
    claimed = path.with_name(f".{path.name}.{'ending' if reason else 'sweep'}-{os.getpid()}")
    try:
        os.rename(path, claimed)
    except FileNotFoundError:
        return []  # another end or sweep claimed it first
    entries, me = wr.load(claimed), wr.host()
    stamp = wr.last_host(entries)
    exclude = {pid for pid, _, _ in wr.chain()} if reason in EXITS else {os.getpid()}
    remover = rm.Remover(f"session {path.stem}", exclude, me[0] if reason and me else stamp[0] if stamp else None)
    # What stays goes back under the session's host, so the first sweep after
    # that process exits takes it: after /clear or /resume that is a run with
    # an unsubmitted lane, whose cell may still be working.
    wr.append(path.parent, path.stem, [dict(e, host=stamp) for e in finish(entries, remover, workloop, reason)])
    claimed.unlink()
    return remover.lines


def finish(entries: list[dict], remover, workloop: Path, reason: str) -> list[dict]:
    """Close the runs, then remove the worktrees; return the entries still standing.
    Claude Code asks keep-or-remove only for the last worktree entered, and reports
    the main checkout as the cwd after the answer (2.1.299), so only that one reads as kept."""
    runs = {(e.get("run"), e.get("state")): e for e in entries if e.get("type") == "run"}
    hold = reason in ("clear", "resume")
    entered = [e["path"] for e in entries if e.get("by") == "EnterWorktree" and e.get("path")]
    remaining = [entry for entry in runs.values() if not close_run(remover, entry, workloop, hold)]
    kept_runs, seen = {entry["run"] for entry in remaining}, set()
    for entry in [e for e in entries if e.get("type") == "worktree" and e.get("path")]:
        path = Path(entry["path"])
        if str(path) in seen:
            continue
        seen.add(str(path))
        if entry.get("run") in kept_runs:
            remaining.append(entry)
        elif reason == "prompt_input_exit" and entered and entry["path"] == entered[-1] and path.is_dir() \
                and not lock_of(path):
            remover.lines.append(f"kept {path}: kept at Claude Code's exit prompt")
        elif remover.retire(path) == "kept":
            remaining.append(entry)
    return remaining


def close_run(remover, entry: dict, workloop: Path, hold: bool) -> bool:
    """Save a run's worktrees and close it with `abandon`; False when it must stay. With
    `hold` (/clear, /resume) a lane not yet submitted keeps the run: its cell may still work."""
    name, state = entry.get("run"), entry.get("state") or ""
    run = wr.runs_in(state).get(name)
    if run is None:
        return True
    lanes = run.get("lanes") or {}
    busy = next((f"lane {lane} is {info.get('state')}, not yet submitted, and the session's process goes on"
                 for lane, info in lanes.items() if hold and info.get("state") not in ("review", "reviewed")), None)
    spaces = [Path(s).resolve() for s in workspaces(run)]
    present = [path for path in spaces if path.is_dir()]
    repo = wr.main_checkout(run.get("repo") or "/nonexistent")
    # Git still lists a workspace that is not on disk (an unmounted volume):
    # abandon's prune would drop it, so the run stays.
    away = next((f"git lists {e['path']} but it is not on disk" for e in (wr.worktrees(repo) if repo else [])
                 if e["path"] in spaces and not e["path"].is_dir()), None)
    refusal = busy or away or next((f"{path}: {r[1]}" for path in present for r in [remover.blocked(path)] if r), None)
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


def lock_of(path: Path) -> str | None:
    main = wr.main_checkout(path)
    return next((e["locked"] for e in wr.worktrees(main) if e["path"] == path.resolve()), None) if main else None


def end(project: Path, session: str, reason: str, workloop: Path) -> list[str]:
    path = wr.records_dir(project) / f"{wr.session_key(session)}.jsonl"
    return close(path, reason or "other", workloop) if wr.session_key(session) and path.is_file() else []


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


def common_dir(main: Path) -> Path:
    return Path(wr.out(main, "rev-parse", "--path-format=absolute", "--git-common-dir"))


def load_cache(common: Path) -> dict | None:
    """The heal's cached verdicts, or None when no start has cached any."""
    path = common / hl.CACHE
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        wr.warn(f"{path} is unreadable ({error}); every idle worktree is judged again")
        return {}
    return data if isinstance(data, dict) else {}


def save_cache(common: Path, kept: dict) -> None:
    try:
        scratch = common / f"{hl.CACHE}.{os.getpid()}"
        scratch.write_text(json.dumps(kept, sort_keys=True))
        os.replace(scratch, common / hl.CACHE)
    except OSError as error:
        wr.warn(f"could not write {common / hl.CACHE} ({error}); the next start judges every idle worktree again")


def listing(project: Path) -> list[str]:
    main = wr.main_checkout(project)
    cache = (load_cache(common_dir(main)) or {}) if main else {}
    lines = [f"{hit['line']} (judged {time.strftime('%Y-%m-%d', time.localtime(hit['at']))})"
             for hit in cache.values() if isinstance(hit, dict) and isinstance(hit.get("line"), str)
             and isinstance(hit.get("at"), (int, float))]
    return lines or [f"No kept idle worktree is cached for {main or project}."]


def sweep(project: Path, session: str, source: str, workloop: Path, emit, budget: float) -> None:
    main = wr.main_checkout(project)
    if main is None:
        return
    with open(common_dir(main) / "colloid-sweep.lock", "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            emit("Another session start is sweeping this repository's worktrees; this one skipped it.")
            return
        locked_sweep(main, wr.session_key(session), source, workloop, emit, budget)


def locked_sweep(main: Path, me: str, source: str, workloop: Path, emit, budget: float) -> None:
    folder = main / wr.RECORDS
    unpark(main)
    if folder.is_dir():
        reclaim(folder)
        if me and (folder / f"{me}.jsonl").is_file():
            wr.append(folder, me, [{"type": "host", "host": wr.host(), "at": int(time.time())}])
        for path in sorted(folder.glob("*.jsonl")):
            if path.stem != me and over(wr.load(path), path):
                for line in close(path, "", workloop):
                    emit(line)
    recorded, leads = set(), set()
    for path in folder.glob("*.jsonl") if folder.is_dir() else []:
        for entry in wr.load(path):
            recorded |= {str(Path(entry["path"]).resolve())} if entry.get("type") == "worktree" else set()
            leads.add(entry.get("run"))
    for line in unowned_runs(main, leads):
        emit(line)
    # A run's state may live in any checkout of the repository, so every one's lanes are spared.
    runs = [run for entry in wr.worktrees(main) for run in wr.runs_in(str(entry["path"] / STATE)).values()]
    spared = recorded | {str(Path(space).resolve()) for run in runs for space in workspaces(run)}
    common = common_dir(main)
    save_cache(common, hl.heal(main, spared, load_cache(common), emit, source != "compact", budget))
    saved = wr.out(main, "for-each-ref", "--format=%(refname:short) %(committerdate:short) %(subject)", "refs/heads/saved/")
    if saved:
        emit("Unsaved work from removed worktrees waits on these branches; merge what is wanted, then delete each branch:")
        for line in saved.splitlines():
            emit(f"  {line}")


def say(line: str) -> None:
    print(line, flush=True)


if __name__ == "__main__":
    if sys.argv[1:2] == ["end"] and len(sys.argv) == 6:
        for report in end(Path(sys.argv[2]), sys.argv[3], sys.argv[4], Path(sys.argv[5])):
            say(report)
    elif sys.argv[1:2] == ["sweep"] and len(sys.argv) == 6:
        seconds = os.environ.get("WORKTREE_HEAL_SECONDS") or str(hl.REMOVE_SECONDS)
        sweep(Path(sys.argv[2]), sys.argv[3], sys.argv[4], Path(sys.argv[5]), say, float(seconds))
    elif sys.argv[1:2] == ["list"] and len(sys.argv) == 3:
        for report in listing(Path(sys.argv[2])):
            say(report)
    else:
        sys.exit(__doc__)
