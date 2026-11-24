"""Commands that close a run: qa, check, integrate, teardown, abandon, and reap."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import sys
from pathlib import Path

import workloop_cells as wc
import workloop_docker as wd
import workloop_git as wg
import workloop_main as wm
import workloop_resume as wr_resume
from workloop_paths import (
    BRIEF_FOLDER,
    WORKTREES,
    foreign_paths,
    normalize_path,
    source_tip,
    start_point,
    uncommitted_owned,
    workspace_for,
)
from workloop_state import (
    ReadStore,
    Store,
    close_run,
    closed_record,
    fail,
    lane_of,
    now,
    rebuild_steps,
    record,
    refresh_readout,
    replayed,
    run_of,
    shared_of,
    state_path,
)


def cmd_qa(args: argparse.Namespace) -> None:
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        if replayed(run, args.event_id): print("replayed event"); return
        if not run.get("verify"):
            fail(f"run {args.run!r} declared no --verify: a read-only fan-out records no QA, and check {args.run} passes once every cell is back")
        # QA runs beside review: a submitted lane is enough, and the record binds
        # the evidence to each lane's submitted tip (`completion_problems` reads it back).
        unresolved = [name for name, lane in run["lanes"].items() if lane["state"] not in ("review", "reviewed") or lane["attention"]]
        if unresolved:
            fail("QA is blocked by lanes: " + ", ".join(unresolved))
        pending = [message["id"] for message in run["messages"] if message["requires_ack"] and not message.get("acknowledged_at")]
        if pending:
            fail("QA is blocked by unacknowledged peer messages: " + ", ".join(pending))
        if not run["lanes"]:
            fail("QA needs at least one submitted lane")
        run["qa"] = {"at": now(), "evidence": args.evidence, "tips": {name: lane.get("tip") for name, lane in run["lanes"].items()}}
        record(args.run, run, "qa", detail=args.evidence, supplied=args.event_id)
    print(f"recorded QA evidence for {args.run!r}")


def cmd_check(args: argparse.Namespace) -> None:
    with ReadStore(state_path(args.state)) as data:
        closed = closed_record(state_path(args.state), args.run) if args.run not in data["runs"] else None
        if closed:
            # Landing and teardown close a run only once it is complete; abandon closes it as it stands.
            how = json.loads((closed / "state.json").read_text())["closed"]["how"]
            if how == "abandoned":
                fail(f"run {args.run!r} was abandoned unfinished; its record is in {closed}")
            print(f"PASS: {args.run!r} was complete and is closed ({how}); its record is in {closed}")
            return
        run = run_of(data, args.run)
        due = not args.recorded and wm.verification_due(run)
    if due:
        run = run_check(args, run)
    problems = wm.completion_problems(run)
    if problems:
        lines = wm.remedies(args.run, run, problems)
        lines += [f"cell {name} is out: returned {args.run} {name} --result <path|reply> when it comes back, or --failed '<why>'"
                  for name, cell in sorted(wc.cells_of(run).items()) if cell["state"] == "out"]
        if "run:empty" in problems:
            lines.append(f"the run holds no lane or cell: add-cell {args.run} <name> --role research|review|qa --model <model>"
                         + (f", or add-lane {args.run} <lane> --worker <type> --path <owned path>" if run.get("verify") else ""))
        fail("completion is blocked by " + ", ".join(problems) + "".join("\n" + line for line in lines))
    if run.get("verify"):
        print(f"PASS: {args.run!r} has reviewed lanes, a passing composed test and QA evidence")
    else:
        print(f"PASS: {args.run!r} is a read-only fan-out and every cell is back")
    if not run.get("torn_down"):
        print(f"the run is still open; land it on its source branch with: .agents/workloop.py land {args.run}"
              f" (teardown {args.run} closes it without landing)" if run.get("verify") else
              f"the run is still open; close it with: .agents/workloop.py teardown {args.run}")


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


def integrable_branches(run: dict, order: list[str]) -> dict[str, tuple[str, str]]:
    """Each lane's (branch, tip) once it is fit to merge; the first lane that is not stops integrate."""
    repo = Path(run["repo"])
    branches = {}
    for name in order:
        lane = run["lanes"][name]
        branch = lane.get("branch")
        tip = wg.branch_tip(repo, branch) if branch else None
        if tip is None:
            fail(f"lane {name!r} branch {branch!r} no longer exists in {repo}")
        # The start the accepted review read; a lane from before starts were recorded is measured afresh.
        start = lane.get("accepted_start") or start_point(run, name, tip)
        if tip == start or not wg.is_ancestor(repo, start, tip):
            fail(f"lane {name!r} branch {branch} is not ahead of its start {start[:12]}")
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
        # submitted, so its own work is measured again against them: a
        # sibling's file in its diff means it is built on a superseded commit.
        # A path no lane owns was listed for its reviewer at submit.
        elsewhere, _ = foreign_paths(run, name, lane, [normalize_path(path) for path in wg.committed_files(repo, start_point(run, name, tip), tip)])
        if elsewhere:
            fail(f"lane {name!r} changed paths another lane owns: " + ", ".join(elsewhere) + "; rebase it onto the sibling's current branch")
        branches[name] = (branch, tip)
    return branches


