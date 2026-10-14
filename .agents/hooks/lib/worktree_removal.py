#!/usr/bin/env python3
"""Remove the worktrees and runs a session recorded, saving unsaved work first.

`Remover.retire` keeps and names a worktree that is no linked worktree; is
locked (Claude Code's own session lock counts only while that session runs,
ruling 22); has a process inside, or cannot be checked for one (no lsof);
holds a nested repository; or whose unsaved work cannot be committed. Unsaved
work goes to `saved/<name>` through a copy of the index, under SAVE_CAP and
with no new gitlink. Ignored folders are parked in `<git dir>/colloid-trash`
behind a manifest the sweep can undo, then `git worktree remove` runs without
--force on a clean tree; the branch goes only when HEAD contains it.

`finish` keeps an EnterWorktree worktree still on disk and unlocked after a
`prompt_input_exit`: the operator kept it at Claude Code's exit prompt. A
run stays while a lane's writer cell is live.
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
CLAUDE_LOCK = re.compile(r"^claude session .* \(pid (\d+) start (.+)\)$")
GITLINK = re.compile(r"^160000 (?:commit )?([0-9a-f]+)(?: \d+)?\t(.*)$")
STAMP = "%a %b %d %H:%M:%S %Y"


def claude_lock_ended(reason: str, ending_pid: int | None) -> bool:
    """True when `reason` is Claude Code's session lock (start in UTC) and that session is over."""
    match = CLAUDE_LOCK.match(reason or "")
    row = wr.ps_row(int(match.group(1))) if match else None
    if not match or int(match.group(1)) == ending_pid or row is None:
        return bool(match)
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
        return ("busy", busy) if busy else ("other", f"it holds a nested repository at {inner}") if inner else None

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
    """The first `.git` below the worktree's own, ignored folders included."""
    return next((root for root, dirs, files in os.walk(path)
                 if Path(root) != path and (".git" in dirs or ".git" in files)), None)


def dirty(path: Path) -> bool:
    return bool(wr.out(path, "--no-optional-locks", "status", "--porcelain", "--ignore-submodules=none"))


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
    bin_ = trash_dir(main) / f"{time.time_ns()}-{os.getpid()}"
    moves = [(str(path / name.rstrip("/")), str(bin_ / str(number)))
             for number, name in enumerate(item for item in listing.stdout.split("\0") if item)]
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


def close_run(remover: Remover, entry: dict, workloop: Path, live: set) -> bool:
    """Save a run's worktrees and close it with `abandon`; False when it must stay."""
    name, state = entry.get("run"), entry.get("state") or ""
    run = wr.runs_in(state).get(name)
    if run is None:
        return True
    lanes = run.get("lanes") or {}
    busy = next((f"lane {lane}'s writer cell {info['claimed_by']} is still live"
                 for lane, info in lanes.items() if info.get("claimed_by") in live), None)
    spaces = [info.get("workspace") for info in lanes.values()] + [(run.get("integration") or {}).get("workspace")]
    present = [Path(space).resolve() for space in spaces if space and Path(space).is_dir()]
    refusal = busy or next((f"{path}: {r[1]}" for path in present for r in [remover.blocked(path)] if r), None)
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
    return abandon(remover, name, state, workloop, saved)


def abandon(remover: Remover, name: str, state: str, workloop: Path, saved: list) -> bool:
    os.chdir(Path(state).parent)
    result = subprocess.run([sys.executable, str(workloop), "--state", state, "abandon", name],
                            text=True, capture_output=True, env=wr.clean_env())
    if result.returncode:
        remover.lines.append(f"kept workloop run {name}: abandon failed: {(result.stderr or result.stdout).strip()}")
        return False
    remover.lines.append(f"closed workloop run {name}: {result.stdout.strip()}"
                         + ("; unsaved work: " + ", ".join(saved) if saved else ""))
    return True


def finish(entries: list[dict], remover: Remover, workloop: Path, live: set, reason: str) -> list[dict]:
    """Close the runs, then remove the worktrees; return the entries still standing."""
    runs = {(e.get("run"), e.get("state")): e for e in entries if e.get("type") == "run"}
    remaining = [entry for entry in runs.values() if not close_run(remover, entry, workloop, live)]
    kept_runs, seen = {entry["run"] for entry in remaining}, set()
    for entry in [e for e in entries if e.get("type") == "worktree" and e.get("path")]:
        path = Path(entry["path"])
        if str(path) in seen:
            continue
        seen.add(str(path))
        if entry.get("run") in kept_runs:
            remaining.append(entry)
        elif entry.get("by") == "EnterWorktree" and reason == "prompt_input_exit" and path.is_dir() and not locked(path):
            remover.lines.append(f"kept {path}: kept at Claude Code's exit prompt")
        elif remover.retire(path) == "kept":
            remaining.append(entry)
    return remaining


def locked(path: Path) -> bool:
    main = wr.main_checkout(path)
    return bool(main) and any(e["path"] == path.resolve() and e["locked"] for e in wr.worktrees(main))
