"""Saved work and its return: the `wip` ref, `park`, `resume`, and the disk floor.

A lane's uncommitted changes, tracked and untracked, are committed on
`refs/workloop/<run>/<lane>/wip` before any controller command removes its
worktree, built from the lane tip in a scratch index so the worktree's own
index and branch are untouched. `submit`, `review`, `integrate` and `land`
read the lane branch only, so half-done work never reaches review or the
source branch. `resume` re-adds a lane's worktree at its branch tip and puts
the saved tree back as uncommitted changes. Ignored files are the one thing no
ref holds: `lost_files` keeps a worktree that has ones that would not come back.
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
import tempfile
from pathlib import Path

import workloop_git as wg
import workloop_main as wm
from workloop_paths import BRIEF_FOLDER, WORKTREES
from workloop_state import ReadStore, Store, fail, lane_of, now, record, replayed, run_of, state_path

# workloop_state put the hooks' library on the path.
import config  # noqa: E402
import worktree_runs  # noqa: E402

# The save cap the session-end sweep's own save uses.
SAVE_CAP = 200 * 1024 * 1024
DISK_FLOOR_GB = 10
INSTALL_DIRS = ("node_modules", ".venv")


def wip_ref(run_name: str, lane_name: str) -> str:
    return f"refs/workloop/{run_name}/{lane_name}/wip"


def ref_tip(repo: Path, ref: str) -> str | None:
    sha = wg.git(repo, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}", check=False)
    return sha if wg.SHA.fullmatch(sha) else None


def save_wip(repo: Path, workspace: Path, run_name: str, lane_name: str) -> tuple[str | None, str | None]:
    """Commit the worktree's tracked and untracked changes on the lane's wip ref; return (ref, why not).

    (None, None) when nothing is uncommitted. A ref already holding saved work
    is never overwritten: that work was never resumed, and a second save would
    lose it.
    """
    if not wg.dirty_paths(workspace):
        return None, None
    ref = wip_ref(run_name, lane_name)
    if ref_tip(repo, ref):
        return None, f"{ref} already holds saved work that was never resumed; resume the lane, or delete the ref with git update-ref -d {ref}"
    untracked = [name for name in wg.git(workspace, "ls-files", "-z", "--others", "--exclude-standard", strip=False).split("\0") if name]
    size = sum((workspace / name).lstat().st_size for name in untracked if os.path.lexists(workspace / name))
    if size > SAVE_CAP:
        return None, f"{size // 2**20} MB of untracked files exceeds the {SAVE_CAP // 2**20} MB save cap"
    admin = Path(wg.git(workspace, "rev-parse", "--path-format=absolute", "--git-dir"))
    handle, scratch = tempfile.mkstemp(prefix="wip-index.", dir=str(admin))
    os.close(handle)
    env = {"GIT_INDEX_FILE": scratch}
    try:
        shutil.copyfile(admin / "index", scratch)
        # --sparse: a sparse lane's untracked file outside its cone is still its work.
        wg.git(workspace, "add", "-A", "--sparse", env=env)
        tree = wg.git(workspace, "write-tree", env=env)
        head = wg.head_of(workspace)
        commit = wg.git(workspace, "commit-tree", tree, "-p", head, "-m",
                        f"Saved work of lane {run_name}/{lane_name}\n\nUncommitted and untracked changes in {workspace}, "
                        "saved before its worktree was removed; `workloop.py resume` puts them back. Ignored files are not saved.")
    finally:
        os.unlink(scratch)
    wg.git(repo, "update-ref", ref, commit, "")
    return ref, None


def restore_wip(repo: Path, workspace: Path, ref: str) -> None:
    """Write the saved tree over the worktree as uncommitted changes, then drop the ref.

    `git restore` writes the files byte for byte from the ref and leaves the
    index alone, so a file the save took untracked comes back untracked; with
    --no-overlay a tracked file the save had deleted is deleted again. The ref
    goes only after the restore succeeded: a failed one leaves it for the next
    `resume`.
    """
    wg.git(workspace, "restore", f"--source={ref}", "--worktree", "--no-overlay", "--", ".")
    wg.git(repo, "update-ref", "-d", ref)


def keep_reason(workspace: Path) -> str | None:
    """Why removing the worktree would lose what no ref holds; None when nothing would.

    Ignored files that would not come back (`lost_files`), and a nested Git
    repository, which a save records as a bare gitlink, its files nowhere.
    """
    return worktree_runs.lost_files(workspace) or worktree_runs.rm.nested(workspace)


def lane_records(repo: Path, run_name: str, lane_name: str, workspace: Path) -> None:
    """Copy a lane worktree's `.workloop/` folder into the run's own, which outlives the worktree."""
    source = workspace / BRIEF_FOLDER
    if source.is_dir():
        target = repo / WORKTREES / run_name / BRIEF_FOLDER / "lanes" / lane_name
        shutil.copytree(source, target, dirs_exist_ok=True)


def release_lane(repo: Path, run_name: str, lane_name: str, workspace: Path) -> tuple[bool, str, str | None]:
    """Save, copy the records of, and remove one lane worktree; (removed, what happened, the wip ref it saved to)."""
    if not workspace.is_dir():
        return False, f"lane {lane_name}: its worktree {workspace} is not on disk", None
    lost = keep_reason(workspace)
    if lost:
        return False, f"worktree {workspace} of lane {lane_name}: {lost}", None
    ref, why = save_wip(repo, workspace, run_name, lane_name)
    if why:
        return False, f"worktree {workspace} of lane {lane_name}: its uncommitted work was not saved ({why})", None
    lane_records(repo, run_name, lane_name, workspace)
    if not wg.remove_worktree(repo, workspace):
        return False, f"worktree {workspace} of lane {lane_name}: git does not list it as a linked worktree, so it was left in place", ref
    return True, (f"lane {lane_name}: uncommitted work saved on {ref}" if ref else f"lane {lane_name}: nothing uncommitted"), ref


def cmd_park(args: argparse.Namespace) -> None:
    """Save a lane's uncommitted work on its wip ref and remove its worktree; `resume` brings both back."""
    with ReadStore(state_path(args.state)) as data:
        run = run_of(data, args.run)
        lane = lane_of(run, args.lane)
        if wm.is_main(lane):
            fail(f"lane {args.lane!r} works in the checkout itself, which has no worktree to park")
        repo, workspace = Path(run["repo"]), Path(lane["workspace"])
    if not workspace.is_dir():
        fail(f"lane {args.lane!r} has no worktree on disk at {workspace}; resume {args.run} re-adds it")
    removed, line, _ = release_lane(repo, args.run, args.lane, workspace)
    if not removed:
        fail(line)
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        if replayed(run, args.event_id): print("replayed event"); return
        lane_of(run, args.lane)["parked"] = {"at": now(), "wip": ref_tip(repo, wip_ref(args.run, args.lane)) and wip_ref(args.run, args.lane)}
        record(args.run, run, "park", args.lane, line, args.event_id)
    print(f"parked lane {args.lane!r}: {line}; worktree {workspace} removed. Bring it back with: resume {args.run}")


