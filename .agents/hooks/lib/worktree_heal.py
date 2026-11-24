#!/usr/bin/env python3
"""Heal what older sessions left: an idle worktree no record or run names, outside every
`.agents/worktrees/`, is removed when nothing in it would be lost, and every other one is
named with its work and the command that shows why it stays. `judge` holds the rules and
runs again in full just before each removal. Removal is `git worktree remove` without
--force; nothing is saved; a branch goes only when the main checkout's HEAD contains it.
"""

from __future__ import annotations

import fnmatch
import functools
import importlib.util
import json
import os
import re
import time
from pathlib import Path
from types import SimpleNamespace

_spec = importlib.util.spec_from_file_location("worktree_removal", Path(__file__).with_name("worktree_removal.py"))
rm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rm)
wr = rm.wr

IDLE_SECONDS = 24 * 3600
CACHE = "colloid-heal-cache.json"
# A kept verdict stands while the worktree's HEAD, lock, index, git folder and top folder
# and the branch tips it turned on are unchanged, for at most a week: what the key cannot
# see, such as a file deleted inside an ignored folder, is judged again by then.
CACHE_SECONDS = 7 * 86400
# How long git keeps a HEAD-log entry no ref reaches (gc.reflogExpireUnreachable's default).
REFLOG_KEEP_SECONDS = 30 * 86400
# A start begins no removal after this many seconds of healing; the rest go at the next one.
REMOVE_SECONDS = 20.0
# Ignored files written again by a tool or the scaffold, which never keep a worktree.
ANYWHERE = frozenset({".DS_Store", "next-env.d.ts"})
# Caches a tool rebuilds the next time it runs, holding no work (ruling 29).
CACHE_DIRS = frozenset({"__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache"})
LEDGERS = (".wrap-*", ".teardown-pending-*", ".ui-pending-*", ".provenance-*", ".writers-*", ".cells-*",
           ".cell-markers-*", ".outside-runs-*", ".inbox-seen-*", ".publish-approved-*", ".compaction-pending",
           ".kimi-pending-findings-*", ".workloop-state.json.lock")
# colloid-only
LEDGERS += (".genome-ledger", ".mutagen-ledger")
# /colloid-only


def stale_ledgers(main: Path, live: set) -> list[str]:
    """Remove the marker ledgers (`.cell-markers-<session>`, `.outside-runs-<session>`, both in
    LEDGERS) a session left that no live record names and nothing has written for IDLE_SECONDS;
    a session start keeps its own unless it starts afresh. One line per ledger that could not go."""
    lines = []
    for pattern in (".cell-markers-*", ".outside-runs-*"):
        for ledger in (main / ".agents").glob(pattern):
            session = ledger.name.removeprefix(pattern[:-1])
            try:
                if session not in live and time.time() - ledger.stat().st_mtime > IDLE_SECONDS:
                    ledger.unlink()
            except FileNotFoundError:
                continue
            except OSError as error:
                lines.append(f"could not remove the stale ledger {ledger}: {error}")
    return lines


def idle_since(path: Path) -> float:
    """The newest of the worktree's commit, checkout and file times, package folders skipped."""
    admin = Path(wr.out(path, "rev-parse", "--path-format=absolute", "--git-dir"))
    stamps = [os.stat(item).st_mtime for item in (admin / "HEAD", admin / "index", admin / "logs" / "HEAD", path)
              if item.exists()]
    committed = wr.out(path, "log", "-1", "--format=%ct")
    newest = max(stamps + ([float(committed)] if committed.isdigit() else []) or [0.0])
    for name in wr.git(path, "ls-files", "-z", "--cached", "--others", "--exclude-standard").stdout.split("\0"):
        if time.time() - newest < IDLE_SECONDS:
            break
        if name and os.path.lexists(path / name) and not rm.PACKAGE_DIRS.intersection(Path(name).parts):
            newest = max(newest, os.lstat(path / name).st_mtime)
    return newest


