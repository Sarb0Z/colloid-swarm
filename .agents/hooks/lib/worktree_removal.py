#!/usr/bin/env python3
"""Remove the worktrees and runs a session recorded, saving unsaved work first.

`Remover.retire` keeps and names a worktree that is no linked worktree; is
locked (Claude Code's own lock counts only while its session runs, ruling
22); has a process inside, or no lsof to tell; holds a nested repository
outside REBUILDABLE_DIRS, or what a save cannot carry (`unsaveable`); or whose
unsaved work cannot be committed to `saved/<name>` (SAVE_CAP, no new
gitlink). Ignored folders are parked behind a manifest the sweep can undo,
then `git worktree remove` runs without --force on a clean tree; the branch
goes only when HEAD contains it.
"""

from __future__ import annotations

import calendar
import errno
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

_spec = importlib.util.spec_from_file_location("worktree_records", Path(__file__).with_name("worktree_records.py"))
wr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(wr)

TRASH = "colloid-trash"
SAVE_CAP = 200 * 1024 * 1024
CLAUDE_LOCK = re.compile(r"^claude (?:session|agent) \S+ \(pid (\d+)(?: start (.+))?\)$")
GITLINK = re.compile(r"^160000 (?:commit )?([0-9a-f]+)(?: \d+)?\t(.*)$")
STAMP = "%a %b %d %H:%M:%S %Y"
# Folders that rebuild from the branch; the nested-repository walk skips them.
REBUILDABLE_DIRS = frozenset({
    "node_modules", ".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache",
    ".tox", ".nox", "dist", "build", "out", ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache",
    ".cache", "coverage", ".nyc_output", "target", ".gradle", "Pods", "DerivedData", ".expo", ".angular",
})
IN_PROGRESS = ("BISECT_LOG", "rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD")


def claude_lock_ended(reason: str, ending_pid: int | None) -> bool:
    """True when `reason` is Claude Code's lock (`claude session|agent <id> (pid N[ start S])`,
    S in UTC) and that session is over: its pid is the ending one, gone, or started at another time."""
    match = CLAUDE_LOCK.match(reason or "")
    row = wr.ps_row(int(match.group(1))) if match else None
    if not match or int(match.group(1)) == ending_pid or row is None:
        return bool(match)
    if not match.group(2):
        return False
    try:
        locked, started = calendar.timegm(time.strptime(match.group(2), STAMP)), time.mktime(time.strptime(row[1], STAMP))
    except ValueError:
        return False
    return abs(locked - started) > 2


