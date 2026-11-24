#!/usr/bin/env python3
"""Mark a session's end, and check dead sessions' worktrees at most once an hour.

    worktree_sweep.py end <project> <session> <reason>                 (session-end.sh)
    worktree_sweep.py sweep <project> <session> <source> <workloop.py> (session-start.sh)
    worktree_sweep.py check <project> <session> <workloop.py>          the hourly check alone
    worktree_sweep.py list <project>          the kept verdicts earlier starts cached, dated
    worktree_sweep.py keep <worktree>         the operator's "keep": not asked again for a week
    worktree_sweep.py remove <worktree> --save|--discard   the operator's other two answers

A session is dead once its record ends with an `end` (`/exit`, `/clear`, a
finished `claude -p`; ruling R1) or its process is gone (killed). The check
(`hourly`, from session-start.sh and the lead's per-prompt digest, stamped in
CHECK_STAMP) judges each dead session's worktrees, and each worktree of the
runs it led, against its source branch (ruling R11): one merged into it, with
nothing uncommitted, untracked or ignored that would not come back, is
removed; every other one gets a `dead session` line naming the three answers
the lead puts to the operator. Nothing with work is removed unasked, and
nothing of a run is touched while one of its agents may still be working
(worktree_runs.live_agents).

`sweep` (one per repository at a time) folds back what a killed sweep left,
runs the check when it is due, closes a run no record leads once git lists
none of its workspaces, and heals what older sessions left
(worktree_heal.py). It prints each line as it happens, so a failure later
keeps the report of what went. A compaction start (source `compact`) removes
no unrecorded worktree. WORKTREE_HEAL_SECONDS overrides how long into the heal
a start may still begin a removal.
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

IDLE_SECONDS = 24 * 3600
PARKED_SECONDS = 600
CHECK_SECONDS = 3600
KEEP_SECONDS = 7 * 86400
# The hourly check's stamp, per checkout; its time is the last check's.
CHECK_STAMP = Path(".agents/worktrees/.dead-session-check")
# The operator's "keep" answers: {worktree path: when}.
KEPT = ".kept.json"


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
    entry has no `at`: no process began, so it dates no resume. Nothing is written when the
    record went or gained another stamp since the sweep read it."""
    start = wr.ps.read(mark["host"][0])
    try:
        current = wr.last_host(wr.load(path))
    except FileNotFoundError:
        return  # a session end claimed the record meanwhile
    if isinstance(start, dict) and current == mark:
        wr.append(path.parent, path.stem, [{"type": "host", "host": mark["host"], "start": start}])


def stamped(entry: dict, mark: dict | None) -> dict:
    """The entry under another stamp, its own `start` dropped where that stamp has none."""
    return dict({key: value for key, value in entry.items() if key != "start"}, **(mark or {"host": None}))


def carriers() -> set[int]:
    """This process and the shells and interpreters between it and the session's own process,
    whose working folders say nothing about a worktree being in use."""
    me, rows = wr.host(), wr.chain()
    stop = next((index for index, (pid, _, _) in enumerate(rows) if me and pid == me[0]), len(rows))
    return {pid for pid, _, _ in rows[:stop]} | {os.getpid()}


def close(path: Path, workloop: Path) -> list[str]:
    """Judge one dead session's records: claim the file, remove what is done, flag the rest,
    write back what stays."""
    claimed = path.with_name(f".{path.name}.sweep-{os.getpid()}")
    try:
        os.rename(path, claimed)
    except FileNotFoundError:
        return []  # another sweep claimed it first
    entries = wr.load(claimed)
    mark, end = wr.last_host(entries), wr.ended(entries)
    if not end and mark and wr.alive(mark):
        # Its session resumed between the sweep's look and the claim: give the records back.
        wr.append(path.parent, path.stem, entries)
        claimed.unlink()
        return []
    # After /clear the session's process runs on: only the lock naming this session ends with it.
    remover = rm.Remover(f"session {path.stem}", carriers(), path.stem, rn.lost_files)
    standing = finish(entries, remover, workloop, path, end)
    again = resumed(path)
    # What stays goes back under the session's stamp, still ended unless it resumed meanwhile.
    wr.append(path.parent, path.stem, [stamped(e, again or mark) for e in standing]
              + ([end] if end and standing and not again else []))
    claimed.unlink()
    return remover.lines


