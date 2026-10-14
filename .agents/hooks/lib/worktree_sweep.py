#!/usr/bin/env python3
"""Sweep a session's records at its end, and the repository's at each start.

    worktree_sweep.py end <project> <session> <reason> <workloop.py>   (session-end.sh)
    worktree_sweep.py sweep <project> <session> <workloop.py>          (session-start.sh)

`sweep` prints the digest, one per repository at a time (a lock in the git
directory). It folds back claims and parked folders a killed run left; ends
the records of sessions whose process is gone or that an end marked `ended`;
closes a run no record leads once all its workspaces are gone, and names the
rest; and heals (ruling 20, amended): a worktree no record or run names,
outside `.agents/worktrees/`, not locked by a running session, idle 24 h and
with no process inside, goes only when nothing would be lost — nothing
uncommitted, no nested repository, no ignored file beyond REBUILDABLE, and
its commits merged into the default branch (a squash merge counts) or all on
a remote; nothing is saved for it, and each other one is named with its work.
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
# Ignored content a worktree may hold and still be removed: each rebuilds from
# the branch with an install or a build.
REBUILDABLE_DIRS = frozenset({
    "node_modules", ".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache",
    ".tox", ".nox", "dist", "build", "out", ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache",
    ".cache", "coverage", ".nyc_output", "target", ".gradle", "Pods", "DerivedData", ".expo", ".angular",
})
REBUILDABLE_FILES = frozenset({".DS_Store", ".eslintcache"})
REBUILDABLE_SUFFIXES = (".pyc", ".pyo", ".tsbuildinfo")
# Never rebuildable, wherever they sit outside a rebuildable folder.
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
        if time.time() - bin_.stat().st_mtime < PARKED_SECONDS:
            continue
        manifest = bin_ / "manifest.json"
        worktree = json.loads(manifest.read_text())["worktree"] if manifest.is_file() else ""
        if worktree and Path(worktree).is_dir():
            rm.restore(bin_)
        else:
            rm.purge([bin_])


def over(entries: list[dict], path: Path) -> bool:
    """The session ended: an end marked it after its last start, or its process is gone."""
    kinds = [entry.get("type") for entry in entries if entry.get("type") in ("ended", "host")]
    stamp = wr.last_host(entries)
    if kinds and kinds[-1] == "ended":
        return True
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
    ending = me[0] if reason and me else stamp[0] if stamp else None
    remover = rm.Remover(f"session {path.stem}", exclude, ending)
    # A lane whose writer cell is still live (parallel-writers-gate.sh's list)
    # keeps its run; what stays is marked ended, so the next sweep takes it
    # even while the process goes on after /clear or /resume.
    live = path.parents[3] / ".agents" / f".writers-live-{path.stem}"
    cells = {line.split("\t", 1)[0] for line in live.read_text().splitlines() if line.strip()} if live.is_file() else set()
    remaining = rm.finish(entries, remover, workloop, cells, reason)
    if remaining:
        wr.append(path.parent, path.stem, [dict(e, host=stamp) for e in remaining] + [{"type": "ended", "at": int(time.time())}])
    claimed.unlink()
    return remover.lines


def end(project: Path, session: str, reason: str, workloop: Path) -> list[str]:
    path = wr.records_dir(project) / f"{wr.session_key(session)}.jsonl"
    return close(path, reason or "other", workloop) if wr.session_key(session) and path.is_file() else []


def ended_sessions(folder: Path, me: str, workloop: Path) -> list[str]:
    lines = []
    for path in sorted(folder.glob("*.jsonl")):
        if path.stem != me and over(wr.load(path), path):
            lines += close(path, "", workloop)
    return lines


def workspaces(run: dict) -> list[str]:
    return [s for s in [lane.get("workspace") for lane in (run.get("lanes") or {}).values()]
            + [(run.get("integration") or {}).get("workspace")] if s]


def unowned_runs(main: Path, leads: set, workloop: Path) -> list[str]:
    state = main / STATE
    names, remover = [], rm.Remover("the sweep", set(), None)
    for name, run in sorted(wr.runs_in(str(state)).items()):
        if name in leads:
            continue
        if not any(Path(space).exists() for space in workspaces(run)):
            rm.abandon(remover, name, str(state), workloop, [])
        else:
            names.append(name)
    lines = remover.lines
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
        if any(part in REBUILDABLE_DIRS for part in parts):
            continue
        if not KEEPS.search(parts[-1]) and not name.endswith("/") and (
                parts[-1] in REBUILDABLE_FILES or parts[-1].endswith(REBUILDABLE_SUFFIXES)):
            continue
        found.append(name)
    return found


def default_refs(main: Path) -> list[str]:
    remote = wr.out(main, "symbolic-ref", "-q", "refs/remotes/origin/HEAD")
    short = remote.rsplit("/", 1)[-1] if remote else ""
    names = [short] if short else ["main", "master"]
    refs = [f"refs/heads/{name}" for name in names] + ([remote] if remote else [])
    return [ref for ref in refs if wr.out(main, "rev-parse", "-q", "--verify", ref)]


def merge_tree_ok() -> bool:
    found = re.search(r"(\d+)\.(\d+)", wr.out(".", "version"))
    return bool(found) and (int(found.group(1)), int(found.group(2))) >= (2, 38)


def settled(path: Path, main: Path, defaults: list[str]) -> str | None:
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


def heal(main: Path, recorded: set) -> list[str]:
    lines, defaults = [], default_refs(main)
    remover = rm.Remover("the sweep", {os.getpid()}, None)
    lanes = main / ".agents" / "worktrees"
    for entry in wr.worktrees(main)[1:]:
        path = entry["path"]
        if entry["prunable"] or not path.is_dir() or str(path) in recorded or path == lanes or lanes in path.parents:
            continue
        if entry["locked"] and not rm.claude_lock_ended(entry["locked"], None):
            continue
        if time.time() - idle_since(path) < IDLE_SECONDS:
            continue
        why = judge(path, main, defaults, remover)
        if why.startswith("removable: "):
            # A lock left here is Claude Code's, from a session that ended.
            if entry["locked"]:
                wr.git(main, "worktree", "unlock", str(path))
            note = rm.remove(path, main, force=False)
            if note is None:
                lines.append(f"removed idle {path}: {why[len('removable: '):]}" + rm.drop_branch(main, entry["branch"]))
                continue
            why = note
        lines.append(f"idle {about(path, entry, defaults)}: stays, {why}")
    return lines


def judge(path: Path, main: Path, defaults: list[str], remover) -> str:
    busy = remover.occupant(path)
    if busy:
        return busy
    if rm.dirty(path):
        return "it holds uncommitted work"
    inner = rm.nested(path)
    if inner:
        return f"it holds a nested repository at {inner}"
    extra = unrebuildable(path)
    if extra:
        return "it holds ignored files that do not rebuild: " + ", ".join(extra[:5])
    safe = settled(path, main, defaults)
    return f"removable: {safe}" if safe else "its commits are neither merged into the default branch nor on a remote"


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
        lines += ended_sessions(folder, me, workloop)
    recorded, leads = set(), set()
    for path in folder.glob("*.jsonl") if folder.is_dir() else []:
        for entry in wr.load(path):
            if entry.get("type") == "worktree":
                recorded.add(str(Path(entry.get("path", "/")).resolve()))
            leads.add(entry.get("run"))
    # A run's workspaces are its lead's to close, wherever they sit; never healed.
    for run in wr.runs_in(str(main / STATE)).values():
        recorded |= {str(Path(space).resolve()) for space in workspaces(run)}
    lines += heal(main, recorded)
    saved = wr.out(main, "for-each-ref", "--format=%(refname:short) %(committerdate:short) %(subject)", "refs/heads/saved/")
    if saved:
        lines.append("Unsaved work from removed worktrees waits on these branches; merge what is wanted, then delete each branch:")
        lines += [f"  {line}" for line in saved.splitlines()]
    return lines + unowned_runs(main, leads, workloop)


if __name__ == "__main__":
    if sys.argv[1:2] == ["end"] and len(sys.argv) == 6:
        report = end(Path(sys.argv[2]), sys.argv[3], sys.argv[4], Path(sys.argv[5]))
    elif sys.argv[1:2] == ["sweep"] and len(sys.argv) == 5:
        report = sweep(Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4]))
    else:
        sys.exit(__doc__)
    for line in report:
        print(line)
