"""Commands that close a run: qa, check, integrate, teardown, abandon, and reap."""

from __future__ import annotations

import argparse
import fcntl
import shutil
import sys
from pathlib import Path

import workloop_docker as wd
import workloop_git as wg
import workloop_main as wm
from workloop_paths import (
    BRIEF_FOLDER,
    WORKTREES,
    normalize_path,
    start_point,
    uncommitted_owned,
    undeclared_paths,
    workspace_for,
)
from workloop_state import (
    ReadStore,
    Store,
    fail,
    lane_of,
    now,
    record,
    replayed,
    run_of,
    state_path,
)


def cmd_qa(args: argparse.Namespace) -> None:
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        if replayed(run, args.event_id): print("replayed event"); return
        unresolved = [name for name, lane in run["lanes"].items() if lane["state"] != "reviewed" or lane["attention"]]
        if unresolved:
            fail("QA is blocked by lanes: " + ", ".join(unresolved))
        pending = [message["id"] for message in run["messages"] if message["requires_ack"] and not message.get("acknowledged_at")]
        if pending:
            fail("QA is blocked by unacknowledged peer messages: " + ", ".join(pending))
        if not run["lanes"]:
            fail("QA needs at least one reviewed lane")
        run["qa"] = {"at": now(), "evidence": args.evidence}
        record(args.run, run, "qa", detail=args.evidence, supplied=args.event_id)
    print(f"recorded QA evidence for {args.run!r}")


def cmd_check(args: argparse.Namespace) -> None:
    with ReadStore(state_path(args.state)) as data:
        run = run_of(data, args.run)
        due = not args.recorded and wm.verification_due(run)
    if due:
        run = run_check(args, run)
    problems = wm.completion_problems(run)
    if problems:
        fail("completion is blocked by " + ", ".join(problems) + "".join("\n" + line for line in wm.remedies(args.run, run, problems)))
    print(f"PASS: {args.run!r} has reviewed lanes, a passing composed test and QA evidence")
    if not run.get("torn_down"):
        print(f"the run is still open; close it with: .agents/workloop.py teardown {args.run}")


def run_check(args: argparse.Namespace, run: dict) -> dict:
    """Run a one-writer run's composed test and record it; return the run as recorded.

    The test runs outside the state lock, as integrate's does: a test is
    minutes, and every other command would otherwise wait on it. One check per
    run at a time: a second would make the same verify worktree.
    """
    name, lane = wm.main_lane(run)
    repo = Path(run["repo"])
    lock_path = repo / WORKTREES / args.run / BRIEF_FOLDER / "check.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            fail(f"check is already running for {args.run!r} (another process holds {lock_path}); wait for it to finish")
        print(f"check: running verify at {lane['accepted_tip'][:12]} in {wm.verify_workspace(repo, args.run)}: {run['verify']}", file=sys.stderr)
        verified = wm.verify_main(args.run, run, name, lane, repo)
        with Store(state_path(args.state)) as data:
            run = run_of(data, args.run)
            run["verified"] = verified
            record(args.run, run, "verify", name, verified["result"], args.event_id)
    if verified["result"] != "pass":
        print(verified["tail"], file=sys.stderr)
        fail(f"verify failed in {verified['workspace']}; the worktree stays for inspection until the next check, teardown or abandon")
    return run


