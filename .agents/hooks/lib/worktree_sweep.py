#!/usr/bin/env python3
"""End a session's records at its end, and sweep the repository's at each start.

    worktree_sweep.py end <project> <session> <reason> <workloop.py>   (session-end.sh)
    worktree_sweep.py sweep <project> <session> <workloop.py>          (session-start.sh)

`sweep` (one per repository at a time) folds back what a killed run left,
ends the records of sessions whose process is gone, closes a run no record
leads once git lists none of its workspaces, and heals what older sessions
left (ruling 20): an idle, unlocked worktree no record or run names, outside
every `.agents/worktrees/`, is removed when nothing in it would be lost, and
every other one is named with its work and why it stays.
"""

from __future__ import annotations

import fcntl
import functools
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
# Ignored files that never rebuild, wherever they lie, rebuild-list folders
# included: environment files, local databases and their journals, keys, and
# Terraform state.
KEEPS = re.compile(r"^\.env|\.(db|sqlite3?)(-\w+)?$|\.(pem|key|p12|pfx|jks|keystore)$|\.tfstate(\.|$)", re.I)
# Rebuild-list folders a package manager fills from a manifest. The keep-list
# walk does not enter them: a key or database file there ships with a package.
INSTALLED_DIRS = frozenset({"node_modules", ".venv", "venv", ".tox", ".nox", "Pods", ".gradle"})
HEAL_CACHE = "colloid-heal-cache.json"
# A kept worktree's verdict stands while its HEAD, lock, index, git folder,
# top folder and the branch tips it turned on are unchanged, for at most this
# long: what the key cannot see, such as a file deleted inside an ignored
# folder, is judged again by then. Only "stays" is cached, never "could go".
CACHE_SECONDS = 7 * 86400
# How long git keeps a HEAD-log entry no ref reaches (gc.reflogExpireUnreachable's default).
REFLOG_KEEP_SECONDS = 30 * 86400
# Removing stops after this long, so a first heal of many worktrees fits the
# start hook; the rest go at the next start.
REMOVE_SECONDS = 20


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
        if name and os.path.lexists(path / name) and not rm.REBUILDABLE_DIRS.intersection(Path(name).parts):
            newest = max(newest, os.lstat(path / name).st_mtime)
    return newest


def scan(path: Path) -> tuple[str | None, list[str]]:
    """One walk of the worktree: the first nested `.git` outside rebuild-list folders, and
    every file whose name is on the keep list. Dependency stores are not entered."""
    keeps = []
    for root, dirs, files in os.walk(path):
        rel = Path(root).relative_to(path)
        if rel.parts and (".git" in dirs or ".git" in files) and not rm.REBUILDABLE_DIRS.intersection(rel.parts):
            return root, keeps
        keeps += [str(rel / name) for name in files if KEEPS.search(name)]
        dirs[:] = [name for name in dirs if name != ".git" and name not in INSTALLED_DIRS]
    return None, keeps


def unrebuildable(path: Path, keeps: list[str]) -> list[str] | str:
    """Ignored entries that would not come back, or why git could not list them. The keep
    list goes first (S1): an ignored keep-list file counts wherever it lies, inside a
    rebuild-list folder too. Any other ignored entry counts unless it is or lies in a
    rebuild-list folder, or is a rebuildable file."""
    found = []
    if keeps:
        checked = wr.git(path, "check-ignore", "-z", "--stdin", stdin="\0".join(keeps) + "\0")
        if checked.returncode > 1:
            return f"git check-ignore failed: {checked.stderr.strip()}"
        found = [name for name in checked.stdout.split("\0") if name]
    listing = wr.git(path, "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory")
    if listing.returncode:
        return f"git could not list its ignored files: {listing.stderr.strip()}"
    names = [entry for entry in listing.stdout.split("\0") if entry]
    for name in names:
        # A folder listed with its contents is judged by them.
        if name.endswith("/") and any(other != name and other.startswith(name) for other in names):
            continue
        parts = Path(name).parts
        if rm.REBUILDABLE_DIRS.intersection(parts) or not name.endswith("/") and (
                parts[-1] in REBUILDABLE_FILES or parts[-1].endswith(REBUILDABLE_SUFFIXES)):
            continue
        found.append(name)
    return list(dict.fromkeys(found))


