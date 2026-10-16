"""Rules for a run's main lane, and what completes a run of either kind.

The lane `init --lane` records is the run's sole lane and works in the checkout
itself: no worktree, branch or install (ruling 31). Its work is the commits
since its first claim that touch its owned or shared paths (ruling 32); another
writer's commits in that range are listed, never refused. `check` verifies it by
running the run's composed test in the checkout and recording the outcome as
the run's `verified`; worktree lanes are verified by `integrate`.
"""

from __future__ import annotations

from pathlib import Path

import workloop_git as wg
from workloop_paths import lane_allows, normalize_path, uncommitted_owned
from workloop_state import fail, now

PLACE = "main"
ENV = "main"


def is_main(lane: dict) -> bool:
    return lane.get("place") == PLACE


def main_lane(run: dict) -> tuple[str, dict] | None:
    return next(((name, lane) for name, lane in run["lanes"].items() if is_main(lane)), None)


def worktree_lanes(run: dict) -> dict[str, dict]:
    return {name: lane for name, lane in run["lanes"].items() if not is_main(lane)}


def new_lane(worker: str, repo: Path, paths: list[str]) -> dict:
    return {
        "worker": worker,
        "place": PLACE,
        "workspace": str(repo),
        "branch": None,
        "sparse": None,
        "paths": paths,
        "depends_on": [],
        "exclusive": [],
        "state": "ready",
        "env": ENV,
        "lock_hash": None,
        "evidence": [],
        "review_refs": [],
        "attention": None,
    }


def commits_with_files(repo: Path, since: str, until: str) -> list[tuple[str, list[str]]]:
    """Each commit in since..until, oldest first, with the paths it changes.

    A merge commit lists no paths: what it brings in is its parents' work.
    """
    out = wg.git(repo, "log", "--reverse", "--format=%x1e%H", "--name-only", f"{since}..{until}", strip=False)
    commits = []
    for chunk in out.split("\x1e"):
        lines = [line for line in chunk.splitlines() if line]
        if lines:
            commits.append((lines[0], sorted(lines[1:])))
    return commits


def tracked_dirty(repo: Path) -> list[str]:
    """Tracked paths with uncommitted changes; untracked files are left out."""
    lines = wg.git(repo, "status", "--porcelain", "--untracked-files=no", strip=False).splitlines()
    return sorted(line[3:] for line in lines if len(line) > 3)


def own_commits(run: dict, lane: dict, repo: Path, since: str, until: str) -> tuple[list[tuple[str, list[str]]], list[str]]:
    """(this lane's commits with the paths of its own they touch, the other commits) in since..until, oldest first.

    A commit is the lane's when it touches an owned or shared path, or a path
    its review cites. One that also touches an undeclared path is refused, by
    hash and paths: the lane committed past its scope, or swept another
    writer's change into its commit.
    """
    own, others = [], []
    for sha, files in commits_with_files(repo, since, until):
        paths = [normalize_path(path) for path in files]
        allowed = [path for path in paths if lane_allows(run, lane, path)]
        if not allowed:
            others.append(sha)
            continue
        foreign = [path for path in paths if path not in allowed]
        if foreign:
            where = "HEAD" if sha == until else "behind HEAD"
            fail(f"commit {sha[:12]} ({where}) touches the lane's paths and undeclared ones: {', '.join(foreign)}. "
                 "Rewrite it with the lane's paths alone (git add -- <path>, never -A), or widen the lane to cover them")
        own.append((sha, allowed))
    return own, others


def submit_main(run_name: str, run: dict, lane: dict, repo: Path) -> tuple[list[str], list[str]]:
    """Set the lane's tip at HEAD; return (its evidence paths, the other writers' commits)."""
    start, head = lane["start"], wg.head_of(repo)
    if head == start:
        fail(f"the checkout has no commits since the lane's first claim at {start[:12]}; nothing to review")
    if not wg.is_ancestor(repo, start, head):
        fail(f"HEAD {head[:12]} does not descend from the lane's start {start[:12]}: the branch was rewritten, "
             f"so the run can never pass; close it with: abandon {run_name}")
    own, others = own_commits(run, lane, repo, start, head)
    if not own:
        fail(f"no commit in {start[:12]}..{head[:12]} touches the lane's paths; nothing to review")
    lane["tip"] = head
    return sorted({path for _, paths in own for path in paths}), others