def cmd_integrate(args: argparse.Namespace) -> None:
    with ReadStore(state_path(args.state)) as data:
        run = run_of(data, args.run)
        if not run.get("verify"):
            fail("integrate needs a verify command; re-init the run with --verify '<test command>'")
        if wm.main_lane(run):
            fail(f"a one-writer run has nothing to integrate; check {args.run} runs the composed test in the checkout")
        blockers = [problem for problem in wm.completion_problems(run) if not problem.startswith(("integration:", "qa:"))]
        if blockers:
            fail("integration is blocked by " + ", ".join(blockers))
        repo, base, verify = Path(run["repo"]), run["base"], run["verify"]
        order = wg.topo_order(run["lanes"])
        branches = {}
        for name in order:
            lane = run["lanes"][name]
            branch = lane.get("branch")
            tip = wg.branch_tip(repo, branch) if branch else None
            if tip is None:
                fail(f"lane {name!r} branch {branch!r} no longer exists in {repo}")
            if tip == base or not wg.is_ancestor(repo, base, tip):
                fail(f"lane {name!r} branch {branch} is not ahead of the base {base[:12]}")
            # The branch is what merges; work still sitting uncommitted in the
            # lane's worktree would be verified by nobody.
            lane_workspace = Path(lane["workspace"])
            if lane_workspace.is_dir():
                dirty = uncommitted_owned(run, lane, lane_workspace)
                if dirty:
                    fail(f"lane {name!r} has uncommitted work in its worktree; commit or discard it first: " + ", ".join(dirty))
            if lane.get("accepted_tip") != tip:
                fail(f"lane {name!r} moved after its accepted review; re-submit it for review")
            # Sibling branches may have been amended since this lane was
            # submitted, so its own work is measured again against them.
            stray = undeclared_paths(run, lane, [normalize_path(path) for path in wg.committed_files(repo, start_point(run, name, tip), tip)])
            if stray:
                fail(f"lane {name!r} changed undeclared paths: " + ", ".join(stray) + "; rebase it onto the sibling's current branch")
            branches[name] = (branch, tip)
    workspace = workspace_for(args.workspace, repo, args.run, "integration", "integration")
    taken = {Path(lane["workspace"]).resolve(): name for name, lane in run["lanes"].items()}
    if workspace in taken:
        fail(f"integration workspace is lane {taken[workspace]!r}'s worktree; use a separate path")
    if workspace == repo.resolve() or (workspace.exists() and not wg.is_linked_worktree(workspace)):
        fail(f"integration workspace must be a new path or a linked worktree of {repo}, not a checkout: {workspace}")
    wg.guard_command(verify, repo)
    print(f"integrate: preparing {workspace} at {base[:12]}", file=sys.stderr)
    wg.prepare_integration(repo, workspace, f"{args.run}/integration", base)
    merged: list[str] = []
    for name in order:
        print(f"integrate: merging {name} ({branches[name][0]})", file=sys.stderr)
        wg.merge_lane(workspace, name, branches[name][0], merged)
        merged.append(name)
    print("integrate: provisioning", file=sys.stderr)
    ok, text = wg.provision(workspace, repo)
    if not ok:
        print(text, file=sys.stderr)
        fail("integration workspace could not be provisioned")
    print(f"integrate: running verify: {verify}", file=sys.stderr)
    passed, tail = wg.run_verify(verify, workspace)
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        run["integration"] = {
            "at": now(),
            "workspace": str(workspace),
            "head": wg.head_of(workspace),
            "base_head": base,
            "lane_heads": {name: tip for name, (_, tip) in branches.items()},
            "verify": verify,
            "result": "pass" if passed else "fail",
            "tail": tail,
        }
        record(args.run, run, "integrate", detail=run["integration"]["result"], supplied=args.event_id)
    if not passed:
        print(tail, file=sys.stderr)
        fail(f"verify failed over the composed tree in {workspace}")
    print(f"PASS: integrated {', '.join(order)} in {workspace}; verify passed")


