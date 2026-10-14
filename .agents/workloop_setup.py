"""Commands that create a run and give its lanes a worktree: init, add-lane, widen, provision."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import workloop_git as wg
from workloop_paths import normalize_path, overlaps, owned, workspace_for
from workloop_state import (
    ReadStore,
    Store,
    fail,
    lane_of,
    now,
    record,
    replayed,
    require_workspace,
    run_of,
    shared_of,
    state_path,
    valid_name,
)

# The delegation shapes, one line each; the workloop skill holds the full guide.
SHAPES = """Delegation shapes (the workloop skill's guide; choose one before dispatching):
  one writer            the default: one cell edits the main tree, read-only cells around it; no run needed
  read-only fan-out     research, review or QA cells returning text; three by default, about ten for broad research
  parallel slices       one lane per writer on disjoint files that merge in any order; about three writers at most
  contract-first split  commit the interface first, then producer and consumer lanes build against it at once
  bake-off              several attempts at one task, one kept; each is paid in full, so two or three, selection rule first"""


def cmd_init(args: argparse.Namespace) -> None:
    valid_name("run", args.run)
    if args.max_lanes < 1 or args.message_limit < 1:
        fail("max-lanes and message-limit must be positive")
    repo = wg.toplevel(args.repo or Path.cwd())
    base = wg.resolve_commit(repo, args.base)
    if args.verify:
        wg.guard_command(args.verify, repo)
    shared = [normalize_path(path) for path in args.shared or []]
    if len(set(shared)) != len(shared):
        fail("a run cannot declare the same shared path twice")
    with Store(state_path(args.state)) as data:
        if args.run in data["runs"]:
            if replayed(data["runs"][args.run], args.event_id):
                print("replayed event")
                return
            fail(f"run {args.run!r} already exists; init is intentionally not destructive")
        data["runs"][args.run] = {
            "objective": args.objective,
            "acceptance": args.acceptance,
            "verify": args.verify,
            "repo": str(repo),
            "base": base,
            "shared": shared,
            "max_lanes": args.max_lanes,
            "supervised": args.supervised,
            "message_limit": args.message_limit,
            "lanes": {},
            "messages": [],
            "qa": None,
            "integration": None,
            "events": [],
        }
        record(args.run, data["runs"][args.run], "init", detail=args.objective, supplied=args.event_id)
    print(f"created workloop {args.run!r} at {base[:12]} in {repo}")
    print(SHAPES)


def cmd_add_lane(args: argparse.Namespace) -> None:
    valid_name("lane", args.lane)
    paths = [normalize_path(path) for path in args.path]
    if len(set(paths)) != len(paths):
        fail("a lane cannot declare the same path twice")
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        if replayed(run, args.event_id): print("replayed event"); return
        repo = Path(run["repo"])
        base = run["base"]
        workspace = workspace_for(args.workspace, repo, args.run, args.lane, "lane")
        existing = run["lanes"].get(args.lane)
        if existing:
            # A lane whose worktree or install failed is resumed, not refused:
            # the state entry exists but nothing has happened in it yet.
            if existing.get("env") == "ready" or existing["evidence"] or existing.get("claimed_by"):
                fail(f"lane {args.lane!r} already exists")
            if Path(existing["workspace"]) != workspace:
                fail(f"lane {args.lane!r} is pending at {existing['workspace']}; rerun with that workspace")
            print(f"add-lane {args.lane}: resuming a {existing.get('env')} lane", file=sys.stderr)
        else:
            if len(run["lanes"]) >= run["max_lanes"] and not args.allow_more:
                fail(f"run reached its {run['max_lanes']}-lane limit; use --allow-more with a deliberate lead decision")
            dependencies = args.depends_on or []
            unknown = sorted(set(dependencies) - set(run["lanes"]))
            if unknown:
                fail(f"unknown dependency lanes: {', '.join(unknown)}")
            if overlaps(paths, shared_of(run)):
                fail("paths overlap a shared path; lanes edit shared paths without owning them")
            for name, other in run["lanes"].items():
                if overlaps(paths, other["paths"]):
                    fail(f"paths overlap lane {name!r}; writing lanes need exclusive ownership")
            if workspace == repo.resolve():
                fail(f"lane workspace is the main checkout {repo}; a lane needs its own worktree")
            cone, cone_notes = wg.cone_for(repo, base, paths, [normalize_path(path) for path in args.also or []]) if args.sparse else (None, [])
            for note in cone_notes:
                print(f"add-lane {args.lane}: {note}", file=sys.stderr)
            run["lanes"][args.lane] = {
                "worker": args.worker,
                "workspace": str(workspace),
                "branch": None,
                "sparse": cone,
                "paths": paths,
                "depends_on": dependencies,
                "exclusive": sorted(set(args.exclusive or [])),
                "state": "ready",
                "env": "pending",
                "lock_hash": None,
                "evidence": [],
                "review_refs": [],
                "attention": None,
            }
            record(args.run, run, "add-lane", args.lane, ", ".join(paths), args.event_id)
    # The worktree and its install run outside the state lock: an install is
    # minutes, and every other workloop command would otherwise wait on it.
    branch = f"{args.run}/{args.lane}"
    if workspace.exists():
        wg.worktree_root(workspace)
        if not wg.same_repository(workspace, repo) or not wg.is_linked_worktree(workspace):
            fail(f"lane workspace must be a linked worktree of {repo}, not a checkout: {workspace}")
        branch = wg.branch_of(workspace)
        print(f"add-lane {args.lane}: using existing worktree on {branch}", file=sys.stderr)
    else:
        if wg.branch_tip(repo, branch):
            fail(f"branch {branch} already exists in {repo} from an earlier run; delete it or land it, then rerun add-lane")
        cone = (existing or run["lanes"][args.lane]).get("sparse")
        shape = f" sparse to {', '.join(cone)}" if cone else ""
        for entry in cone or []:
            if wg.git(repo, "ls-tree", "--name-only", base, "--", entry) != entry:
                print(f"add-lane {args.lane}: cone directory {entry!r} does not exist at the base; created empty", file=sys.stderr)
        print(f"add-lane {args.lane}: creating worktree {workspace} on {branch} at {base[:12]}{shape}", file=sys.stderr)
        wg.worktree_add(repo, workspace, branch, base, cone)
    print(f"add-lane {args.lane}: provisioning", file=sys.stderr)
    ok, text = wg.provision(workspace, repo)
    lock_hash = wg.lock_hash(workspace) if ok else None
    with Store(state_path(args.state)) as data:
        lane = lane_of(run_of(data, args.run), args.lane)
        lane["branch"] = branch
        lane["env"] = "ready" if ok else "broken"
        lane["env_detail"] = text
        lane["lock_hash"] = lock_hash
        lane["provisioned_at"] = now()
    if not ok:
        print(text, file=sys.stderr)
        fail(f"lane {args.lane!r} exists but its environment is broken; fix it and run: provision {args.run} {args.lane}")
    print(f"added lane {args.lane!r} on {branch}; {text}")


def cmd_widen(args: argparse.Namespace) -> None:
    """Grow a running lane's owned paths, or its sparse cone, without a new lane."""
    paths = list(dict.fromkeys(normalize_path(path) for path in args.path or []))
    also = [normalize_path(path) for path in args.also or []]
    if not paths and not also:
        fail("widen needs --path or --also")
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        if replayed(run, args.event_id): print("replayed event"); return
        lane = lane_of(run, args.lane)
        if overlaps(paths, shared_of(run)):
            fail("paths overlap a shared path; lanes edit shared paths without owning them")
        for name, other in run["lanes"].items():
            if name != args.lane and overlaps(paths, other["paths"]):
                fail(f"paths overlap lane {name!r}; writing lanes need exclusive ownership")
        cone = lane.get("sparse")
        if also and not cone:
            fail(f"lane {args.lane!r} is a full checkout; --also widens a sparse lane's cone only")
        added = [path for path in paths if not owned(path, lane["paths"])]
        gained: list[str] = []
        if cone:
            # The lane's own commits may have created a directory the base lacks.
            workspace = require_workspace(lane)
            wanted = wg.cone_dirs(workspace, "HEAD", paths + also)
            gained = [entry for entry in dict.fromkeys(wanted) if not any(entry == c or entry.startswith(c + "/") for c in cone)]
            if gained:
                wg.sparse_add(workspace, gained)
                lane["sparse"] = sorted(set(cone) | set(gained))
        if not added and not gained:
            print(f"lane {args.lane!r} already covers {', '.join(paths + also)}; nothing changed")
            return
        if added:
            lane["paths"] = [path for path in lane["paths"] if not owned(path, added)] + added
        changes = ([f"owned + {', '.join(added)}"] if added else []) + ([f"cone + {', '.join(gained)}"] if gained else [])
        record(args.run, run, "widen", args.lane, "; ".join(changes), args.event_id)
    print(f"widened lane {args.lane!r}: {'; '.join(changes)}")


def cmd_provision(args: argparse.Namespace) -> None:
    with ReadStore(state_path(args.state)) as data:
        run = run_of(data, args.run)
        lane = lane_of(run, args.lane)
        workspace = require_workspace(lane)
        repo = Path(run["repo"])
    ok, text = wg.provision(workspace, repo)
    lock_hash = wg.lock_hash(workspace) if ok else None
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        lane = lane_of(run, args.lane)
        lane["env"] = "ready" if ok else "broken"
        lane["env_detail"] = text
        lane["lock_hash"] = lock_hash
        lane["provisioned_at"] = now()
        record(args.run, run, "provision", args.lane, lane["env"], args.event_id)
    if not ok:
        print(text, file=sys.stderr)
        fail(f"lane {args.lane!r} environment is broken")
    print(f"lane {args.lane!r} environment ready; {text}")