def cmd_integrate(args: argparse.Namespace) -> None:
    with run_lock(state_path(args.state), args.run, "integrate"):
        integration = compose(args, args.workspace)
    if integration["result"] != "pass":
        print(integration["tail"], file=sys.stderr)
        fail(f"{'rebuild' if integration.get('failed_at') == 'rebuild' else 'verify'} failed over the composed tree in {integration['workspace']}")
    print(f"PASS: integrated {', '.join(integration['lane_heads'])} in {integration['workspace']}; verify passed over the source branch at {integration['base_head'][:12]}")


@contextlib.contextmanager
def run_lock(state: Path, run_name: str, command: str):
    """Hold the run's integration lock: one integrate or land per run at a time, since both reset one integration worktree."""
    with ReadStore(state) as data:
        repo = Path(run_of(data, run_name)["repo"])
    lock_path = repo / WORKTREES / run_name / BRIEF_FOLDER / "integrate.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    (lock_path.parent / ".gitignore").write_text("*\n")
    with lock_path.open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            fail(f"{command}: another integrate or land holds {run_name!r} ({lock_path}); wait for it to finish")
        yield


def compose(args: argparse.Namespace, workspace_arg: str | None) -> dict:
    """Merge every lane onto the source branch's tip now, run the composed test, record it; return the record.

    The caller holds `run_lock`.
    """
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        if not run.get("verify") and not run["lanes"]:
            fail(f"run {args.run!r} declared no --verify, so it has nothing to merge: a read-only fan-out holds cells only, and check {args.run} passes once every cell is back")
        if not run.get("verify"):
            fail("integrate needs a verify command; re-init the run with --verify '<test command>'")
        if wm.main_lane(run):
            fail(f"a one-writer run has nothing to integrate; land {args.run} runs the composed test at its accepted commit")
        # A QA cell recorded before the merge waits for the merge; a cell out
        # never blocks it. Dropped by exact problem, never by prefix: a lane
        # named `cell` or `qa` has problems that start the same way.
        waiting = {*wc.cell_problems(run), "qa:missing", "qa:stale", *wm.integration_problems(run)}
        blockers = [problem for problem in wm.completion_problems(run) if problem not in waiting]
        if blockers:
            fail("integration is blocked by " + ", ".join(blockers))
        # The source branch as it stands now, not as it stood at init (ruling R2).
        repo, base, verify = Path(run["repo"]), source_tip(run), run["verify"]
        order = wg.topo_order(run["lanes"])
        branches = integrable_branches(run, order)
        # What this merge used: a `share` landing meanwhile makes it stale.
        steps, shared = rebuild_steps(run), list(shared_of(run))
    workspace = workspace_for(workspace_arg, repo, args.run, "integration", "integration")
    taken = {Path(lane["workspace"]).resolve(): name for name, lane in run["lanes"].items()}
    if workspace in taken:
        fail(f"integration workspace is lane {taken[workspace]!r}'s worktree; use a separate path")
    if workspace == repo.resolve() or (workspace.exists() and not wg.is_linked_worktree(workspace)):
        fail(f"integration workspace must be a new path or a linked worktree of {repo}, not a checkout: {workspace}")
    timeout = wg.verify_timeout()
    wg.guard_command(verify, repo, "verify")
    for _, command in steps:
        wg.guard_command(command, repo, "rebuild")
    print(f"integrate: preparing {workspace} at {base[:12]}", file=sys.stderr)
    wg.prepare_integration(repo, workspace, f"{args.run}/integration", base)
    merged: dict[str, str] = {}
    for name in order:
        print(f"integrate: merging {name} ({branches[name][0]})", file=sys.stderr)
        wg.merge_lane(repo, workspace, base, name, branches[name][0], merged, [path for path, _ in steps])
        merged[name] = branches[name][0]
    rebuilt_ok, passed, tail = True, False, ""
    if steps:
        print(f"integrate: rebuilding {', '.join(path for path, _ in steps)}", file=sys.stderr)
        rebuilt_ok, tail = wg.rebuild_all(workspace, steps, timeout)
    if rebuilt_ok:
        print("integrate: provisioning", file=sys.stderr)
        ok, text = wg.provision(workspace, repo)
        if not ok:
            print(text, file=sys.stderr)
            fail("integration workspace could not be provisioned")
        print(f"integrate: running verify: {verify}", file=sys.stderr)
        passed, tail = wg.run_verify(verify, workspace, "verify", timeout)
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        run["integration"] = {
            "at": now(),
            "workspace": str(workspace),
            "head": wg.head_of(workspace),
            "base_head": base,
            "lane_heads": {name: tip for name, (_, tip) in branches.items()},
            "verify": verify,
            "rebuilt": dict(steps),
            "shared": shared,
            "result": "pass" if passed else "fail",
            "tail": tail,
        }
        if not rebuilt_ok:
            run["integration"]["failed_at"] = "rebuild"
        record(args.run, run, "integrate", detail=run["integration"]["result"], supplied=args.event_id)
        return run["integration"]


