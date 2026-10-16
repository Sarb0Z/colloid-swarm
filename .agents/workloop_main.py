"""Rules for a run's main lane, and what completes a run of either kind.

The lane `init --lane` records is the run's sole lane and works in the checkout
itself: no worktree, branch or install (ruling 31). Its work is the commits
since its first claim that touch its owned or shared paths (ruling 32); a
commit in that range touching other paths too is listed as mixed for the
reviewer and never refused (ruling 34), and another writer's commits are listed,
never refused. `check` verifies it by running the run's composed test in a
short-lived worktree at the lane's accepted commit (ruling 33) and recording the
outcome as the run's `verified`; worktree lanes are verified by `integrate`.
"""

from __future__ import annotations

from pathlib import Path

import workloop_git as wg
from workloop_paths import WORKTREES, lane_allows, normalize_path, owned
from workloop_state import fail, now, shared_of

PLACE = "main"
ENV = "main"
# The verify worktree's leaf under .agents/worktrees/<run>/.
VERIFY_LEAF = "verify"


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


def verify_workspace(repo: Path, run_name: str) -> Path:
    return repo / WORKTREES / run_name / VERIFY_LEAF


def own_commits(run: dict, lane: dict, repo: Path, since: str, until: str) -> tuple[list[tuple[str, list[str], list[str]]], list[str]]:
    """The lane's commits in since..until, oldest first, and the other commits.

    A commit is the lane's when it touches an owned or shared path, or a path
    its review cites: (sha, those paths, the other paths it touches). Other
    paths make it a mixed commit, listed for the reviewer, whoever made it.
    """
    own, others = [], []
    for sha, files in wg.commits_with_files(repo, since, until):
        paths = [normalize_path(path) for path in files]
        allowed = [path for path in paths if lane_allows(run, lane, path)]
        if allowed:
            own.append((sha, allowed, [path for path in paths if path not in allowed]))
        else:
            others.append(sha)
    return own, others


def mixed_line(sha: str, foreign: list[str]) -> str:
    """How a mixed commit is named everywhere: submit's output, the evidence, the reviewer brief."""
    return f"mixed: {sha[:12]} also touches {', '.join(foreign)}"


def rewrite_remedy(run_name: str, lane: dict, repo: Path, head: str, lost: str) -> str:
    """What to do when HEAD no longer contains `lost`: switch back when another local
    branch still holds it, re-submit while the claim's start is still in HEAD's
    history (an amend), else the run can never pass."""
    elsewhere = wg.branches_containing(repo, lost)
    if elsewhere:
        return (f"HEAD {head[:12]} no longer contains {lost[:12]}, which branch {elsewhere[0]} still holds: "
                f"switch back to it (git switch {elsewhere[0]}), then rerun")
    if lane.get("start") and wg.is_ancestor(repo, lane["start"], head):
        return f"HEAD {head[:12]} no longer contains {lost[:12]}; re-submit the lane, then review HEAD"
    return (f"HEAD {head[:12]} does not descend from the lane's start {str(lane.get('start'))[:12]}: the branch was "
            f"rewritten, so the run can never pass; close it with: abandon {run_name}")


def submit_main(run_name: str, run: dict, lane: dict, repo: Path) -> tuple[list[str], list[str], list[dict]]:
    """Set the lane's tip at HEAD; return (its evidence paths, the other commits, the mixed ones)."""
    start, head = lane["start"], wg.head_of(repo)
    if head == start:
        fail(f"the checkout has no commits since the lane's first claim at {start[:12]}; nothing to review")
    if not wg.is_ancestor(repo, start, head):
        fail(rewrite_remedy(run_name, lane, repo, head, start))
    own, others = own_commits(run, lane, repo, start, head)
    if not own:
        fail(f"no commit in {start[:12]}..{head[:12]} touches the lane's paths; nothing to review")
    lane["tip"] = head
    mixed = [{"commit": sha, "paths": foreign, "text": mixed_line(sha, foreign)} for sha, _, foreign in own if foreign]
    return sorted({path for _, paths, _ in own for path in paths}), others, mixed


def lane_work(run: dict, lane: dict, path: str) -> bool:
    """Whether a path is the lane's work after its review: owned or shared. A path
    the review cites is the review report, which the lead commits in this same
    checkout once the review is in, so it never moves the lane."""
    return owned(path, lane["paths"]) or owned(path, shared_of(run))


def moved_since(run: dict, lane: dict, repo: Path, since: str, until: str) -> list[str]:
    """Commits in since..until touching the lane's owned or shared paths."""
    return [sha for sha, files in wg.commits_with_files(repo, since, until)
            if any(lane_work(run, lane, normalize_path(path)) for path in files)]


def uncommitted_work(run: dict, lane: dict, repo: Path) -> list[str]:
    """Dirty owned or shared paths in the checkout."""
    return [path for path in wg.dirty_paths(repo) if lane_work(run, lane, path)]


