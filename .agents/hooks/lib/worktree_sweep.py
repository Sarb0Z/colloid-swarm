#!/usr/bin/env python3
"""End a session's records at its end, and sweep the repository's at each start.

    worktree_sweep.py end <project> <session> <reason> <workloop.py>   (session-end.sh)
    worktree_sweep.py sweep <project> <session> <workloop.py>          (session-start.sh)

`sweep` (one per repository at a time) folds back what a killed run left,
ends the records of sessions whose process is gone, closes a run no record
leads once git lists none of its workspaces, and names each idle worktree no
record or run names with its work and a verdict, "could go: <why>" or
"stays: <why>". It removes none of them: that is unit 5b's (ruling 24).
"""

from __future__ import annotations

import fcntl
import importlib.util
import json
import os
import re
import sys
import time
from pathlib import Path

_spec = importlib.util.spec_from_file_location("worktree_removal", Path(__file__).with_name("worktree_removal.py"))
rm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rm)
wr = rm.wr

# Reasons after which the session's process exits; after /clear and /resume it
# goes on working, so its own folder still counts as occupied.
EXITS = {"prompt_input_exit", "other", "logout", "bypass_permissions_disabled"}
IDLE_SECONDS = 24 * 3600
PARKED_SECONDS = 600
STATE = Path(".agents/.workloop-state.json")
# Ignored files that rebuild; rm.REBUILDABLE_DIRS holds the folders.
REBUILDABLE_FILES = frozenset({".DS_Store", ".eslintcache"})
REBUILDABLE_SUFFIXES = (".pyc", ".pyo", ".tsbuildinfo")
KEEPS = re.compile(r"^\.env|\.(sqlite3?|db)$")


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
    remaining = [entry for entry in runs.values() if not rm.close_run(remover, entry, workloop, hold)]
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


def idle_since(path: Path) -> float:
    """The newest of the worktree's commit, checkout and file times."""
    admin = Path(wr.out(path, "rev-parse", "--path-format=absolute", "--git-dir"))
    stamps = [os.stat(item).st_mtime for item in (admin / "HEAD", admin / "index", admin / "logs" / "HEAD", path)
              if item.exists()]
    committed = wr.out(path, "log", "-1", "--format=%ct")
    newest = max(stamps + ([float(committed)] if committed.isdigit() else []) or [0.0])
    for name in wr.git(path, "ls-files", "-z", "--cached", "--others", "--exclude-standard").stdout.split("\0"):
        if time.time() - newest < IDLE_SECONDS:
            break
        if name and os.path.lexists(path / name):
            newest = max(newest, os.lstat(path / name).st_mtime)
    return newest


def unrebuildable(path: Path) -> list[str]:
    listing = wr.git(path, "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory")
    found = []
    for name in (entry for entry in listing.stdout.split("\0") if entry):
        parts = Path(name).parts
        if any(part in rm.REBUILDABLE_DIRS for part in parts):
            continue
        if not KEEPS.search(parts[-1]) and not name.endswith("/") and (
                parts[-1] in REBUILDABLE_FILES or parts[-1].endswith(REBUILDABLE_SUFFIXES)):
            continue
        found.append(name)
    return found


def default_refs(main: Path) -> list[str]:
    remote = wr.out(main, "symbolic-ref", "-q", "refs/remotes/origin/HEAD")
    names = [remote.rsplit("/", 1)[-1]] if remote else ["main", "master"]
    refs = [f"refs/heads/{name}" for name in names] + ([remote] if remote else [])
    return [ref for ref in refs if wr.out(main, "rev-parse", "-q", "--verify", ref)]


def merge_tree_ok() -> bool:
    found = re.search(r"(\d+)\.(\d+)", wr.out(".", "version"))
    return bool(found) and (int(found.group(1)), int(found.group(2))) >= (2, 38)


def settled(path: Path, defaults: list[str]) -> str | None:
    """How the worktree's commits are safe elsewhere, or None."""
    for ref in defaults:
        if wr.git(path, "merge-base", "--is-ancestor", "HEAD", ref).returncode == 0:
            return f"merged into {ref.split('/', 2)[-1]}"
        if merge_tree_ok():
            merged = wr.git(path, "merge-tree", "--write-tree", ref, "HEAD")
            if merged.returncode == 0 and merged.stdout.split()[:1] == [wr.out(path, "rev-parse", f"{ref}^{{tree}}")]:
                return f"its changes are already in {ref.split('/', 2)[-1]}"
    upstream = wr.out(path, "rev-parse", "-q", "--abbrev-ref", "@{upstream}")
    if upstream and wr.out(path, "rev-list", "--count", "HEAD", "--not", "@{upstream}") == "0":
        return f"every commit is on {upstream}"
    if not wr.out(path, "symbolic-ref", "-q", "HEAD") and wr.out(path, "branch", "-r", "--contains", "HEAD"):
        return "its detached HEAD is on a remote branch"
    return None


