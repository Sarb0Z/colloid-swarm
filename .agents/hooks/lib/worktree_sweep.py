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
import sys
import time
from pathlib import Path

_spec = importlib.util.spec_from_file_location("worktree_runs", Path(__file__).with_name("worktree_runs.py"))
rn = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rn)
hl, rm, wr = rn.hl, rn.rm, rn.wr

# Reasons after which the session's process exits; after /clear and /resume it
# goes on working, so its own folder still counts as occupied.
EXITS = {"prompt_input_exit", "other", "logout", "bypass_permissions_disabled"}
IDLE_SECONDS = 24 * 3600
PARKED_SECONDS = 600


def reclaim(folder: Path) -> None:
    """Fold claim files whose claiming process died back into their record files. A claim stays
    while the stamp a resumed session wrote beside it cannot be told live or gone."""
    for claim in folder.glob(".*.jsonl.*-*"):
        pid = claim.name.rsplit("-", 1)[-1]
        if pid.isdigit() and wr.ps_row(int(pid)) is None:
            record = folder / claim.name[1:].rsplit(".", 1)[0]
            mark = wr.last_host(wr.load(record)) if record.is_file() else None
            verdict = wr.stamp_state(mark)
            if verdict == wr.ps.CANNOT_TELL:
                continue
            with open(record, "a") as stream:
                stream.write(claim.read_text())
            # The folded entries end under their dead host; a session that resumed
            # meanwhile is written last again, so it does not read as gone.
            if verdict in (wr.ps.LIVE, wr.MEND):
                wr.append(folder, record.stem, [dict({"type": "host", "at": int(time.time())}, **mark)])
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
    """The session's process is gone (a file with no host: untouched for 24 hours). A stamp live
    by its host text alone is written again with its process's `start` (`upgrade`)."""
    mark = wr.last_host(entries)
    if not mark:
        return time.time() - path.stat().st_mtime > IDLE_SECONDS
    verdict = wr.stamp_state(mark)
    if verdict == wr.MEND:
        upgrade(path, mark)
    return verdict == wr.ps.GONE


def upgrade(path: Path, mark: dict) -> None:
    """Append a stamp live by its host text again with its process's own `start`, so its session
    reads the same in any zone or locale from now on (debt: worktree-records-local-stamps). The
    entry has no `at`: no process began, so it dates no resume (`finish`). Nothing is written
    when the record went or gained another stamp since the sweep read it."""
    start = wr.ps.read(mark["host"][0])
    try:
        current = wr.last_host(wr.load(path))
    except FileNotFoundError:
        return  # the session's own end claimed the record meanwhile
    if isinstance(start, dict) and current == mark:
        wr.append(path.parent, path.stem, [{"type": "host", "host": mark["host"], "start": start}])


def stamped(entry: dict, mark: dict | None) -> dict:
    """The entry under another stamp, its own `start` dropped where that stamp has none."""
    return dict({key: value for key, value in entry.items() if key != "start"}, **(mark or {"host": None}))


def close(path: Path, reason: str, workloop: Path) -> list[str]:
    """End one session's records: claim the file, remove, write back what stays."""
    claimed = path.with_name(f".{path.name}.{'ending' if reason else 'sweep'}-{os.getpid()}")
    try:
        os.rename(path, claimed)
    except FileNotFoundError:
        return []  # another end or sweep claimed it first
    entries, me = wr.load(claimed), wr.host()
    mark = wr.last_host(entries)
    if not reason and mark and wr.alive(mark):
        # Its session resumed between the sweep's look and the claim: give the records back.
        wr.append(path.parent, path.stem, entries)
        claimed.unlink()
        return []
    exclude = {pid for pid, _, _ in wr.chain()} if reason in EXITS else {os.getpid()}
    ending = me[0] if reason and me else mark["host"][0] if mark else None
    remover = rm.Remover(f"session {path.stem}", exclude, ending, rn.lost_files)
    standing = finish(entries, remover, workloop, reason, path)
    # What stays goes back under the session's stamp, so only a sweep after that
    # process exits takes it; under a live one when the session resumed meanwhile.
    wr.append(path.parent, path.stem, [stamped(e, resumed(path) or mark) for e in standing])
    claimed.unlink()
    return remover.lines


def resumed(path: Path):
    """The stamp a resumed session wrote to its record while a sweep held the claim, while its
    process may still run."""
    mark = wr.last_host(wr.load(path)) if path.is_file() else None
    return mark if mark and wr.alive(mark) else None