def resumed(path: Path):
    """The stamp a resumed session wrote to its record while a sweep held the claim, while its
    process may still run."""
    mark = wr.last_host(wr.load(path)) if path.is_file() else None
    return mark if mark and wr.alive(mark) else None


def source_for(main: Path, recorded: str | None, branch: str | None) -> tuple[str, list[str]]:
    """(Name, refs) of the branch a worktree's work is judged merged against: the source branch
    recorded at its creation or named by its branch's reflog, else its branch's upstream, else
    the default branch (ruling R11)."""
    found = hl.named_source(main, recorded, branch)
    if found:
        return found
    upstream = wr.out(main, "rev-parse", "-q", "--symbolic-full-name", f"refs/heads/{branch}@{{upstream}}") if branch else ""
    if upstream.startswith("refs/"):
        return hl.short(upstream), [upstream]
    defaults = hl.default_refs(main)
    return (hl.short(defaults[0]) if defaults else "the default branch"), defaults


def kept_answers(main: Path) -> dict:
    path = main / wr.RECORDS / KEPT
    try:
        data = json.loads(path.read_text())
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as error:
        wr.warn(f"{path} is unreadable ({error}); every kept worktree is asked about again")
        return {}
    return data if isinstance(data, dict) else {}


class Ask:
    """What a `dead session` line names: the session, and the operator's three answers for one
    worktree. A lane's "save and remove" is the controller's `park`."""

    def __init__(self, session: str, workloop: Path, kept: dict) -> None:
        self.session, self.workloop, self.kept = session, workloop, kept
        self.script = Path(__file__).resolve()

    def answers(self, path: Path, lane: tuple[str, str, str] | None, drops: str) -> str:
        """`lane` is (state file, run, lane) for a lane's worktree; `drops` what discard loses."""
        save = (f"python3 {self.workloop} --state {lane[0]} park {lane[1]} {lane[2]}" if lane
                else f"python3 {self.script} remove {path} --save")
        return (f"keep it (asked again in a week): `python3 {self.script} keep {path}`; save and remove: `{save}`; "
                f"discard ({drops}): `python3 {self.script} remove {path} --discard`")

    def blocked(self, path: Path, why: str) -> str:
        """The line for a worktree the check cannot judge until a step by hand."""
        return (f"kept {path}: {why}; dead session {self.session} left it: resolve that by hand, or keep it with "
                f"`git worktree lock {path}`; to be asked again in a week instead: `python3 {self.script} keep {path}`")

    def asked_lately(self, path: Path) -> bool:
        at = self.kept.get(str(path))
        return isinstance(at, (int, float)) and time.time() - at < KEEP_SECONDS


def drops(path: Path, branch: str | None) -> str:
    """What discarding the worktree does (the operator's ruling of 2026-11-25): its folder goes
    with its uncommitted, untracked and ignored files; its branch stays, with the commits no
    other ref reaches, so `git switch <branch>` brings them back."""
    count = rm.unreferenced(path, "HEAD", branch)
    kept = (f"keeps branch {branch} with its {count} commits in no other ref" if branch
            else f"puts its detached HEAD's {count} commits in no other ref on a saved/ branch")
    return f"removes the folder with its uncommitted, untracked and ignored files; {kept}"