def rebuilds(path: Path, name: str) -> bool:
    """An ignored entry that comes back on its own: inside a package folder or a tool cache,
    the lane brief folder `.workloop/`, a file in ANYWHERE, a session-keyed scaffold ledger
    directly in `.agents/`, or `.agents/.workloop-state.json` holding no run."""
    parts = Path(name).parts
    if (rm.PACKAGE_DIRS | CACHE_DIRS).intersection(parts) or parts[0] == ".workloop" \
            or (not name.endswith("/") and parts[-1] in ANYWHERE):
        return True
    if len(parts) != 2 or parts[0] != ".agents":
        return False
    if any(fnmatch.fnmatchcase(parts[1], pattern) for pattern in LEDGERS):
        return True
    try:
        state = json.loads((path / name).read_text()) if parts[1] == ".workloop-state.json" else None
    except (OSError, ValueError):
        return False
    return isinstance(state, dict) and not state.get("runs")


def unrebuildable(path: Path) -> list[str] | str:
    """Ignored entries that would not come back, or why git could not list them. A folder
    listed with its contents is judged by them; an empty folder holds nothing to lose."""
    listing = wr.git(path, "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory")
    if listing.returncode:
        return f"git could not list its ignored files ({listing.stderr.strip()}); see `git -C {path} status --ignored`"
    names = [name for name in listing.stdout.split("\0") if name]
    leaves = [name for name in names if not (name.endswith("/") and any(o != name and o.startswith(name) for o in names))]
    return [name for name in leaves if not rebuilds(path, name)
            and not (name.endswith("/") and not any(files for _, _, files in os.walk(path / name)))]


def default_refs(main: Path) -> list[str]:
    remote = wr.out(main, "symbolic-ref", "-q", "refs/remotes/origin/HEAD")
    names = [remote.split("/", 3)[-1]] if remote else ["main", "master"]
    refs = [f"refs/heads/{name}" for name in names] + ([remote] if remote else [])
    return [ref for ref in refs if wr.out(main, "rev-parse", "-q", "--verify", ref)]


def short(ref: str) -> str:
    return ref.removeprefix("refs/heads/").removeprefix("refs/remotes/")


def branch_refs(main: Path, name: str | None) -> list[str]:
    """The refs a source branch name stands for: the local branch and its upstream, or the
    remote-tracking branch; [] when it names neither."""
    if not name:
        return []
    if wr.out(main, "rev-parse", "-q", "--verify", f"refs/heads/{name}"):
        upstream = wr.out(main, "rev-parse", "-q", "--symbolic-full-name", f"refs/heads/{name}@{{upstream}}")
        return [f"refs/heads/{name}"] + ([upstream] if upstream.startswith("refs/") else [])
    return [f"refs/remotes/{name}"] if wr.out(main, "rev-parse", "-q", "--verify", f"refs/remotes/{name}") else []


def created_from(main: Path, branch: str | None) -> str | None:
    """The start point git wrote into the branch's own reflog when it made the branch
    (`branch: Created from staging`); None when that names HEAD or the log is gone."""
    log = wr.out(main, "reflog", "show", "--format=%gs", f"refs/heads/{branch}") if branch else ""
    first = log.splitlines()[-1] if log else ""
    name = first.removeprefix("branch: Created from ") if first.startswith("branch: Created from ") else ""
    return name if name and name != "HEAD" else None


def named_source(main: Path, recorded: str | None, branch: str | None) -> tuple[str, list[str]] | None:
    """(The source branch's name, its refs) a worktree's work is judged merged against (ruling R11):
    the branch recorded when it was made, else the start point in its branch's reflog; None when
    neither names a branch that still exists."""
    for name in (recorded, created_from(main, branch)):
        refs = branch_refs(main, name)
        if refs:
            return name, refs
    return None


@functools.cache
def merge_tree_ok() -> bool:
    found = re.search(r"(\d+)\.(\d+)", wr.out(".", "version"))
    return bool(found) and (int(found.group(1)), int(found.group(2))) >= (2, 38)


def contained(path: Path, refs: list[str]) -> str | None:
    """The first of `refs` whose history holds HEAD, short; None when none does."""
    return next((short(ref) for ref in refs if wr.git(path, "merge-base", "--is-ancestor", "HEAD", ref).returncode == 0), None)