def release_run(repo: Path, run_name: str, lane_names: list[str], worktrees: dict[str, tuple[str, str | None]],
                integration: dict, head: str, discard: bool) -> tuple[list[str], list[str], list[str], int]:
    """Reap every lane's containers, remove the run's worktrees, delete its merged branches.

    `worktrees` holds the worktree lanes' (workspace, branch); a main lane has
    neither, and only its labelled resources are reaped. A lane worktree's
    uncommitted and untracked work goes to its wip ref first and its
    `.workloop/` folder into the run's; a worktree holding ignored files that
    would not come back (`lost_files`) is kept and named, with its branch.
    Every step records its outcome rather than raising, so a directory an
    operator already deleted by hand, or a branch git refuses to drop, leaves
    a report instead of a run that no command can move forward. A branch whose
    commits `head` does not contain is kept unless `discard` is set.
    Returns (removed worktrees, kept worktrees and branches, errors, docker resources removed).
    """
    removed, kept, errors = [], [], []
    docker_result = wd.reap(run_name, sorted(lane_names))
    errors.extend(docker_result["failed"])
    # The prune is repository-wide: it drops the registration of any worktree
    # whose folder is away (an unmounted disk), so only a run that had a
    # worktree of its own pays that risk.
    if worktrees or integration.get("workspace") or wm.verify_workspace(repo, run_name).exists():
        wg.git(repo, "worktree", "prune", check=False)
    targets = [(name, workspace, branch, f"not merged into {head[:12]}") for name, (workspace, branch) in sorted(worktrees.items())]
    targets.append((None, integration.get("workspace"), f"{run_name}/integration", f"carries the verified composition, not merged into {head[:12]}"))
    targets.append((None, str(wm.verify_workspace(repo, run_name)), None, ""))
    for lane_name, workspace, branch, keep_reason in targets:
        label = f"lane {lane_name}" if lane_name else ("integration" if branch else "verify")
        path = Path(workspace) if workspace else None
        saved = None
        if path is not None and path.is_dir() and wg.is_linked_worktree(path):
            if lane_name:
                gone, line, saved = wr_resume.release_lane(repo, run_name, lane_name, path)
            else:
                lost = wr_resume.keep_reason(path)
                gone, line = (False, f"worktree {path}: {lost}") if lost else (wg.remove_worktree(repo, path), "")
            if gone:
                removed.append(workspace)
            elif line:
                kept.append(line)
                continue
        tip = wg.branch_tip(repo, branch) if branch else None
        if not tip:
            continue
        if saved:
            # The saved work is built on this branch's tip; the pair stays together.
            kept.append(f"branch {branch} (its saved work is on {saved})")
            continue
        if discard or wg.is_ancestor(repo, tip, head):
            reason = wg.delete_branch(repo, branch)
            if reason:
                errors.append(f"{label}: could not delete {branch}: {reason}")
        else:
            kept.append(f"branch {branch} ({keep_reason})")
    # Saved work of a lane parked and never resumed outlives the run; it is named, never dropped.
    for ref in wg.git(repo, "for-each-ref", "--format=%(refname)", f"refs/workloop/{run_name}/", check=False).splitlines():
        if not any(ref in line for line in kept):
            kept.append(f"saved work {ref} (never resumed: git show --stat {ref}; delete it with git update-ref -d {ref})")
    return removed, kept, errors, wd.removed_count(docker_result)