def du_bytes(paths: list[Path]) -> int:
    """Bytes on disk under `paths`, links not followed; a path not on disk counts nothing."""
    present = [str(path) for path in paths if path.exists()]
    if not present:
        return 0
    out = wg.run_text(["du", "-sk", *present])
    return sum(int(line.split()[0]) for line in out.splitlines() if line.split()[:1] and line.split()[0].isdigit()) * 1024


def gb(value: int) -> str:
    return f"{value / 2**30:.1f} GB"


def disk_floor_gb(repo: Path) -> float:
    """`workloop.disk_floor_gb` from the checkout's policy and config; DISK_FLOOR_GB when neither states it.

    WORKLOOP_DISK_FLOOR_GB overrides both for one process, as WORKLOOP_VERIFY_TIMEOUT
    does the verify budget: a test suite pins it so its result does not hang on
    the machine's free space.
    """
    override = os.environ.get("WORKLOOP_DISK_FLOOR_GB")
    if override is not None:
        try:
            raw = float(override)
        except ValueError:
            fail(f"WORKLOOP_DISK_FLOOR_GB must be a number of gigabytes, 0 or more; got {override!r}")
    else:
        raw = config.read(config.load(str(repo / ".agents/config.json")), "workloop.disk_floor_gb", DISK_FLOOR_GB)
    if isinstance(raw, bool) or not isinstance(raw, (int, float)) or raw < 0:
        fail(f"workloop.disk_floor_gb must be a number of gigabytes, 0 or more; got {raw!r}")
    return float(raw)


def disk_report(repo: Path, run: dict) -> tuple[int, int, int]:
    """(free bytes, bytes in the run's worktrees, bytes of the checkout's installs a new lane may copy)."""
    free = shutil.disk_usage(repo).free
    spaces = [Path(lane["workspace"]) for lane in wm.worktree_lanes(run).values()]
    return free, du_bytes(spaces), du_bytes([repo / name for name in INSTALL_DIRS])