def default_refs(main: Path) -> list[str]:
    remote = wr.out(main, "symbolic-ref", "-q", "refs/remotes/origin/HEAD")
    names = [remote.split("/", 3)[-1]] if remote else ["main", "master"]
    refs = [f"refs/heads/{name}" for name in names] + ([remote] if remote else [])
    return [ref for ref in refs if wr.out(main, "rev-parse", "-q", "--verify", ref)]


@functools.cache
def merge_tree_ok() -> bool:
    found = re.search(r"(\d+)\.(\d+)", wr.out(".", "version"))
    return bool(found) and (int(found.group(1)), int(found.group(2))) >= (2, 38)


def settled(path: Path, branch: str | None, defaults: list[str]) -> str | None:
    """How the worktree's commits are safe elsewhere, or None. A branch is safe when the
    default branch contains it, when merging it there would change nothing (a squash
    merge), or when its upstream holds every commit, as of the last fetch. A detached HEAD
    is safe only inside the default branch (S3): a remote-tracking copy of a branch the
    remote deleted holds it only until the next prune."""
    for ref in defaults:
        if wr.git(path, "merge-base", "--is-ancestor", "HEAD", ref).returncode == 0:
            return f"merged into {ref.split('/', 2)[-1]}"
    if not branch:
        return None
    for ref in defaults if merge_tree_ok() else []:
        merged = wr.git(path, "merge-tree", "--write-tree", ref, "HEAD")
        if merged.returncode == 0 and merged.stdout.split()[:1] == [wr.out(path, "rev-parse", f"{ref}^{{tree}}")]:
            return f"its changes are already in {ref.split('/', 2)[-1]}"
    upstream = wr.out(path, "rev-parse", "-q", "--abbrev-ref", "@{upstream}")
    if upstream and wr.out(path, "rev-list", "--count", "HEAD", "--not", "@{upstream}") == "0":
        return f"every commit is on {upstream}"
    return None


def reflog_keep(main: Path) -> float | None:
    """How long git keeps a HEAD-log entry no ref reaches: its default, or for as long as
    the worktree stands (None) when the repository sets gc.reflogExpireUnreachable."""
    return None if wr.out(main, "config", "--get", "gc.reflogExpireUnreachable") else REFLOG_KEEP_SECONDS


def stranded(path: Path, keep: float | None) -> tuple[str | None, float | None]:
    """Why the worktree's HEAD log keeps it, and until when: commits an amend, a rebase or
    a switch away from a detached HEAD left that no branch, tag or remote reaches. Removing
    the worktree deletes its HEAD log, so they stay while git would keep them."""
    logged = {}
    for line in wr.out(path, "reflog", "show", "--date=unix", "--format=%H %gd", "HEAD").splitlines():
        commit, _, selector = line.partition(" ")
        stamp = selector.rpartition("{")[2].rstrip("}")
        if stamp.isdigit() and (keep is None or time.time() - int(stamp) < keep):
            logged[commit] = max(logged.get(commit, 0), int(stamp))
    if not logged:
        return None, None
    found = wr.git(path, "rev-list", "--ignore-missing", "--stdin", "--not", "--branches", "--tags", "--remotes",
                   stdin="".join(f"{commit}\n" for commit in logged))
    if found.returncode:
        return f"git could not read its HEAD log: {found.stderr.strip()}", None
    lost = set(found.stdout.split())
    if not lost:
        return None, None
    until = max(stamp for commit, stamp in logged.items() if commit in lost) + keep if keep is not None else None
    kept = f", which git keeps until {time.strftime('%Y-%m-%d', time.localtime(until))}" if until else ""
    return f"its HEAD log holds {len(lost)} commit(s) no branch, tag or remote reaches{kept}", until


def about(path: Path, entry: dict, defaults: list[str]) -> str:
    subject = wr.out(path, "log", "-1", "--format=%cs %s")
    ahead = wr.out(path, "rev-list", "--count", "HEAD", "--not", *defaults) if defaults else "?"
    changed = len(wr.out(path, "--no-optional-locks", "status", "--porcelain", "--untracked-files=all").splitlines())
    return (f"{path} [{entry['branch'] or 'detached'}] last commit {subject or 'none'}; "
            f"{ahead} commit(s) not in the default branch, {changed} uncommitted file(s)")