def about(path: Path, entry: dict, defaults: list[str]) -> str:
    subject = wr.out(path, "log", "-1", "--format=%cs %s")
    ahead = wr.out(path, "rev-list", "--count", "HEAD", "--not", *defaults) if defaults else "?"
    changed = len(wr.out(path, "--no-optional-locks", "status", "--porcelain").splitlines())
    return (f"{path} [{entry['branch'] or 'detached'}] last commit {subject or 'none'}; "
            f"{ahead} commit(s) not in the default branch, {changed} uncommitted file(s)")


def verdict(path: Path, entry: dict, defaults: list[str], remover) -> str:
    """Whether the worktree could go with nothing lost; no nested-repository walk."""
    if entry["locked"] and not rm.claude_lock_ended(entry["locked"], None):
        return f"stays: it is locked ({entry['locked']})"
    why = remover.occupant(path) or rm.unsaveable(path) or ("it holds uncommitted work" if rm.dirty(path) else None)
    extra = None if why else unrebuildable(path)
    if extra:
        why = "it holds ignored files that do not rebuild: " + ", ".join(extra[:5])
    safe = None if why else settled(path, defaults)
    return f"could go: {safe}" if safe else f"stays: {why or 'its commits are neither merged into the default branch nor on a remote'}"


def name_idle(main: Path, recorded: set, lanes_of_runs: set) -> list[str]:
    """Name each idle worktree no record or run names, and each lane folder no run owns."""
    lines, defaults = [], default_refs(main)
    remover, folder = rm.Remover("the sweep", {os.getpid()}, None), main / ".agents" / "worktrees"
    for entry in wr.worktrees(main)[1:]:
        path = entry["path"]
        if entry["prunable"] or not path.is_dir() or str(path) in recorded | lanes_of_runs:
            continue
        if folder in path.parents:
            lines.append(f"lane folder {about(path, entry, defaults)}: belongs to no workloop run")
        elif time.time() - idle_since(path) >= IDLE_SECONDS:
            lines.append(f"idle {about(path, entry, defaults)}: {verdict(path, entry, defaults, remover)}")
    return lines


def sweep(project: Path, session: str, workloop: Path) -> list[str]:
    main = wr.main_checkout(project)
    if main is None:
        return []
    common = Path(wr.out(main, "rev-parse", "--path-format=absolute", "--git-common-dir"))
    with open(common / "colloid-sweep.lock", "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return ["Another session start is sweeping this repository's worktrees; this one skipped it."]
        return locked_sweep(main, wr.session_key(session), workloop)


def locked_sweep(main: Path, me: str, workloop: Path) -> list[str]:
    folder, lines = main / wr.RECORDS, []
    unpark(main)
    if folder.is_dir():
        reclaim(folder)
        if me and (folder / f"{me}.jsonl").is_file():
            wr.append(folder, me, [{"type": "host", "host": wr.host(), "at": int(time.time())}])
        for path in sorted(folder.glob("*.jsonl")):
            if path.stem != me and over(wr.load(path), path):
                lines += close(path, "", workloop)
    recorded, leads = set(), set()
    for path in folder.glob("*.jsonl") if folder.is_dir() else []:
        for entry in wr.load(path):
            recorded |= {str(Path(entry["path"]).resolve())} if entry.get("type") == "worktree" else set()
            leads.add(entry.get("run"))
    lines += unowned_runs(main, leads)
    runs = wr.runs_in(str(main / STATE)).values()
    lines += name_idle(main, recorded, {str(Path(space).resolve()) for run in runs for space in workspaces(run)})
    saved = wr.out(main, "for-each-ref", "--format=%(refname:short) %(committerdate:short) %(subject)", "refs/heads/saved/")
    if saved:
        lines.append("Unsaved work from removed worktrees waits on these branches; merge what is wanted, then delete each branch:")
        lines += [f"  {line}" for line in saved.splitlines()]
    return lines


if __name__ == "__main__":
    if sys.argv[1:2] == ["end"] and len(sys.argv) == 6:
        report = end(Path(sys.argv[2]), sys.argv[3], sys.argv[4], Path(sys.argv[5]))
    elif sys.argv[1:2] == ["sweep"] and len(sys.argv) == 5:
        report = sweep(Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4]))
    else:
        sys.exit(__doc__)
    for line in report:
        print(line)