def finish(entries: list[dict], remover, workloop: Path, reason: str, record: Path) -> list[dict]:
    """Close the finished runs, then remove the worktrees; return the entries still standing.
    Claude Code asks keep-or-remove only for the last worktree entered, and reports
    the main checkout as the cwd after the answer (2.1.299), so only that one reads as kept."""
    runs = {(e.get("run"), e.get("state")): e for e in entries if e.get("type") == "run"}
    since, now = max((e.get("at") or 0 for e in entries if e.get("type") == "host"), default=0), time.time()
    entered = [e["path"] for e in entries if e.get("by") == "EnterWorktree" and e.get("path")]
    remaining = []
    for entry in runs.values():
        why = rn.unfinished(entry, workloop)
        if why and rn.waits(entry, reason, since, now):
            until = time.strftime("%Y-%m-%d %H:%M", time.localtime(entry["held"] + rn.HOLD_SECONDS))
            remover.lines.append(f"kept workloop run {entry['run']}: {why}; it waits for this conversation's "
                                 f"resume until {until}")
            remaining.append(entry)
        elif not reason and resumed(record):
            remover.lines.append(f"kept workloop run {entry['run']}: its session resumed during this sweep")
            remaining.append(entry)
        elif not rn.close_run(remover, entry, workloop):
            remaining.append(entry)
    kept_runs, seen = {entry["run"] for entry in remaining}, set()
    for entry in [e for e in entries if e.get("type") == "worktree" and e.get("path")]:
        worktree = Path(entry["path"])
        if str(worktree) in seen:
            continue
        seen.add(str(worktree))
        if entry.get("run") in kept_runs:
            remaining.append(entry)
        elif not reason and resumed(record):
            remover.lines.append(f"kept {worktree}: its session resumed during this sweep")
            remaining.append(entry)
        elif reason == "prompt_input_exit" and entered and entry["path"] == entered[-1] and worktree.is_dir() \
                and not lock_of(worktree):
            remover.lines.append(f"kept {worktree}: kept at Claude Code's exit prompt")
        elif remover.retire(worktree) == "kept":
            remaining.append(entry)
    return remaining


def lock_of(path: Path) -> str | None:
    main = wr.main_checkout(path)
    return next((e["locked"] for e in wr.worktrees(main) if e["path"] == path.resolve()), None) if main else None


def end(project: Path, session: str, reason: str, workloop: Path) -> list[str]:
    path = wr.records_dir(project) / f"{wr.session_key(session)}.jsonl"
    return close(path, reason or "other", workloop) if wr.session_key(session) and path.is_file() else []


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


def rehost(folder: Path, me: str) -> None:
    """Claim a resumed session's records for its new process, before any lock: a start that
    finds another sweeping skips the sweep, never this. A record another sweep holds counts."""
    if me and ((folder / f"{me}.jsonl").is_file() or any(folder.glob(f".{me}.jsonl.*-*"))):
        wr.append(folder, me, [dict({"type": "host", "at": int(time.time())}, **wr.stamp())])


def sweep(project: Path, session: str, source: str, workloop: Path, emit, budget: float) -> None:
    main = wr.main_checkout(project)
    if main is None:
        return
    rehost(main / wr.RECORDS, wr.session_key(session))
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
        rehost(folder, me)  # again: a claim folded back above ends under its old host
        for path in sorted(folder.glob("*.jsonl")):
            if path.stem != me and over(wr.load(path), path):
                for line in close(path, "", workloop):
                    emit(line)
    recorded, leads = set(), set()
    # A claim still standing (its sweep runs, or its record's stamp cannot be told) records too.
    for path in [*folder.glob("*.jsonl"), *folder.glob(".*.jsonl.*-*")] if folder.is_dir() else []:
        try:
            entries = wr.load(path)
        except FileNotFoundError:
            continue  # a session end claimed it, or a sweep gave it back, since the listing
        for entry in entries:
            recorded |= {str(Path(entry["path"]).resolve())} if entry.get("type") == "worktree" else set()
            leads.add(entry.get("run"))
    for line in rn.unowned_runs(main, leads):
        emit(line)
    # A run's state may live in any checkout of the repository, so every one's lanes are spared.
    runs = [run for entry in wr.worktrees(main) for run in wr.runs_in(str(entry["path"] / rn.STATE)).values()]
    spared = recorded | {str(Path(space).resolve()) for run in runs for space in rn.workspaces(run)}
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