def held(path: Path, entry: dict, remover) -> tuple[str | None, bool]:
    """(Why the worktree stays whatever its contents, whether that reason may be cached.)
    Any lock keeps it: Claude Code's lock of an ended session included, since nothing
    records whether the operator kept that worktree at its exit prompt (ruling 22)."""
    if entry["locked"] and rm.claude_lock_ended(entry["locked"], None):
        return (f"it is locked ({entry['locked']}) by a Claude Code session that has ended, and nothing records "
                f"whether the operator kept it at the exit prompt; `git worktree unlock {path}` lets the next start judge it"), True
    if entry["locked"]:
        return f"it is locked ({entry['locked']})", True
    return remover.occupant(path), False


def judge(path: Path, entry: dict, listed: list[dict], defaults: list[str],
          keep: float | None) -> tuple[str | None, str | None, bool, float | None]:
    """(Why it stays, or None; how its work is safe elsewhere; whether the verdict turned on
    the branch tips; when it must be judged again.) Cheap checks first, the walk last."""
    why = rm.unsaveable(path) or ("it holds uncommitted work" if rm.dirty(path) else None)
    if why:
        return why, None, False, None
    safe = settled(path, entry["branch"], defaults)
    if not safe:
        return ("its commits are neither merged into the default branch nor on its upstream" if entry["branch"]
                else "its detached HEAD is not in the default branch"), None, True, None
    why, until = stranded(path, keep)
    if why:
        return why, None, False, until
    inner = next((e["path"] for e in listed if path in e["path"].parents), None)
    if inner:
        return f"another worktree lies inside it: {inner}", None, False, None
    nested, keeps = scan(path)
    if nested:
        return f"it holds a nested repository at {nested}", None, False, None
    extra = unrebuildable(path, keeps)
    if isinstance(extra, str):
        return extra, None, False, None
    if extra:
        return "it holds ignored files that do not rebuild: " + ", ".join(extra[:5]), None, False, None
    return None, safe, False, None


def cache_key(path: Path, entry: dict) -> list | None:
    """What a kept verdict stands on: HEAD, the lock, and the times of the top folder, the
    worktree's git folder and its index. None when its `.git` file names no git folder."""
    try:
        pointer = (path / ".git").read_text()
    except OSError:
        return None
    if not pointer.startswith("gitdir: "):
        return None
    admin = path / pointer[len("gitdir: "):].strip()
    stamps = [[os.stat(item).st_mtime_ns, os.stat(item).st_size] if item.exists() else None
              for item in (path, admin, admin / "index")]
    return [entry["head"], entry["locked"], stamps]


def ref_tips(main: Path) -> tuple[dict, dict]:
    """{ref: commit} of every branch and remote-tracking ref, and {branch ref: its upstream ref}."""
    tips, upstreams = {}, {}
    listing = wr.out(main, "for-each-ref", "--format=%(refname)%00%(objectname)%00%(upstream)", "refs/heads", "refs/remotes")
    for ref, tip, upstream in (line.split("\0") for line in listing.splitlines()):
        tips[ref] = tip
        if upstream:
            upstreams[ref] = upstream
    return tips, upstreams


def load_cache(common: Path) -> dict:
    path = common / HEAL_CACHE
    try:
        data = json.loads(path.read_text()) if path.is_file() else {}
    except (OSError, ValueError) as error:
        wr.warn(f"{path} is unreadable ({error}); every idle worktree is judged again")
        return {}
    return data if isinstance(data, dict) else {}


def cached(hit, key: list | None, refs: list) -> str | None:
    """The kept verdict's line while it stands, else None."""
    if not isinstance(hit, dict) or key is None or hit.get("key") != key or not isinstance(hit.get("line"), str):
        return None
    now, at, until = time.time(), hit.get("at"), hit.get("until")
    if hit.get("refs") not in (None, refs) or not isinstance(at, (int, float)) or not 0 <= now - at < CACHE_SECONDS:
        return None
    return None if isinstance(until, (int, float)) and now >= until else hit["line"]