def worktree_lines(repo: Path, busy: dict[Path, str]) -> list[str]:
    """One line per linked worktree of the checkout, with its size: kept when removing it would lose
    ignored files (`lost_files`, which are named), in use when `busy` names its active lane, else droppable."""
    lines = []
    for line in wg.git(repo, "worktree", "list", "--porcelain").splitlines():
        path = Path(line.removeprefix("worktree ")).resolve()
        if not line.startswith("worktree ") or path == repo.resolve() or not path.is_dir():
            continue
        lost = keep_reason(path)
        verdict = f"kept, {lost}" if lost else f"in use by active lane {busy[path]}" if path in busy else "could be dropped"
        lines.append(f"{path} ({gb(du_bytes([path]))}): {verdict}")
    return lines


def busy_worktrees(state: Path) -> dict[Path, str]:
    """The worktree of each active lane in every live run of the state file, with its `<run>/<lane>`."""
    with ReadStore(state) as data:
        return {Path(lane["workspace"]).resolve(): f"{run_name}/{name}" for run_name, run in data["runs"].items()
                for name, lane in run["lanes"].items() if lane.get("state") == "active" and not wm.is_main(lane)}


def floor_check(state: Path, repo: Path, run: dict, refuse: bool) -> None:
    """Print free space and the run's worktree sizes; with `refuse`, fail under the disk floor, naming what could go."""
    free, used, installs = disk_report(repo, run)
    floor = disk_floor_gb(repo)
    print(f"disk: {gb(free)} free; this run's worktrees hold {gb(used)}; a new lane's install may take {gb(installs)}; floor {floor:g} GB",
          file=sys.stderr)
    if refuse and free - installs < floor * 2**30:
        listed = worktree_lines(repo, busy_worktrees(state))
        fail(f"free space less the checkout's installs ({gb(free - installs)}) is under workloop.disk_floor_gb ({floor:g} GB); "
             "free space, or drop an idle worktree (park <run> <lane> or abandon <run>):"
             + "".join(f"\n  {line}" for line in listed) + ("" if listed else "\n  no worktree to drop"))


def cmd_resume(args: argparse.Namespace) -> None:
    """Re-add each lane worktree that is gone, at its branch tip, reprovision it, and restore its saved work."""
    state = state_path(args.state)
    with ReadStore(state) as data:
        run = run_of(data, args.run)
        repo = Path(run["repo"])
        lanes = {name: dict(lane) for name, lane in wm.worktree_lanes(run).items()}
    floor_check(state, repo, run, refuse=False)
    lines, restored = [], {}
    for name, lane in sorted(lanes.items()):
        workspace, branch = Path(lane["workspace"]), lane.get("branch")
        ref = wip_ref(args.run, name)
        saved = ref_tip(repo, ref)
        if workspace.is_dir():
            # A restore that failed after the worktree came back left its ref:
            # it is restored again while the worktree still sits on the commit
            # the save was built on, so later work there is never overwritten.
            if saved and wg.head_of(workspace) == wg.git(repo, "rev-parse", f"{saved}^"):
                restore_wip(repo, workspace, ref)
                lines.append(f"lane {name}: saved work restored as uncommitted changes into its worktree {workspace}")
            elif saved:
                lines.append(f"lane {name}: {ref} holds saved work, but its worktree moved past the commit it was saved on; "
                             f"look with git -C {workspace} diff HEAD {ref}, then delete it with git update-ref -d {ref}")
            continue
        if lane["state"] == "reviewed":
            lines.append(f"lane {name}: reviewed; integrate and land read its branch, so it needs no worktree")
            continue
        if not branch or not wg.branch_tip(repo, branch):
            lines.append(f"lane {name}: branch {branch} is gone, merged and deleted; nothing to resume (landed)")
            continue
        wg.worktree_readd(repo, workspace, branch, lane.get("sparse"))
        ok, text = wg.provision(workspace, repo)
        if saved:
            restore_wip(repo, workspace, ref)
        restored[name] = (ok, text, wg.lock_hash(workspace) if ok else None)
        lines.append(f"lane {name}: worktree {workspace} at {branch}" + ("; saved work restored as uncommitted changes" if saved else "")
                     + ("" if ok else f"; its environment is broken: {text}"))
    with Store(state) as data:
        run = run_of(data, args.run)
        if replayed(run, args.event_id): print("replayed event"); return
        for name, (ok, text, lock_hash) in restored.items():
            lane = lane_of(run, name)
            lane.update(env="ready" if ok else "broken", env_detail=text, lock_hash=lock_hash, provisioned_at=now())
            lane.pop("parked", None)
        record(args.run, run, "resume", detail="; ".join(lines) or "nothing to resume", supplied=args.event_id)
    print("\n".join(lines) if lines else f"run {args.run!r}: every lane worktree is on disk; nothing to resume")