def squashed(path: Path, refs: list[str]) -> str | None:
    """The first of `refs` that already holds HEAD's changes (a squash merge), short; None when none does."""
    for ref in refs if merge_tree_ok() else []:
        merged = wr.git(path, "merge-tree", "--write-tree", ref, "HEAD")
        if merged.returncode == 0 and merged.stdout.split()[:1] == [wr.out(path, "rev-parse", f"{ref}^{{tree}}")]:
            return short(ref)
    return None


def settled(path: Path, branch: str | None, defaults: list[str]) -> tuple[str | None, str | None]:
    """(How its commits are safe elsewhere, or None; why not, with the command to look.)
    `defaults` are its source branch's refs (`source_refs`)."""
    short_name = short(defaults[0]) if defaults else "the default branch"
    if into := contained(path, defaults):
        return f"merged into {into}", None
    look = f"see `git -C {path} log {short_name}..HEAD`" if defaults else "no main, master or origin/HEAD names it"
    if not branch:
        return None, f"its detached HEAD is not in {short_name}; {look}"
    if into := squashed(path, defaults):
        return f"its changes are already in {into}", None
    upstream, _, track = wr.out(path, "for-each-ref", "--format=%(upstream:short)%00%(upstream:track)",
                                f"refs/heads/{branch}").partition("\0")
    if not upstream:
        return None, f"its commits are not in {short_name} and it has no upstream; {look}, or `git -C {path} push -u`"
    if track == "[gone]":
        return None, f"its commits are not in {short_name} and its upstream {upstream} is gone; {look}"
    ahead = wr.out(path, "rev-list", "--count", "HEAD", "--not", "@{upstream}")
    if ahead == "0":
        return f"every commit is on {upstream}", None
    return None, f"{ahead or 'some'} commit(s) are neither in {short_name} nor on {upstream}; see `git -C {path} log @{{upstream}}..HEAD`"


def stranded(path: Path, keep: float | None) -> tuple[str | None, float | None]:
    """Why commits only this worktree reaches keep it, and until when. Removal deletes its
    HEAD log and its refs/worktree/ refs; a log entry counts while git would keep it."""
    log = wr.git(path, "reflog", "show", "--date=unix", "--format=%H %gd", "HEAD")
    own = wr.git(path, "for-each-ref", "--format=%(objectname)", "refs/worktree/")
    if log.returncode or own.returncode:
        return f"git could not read its HEAD log or refs ({(log.stderr or own.stderr).strip()}); see `git -C {path} reflog`", None
    reached: dict[str, float | None] = {tip: None for tip in own.stdout.split()}
    for commit, _, selector in (line.partition(" ") for line in log.stdout.splitlines()):
        stamp = selector.rpartition("{")[2].rstrip("}")
        if commit not in reached and stamp.isdigit() and (keep is None or time.time() - int(stamp) < keep):
            reached[commit] = max(reached.get(commit) or 0, int(stamp) + keep) if keep is not None else None
    if not reached:
        return None, None
    found = wr.git(path, "rev-list", "--ignore-missing", "--stdin", "--not", "--branches", "--tags", "--remotes",
                   stdin="".join(f"{commit}\n" for commit in reached))
    if found.returncode:
        return f"git could not read its HEAD log ({found.stderr.strip()}); see `git -C {path} reflog`", None
    lost = set(found.stdout.split())
    if not lost:
        return None, None
    ends = [reached[commit] for commit in reached if commit in lost]
    until = None if None in ends else max(ends)
    kept = f", which git keeps until {time.strftime('%Y-%m-%d', time.localtime(until))}" if until else ""
    return (f"{len(lost)} commit(s) only its HEAD log or refs/worktree/ refs reach{kept}; "
            f"see `git -C {path} reflog`"), until


def about(path: Path, entry: dict, refs: list[str], label: str) -> str:
    """The worktree, its branch and last commit, and its commits not in `refs` (`label`)."""
    subject = wr.out(path, "log", "-1", "--format=%cs %s")
    ahead = wr.out(path, "rev-list", "--count", "HEAD", "--not", *refs) if refs else "?"
    status = wr.git(path, "--no-optional-locks", "status", "--porcelain", "--untracked-files=all")
    changed = "status unreadable" if status.returncode else f"{len(status.stdout.splitlines())} uncommitted file(s)"
    return (f"{path} [{entry['branch'] or 'detached'}] last commit {subject or 'none'}; "
            f"{ahead} commit(s) not in {label}, {changed}")