def heal(main: Path, recorded: set, lanes_of_runs: set) -> list[str]:
    """Remove each idle worktree no record or run names that would lose nothing, and name
    every other one with its work. A lane folder, inside any `.agents/worktrees/`, is named only.

    Cost per start: one `git worktree list`, one `for-each-ref`, and per worktree a read of
    its `.git` file and three stats, which is all a worktree whose kept verdict stands costs.
    A miss adds the idle check (a stat per tracked and untracked file, rebuild-list folders
    skipped), three git calls to name it, up to eleven to judge it, one lsof for the whole
    sweep, and, only once every cheaper check has passed, one walk of the worktree that
    skips dependency stores. Removal stops after REMOVE_SECONDS."""
    listed, defaults, (tips, upstreams) = wr.worktrees(main), default_refs(main), ref_tips(main)
    common = Path(wr.out(main, "rev-parse", "--path-format=absolute", "--git-common-dir"))
    cache, kept, lines, ready = load_cache(common), {}, [], []
    remover, keep = rm.Remover("the sweep", {os.getpid()}, None), reflog_keep(main)
    for entry in listed[1:]:
        path = entry["path"]
        if entry["prunable"] or not path.is_dir() or str(path) in recorded | lanes_of_runs:
            continue
        if any(folder.name == "worktrees" and folder.parent.name == ".agents" for folder in path.parents):
            lines.append(f"lane folder {about(path, entry, defaults)}: belongs to no workloop run")
            continue
        key = cache_key(path, entry)
        refs = [tips.get(ref) for ref in defaults] + [tips.get(upstreams.get(f"refs/heads/{entry['branch']}"))]
        line = cached(cache.get(str(path)), key, refs)
        if line:
            kept[str(path)] = cache[str(path)]
            lines.append(line)
            continue
        if time.time() - idle_since(path) < IDLE_SECONDS:
            continue
        named, (why, lasting) = about(path, entry, defaults), held(path, entry, remover)
        safe, on_refs, until = None, False, None
        if why is None:
            why, safe, on_refs, until = judge(path, entry, listed, defaults, keep)
            lasting = True
        if why is None:
            ready.append((path, named, safe))
            continue
        lines.append(f"idle {named}: stays: {why}")
        if lasting and key is not None:
            kept[str(path)] = {"key": key, "refs": refs if on_refs else None, "line": lines[-1],
                               "at": time.time(), "until": until}
    lines += remove_ready(main, ready)
    scratch = common / f"{HEAL_CACHE}.{os.getpid()}"
    scratch.write_text(json.dumps(kept, sort_keys=True))
    os.replace(scratch, common / HEAL_CACHE)
    return lines


def remove_ready(main: Path, ready: list) -> list[str]:
    """Remove each worktree judged to lose nothing, after a fresh look at its lock, its
    processes and its unsaved state. Nothing is saved; `git worktree remove` runs without
    --force, so git refuses one that turned dirty. The branch goes by `drop_branch`'s rule."""
    lines, started, remover = [], time.monotonic(), rm.Remover("the heal", {os.getpid()}, None)
    for path, named, safe in ready:
        if time.monotonic() - started > REMOVE_SECONDS:
            lines.append(f"idle {named}: could go: {safe}; the next start removes it")
            continue
        entry = next((e for e in wr.worktrees(main) if e["path"] == path), None)
        if entry is None:
            lines.append(f"idle {named}: stays: git no longer lists it")
            continue
        why = held(path, entry, remover)[0] or rm.unsaveable(path) or (
            "it holds uncommitted work" if rm.dirty(path) else None)
        why = why or rm.remove(path, main, force=False)
        lines.append(f"idle {named}: stays: {why}" if why else
                     f"removed idle {named}: could go: {safe}" + rm.drop_branch(main, entry["branch"]))
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
    # A run's state may live in any checkout of the repository, so every one's lanes are spared.
    runs = [run for entry in wr.worktrees(main) for run in wr.runs_in(str(entry["path"] / STATE)).values()]
    lines += heal(main, recorded, {str(Path(space).resolve()) for run in runs for space in workspaces(run)})
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