def settle(path: Path, source: tuple[str, list[str]], remover, record: Path, ask: Ask,
           lane: tuple[str, str, str] | None, squash: bool, removable: bool, copy: str | None) -> str:
    """Remove a dead session's worktree whose work is merged into its source branch, with nothing
    uncommitted, untracked or ignored that would not come back; flag any other one. `copy` is
    the commit a review snapshot was made at: a snapshot still there holds only a copy of what
    its checkout holds, so it counts as merged. With `removable` off (a lane of an unfinished
    run, which is not done under ruling R1) nothing is removed: a worktree holding work is
    flagged and an empty one left as it is. A worktree the operator kept is passed over before
    anything is read from it. Returns "removed", "gone", "locked" (a standing decision to keep
    it) or "kept"."""
    path = path.resolve() if path.exists() else path
    if not path.is_dir():
        return "gone"
    if resumed(record):
        remover.lines.append(f"kept {path}: its session resumed during this sweep")
        return "kept"
    main = wr.main_checkout(path)
    listed = wr.worktrees(main) if main else []
    entry = next((item for item in listed[1:] if item["path"] == path), None)
    if entry is None:
        remover.lines.append(f"kept {path}: git lists it as no linked worktree")
        return "kept"
    if entry["locked"] and not rm.claude_lock_ended(entry["locked"], remover.ended_session):
        remover.lines.append(f"kept {path}: it is locked ({entry['locked']})")
        return "locked"
    if ask.asked_lately(path):
        return "kept"
    label, refs = source
    snapshot = copy is not None and wr.out(path, "rev-parse", "-q", "--verify", "HEAD") == copy
    ahead = wr.out(path, "rev-list", "--count", "HEAD", "--not", *refs) if refs else ""
    merged = snapshot or ahead == "0" or bool(entry["branch"] and hl.squashed(path, refs))
    stranded = hl.stranded(path, hl.REFLOG_KEEP_SECONDS, (copy,) if snapshot else ())[0] if merged else None
    why = remover.occupant(path) or rm.inner_worktree(path, listed) or rm.nested(path) or rm.unsaveable(path)
    if why:
        remover.lines.append(ask.blocked(path, why))
        return "kept"
    status = wr.git(path, "--no-optional-locks", "-c", "core.fsmonitor=false", "status", "--porcelain",
                    "--ignore-submodules=none", "--untracked-files=all")
    changed = "an unreadable number of" if status.returncode else str(len(status.stdout.splitlines()))
    lost = hl.unrebuildable(path)
    ignored = lost if isinstance(lost, str) else (", ".join(lost) or "none")
    if merged and changed == "0" and lost == [] and not stranded:
        if not removable:
            return "kept"
        if entry["locked"]:
            wr.git(main, "worktree", "unlock", str(path))
        note = rm.remove(path, main, force=False)
        if note:
            remover.lines.append(f"kept {path}: {note}")
            return "kept"
        remover.lines.append((f"removed {path}: a review snapshot still at the commit it was made at" if snapshot
                              else f"removed {path}: its work is merged into {label}")
                             + rm.drop_branch(main, entry["branch"], refs, squash=squash))
        return "removed"
    remover.lines.append(f"dead session {ask.session} left {path}: {ahead or '?'} commits not in {label}, "
                         f"{changed} uncommitted files, ignored: {ignored}" + (f"; {stranded}" if stranded else "")
                         + f". Ask the operator, then run the answer: {ask.answers(path, lane, drops(path, entry['branch']))}")
    return "kept"