def heal_source(main: Path, branch: str | None, defaults: list[str]) -> tuple[str, list[str]]:
    """(Label, refs) an unrecorded worktree is judged against: the start point its branch's reflog
    names, else the default branch."""
    found = named_source(main, None, branch)
    return found if found else ("the default branch", defaults)


def held(path: Path, entry: dict, remover) -> tuple[str | None, bool]:
    """(Why it stays whatever it holds, whether that may be cached.) Claude Code's lock of
    an ended session keeps nothing: answering "keep" at its exit prompt unlocks the worktree."""
    lock = entry["locked"]
    if lock and rm.CLAUDE_LOCK.match(lock) and not rm.claude_lock_ended(lock, None):
        return f"a running Claude Code session holds it ({lock})", False
    if lock and not rm.CLAUDE_LOCK.match(lock):
        return f"it is locked ({lock}); `git worktree unlock {path}` lets the next start judge it", True
    return remover.occupant(path), False


def judge(path: Path, entry: dict, ctx, refs: list[str]) -> tuple[str | None, str | None, bool, float | None, bool]:
    """(Why it stays, or None; how its work is safe; whether that turned on the branch tips;
    when to judge again; whether to cache it.) It goes only with no live lock and no process
    inside; nothing uncommitted, untracked or hidden from status; its branch merged into its
    source branch's `refs`, squash included, or on its upstream, a detached HEAD only inside
    them; no commit only its HEAD log or refs/worktree/ reach while git keeps it;
    no worktree or `.git` inside outside package folders; and no ignored file that does not
    rebuild. Cheap checks first, the walk last."""
    why, lasting = held(path, entry, ctx.remover)
    if why:
        return why, None, False, None, lasting
    why = rm.unsaveable(path) or (f"it holds uncommitted work; see `git -C {path} status`" if rm.dirty(path) else None)
    if why:
        return why, None, False, None, True
    safe, why = settled(path, entry["branch"], refs)
    if why:
        return why, None, True, None, True
    why, until = stranded(path, ctx.keep)
    if why:
        return why, None, False, until, True
    why = rm.inner_worktree(path, ctx.listed) or rm.nested(path)
    extra = None if why else unrebuildable(path)
    if extra:
        why = extra if isinstance(extra, str) else (
            f"it holds ignored files that do not rebuild: {', '.join(extra[:5])}; see `git -C {path} status --ignored`")
    return why, None if why else safe, False, None, True


def cache_key(path: Path, entry: dict) -> list | None:
    """HEAD, the lock, and the times of the top folder, the git folder and the index."""
    try:
        admin = path / (path / ".git").read_text().removeprefix("gitdir: ").strip()
    except OSError:
        return None
    stamps = [[os.stat(item).st_mtime_ns, os.stat(item).st_size] if item.exists() else None
              for item in (path, admin, admin / "index")]
    return [entry["head"], entry["locked"], stamps]


def branch_tips(main: Path) -> tuple[dict, dict]:
    """{ref: commit} of every branch and remote-tracking ref, and {branch ref: its upstream}."""
    tips, upstreams = {}, {}
    listing = wr.out(main, "for-each-ref", "--format=%(refname)%00%(objectname)%00%(upstream)", "refs/heads", "refs/remotes")
    for ref, tip, upstream in (line.split("\0") for line in listing.splitlines()):
        tips[ref] = tip
        upstreams.update({ref: upstream} if upstream else {})
    return tips, upstreams


def cached(hit, key: list | None, refs: list) -> bool:
    if not isinstance(hit, dict) or key is None or hit.get("key") != key or not isinstance(hit.get("line"), str):
        return False
    now, at, until = time.time(), hit.get("at"), hit.get("until")
    if hit.get("refs") not in (None, refs) or not isinstance(at, (int, float)) or not 0 <= now - at < CACHE_SECONDS:
        return False
    return not (isinstance(until, (int, float)) and now >= until)