class Remover:
    """Retires worktrees; collects one report line per outcome."""

    def __init__(self, label: str, exclude: set, ending_pid: int | None):
        self.label, self.exclude, self.ending_pid = label, exclude, ending_pid
        self.lines: list[str] = []
        self._procs, self._loaded = None, False

    def procs(self):
        """(pid, cwd) of every visible process but lsof and this one, or None when lsof cannot say."""
        if not self._loaded and shutil.which("lsof"):
            child = subprocess.Popen(["lsof", "-n", "-P", "-w", "-d", "cwd", "-F", "pn"], text=True,
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            rows, pid = [], None
            for line in child.communicate()[0].splitlines():
                pid = int(line[1:]) if line.startswith("p") else pid
                if line.startswith("n") and pid not in (None, child.pid, os.getpid()):
                    rows.append((pid, Path(line[1:])))
            self._procs = rows or None
        self._loaded = True
        return self._procs

    def occupant(self, path: Path) -> str | None:
        rows = self.procs()
        if rows is None:
            return "lsof is missing or failed, so a process may be working in it"
        pid = next((pid for pid, cwd in rows if pid not in self.exclude and (cwd == path or path in cwd.parents)), None)
        return f"process {pid} is working in it" if pid else None

    def blocked(self, path: Path) -> tuple[str, str] | None:
        """(kind, reason) when `path` must stay; kind "locked" is a decision to keep it."""
        main = wr.main_checkout(path)
        entry = next((item for item in wr.worktrees(main)[1:] if item["path"] == path), None) if main else None
        if entry is None:
            return "other", "git lists it as no linked worktree"
        if entry["locked"] and not claude_lock_ended(entry["locked"], self.ending_pid):
            return "locked", f"it is locked ({entry['locked']})"
        busy = self.occupant(path)
        inner = None if busy else nested(path)
        held = None if busy or inner else unsaveable(path)
        return ("busy", busy) if busy else ("other", f"it holds a nested repository at {inner}") if inner \
            else ("other", held) if held else None

    def retire(self, path: Path) -> str:
        """Remove one worktree; return "removed", "gone", "locked" or "kept"."""
        path = path.resolve() if path.exists() else path
        if not path.is_dir():
            return "gone"
        refusal = self.blocked(path)
        if refusal:
            self.lines.append(f"kept {path}: {refusal[1]}")
            return "locked" if refusal[0] == "locked" else "kept"
        saved, error = save(path, self.label) if dirty(path) else (None, None)
        if error:
            self.lines.append(f"kept {path}: its unsaved work could not be committed ({error})")
            return "kept"
        main = wr.main_checkout(path)
        entry = next(item for item in wr.worktrees(main) if item["path"] == path)
        if entry["locked"]:
            wr.git(main, "worktree", "unlock", str(path))
        note = remove(path, main, force=bool(saved))
        if note:
            self.lines.append(f"kept {path}: {note}")
            return "kept"
        line = f"removed {path}" + (f"; its unsaved work is on branch {saved}" if saved else "")
        self.lines.append(line + drop_branch(main, entry["branch"]))
        return "removed"


def nested(path: Path) -> str | None:
    """The first `.git` below the worktree's own, ignored folders included, rebuildable ones skipped."""
    for root, dirs, files in os.walk(path):
        if Path(root) != path and (".git" in dirs or ".git" in files):
            return root
        dirs[:] = [name for name in dirs if name not in REBUILDABLE_DIRS]
    return None


def unsaveable(path: Path) -> str | None:
    """Why a save cannot carry the worktree's state: an operation in progress, or a
    skip-worktree or assume-unchanged file on disk, whose edits `git status` and
    `git add` do not see (a sparse checkout's absent files are fine)."""
    admin = Path(wr.out(path, "rev-parse", "--path-format=absolute", "--git-dir"))
    busy = [name for name in IN_PROGRESS if (admin / name).exists()]
    if busy:
        return f"a {busy[0]} operation is in progress"
    listing = wr.git(path, "ls-files", "-v")
    if listing.returncode:
        return f"git could not read its index: {listing.stderr.strip()}"
    flagged = [line[2:] for line in listing.stdout.splitlines()
               if line[:1] in ("S", "s", "h") and os.path.lexists(path / line[2:])]
    return f"it holds skip-worktree or assume-unchanged files git status does not show: {', '.join(flagged[:3])}" if flagged else None


def dirty(path: Path) -> bool:
    """Uncommitted or untracked work. The flags override what the repository's config may
    hide: `status.showUntrackedFiles=no` blanks untracked files, and `git worktree remove`
    without --force then deletes them; a stale fsmonitor or untracked cache can miss edits.
    A status that fails counts as dirty."""
    status = wr.git(path, "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
                    "status", "--porcelain", "--ignore-submodules=none", "--untracked-files=all")
    return bool(status.returncode or status.stdout.strip())


def gitlinks(path: Path, *args, env: dict | None = None) -> set:
    """(path, commit) of every gitlink `ls-files -s` or `ls-tree -r` prints."""
    found = (GITLINK.match(line) for line in wr.git(path, *args, env=env).stdout.splitlines())
    return {(match.group(2), match.group(1)) for match in found if match}


def save(path: Path, label: str) -> tuple[str | None, str | None]:
    """Commit unsaved work to a new `saved/<name>` branch; return (branch, error)."""
    admin = Path(wr.out(path, "rev-parse", "--path-format=absolute", "--git-dir"))
    untracked = wr.git(path, "ls-files", "-z", "--others", "--exclude-standard").stdout.split("\0")
    size = sum((path / name).lstat().st_size for name in untracked if name and os.path.lexists(path / name))
    if size > SAVE_CAP:
        return None, f"{size // 2**20} MB of untracked files exceeds the {SAVE_CAP // 2**20} MB save cap"
    handle, scratch = tempfile.mkstemp(prefix="saved-index.", dir=str(admin))
    os.close(handle)
    env, head = {"GIT_INDEX_FILE": scratch}, wr.out(path, "rev-parse", "-q", "--verify", "HEAD^{commit}")
    try:
        if (admin / "index").exists():
            shutil.copyfile(admin / "index", scratch)
            steps = []
        else:
            os.unlink(scratch)
            steps = [("read-tree", head or "--empty")]
        for step in steps + [("add", "-A"), ("write-tree",)]:
            result = wr.git(path, *step, env=env)
            if result.returncode:
                return None, result.stderr.strip()
        if gitlinks(path, "ls-files", "-s", env=env) - (gitlinks(path, "ls-tree", "-r", head) if head else set()):
            return None, "it would save a nested repository as a bare gitlink"
        message = (f"Save unsaved work from worktree {path}\n\nCommitted when {label} ended, before the "
                   "worktree was removed. Untracked files are included; ignored files are not.")
        commit = wr.git(path, "commit-tree", result.stdout.strip(), *(["-p", head] if head else []), "-m", message)
        if commit.returncode:
            return None, commit.stderr.strip()
        name = re.sub(r"[^A-Za-z0-9._-]", "-", admin.name).strip(".-") or "worktree"
        for candidate in [name] + [f"{name}-{time.strftime('%Y%m%d-%H%M%S')}-{n}" for n in range(1, 10)]:
            if not wr.git(path, "update-ref", f"refs/heads/saved/{candidate}", commit.stdout.strip(), "").returncode:
                return f"saved/{candidate}", None
        return None, f"no free branch name under saved/{name}"
    finally:
        if os.path.exists(scratch):
            os.unlink(scratch)


def trash_dir(main: Path) -> Path:
    return Path(wr.out(main, "rev-parse", "--path-format=absolute", "--git-common-dir")) / TRASH


def remove(path: Path, main: Path, force: bool) -> str | None:
    """Park the ignored folders, run `git worktree remove`; return why it stayed, or None."""
    listing = wr.git(path, "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory")
    if listing.returncode:
        return f"git could not list its ignored files ({listing.stderr.strip()})"
    names = [item for item in listing.stdout.split("\0") if item]
    # A folder holding only ignored files is listed with its contents; moving the
    # folder moves them, and a second move of a file inside would fail.
    outermost = [name for name in names if not any(other != name and other.endswith("/") and name.startswith(other)
                                                   for other in names)]
    bin_ = trash_dir(main) / f"{time.time_ns()}-{os.getpid()}"
    moves = [(str(path / name.rstrip("/")), str(bin_ / str(number))) for number, name in enumerate(outermost)]
    if moves:
        bin_.mkdir(parents=True, exist_ok=True)
        (bin_ / "manifest.json").write_text(json.dumps({"worktree": str(path), "moves": moves}))
    for source, target in moves:
        try:
            os.rename(source, target)
        except OSError as error:
            if error.errno != errno.EXDEV:  # another filesystem: git deletes it in place
                restore(bin_)
                return f"could not move {source} aside ({error})"
    result = wr.git(main, "worktree", "remove", *(["--force"] if force else []), str(path))
    if result.returncode:
        restore(bin_)
        return f"git refused to remove it ({(result.stderr or result.stdout).strip()})"
    purge([bin_])
    return None


def restore(bin_: Path) -> None:
    """Move parked folders back where the manifest says they came from, then drop the bin."""
    manifest = bin_ / "manifest.json"
    for source, target in json.loads(manifest.read_text())["moves"] if manifest.is_file() else []:
        if os.path.lexists(target) and not os.path.lexists(source):
            try:
                os.rename(target, source)
            except OSError as error:
                wr.warn(f"could not move {target} back to {source}: {error}; it stays in {bin_}")
                return
    if bin_.exists():
        shutil.rmtree(bin_)


def purge(bins: list[Path]) -> None:
    present = [str(item) for item in bins if item.exists()]
    if present:
        subprocess.Popen(["rm", "-rf", *present], start_new_session=True, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)


def drop_branch(main: Path, branch: str | None) -> str:
    trunk = wr.out(main, "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD").split("/", 1)[-1]
    if not branch:
        return ""
    if branch in ("main", "master", trunk) or wr.out(main, "rev-parse", "-q", "--abbrev-ref", f"{branch}@{{upstream}}"):
        return f"; branch {branch} kept, it is the trunk or tracks a remote"
    head = wr.out(main, "rev-parse", "-q", "--verify", "HEAD")
    if not head or wr.git(main, "merge-base", "--is-ancestor", f"refs/heads/{branch}", head).returncode:
        return f"; branch {branch} kept, HEAD does not contain it"
    result = wr.git(main, "branch", "-D", branch)
    return f"; branch {branch} kept: {result.stderr.strip()}" if result.returncode else f"; branch {branch} deleted, HEAD contains it"


def close_run(remover: Remover, entry: dict, workloop: Path, hold: bool) -> bool:
    """Save a run's worktrees and close it with `abandon`; False when it must stay. With
    `hold` (/clear, /resume) a lane not yet submitted keeps the run: its cell may still work."""
    name, state = entry.get("run"), entry.get("state") or ""
    run = wr.runs_in(state).get(name)
    if run is None:
        return True
    lanes = run.get("lanes") or {}
    busy = next((f"lane {lane} is {info.get('state')}, not yet submitted, and the session's process goes on"
                 for lane, info in lanes.items() if hold and info.get("state") not in ("review", "reviewed")), None)
    spaces = [Path(s).resolve() for s in [i.get("workspace") for i in lanes.values()]
              + [(run.get("integration") or {}).get("workspace")] if s]
    present = [path for path in spaces if path.is_dir()]
    repo = wr.main_checkout(run.get("repo") or "/nonexistent")
    # Git still lists a workspace that is not on disk (an unmounted volume):
    # abandon's prune would drop it, so the run stays.
    away = next((f"git lists {e['path']} but it is not on disk" for e in (wr.worktrees(repo) if repo else [])
                 if e["path"] in spaces and not e["path"].is_dir()), None)
    refusal = busy or away or next((f"{path}: {r[1]}" for path in present for r in [remover.blocked(path)] if r), None)
    saved = []
    for path in [] if refusal else [path for path in present if dirty(path)]:
        branch, error = save(path, remover.label)
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