def release_without_checkout(run_name: str, lane_names: list[str], repo: Path,
                             folders: list[str]) -> tuple[list[str], list[str], int]:
    """Release a run whose checkout was deleted and whose branches no surviving checkout holds.

    Only its labelled containers can still be reaped. Every lane and
    integration folder recorded outside the checkout is named: one on disk
    holds the only copy left of its work, and one not on disk may be on a disk
    that is not mounted.
    Returns (lines naming those folders, errors, docker resources removed).
    """
    docker_result = wd.reap(run_name, sorted(lane_names))
    lines = []
    for folder in sorted({folder for folder in folders if folder and not Path(folder).resolve().is_relative_to(repo)}):
        if Path(folder).exists():
            lines.append(f"left folder {folder}: it holds the only copy left of its work; copy out what you need, then delete it")
        else:
            lines.append(f"folder {folder} is not on disk: if it is on a disk that is not mounted, its files are still there")
    return lines, docker_result["failed"], wd.removed_count(docker_result)


def checkout_for_release(args: argparse.Namespace, repo: Path, state: Path, lanes: dict[str, tuple[str, str | None]],
                         integration: dict) -> tuple[Path | None, str | None]:
    """The checkout to release the run through and its HEAD; (None, None) when none survives.

    A checkout git cannot read may be deleted, or on a disk that is not
    mounted, and the session-end sweep runs abandon unattended: only the
    operator's --checkout-gone, once the folder itself is gone, lets the run go.
    A deleted linked worktree leaves its branches and worktree registrations in
    its main checkout, which a surviving folder leads back to.
    """
    head, why = wg.checkout_reading(repo)
    if head is not None:
        if args.checkout_gone:
            fail(f"the run's checkout {repo} is readable; abandon it without --checkout-gone, "
                 "which would leave its worktrees and branches behind")
        return repo, head
    if not args.checkout_gone:
        fail(f"the run's checkout {repo} {why}, so its worktrees and branches cannot be released: "
             "mount or repair it and rerun; if it was deleted, rerun with --checkout-gone")
    if repo.exists():
        fail(f"--checkout-gone needs the checkout gone, and {repo} is still there ({why}): repair it and rerun, "
             "or, if it is no longer the run's checkout, move it away and rerun with --checkout-gone")
    folders = [repo] + [Path(workspace) for workspace, _ in lanes.values() if workspace]
    folders += [Path(integration["workspace"])] if integration.get("workspace") else []
    branches = [branch for _, branch in lanes.values() if branch] + [f"{args.run}/integration"]
    holder = wg.checkout_holding([state.parent, *folders], branches, folders)
    return holder, (wg.head_of(holder) if holder else None)


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
    print(close(args, "torn down", repo, names, lanes, integration, head))