def heal(main: Path, spared: set, cache: dict | None, emit, remove: bool, budget: float) -> dict:
    """Judge each idle worktree `spared` leaves out and remove what loses nothing, emitting
    each line as it happens; return the kept verdicts to cache. `cache` is None before any
    start has cached one. Lane folders are named only. With `remove` off (a compaction
    start) nothing goes. Removal begins only within `budget` seconds of the heal's start.

    Per start: one `git worktree list`, one `for-each-ref`, and per worktree a read of its
    `.git` file and three stats, which is all a cached verdict costs. A miss adds about 21
    git calls (3 for idleness, 3 to name it, up to 15 to judge it), a stat of every
    tracked and untracked file, one lsof for the whole start, and a walk outside package
    folders. A removal lists the worktrees and judges again (up to 16 calls and the walk),
    then makes about 7 more to remove the worktree and settle its branch."""
    started, listed = time.monotonic(), wr.worktrees(main)
    defaults, (tips, upstreams) = default_refs(main), branch_tips(main)
    keep = None if wr.out(main, "config", "--get", "gc.reflogExpireUnreachable") else REFLOG_KEEP_SECONDS
    ctx = SimpleNamespace(keep=keep, listed=listed, remover=rm.Remover("the heal", {os.getpid()}, None, None))
    kept, ready, standing = {}, [], 0
    for entry in listed[1:]:
        path = entry["path"]
        if entry["prunable"] or not path.is_dir() or str(path) in spared:
            continue
        if any(folder.name == "worktrees" and folder.parent.name == ".agents" for folder in path.parents):
            emit(f"lane folder {about(path, entry, defaults, 'the default branch')}: belongs to no workloop run; "
                 "see `git worktree list`")
            continue
        key, hit = cache_key(path, entry), (cache or {}).get(str(path))
        # A cached verdict names the source refs it was judged on; a hit costs no reflog read.
        on = hit["on"] if isinstance(hit, dict) and isinstance(hit.get("on"), list) else defaults
        upstream_tip = tips.get(upstreams.get(f"refs/heads/{entry['branch']}"))
        if cache and cached(hit, key, [tips.get(ref) for ref in on] + [upstream_tip]):
            kept[str(path)], standing = cache[str(path)], standing + 1
            continue
        if time.time() - idle_since(path) < IDLE_SECONDS:
            continue
        label, on = heal_source(main, entry["branch"], defaults)
        refs = [tips.get(ref) for ref in on] + [upstream_tip]
        named = about(path, entry, on, label)
        why, safe, on_refs, until, lasting = judge(path, entry, ctx, on)
        if why is None:
            ready.append((path, named, safe, on))
            continue
        emit(f"idle {named}: stays: {why}")
        if lasting and key is not None:
            kept[str(path)] = {"key": key, "refs": refs if on_refs else None, "on": on, "until": until,
                               "line": f"idle {named}: stays: {why}", "at": time.time()}
    if standing:
        emit(f"{standing} other idle worktree(s) stay as judged at an earlier start; list them with "
             f"`python3 {Path(__file__).with_name('worktree_sweep.py').resolve()} list {main}`")
    ctx.remover = rm.Remover("the heal", {os.getpid()}, None, None)  # removal looks at processes afresh
    for path, named, safe, on in ready:
        late = None if remove else "a compaction start removes nothing"
        late = late or (f"this start begins no removal after {budget:g} s" if time.monotonic() - started > budget else None)
        if late:
            emit(f"idle {named}: could go: {safe}; {late}, so the next start removes it")
            continue
        emit(remove_one(main, path, named, ctx, on))
    return kept


def remove_one(main: Path, path: Path, named: str, ctx, refs: list[str]) -> str:
    """Judge one worktree again in full, then remove it; the line saying what happened."""
    ctx.listed = wr.worktrees(main)
    entry = next((e for e in ctx.listed if e["path"] == path), None)
    if entry is None:
        return f"idle {named}: stays: git no longer lists it"
    why, safe = judge(path, entry, ctx, refs)[:2]
    if not why and entry["locked"]:
        unlocked = wr.git(main, "worktree", "unlock", str(path))
        why = f"git could not unlock it ({unlocked.stderr.strip()})" if unlocked.returncode else None
    why = why or rm.remove(path, main, force=False)
    return f"idle {named}: stays: {why}" if why else (
        f"removed idle {named}: could go: {safe}" + rm.drop_branch(main, entry["branch"], refs, squash=False))