def review_range(run: dict, lane: dict) -> tuple[str, str, list[str], list[str]] | None:
    """(start, tip, the lane's commits, the mixed lines) for the reviewer brief; None before submit."""
    start, tip = lane.get("start"), lane.get("tip")
    if not start or not tip:
        return None
    own, _ = own_commits(run, lane, Path(run["repo"]), start, tip)
    return start, tip, [sha for sha, _, _ in own], [mixed_line(sha, foreign) for sha, _, foreign in own if foreign]


def live_problems(run: dict, name: str, lane: dict) -> list[str]:
    """What moved in the checkout since the main lane's review was accepted.

    A reviewed main lane is judged against the checkout as a worktree lane is
    against its branch: a commit touching its paths after the accepted tip, a
    rewritten history, or a dirty lane path makes the run stale, for `check`,
    `check --recorded`, teardown and the session end alike.
    """
    if lane["state"] != "reviewed" or not lane.get("accepted_tip"):
        return []
    repo, accepted = Path(run["repo"]), lane["accepted_tip"]
    head = wg.head_of(repo)
    problems = []
    if not wg.is_ancestor(repo, accepted, head):
        problems.append(f"{name}:rewritten")
    elif moved_since(run, lane, repo, accepted, head):
        problems.append(f"{name}:moved-after-review")
    if uncommitted_work(run, lane, repo):
        problems.append(f"{name}:uncommitted")
    return problems


def remedies(run_name: str, run: dict, problems: list[str]) -> list[str]:
    """One sentence per live problem of the main lane, for `check`'s refusal."""
    found = main_lane(run)
    if not found:
        return []
    name, lane = found
    repo = Path(run["repo"])
    lines = []
    if f"{name}:rewritten" in problems:
        lines.append(rewrite_remedy(run_name, lane, repo, wg.head_of(repo), lane["accepted_tip"]))
    if f"{name}:moved-after-review" in problems:
        lines.append(f"the checkout has commits touching the lane's paths after its accepted tip {lane['accepted_tip'][:12]}; re-submit the lane for review")
    if f"{name}:uncommitted" in problems:
        lines.append("the checkout has uncommitted changes in the lane's paths: " + ", ".join(uncommitted_work(run, lane, repo)) + "; commit or discard them")
    return lines


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
    """`check` runs the composed test: only the test and QA stand between the run and completion."""
    if not main_lane(run) or not run.get("verify"):
        return False
    problems = completion_problems(run)
    return any(p.startswith("verified:") for p in problems) and all(p.startswith(("verified:", "qa:")) for p in problems)


def verify_main(run_name: str, run: dict, name: str, lane: dict, repo: Path) -> dict:
    """Run the composed test in a worktree at the lane's accepted commit; return the `verified` record.

    The checkout itself is not the tested tree: other sessions' files and
    edits made while the test runs stay out (ruling 33). The worktree is
    provisioned sharing the checkout's installs, removed after a pass, and
    left for inspection after a failure until the next check, teardown or
    abandon removes it.
    """
    verify, accepted = run["verify"], lane["accepted_tip"]
    wg.guard_command(verify, repo)
    workspace = verify_workspace(repo, run_name)
    if workspace.exists() and not wg.remove_worktree(repo, workspace):
        fail(f"{workspace} exists and is not a worktree of {repo}; move it away, then rerun check")
    # No prune here: it would drop the registration of any worktree whose
    # folder is away (an unmounted disk); the forced add overrides a stale
    # registration at the verify path alone.
    wg.worktree_add_detached(repo, workspace, accepted)
    ok, text = wg.provision(workspace, repo)
    if not ok:
        wg.remove_worktree(repo, workspace)
        fail(f"the verify worktree could not be provisioned: {text}")
    passed, tail = wg.run_verify(verify, workspace)
    if passed:
        wg.remove_worktree(repo, workspace)
    verified = {
        "at": now(),
        "head": accepted,
        "lane_tips": {name: accepted},
        "verify": verify,
        "result": "pass" if passed else "fail",
        "tail": tail,
    }
    # The path is recorded only while the worktree stands: a recorded path to
    # a removed worktree would read, at the start sweep, as a run whose every
    # worktree is gone, and the run would be dropped before its QA.
    if not passed:
        verified["workspace"] = str(workspace)
    return verified


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
    # Every run's composed test runs: a main lane's at its accepted commit by
    # `check`, worktree lanes' over the merged tree by `integrate`, re-run if
    # any lane moved afterwards. A run from before `--verify` was required
    # cannot. After teardown the checkout and the branches move on.
    found = main_lane(run)
    if run["lanes"] and not run.get("verify"):
        problems.append("verify:undeclared")
    elif found:
        if not run.get("torn_down"):
            problems += live_problems(run, *found)
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
