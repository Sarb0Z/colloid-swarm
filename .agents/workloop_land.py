"""`land`: put a finished run's work on its source branch in this checkout, verified there, and close it.

A one-writer run's work is on the source branch already: `land` runs the
run's `--verify` at the accepted commit and closes the run. A run with
worktree lanes is composed again on the source branch's tip when that branch
moved since `integrate` (or was never integrated), verified there under the
run's integration lock, and the source branch is fast-forwarded to the
verified commit. Either way the run then closes as `teardown` closes it. A
failing verify refuses and leaves the run open. `land` never pushes: pushing
is an outward action with its own approval.

`prune` deletes closed runs' records on request.
"""

from __future__ import annotations

import argparse
import calendar
import json
import shutil
import sys
import time
from pathlib import Path

import workloop_git as wg
import workloop_main as wm
from workloop_finish import close, compose, run_lock
from workloop_paths import source_branch, source_tip
from workloop_state import Store, closed_root, fail, now, record, run_of, shared_of, state_path


def land_blockers(run: dict) -> list[str]:
    """What keeps the run from landing: every completion problem except a composed test `land` runs itself."""
    own = set(wm.verification_problems(run)) if wm.main_lane(run) else set(wm.integration_problems(run))
    return [problem for problem in wm.completion_problems(run) if problem not in own]


def dirty_touched(repo: Path, paths: list[str]) -> list[str]:
    """Uncommitted changes in the checkout to a path the run touched."""
    return [path for path in wg.dirty_paths(repo) if wg.within(path, paths)]


def cmd_land(args: argparse.Namespace) -> None:
    state = state_path(args.state)
    with Store(state) as data:
        run = run_of(data, args.run)
        if not run.get("verify"):
            fail(f"run {args.run!r} declared no --verify: a read-only fan-out lands nothing; close it with teardown {args.run}")
        source = source_branch(run)
        if not source:
            fail(f"run {args.run!r} was started from a detached commit, so it has no branch to land on; merge its work by hand, then abandon {args.run}")
        repo = Path(run["repo"])
        landed = run.get("landed")
        if landed:
            # The work is on the branch already; only the close failed, so only the close runs again.
            names = sorted(run["lanes"])
            lanes = {name: (lane["workspace"], lane.get("branch")) for name, lane in wm.worktree_lanes(run).items()}
            integration = run.get("integration") or {}
    if landed:
        print(f"{args.run!r} landed on {landed['branch']} at {landed['tip'][:12]} already; closing it")
        print(close(args, "landed", repo, names, lanes, integration, wg.head_of(repo)))
        return
    with Store(state) as data:
        run = run_of(data, args.run)
        blockers = land_blockers(run)
        if blockers:
            fail("land waits for completion; blocked by " + ", ".join(blockers))
        touched = sorted({path for lane in run["lanes"].values() for path in lane["paths"]} | set(shared_of(run)))
    on = wg.current_branch(repo)
    if on != source:
        fail(f"the checkout {repo} is on {on or 'a detached HEAD'}, not the run's source branch {source}; switch to {source}, then rerun land")
    dirty = dirty_touched(repo, touched)
    if dirty:
        fail(f"the checkout has uncommitted changes in paths the run touched: {', '.join(dirty)}; commit or discard them, then rerun land")
    if wm.main_lane(run):
        landed = land_main(args, state, run, repo)
    else:
        landed = land_worktrees(args, state, run, repo, source, touched)
    with Store(state) as data:
        current = run_of(data, args.run)
        current["landed"] = {"at": now(), "branch": source, "tip": landed}
        record(args.run, current, "land", detail=f"{source} at {landed}", supplied=args.event_id)
        names = sorted(current["lanes"])
        lanes = {name: (lane["workspace"], lane.get("branch")) for name, lane in wm.worktree_lanes(current).items()}
        integration = current.get("integration") or {}
    print(f"landed {args.run!r}: {source} is at {landed[:12]}, verified there; nothing was pushed")
    print(close(args, "landed", repo, names, lanes, integration, wg.head_of(repo)))