def finish(entries: list[dict], remover, workloop: Path, record: Path, end: dict | None) -> list[dict]:
    """Settle the dead session's runs, then its other worktrees; return the entries still standing.
    Claude Code asks keep-or-remove only for the last worktree entered, and reports the main
    checkout as the cwd after the answer (2.1.299), so only that one reads as kept at `/exit`."""
    main = record.parents[3]  # <main>/.agents/worktrees/.records/<session>.jsonl
    ask, now = Ask(record.stem, workloop, kept_answers(main)), time.time()
    runs = {(e.get("run"), e.get("state")): e for e in entries if e.get("type") == "run"}
    entered = [e["path"] for e in entries if e.get("by") == "EnterWorktree" and e.get("path")]
    remaining, held, settled = [], set(), set()
    # After /clear the session's process runs on, and a reviewer cell it started may still
    # read a review snapshot through absolute paths, which no occupant check sees.
    host_alive = bool((mark := wr.last_host(entries)) and wr.alive(mark))
    for entry in runs.values():
        name, state = entry.get("run"), entry.get("state") or ""
        found, error = rn.runs_of(state)
        if error:
            remover.lines.append(f"kept workloop run {name}: {error}")
            remaining.append(entry)
            held.add(name)
            continue
        run = found.get(name)
        if run is None or run.get("torn_down"):
            continue  # closed elsewhere
        if rn.live_agents(main, run, now):
            remaining.append(entry)
            held.add(name)
            continue
        # Finished or not decides first: an unfinished run is not done (ruling R1), so
        # nothing of it is removed, and only its lanes holding work are flagged.
        why = rn.unfinished(entry, workloop)
        base = run.get("source")
        lanes = {str(Path(lane["workspace"]).resolve()): (lane_name, lane.get("branch"))
                 for lane_name, lane in (run.get("lanes") or {}).items() if lane.get("workspace") and lane.get("place") != "main"}
        pending = False
        for space in rn.workspaces(run):
            space_path = Path(space).resolve() if Path(space).exists() else Path(space)
            lane_name, branch = lanes.get(str(space_path), (None, None))
            outcome = settle(space_path, source_for(wr.main_checkout(space_path) or main, base, branch), remover, record,
                             ask, (state, name, lane_name) if lane_name else None, squash=True, removable=why is None,
                             copy=None)
            settled.add(str(space_path))
            pending = pending or outcome == "kept"
        if resumed(record):
            remover.lines.append(f"kept workloop run {name}: its session resumed during this sweep")
        elif pending:
            pass
        elif why is None:
            # Finished, so it closes as complete: abandon would record it as given up.
            closed, line = rn.close(name, state, workloop, "teardown", "its lead's session ended and its work is finished")
            remover.lines.append(line)
            if closed:
                continue
        elif lane := rn.parked(wr.run_checkout(run.get("repo") or "/nonexistent"), name, run):
            remover.lines.append(f"kept workloop run {name}: lane {lane}'s saved work waits; bring it back with "
                                 f"`python3 {workloop} --state {state} resume {name}`")
        else:
            # Unfinished with no worktree left: the sweep's unowned-run pass closes it.
            continue
        remaining.append(entry)
        held.add(name)
    seen = set(settled)
    for entry in [e for e in entries if e.get("type") == "worktree" and e.get("path")]:
        worktree = Path(entry["path"])
        if str(worktree) in seen or str(worktree.resolve()) in seen:
            continue
        seen.add(str(worktree))
        if entry.get("run") in held:
            continue
        if end and end.get("reason") == "prompt_input_exit" and entered and entry["path"] == entered[-1] \
                and worktree.is_dir() and not lock_of(worktree):
            remover.lines.append(f"kept {worktree}: kept at Claude Code's exit prompt")
            continue
        snapshot = entry.get("by") == "review-snapshot"
        if snapshot and host_alive and worktree.is_dir():
            remaining.append(entry)  # judged again once the session's process is gone
            continue
        where = wr.main_checkout(worktree) if worktree.is_dir() else None
        branch = next((e["branch"] for e in wr.worktrees(where) if e["path"] == worktree.resolve()), None) if where else None
        outcome = settle(worktree, source_for(where or main, entry.get("source"), branch), remover, record, ask, None,
                         squash=False, removable=True, copy=entry.get("head") if snapshot else None)
        if outcome == "kept":
            remaining.append(entry)
    return remaining


def lock_of(path: Path) -> str | None:
    main = wr.main_checkout(path)
    return next((e["locked"] for e in wr.worktrees(main) if e["path"] == path.resolve()), None) if main else None


def end(project: Path, session: str, reason: str) -> None:
    """Mark the session ended in its record; the next hourly check judges what it left."""
    key = wr.session_key(session)
    folder = wr.records_dir(project)
    if key and ((folder / f"{key}.jsonl").is_file() or any(folder.glob(f".{key}.jsonl.*-*"))):
        wr.append(folder, key, [{"type": "end", "reason": reason or "other", "at": int(time.time())}])


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


def due(main: Path) -> bool:
    stamp = main / CHECK_STAMP
    return not stamp.exists() or time.time() - stamp.stat().st_mtime >= CHECK_SECONDS


def check_dead(main: Path, me: str, workloop: Path, emit) -> None:
    """Judge every dead session's records but this session's own, then stamp the hourly check:
    a check that fails part way runs again at the next prompt."""
    folder = main / wr.RECORDS
    for path in sorted(folder.glob("*.jsonl")) if folder.is_dir() else []:
        try:
            entries = wr.load(path)
        except FileNotFoundError:
            continue  # a sweep claimed it since the listing
        if path.stem != me and (wr.ended(entries) or over(entries, path)):
            for line in close(path, workloop):
                emit(line)
    stamp = main / CHECK_STAMP
    stamp.parent.mkdir(parents=True, exist_ok=True)
    stamp.touch()


def leading(folder: Path) -> set:
    """The runs a record names. A claim still standing (its sweep runs, or its record's stamp
    cannot be told) leads too."""
    leads = set()
    for path in [*folder.glob("*.jsonl"), *folder.glob(".*.jsonl.*-*")] if folder.is_dir() else []:
        try:
            leads |= {entry.get("run") for entry in wr.load(path) if entry.get("run")}
        except FileNotFoundError:
            continue  # a session end claimed it, or a sweep gave it back, since the listing
    return leads