# How a complete run closed, as its record says, and the command that closed it.
CLOSING_COMMANDS = {"torn down": "teardown", "landed": "land"}


def close(args: argparse.Namespace, how: str, repo: Path, names: list[str], lanes: dict[str, tuple[str, str | None]],
          integration: dict, head: str) -> str:
    """Release a complete run's worktrees and containers and move its record to `.closed/`; return the report.

    Shared by teardown and land. The release runs outside the state lock, so
    a cell added or a lane moved meanwhile is caught before the record moves.
    Judged as torn down: the release itself removed the worktrees and merged
    branches the live checks read.
    """
    state, command = state_path(args.state), CLOSING_COMMANDS[how]
    removed, kept, errors, docker_removed = release_run(repo, args.run, names, lanes, integration, head, discard=False)
    with Store(state) as data:
        run = run_of(data, args.run)
        changed = wm.completion_problems(dict(run, torn_down=True))
        if changed:
            fail(f"completion changed while {command} ran: blocked by {', '.join(changed)}; the worktrees and containers are "
                 f"released ({len(removed)} worktree(s) removed) but the run stays open: once that is resolved, close it with abandon {args.run}")
        run["torn_down"] = {"at": now(), "removed": removed, "kept": kept, "errors": errors}
        record(args.run, run, "teardown", detail=f"removed {len(removed)}, kept {len(kept)}, errors {len(errors)}", supplied=args.event_id)
    if errors:
        for line in errors:
            print(line, file=sys.stderr)
        fail(f"{command} finished with errors; the run stays open, rerun after resolving them")
    target = close_run(state, args.run, how, repo / WORKTREES / args.run / BRIEF_FOLDER)
    refresh_readout(state, str(repo))
    return "\n".join([f"removed {len(removed)} worktree(s) and {docker_removed} docker resource(s); the run's record is in {target}",
                      *(f"kept {line}" for line in kept)])


def cmd_abandon(args: argparse.Namespace) -> None:
    """Close a run whose work landed outside integrate, e.g. after main moved on."""
    state = state_path(args.state)
    with ReadStore(state) as data:
        run = run_of(data, args.run)
        repo = Path(run["repo"])
        names = sorted(run["lanes"])
        lanes = {name: (lane["workspace"], lane.get("branch")) for name, lane in wm.worktree_lanes(run).items()}
        integration = run.get("integration") or {}
    holder, head = checkout_for_release(args, repo, state, lanes, integration)
    if holder is not None and head is not None:
        removed, kept, errors, docker_removed = release_run(holder, args.run, names, lanes, integration, head, args.discard_branches)
        through = "" if holder == repo else f"its checkout {repo} is gone; released its worktrees and branches through {holder}: "
        lines = [f"abandoned {args.run!r}: {through}removed {len(removed)} worktree(s) and {docker_removed} docker resource(s)"]
        lines += [f"kept {line}; delete it yourself or rerun with --discard-branches" if line.startswith("branch ") else f"kept {line}"
                  for line in kept]
    else:
        folders = [workspace for workspace, _ in lanes.values()] + [integration.get("workspace")]
        named, errors, docker_removed = release_without_checkout(args.run, names, repo, folders)
        lines = [f"abandoned {args.run!r}: its checkout {repo} is gone, so no worktree or branch was touched; "
                 f"removed {docker_removed} docker resource(s)"]
        lines += ["no branch was deleted: the run's branches went with its checkout"] if args.discard_branches else []
        lines += named
    # A failure leaves the run in state: rerunning abandon retries what is left.
    if errors:
        for line in errors:
            print(line, file=sys.stderr)
        fail(f"abandon finished with errors; run {args.run!r} is still in state, rerun after resolving them")
    # The session-end sweep runs abandon from a hook: no prompt, and the exit
    # code says whether the run closed.
    target = close_run(state, args.run, "abandoned", (holder or repo) / WORKTREES / args.run / BRIEF_FOLDER)
    print("\n".join(lines + [f"the run's record is in {target}"]))


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