def land_main(args: argparse.Namespace, state: Path, run: dict, repo: Path) -> str:
    """Run a one-writer run's verify at its accepted commit and record it; return that commit. No merge is made."""
    name, lane = wm.main_lane(run)
    with run_lock(state, args.run, "land"):
        print(f"land: running verify at {lane['accepted_tip'][:12]} in {wm.verify_workspace(repo, args.run)}: {run['verify']}", file=sys.stderr)
        verified = wm.verify_main(args.run, run, name, lane, repo)
        with Store(state) as data:
            current = run_of(data, args.run)
            current["verified"] = verified
            record(args.run, current, "verify", name, verified["result"], args.event_id)
    if verified["result"] != "pass":
        print(verified["tail"], file=sys.stderr)
        fail(f"verify failed at {lane['accepted_tip'][:12]} in {verified['workspace']}; the run stays open")
    return lane["accepted_tip"]


def land_worktrees(args: argparse.Namespace, state: Path, run: dict, repo: Path, source: str, touched: list[str]) -> str:
    """Compose again when the source branch moved, then fast-forward it to the verified commit; return that commit."""
    with run_lock(state, args.run, "land"):
        integration = run.get("integration") or {}
        problems = wm.integration_problems(run)
        if problems:
            print(f"land: {', '.join(problems)}; integrating again on {source} at {source_tip(run)[:12]}", file=sys.stderr)
            integration = compose(args, integration.get("workspace"))
            if integration["result"] != "pass":
                print(integration["tail"], file=sys.stderr)
                fail(f"verify failed over the composed tree on {source}'s tip in {integration['workspace']}; {source} is unchanged and the run stays open")
        head, tip = integration["head"], wg.branch_tip(repo, source)
        if not wg.is_ancestor(repo, tip, head):
            fail(f"{source} moved to {tip[:12]} while land ran; rerun land, which composes on the new tip")
        dirty = dirty_touched(repo, sorted(set(touched) | set(wg.committed_files(repo, tip, head))))
        if dirty:
            fail(f"the checkout has uncommitted changes in paths the merge brings: {', '.join(dirty)}; commit or discard them, then rerun land")
        if tip != head:
            # The checkout may have been switched while the composed test ran;
            # a merge now would move whatever branch is checked out.
            on = wg.current_branch(repo)
            if on != source:
                fail(f"the checkout {repo} was switched to {on or 'a detached HEAD'} while land ran; nothing was merged. "
                     f"Switch back to {source}, then rerun land")
            wg.git(repo, "merge", "--ff-only", "-q", head)
            if wg.branch_tip(repo, source) != head:
                fail(f"{source} is not at the verified commit {head[:12]} after the fast-forward; see git -C {repo} log -1 {source}")
    return head


def stamp_of(value: str) -> float:
    """A `--closed-before` date (`2026-11-25`) or time (`2026-11-25T08:00:00Z`) in seconds, UTC."""
    for layout in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%d"):
        try:
            return float(calendar.timegm(time.strptime(value, layout)))
        except ValueError:
            continue
    fail(f"--closed-before takes a date such as 2026-11-25, or a UTC time such as 2026-11-25T08:00:00Z; got {value!r}")


def cmd_prune(args: argparse.Namespace) -> None:
    """Delete the records of runs closed before a date, from `.agents/worktrees/.closed/`."""
    cutoff = stamp_of(args.closed_before)
    root = closed_root(state_path(args.state))
    removed = []
    for folder in sorted(root.iterdir()) if root.is_dir() else []:
        record_file = folder / "state.json"
        try:
            closed_at = json.loads(record_file.read_text())["closed"]["at"]
        except (OSError, ValueError, KeyError) as error:
            print(f"prune: left {folder}: its state.json is unreadable ({error})", file=sys.stderr)
            continue
        if stamp_of(closed_at) < cutoff:
            shutil.rmtree(folder)
            removed.append(folder.name)
    print(f"pruned {len(removed)} closed run record(s)" + (f": {', '.join(removed)}" if removed else ""))