def hourly(project: Path, session: str, workloop: Path, emit) -> None:
    """The dead-session check and the unowned runs it leaves, when the hour is up and no other
    sweep holds the repository; one stat of the stamp otherwise."""
    main = wr.main_checkout(project)
    if main is None or not due(main):
        return
    with open(common_dir(main) / "colloid-sweep.lock", "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return  # a session start sweeps meanwhile, and runs the check itself
        if due(main):
            check_dead(main, wr.session_key(session), workloop, emit)
            for line in rn.unowned_runs(main, leading(main / wr.RECORDS), workloop):
                emit(line)


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
    if due(main):
        check_dead(main, me, workloop, emit)
    recorded = set()
    for path in [*folder.glob("*.jsonl"), *folder.glob(".*.jsonl.*-*")] if folder.is_dir() else []:
        try:
            recorded |= {str(Path(e["path"]).resolve()) for e in wr.load(path) if e.get("type") == "worktree" and e.get("path")}
        except FileNotFoundError:
            continue
    for line in rn.unowned_runs(main, leading(folder), workloop):
        emit(line)
    # A run's state may live in any checkout of the repository, so every one's lanes are spared.
    runs = [run for entry in wr.worktrees(main) for run in wr.runs_in(str(entry["path"] / rn.STATE)).values()]
    spared = recorded | {str(Path(space).resolve()) for run in runs for space in rn.workspaces(run)}
    common = common_dir(main)
    save_cache(common, hl.heal(main, spared, load_cache(common), emit, source != "compact", budget))
    stores = rn.ar.real_folders(d / "projects" for d in rn.ar.config_dirs(Path.home(), os.environ.get("CLAUDE_CONFIG_DIR", "")))
    for line in hl.stale_ledgers(main, me, stores):
        emit(line)
    saved = wr.out(main, "for-each-ref", "--format=%(refname:short) %(committerdate:short) %(subject)", "refs/heads/saved/")
    if saved:
        emit("Unsaved work from removed worktrees waits on these branches; merge what is wanted, then delete each branch:")
        for line in saved.splitlines():
            emit(f"  {line}")


def keep(path: Path) -> str:
    """Record the operator's "keep": the check names the worktree again after KEEP_SECONDS."""
    path = path.resolve()
    main = wr.main_checkout(path)
    if main is None:
        raise SystemExit(f"worktree_sweep: {path} is in no repository's checkout")
    folder = main / wr.RECORDS
    folder.mkdir(parents=True, exist_ok=True)
    kept = dict(kept_answers(main), **{str(path): int(time.time())})
    scratch = folder / f"{KEPT}.{os.getpid()}"
    scratch.write_text(json.dumps(kept, sort_keys=True))
    os.replace(scratch, folder / KEPT)
    return f"kept {path}; the hourly check asks about it again after {time.strftime('%Y-%m-%d', time.localtime(time.time() + KEEP_SECONDS))}"


def recorded(main: Path, path: Path) -> tuple[str | None, str | None]:
    """(The source branch a session record gave the worktree at its creation, the session that
    recorded it when that session has ended), each None when no record says."""
    folder = main / wr.RECORDS
    for record in folder.glob("*.jsonl") if folder.is_dir() else []:
        entries = wr.load(record)
        mine = [e for e in entries if e.get("type") == "worktree" and Path(e.get("path", "")).resolve() == path]
        if mine:
            return next((e["source"] for e in mine if e.get("source")), None), record.stem if wr.ended(entries) else None
    return None, None


def run_holding(main: Path, path: Path) -> tuple[str, str, str | None, dict] | None:
    """(State file, run, lane or None, the run) of the workloop run whose worktree `path` is, read
    from every checkout's state file, as the sweep spares them."""
    for checkout in wr.worktrees(main):
        state = str(checkout["path"] / rn.STATE)
        for name, run in wr.runs_in(state).items():
            if run.get("torn_down") or str(path) not in {str(Path(s).resolve()) for s in rn.workspaces(run)}:
                continue
            lane = next((lane_name for lane_name, lane in (run.get("lanes") or {}).items()
                         if lane.get("workspace") and str(Path(lane["workspace"]).resolve()) == str(path)), None)
            return state, name, lane, run
    return None


def remove(path: Path, how: str, workloop: Path) -> list[str]:
    """The operator's answer for a flagged worktree: `--save` commits its unsaved work to
    `saved/<name>` (a detached HEAD no ref reaches too) and removes it, keeping it while ignored
    files or commits only its HEAD log reaches would be lost; `--discard` removes the folder with
    its uncommitted, untracked and ignored files and keeps its branch. Both refuse a lock whose
    holder still runs, and a worktree of a run an agent may still be working for; a lane's save
    is the controller's `park`."""
    path = path.resolve() if path.exists() else path
    main = wr.main_checkout(path) if path.is_dir() else None
    if main is None:
        return [f"{path} is no worktree on disk; nothing was removed"]
    entry = next((item for item in wr.worktrees(main)[1:] if item["path"] == path), None)
    if entry is None:
        return [f"kept {path}: git lists it as no linked worktree"]
    holder = run_holding(main, path)
    if holder:
        state, name, lane, run = holder
        live = rn.live_agents(main, run, time.time())
        if live:
            return [f"kept {path}: workloop run {name}'s agent {live[0]} may still be working; answer once it is back"]
        if lane and how == "--save":
            return [f"kept {path}: it is lane {lane} of workloop run {name}, whose save is "
                    f"`python3 {workloop} --state {state} park {name} {lane}`"]
    source, ended = recorded(main, path)
    refs = source_for(main, source, entry["branch"])[1]
    if how == "--save":
        lost = hl.stranded(path, hl.REFLOG_KEEP_SECONDS, ("HEAD",))[0]
        if lost:
            return [f"kept {path}: {lost}; put them on a branch first, then answer again"]
        remover = rm.Remover("the operator's save-and-remove answer", carriers(), ended, rn.lost_files)
        remover.retire(path, refs)
        return remover.lines
    remover = rm.Remover("the operator's discard answer", carriers(), ended, None)
    if entry["locked"] and not rm.claude_lock_ended(entry["locked"], ended):
        return [f"kept {path}: it is locked ({entry['locked']}); unlock it first if it is to go"]
    refusal = remover.occupant(path) or rm.inner_worktree(path, wr.worktrees(main)) or rm.nested(path)
    if refusal:
        return [f"kept {path}: {refusal}"]
    branch, count = entry["branch"], rm.unreferenced(path, "HEAD", entry["branch"])
    saved = None
    if not branch and count:
        saved, error = rm.saved_branch(path, wr.out(path, "rev-parse", "HEAD"))
        if error:
            return [f"kept {path}: its detached HEAD's {count} commits could not be put on a branch ({error})"]
    removed = wr.git(main, "worktree", "remove", "--force", "--force", str(path))
    if removed.returncode:
        return [f"kept {path}: git refused to remove it ({(removed.stderr or removed.stdout).strip()})"]
    # The operator's ruling of 2026-11-25: discard keeps the branch, so its commits come back
    # with `git switch <branch>`; only the folder's uncommitted, untracked and ignored files go.
    if branch:
        return [f"discarded {path} with its uncommitted, untracked and ignored files; branch {branch} kept with its "
                f"{count} commits in no other ref (`git switch {branch}` brings them back)"]
    return [f"discarded {path} with its uncommitted, untracked and ignored files"
            + (f"; its detached HEAD's {count} commits are on branch {saved}" if saved else "")]


def say(line: str) -> None:
    print(line, flush=True)


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["end"] and len(args) == 4:
        end(Path(args[1]), args[2], args[3])
    elif args[:1] == ["sweep"] and len(args) == 5:
        seconds = os.environ.get("WORKTREE_HEAL_SECONDS") or str(hl.REMOVE_SECONDS)
        sweep(Path(args[1]), args[2], args[3], Path(args[4]), say, float(seconds))
    elif args[:1] == ["check"] and len(args) == 4:
        hourly(Path(args[1]), args[2], Path(args[3]), say)
    elif args[:1] == ["list"] and len(args) == 2:
        for report in listing(Path(args[1])):
            say(report)
    elif args[:1] == ["keep"] and len(args) == 2:
        say(keep(Path(args[1])))
    elif args[:1] == ["remove"] and len(args) == 3 and args[2] in ("--save", "--discard"):
        for report in remove(Path(args[1]), args[2], Path(__file__).resolve().parents[2] / "workloop.py"):
            say(report)
    else:
        sys.exit(__doc__)