def release_run(repo: Path, run_name: str, lane_names: list[str], worktrees: dict[str, tuple[str, str | None]],
                integration: dict, head: str, discard: bool) -> tuple[list[str], list[str], list[str], int]:
    """Reap every lane's containers, remove the run's worktrees, delete its merged branches.

    `worktrees` holds the worktree lanes' (workspace, branch); a main lane has
    neither, and only its labelled resources are reaped. Every step records its
    outcome rather than raising, so a directory an operator already deleted by
    hand, or a branch git refuses to drop, leaves a report instead of a run
    that no command can move forward. A branch whose commits `head` does not
    contain is kept unless `discard` is set.
    Returns (removed worktrees, kept branches, errors, docker resources removed).
    """
    removed, kept, errors = [], [], []
    docker_result = wd.reap(run_name, sorted(lane_names))
    errors.extend(docker_result["failed"])
    wg.git(repo, "worktree", "prune", check=False)
    targets = [(f"lane {name}", workspace, branch, f"not merged into {head[:12]}") for name, (workspace, branch) in sorted(worktrees.items())]
    targets.append(("integration", integration.get("workspace"), f"{run_name}/integration",
                    "carries the verified composition; land it, then rerun teardown"))
    targets.append(("verify", str(wm.verify_workspace(repo, run_name)), None, ""))
    for label, workspace, branch, keep_reason in targets:
        if workspace and wg.remove_worktree(repo, Path(workspace)):
            removed.append(workspace)
        tip = wg.branch_tip(repo, branch) if branch else None
        if not tip:
            continue
        if discard or wg.is_ancestor(repo, tip, head):
            reason = wg.delete_branch(repo, branch)
            if reason:
                errors.append(f"{label}: could not delete {branch}: {reason}")
        else:
            kept.append(f"{branch} ({keep_reason})")
    run_folder = repo / WORKTREES / run_name
    briefs = run_folder / BRIEF_FOLDER
    if briefs.is_dir():
        shutil.rmtree(briefs)
    if run_folder.is_dir() and not any(run_folder.iterdir()):
        run_folder.rmdir()
    return removed, kept, errors, wd.removed_count(docker_result)


def cmd_teardown(args: argparse.Namespace) -> None:
    with ReadStore(state_path(args.state)) as data:
        run = run_of(data, args.run)
        problems = wm.completion_problems(run)
        if problems:
            fail("teardown waits for completion; blocked by " + ", ".join(problems))
        repo = Path(run["repo"])
        head = wg.head_of(repo)
        names = sorted(run["lanes"])
        lanes = {name: (lane["workspace"], lane.get("branch")) for name, lane in wm.worktree_lanes(run).items()}
        integration = run.get("integration") or {}
    removed, kept, errors, docker_removed = release_run(repo, args.run, names, lanes, integration, head, discard=False)
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        run["torn_down"] = {"at": now(), "removed": removed, "kept": kept, "errors": errors}
        record(args.run, run, "teardown", detail=f"removed {len(removed)}, kept {len(kept)}, errors {len(errors)}", supplied=args.event_id)
    print(f"removed {len(removed)} worktree(s) and {docker_removed} docker resource(s)")
    for line in kept:
        print(f"kept branch {line}")
    if errors:
        for line in errors:
            print(line, file=sys.stderr)
        fail("teardown finished with errors; rerun after resolving them")


def cmd_abandon(args: argparse.Namespace) -> None:
    """Close a run whose work landed outside integrate, e.g. after main moved on."""
    with ReadStore(state_path(args.state)) as data:
        run = run_of(data, args.run)
        repo = Path(run["repo"])
        head = wg.head_of(repo)
        names = sorted(run["lanes"])
        lanes = {name: (lane["workspace"], lane.get("branch")) for name, lane in wm.worktree_lanes(run).items()}
        integration = run.get("integration") or {}
    removed, kept, errors, docker_removed = release_run(repo, args.run, names, lanes, integration, head, args.discard_branches)
    # A failure leaves the run in state: rerunning abandon retries what is left.
    if errors:
        for line in errors:
            print(line, file=sys.stderr)
        fail(f"abandon finished with errors; run {args.run!r} is still in state, rerun after resolving them")
    with Store(state_path(args.state)) as data:
        del data["runs"][args.run]
    print(f"abandoned {args.run!r}: removed {len(removed)} worktree(s) and {docker_removed} docker resource(s)")
    for line in kept:
        print(f"kept branch {line}; delete it yourself or rerun with --discard-branches")


def cmd_reap(args: argparse.Namespace) -> None:
    with ReadStore(state_path(args.state)) as data:
        run = run_of(data, args.run)
        lane_names = sorted(run["lanes"])
        if args.lane:
            lane_of(run, args.lane)
    result = wd.reap(args.run, lane_names, args.lane)
    scope = f"lane {args.lane!r}" if args.lane else f"run {args.run!r}"
    print(f"{scope}: {wd.summary(result)}")
    for line in wd.foreign_orphans():
        print(f"not ours, still running: {line}")
    if result["failed"]:
        raise SystemExit(1)