def accept_main(run_name: str, run: dict, lane: dict, repo: Path) -> str:
    """The tip an accepting review records; refused when the lane's paths moved since submit."""
    tip, head = lane["tip"], wg.head_of(repo)
    if not wg.is_ancestor(repo, tip, head):
        fail(f"HEAD {head[:12]} does not contain the submitted tip {tip[:12]}: the branch was rewritten, "
             f"so the run can never pass; close it with: abandon {run_name}")
    moved = [sha for sha, files in commits_with_files(repo, tip, head)
             if any(lane_allows(run, lane, normalize_path(path)) for path in files)]
    if moved:
        fail(f"the checkout moved past the submitted tip {tip[:12]} with commits touching the lane's paths: "
             f"{', '.join(sha[:12] for sha in moved)}; re-submit the lane for review")
    return tip


def review_range(run: dict, lane: dict) -> tuple[str, str, list[str]] | None:
    """(start, tip, the lane's commits) for the reviewer brief; None before submit."""
    start, tip = lane.get("start"), lane.get("tip")
    if not start or not tip:
        return None
    own, _ = own_commits(run, lane, Path(run["repo"]), start, tip)
    return start, tip, [sha for sha, _ in own]


def verification_problems(run: dict) -> list[str]:
    """Why the recorded `verified` does not settle a one-writer run; empty when it does."""
    name, lane = main_lane(run)
    verified = run.get("verified")
    if not verified:
        return ["verified:missing"]
    problems = []
    if verified["result"] != "pass":
        problems.append("verified:" + verified["result"])
    if verified["verify"] != run["verify"] or verified["lane_tips"] != {name: lane.get("accepted_tip")}:
        problems.append("verified:stale")
    return problems


def verification_due(run: dict) -> bool:
    """`check` runs the composed test: the main lane is reviewed and no pass is current."""
    found = main_lane(run)
    if not found or not run.get("verify"):
        return False
    _, lane = found
    return lane["state"] == "reviewed" and not lane["attention"] and bool(verification_problems(run))


def verify_main(run_name: str, run: dict, name: str, lane: dict, repo: Path) -> dict:
    """Run the composed test in the checkout and return the run's `verified` record.

    HEAD is read before and after: a commit landing while the test runs leaves
    a result that belongs to neither tree, recorded as a failure. Tracked paths
    dirty outside the lane's are noted, not refused: they are another writer's
    unfinished work in the same checkout.
    """
    verify = run["verify"]
    wg.guard_command(verify, repo)
    dirty = uncommitted_owned(run, lane, repo)
    if dirty:
        fail("the checkout has uncommitted changes in the lane's paths: " + ", ".join(dirty)
             + "; commit or discard them, then rerun check")
    head, accepted = wg.head_of(repo), lane["accepted_tip"]
    if not wg.is_ancestor(repo, accepted, head):
        fail(f"HEAD {head[:12]} does not contain the lane's accepted tip {accepted[:12]}: the branch was rewritten, "
             f"so the run can never pass; close it with: abandon {run_name}")
    passed, tail = wg.run_verify(verify, repo)
    after = wg.head_of(repo)
    if after != head:
        passed = False
        tail = f"HEAD moved from {head[:12]} to {after[:12]} while verify ran; the result belongs to neither tree\n{tail}"
    return {
        "at": now(),
        "head": head,
        "lane_tips": {name: accepted},
        "verify": verify,
        "result": "pass" if passed else "fail",
        "tail": tail,
        "dirty": [path for path in tracked_dirty(repo) if not lane_allows(run, lane, path)],
    }


def completion_problems(run: dict) -> list[str]:
    problems = []
    for name, lane in run["lanes"].items():
        if lane["state"] != "reviewed":
            problems.append(f"{name}:{lane['state']}")
        if lane["attention"]:
            problems.append(f"{name}:attention")
        if not lane["evidence"]:
            problems.append(f"{name}:no-evidence")
    pending = [message["id"] for message in run["messages"] if message["requires_ack"] and not message.get("acknowledged_at")]
    if pending:
        problems.append("messages:" + ",".join(pending))
    if not run["qa"]:
        problems.append("qa:missing")
    # Every run's composed test runs: a main lane's in the checkout by `check`,
    # worktree lanes' over the merged tree by `integrate`, re-run if any lane
    # moved afterwards. A run from before `--verify` was required cannot.
    if run["lanes"] and not run.get("verify"):
        problems.append("verify:undeclared")
    elif main_lane(run):
        problems += verification_problems(run)
    elif run["lanes"] and not run.get("torn_down"):
        integration = run.get("integration")
        if not integration:
            problems.append("integration:missing")
        else:
            if integration["result"] != "pass":
                problems.append("integration:" + integration["result"])
            if integration["base_head"] != run["base"]:
                problems.append("integration:base-moved")
            repo = Path(run["repo"])
            for name, lane in run["lanes"].items():
                tip = wg.branch_tip(repo, lane["branch"]) if lane.get("branch") else None
                if tip != integration["lane_heads"].get(name):
                    problems.append(f"integration:stale:{name}")
    return problems
