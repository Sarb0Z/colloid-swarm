"""Shared paths: the `share` command, and the rule a brief states for each path.

A shared path has no owner. Without a rebuild command, lanes edit it and Git
merges it at `integrate`; with one, `integrate` takes the path from the base in
every lane merge and runs the command once over the merged tree.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import workloop_git as wg
import workloop_main as wm
from workloop_paths import normalize_path, owning_lane
from workloop_state import (
    ReadStore,
    Store,
    fail,
    rebuild_of,
    record,
    replayed,
    run_of,
    shared_of,
    state_path,
)

MERGED_RULE = ("any lane may edit it. Append only; never restructure or reorder existing lines. Two lanes appending at the "
               "same end of a list still conflict, so add in the middle of a sorted list where the file allows it.")
REBUILT_RULE = ("change it to test in your worktree and commit it with your work; integrate replaces it with the copy "
                "that command rebuilds.")


def shared_lines(run: dict) -> list[str]:
    """The brief's lines for the run's shared paths; none when it shares nothing."""
    paths, rebuild = shared_of(run), rebuild_of(run)
    if not paths:
        return []
    rules = [f"Shared path {path} — rebuilt at integrate by `{rebuild[path]}`: {REBUILT_RULE}" if path in rebuild
             else f"Shared path {path} — merged by Git: {MERGED_RULE}" for path in paths]
    return [f"Shared paths: {', '.join(paths)}", *rules,
            "When a lane you build on is reviewed, rebase onto its branch and resolve shared-path conflicts in your worktree."]


def share_line(run: dict, path: str) -> str:
    """How `status` names a shared path: the path, and its rebuild command when it has one."""
    command = rebuild_of(run).get(path)
    return f"{path} (rebuilt by: {command})" if command else path


def cmd_share(args: argparse.Namespace) -> None:
    """Declare a shared path mid-run, or change how an existing one is handled."""
    path = normalize_path(args.path)
    if args.rebuild:
        # The controller runs it at integrate with no hook watching, so it is
        # judged now and again then, as the verify command is.
        with ReadStore(state_path(args.state)) as data:
            repo = Path(run_of(data, args.run)["repo"])
        wg.guard_command(args.rebuild, repo, "rebuild")
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        if replayed(run, args.event_id): print("replayed event"); return
        if run.get("torn_down"):
            fail(f"run {args.run!r} is torn down; share applies to a live run")
        if not run.get("verify"):
            fail(f"run {args.run!r} declared no --verify, so it holds read-only cells and has no writers to share files between")
        if args.rebuild is not None and wm.main_lane(run):
            fail("a one-writer run merges nothing, so a rebuild command has no moment to run: its lane commits the lockfile it changed")
        owner = owning_lane([path], run["lanes"])
        if owner:
            fail(f"lane {owner!r} owns it: {path} overlaps its owned paths, and a shared path has no owner; share a path no lane owns")
        shared, rebuild = shared_of(run), dict(rebuild_of(run))
        if path in shared and args.rebuild is None:
            print(f"{path} is already shared" + (f", rebuilt by: {rebuild[path]}" if path in rebuild else ""))
            return
        if path in shared and rebuild.get(path) == (args.rebuild or None):
            print(f"{path} is already shared with that rebuild command")
            return
        if path not in shared:
            shared = shared + [path]
        if args.rebuild:
            rebuild[path] = args.rebuild
        else:
            rebuild.pop(path, None)
        run["shared"], run["rebuild"] = shared, rebuild
        record(args.run, run, "share", detail=f"{path}" + (f" rebuilt by {args.rebuild}" if args.rebuild else ""), supplied=args.event_id)
        briefed = [name for name, lane in run["lanes"].items() if lane.get("claimed_by") and lane["state"] != "reviewed"]
    print(f"shared {share_line(run, path)}")
    for name in briefed:
        print(f"brief {args.run} {name}")
