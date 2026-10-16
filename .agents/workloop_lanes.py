"""Commands that move one lane through its life: claim, heartbeat, submit, review, attention, and the readouts."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import workloop_docker as wd
import workloop_git as wg
import workloop_main as wm
from workloop_paths import (
    BRIEF_FOLDER,
    WORKTREES,
    canonical_reference,
    changed_paths,
    reference_roots,
    review_start,
    start_point,
    uncommitted_owned,
    undeclared_paths,
)
from workloop_state import (
    ReadStore,
    Store,
    fail,
    lane_of,
    now,
    pending_messages,
    record,
    replayed,
    require_workspace,
    run_of,
    shared_of,
    state_path,
)

WORKING_PRACTICE = Path(__file__).resolve().parent / "skills/workloop/working-practice.md"
BRIEF_FILES = {"worker": "BRIEF.md", "reviewer": "BRIEF-reviewer.md", "qa": "BRIEF-qa.md"}
BRIEF_SUFFIXES = {"worker": "", "reviewer": "-reviewer", "qa": "-qa"}
# A main lane's reviewer or QA cell reads the checkout a writer works in; the
# marker makes the parallel-writers gate hold it to reading.
READ_ONLY = "READ-ONLY — this lane works in the checkout itself; read it and write nothing."
MAX_REVIEW_ROUNDS = 4
P2_REFUSAL = "a P2 is filed, not reopened: accept the lane and file the finding"


def cmd_claim(args: argparse.Namespace) -> None:
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        if replayed(run, args.event_id): print("replayed event"); return
        lane = lane_of(run, args.lane)
        if lane["state"] not in {"ready", "reopened"}:
            fail(f"lane is {lane['state']}, not ready to claim")
        blocked = [name for name in lane["depends_on"] if lane_of(run, name)["state"] != "reviewed"]
        if blocked:
            fail(f"dependencies are not reviewed: {', '.join(blocked)}")
        if lane["attention"]:
            fail("lane has unacknowledged attention")
        workspace = require_workspace(lane)
        shared = [name for name, other in run["lanes"].items()
                  if name != args.lane and other["state"] == "active" and other["workspace"] == lane["workspace"]]
        if shared:
            fail("concurrent writing lanes need separate Git worktrees; shared with " + ", ".join(shared))
        # A named exclusive resource is held by one active lane at a time —
        # a browser pool, a device, one shared service that cannot be given
        # a copy per lane. The next lane waits rather than contends.
        held = {name: other for name, other in run["lanes"].items()
                if name != args.lane and other["state"] == "active"
                and set(other.get("exclusive") or []) & set(lane.get("exclusive") or [])}
        if held:
            holders = "; ".join(f"{name} holds {', '.join(sorted(set(other['exclusive']) & set(lane['exclusive'])))}" for name, other in held.items())
            fail(f"exclusive resource in use: {holders}. Claim again when that lane submits or is released.")
        if wm.is_main(lane):
            # The checkout's own install serves the lane; its work is measured
            # from where the checkout stood at the first claim, across reopens.
            lane.setdefault("start", wg.head_of(workspace))
        else:
            # A lane whose lockfiles moved since its install would fail its first
            # test on a missing module and read that as a code defect.
            repair = f"run: .agents/workloop.py provision {args.run} {args.lane}"
            if lane.get("env") != "ready":
                fail(f"lane environment is {lane.get('env')}; {repair}")
            if wg.lock_hash(workspace) != lane.get("lock_hash"):
                fail(f"lockfiles changed since the lane was provisioned; {repair}")
        lane["state"] = "active"
        lane["claimed_by"] = args.agent
        lane["claimed_at"] = now()
        lane["heartbeat_at"] = now()
        record(args.run, run, "claim", args.lane, args.agent, args.event_id)
    print(f"claimed lane {args.lane!r} for {args.agent}")


def cmd_submit(args: argparse.Namespace) -> None:
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        if replayed(run, args.event_id): print("replayed event"); return
        lane = lane_of(run, args.lane)
        # A lane whose work moved after submit, before or after its review was
        # accepted, is re-submitted for a fresh review.
        if lane["state"] not in ("active", "review", "reviewed"):
            fail(f"lane is {lane['state']}, not active")
        if pending_messages(run, args.lane):
            fail("lane has acknowledgement-required peer messages; read inbox and acknowledge them first")
        # Review and integration read the lane branch, so the work has to be
        # on it: an uncommitted tree would merge as nothing and pass.
        workspace = require_workspace(lane)
        dirty = uncommitted_owned(run, lane, workspace)
        if dirty:
            where = "in the checkout" if wm.is_main(lane) else "on the lane branch"
            fail(f"lane has uncommitted changes; commit them {where} first: " + ", ".join(dirty))
        if wm.is_main(lane):
            actual, others = wm.submit_main(args.run, run, lane, workspace)
            for sha in others:
                print(f"submit {args.lane}: commit {sha[:12]} is not this lane's: it touches none of its paths", file=sys.stderr)
        else:
            if wg.head_of(workspace) == run["base"]:
                fail(f"lane branch {lane.get('branch')} has no commits beyond the base; nothing to review")
            actual = changed_paths(lane, start_point(run, args.lane, wg.head_of(workspace)))
            undeclared = undeclared_paths(run, lane, actual)
            if undeclared:
                fail("lane changed undeclared paths: " + ", ".join(undeclared))
        lane["evidence"].append({"at": now(), "text": args.evidence, "paths": actual})
        lane["state"] = "review"
        record(args.run, run, "submit", args.lane, args.evidence, args.event_id)
    print(f"lane {args.lane!r} is ready for final review")


def cmd_review(args: argparse.Namespace) -> None:
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        if replayed(run, args.event_id): print("replayed event"); return
        lane = lane_of(run, args.lane)
        if lane["state"] != "review":
            fail(f"lane is {lane['state']}, not awaiting final review")
        if args.result == "reopen":
            if not args.severity:
                fail("--result reopen needs --severity P0 or P1")
            if args.severity == "P2":
                fail(P2_REFUSAL)
        # A reopen that is resubmitted, or an attention that is acknowledged and
        # resubmitted, each add a submission, so the count covers both paths.
        rounds = len(lane["evidence"])
        if rounds >= MAX_REVIEW_ROUNDS and not args.ruling:
            fail(f"lane has been submitted {rounds} times; review round {rounds} needs the operator's ruling: pass --ruling \"<operator's words>\"")
        reference = canonical_reference(args.reference, reference_roots(run, lane))
        if args.result == "accept":
            repo = Path(run["repo"])
            lane["accepted_tip"] = wm.accept_main(args.run, run, lane, repo) if wm.is_main(lane) else wg.branch_tip(repo, lane["branch"])
            lane["state"] = "reviewed"
        else:
            lane["state"] = "reopened"
            lane["attention"] = {"severity": args.severity, "message": args.message, "reference": reference}
        entry = {"at": now(), "reference": reference, "result": args.result}
        if args.ruling:
            entry["ruling"] = args.ruling
        lane["review_refs"].append(entry)
        record(args.run, run, "review-" + args.result, args.lane, reference, args.event_id)
    print(f"recorded {args.result} review for lane {args.lane!r}")


def cmd_attention(args: argparse.Namespace) -> None:
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        if replayed(run, args.event_id): print("replayed event"); return
        lane = lane_of(run, args.lane)
        if lane["state"] not in {"active", "review", "reopened"}:
            fail(f"lane is {lane['state']}; attention applies only to live work")
        if args.severity == "P2" and lane["state"] == "review":
            fail(P2_REFUSAL)
        reference = canonical_reference(args.reference, reference_roots(run, lane)) if args.reference else ""
        lane["attention"] = {"severity": args.severity, "message": args.message, "reference": reference}
        record(args.run, run, "attention", args.lane, args.severity + ": " + args.message, args.event_id)
    print("\n".join((
        f"WORKLOOP ATTENTION — {args.run}/{args.lane} [{args.severity}]",
        args.message,
        f"Pause this lane if it is a P0 or ownership conflict. Inspect {reference or 'the workloop state'}.",
        f"Acknowledge with: .agents/workloop.py ack {args.run} {args.lane} --agent <agent-id>",
        "This prompt is for the lead to deliver; workloop does not claim to interrupt a provider.",
    )))


def cmd_ack(args: argparse.Namespace) -> None:
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        if replayed(run, args.event_id): print("replayed event"); return
        lane = lane_of(run, args.lane)
        if not lane["attention"]:
            fail("lane has no pending attention")
        lane["attention"] = None
        lane["state"] = "active"
        lane["claimed_by"] = args.agent
        record(args.run, run, "ack", args.lane, args.agent, args.event_id)
    print(f"acknowledged attention for lane {args.lane!r}")


def cmd_release_stale(args: argparse.Namespace) -> None:
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        if replayed(run, args.event_id): print("replayed event"); return
        lane = lane_of(run, args.lane)
        if lane["state"] != "active":
            fail("only an active lane can be released")
        lane["state"] = "reopened"
        lane.pop("claimed_by", None)
        lane.pop("claimed_at", None)
        record(args.run, run, "release-stale", args.lane, args.reason, args.event_id)
        lane_names = sorted(run["lanes"])
    # The worker is gone; what it started in Docker is not.
    result = wd.reap(args.run, lane_names, args.lane)
    print(f"released stale claim for lane {args.lane!r}; {wd.summary(result)}")


def cmd_heartbeat(args: argparse.Namespace) -> None:
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run); lane = lane_of(run, args.lane)
        if lane.get("claimed_by") != args.agent:
            fail("heartbeat requires a lane claimed by this agent")
        # The payload is what separates a slow lane from a dead one: the
        # lead's digest shows it beside the age.
        lane["heartbeat_at"] = now()
        if args.progress:
            lane["progress"] = args.progress
        record(args.run, run, "heartbeat", args.lane, args.progress or args.agent, args.event_id)
    print(f"heartbeat recorded for {args.lane!r}")


def cmd_status(args: argparse.Namespace) -> None:
    with ReadStore(state_path(args.state)) as data:
        run = run_of(data, args.run)
        print(f"workloop {args.run}: {run['objective']}")
        if shared_of(run):
            print(f"shared\t{', '.join(shared_of(run))}")
        for name, lane in sorted(run["lanes"].items()):
            attention = " attention" if lane["attention"] else ""
            pending = len(pending_messages(run, name))
            progress = f"\t{lane['progress']}" if lane.get("progress") else ""
            lease = f"\texclusive={','.join(lane['exclusive'])}" if lane.get("exclusive") else ""
            print(f"{name}\t{lane['state']}{attention}\tpending={pending}\t{lane['worker']}\t{', '.join(lane['paths'])}{lease}{progress}")
        print("qa\t" + (run["qa"]["evidence"] if run["qa"] else "pending"))


def cmd_brief(args: argparse.Namespace) -> None:
    with ReadStore(state_path(args.state)) as data:
        run = run_of(data, args.run)
        lane = lane_of(run, args.lane)
    print(dispatch_prompt(state_path(args.state), args.run, run, args.lane, lane, args.role))


def place_lines(run: dict, run_name: str, lane_name: str, lane: dict, role: str, command: str) -> list[str]:
    """Where the lane works and how it commits: a main lane in the checkout, any other in its worktree."""
    if wm.is_main(lane):
        repo = lane["workspace"]
        found = wm.review_range(run, lane) if role == "reviewer" else None
        return [
            f"Workspace: the checkout {repo}, on its current branch — no worktree; this lane's work is the commits since its first claim that touch its paths.",
            *([f"Diff: {found[0][:12]}..{found[1][:12]} in the checkout; this lane's commits: {', '.join(sha[:12] for sha in found[2])} — build its diff with: git diff {found[0]}..{found[1]} -- {' '.join(lane['paths'] + shared_of(run))}"] if found else []),
            f"Provision: .agents/provision.sh {repo} — a test failure naming a missing module, binary, or runtime version is an environment failure, not a code failure; run this and rerun before touching source.",
            "Commit on the checkout's current branch before submit, staging by path only (git add -- <path>..., never -A, . or commit -a): others may hold uncommitted work in this checkout. Review reads the commits, not the working tree.",
        ]
    return [
        f"Workspace: {lane['workspace']} (branch {lane.get('branch')})",
        *([f"Diff: start point {start} — build this lane's diff with: git diff {start}..{lane.get('branch')}"] if role == "reviewer" and (start := review_start(run, lane_name, lane)) else []),
        *([f"Sparse cone: {', '.join(lane['sparse'])} — files outside it are absent from this worktree, not deleted; ask the lead to widen it ({command} widen {run_name} {lane_name} --also <dir>)"] if lane.get("sparse") else []),
        *(["node_modules here is a link into the checkout this lane branched from. Never install into it: change the lockfile and run provision, which gives this lane its own tree."] if "shared from" in (lane.get("env_detail") or "") else []),
        f"Provision: .agents/provision.sh {lane['workspace']} — a test failure naming a missing module, binary, or runtime version is an environment failure, not a code failure; run this and rerun before touching source.",
        "Commit on the lane branch before submit; review and integration read the branch, not the working tree.",
    ]


def dispatch_prompt(state: Path, run_name: str, run: dict, lane_name: str, lane: dict, role: str) -> str:
    """Write the role's full brief and return the short prompt the lead pastes."""
    command = f".agents/workloop.py --state {state}"
    if wm.is_main(lane):
        brief_file = Path(lane["workspace"]) / WORKTREES / run_name / BRIEF_FOLDER / f"{lane_name}{BRIEF_SUFFIXES[role]}.md"
    else:
        brief_file = require_workspace(lane) / BRIEF_FOLDER / BRIEF_FILES[role]
    brief_file.parent.mkdir(parents=True, exist_ok=True)
    # Ignored in every repository, so a `git add -A` never stages a brief.
    (brief_file.parent / ".gitignore").write_text("*\n")
    supervised = (f"Peer inbox: {command} inbox {run_name} {lane_name} — check it after claim and before every state-changing handoff." if run["supervised"] else "Peer inbox is disabled for this ordinary workloop.")
    header = f"WORKLOOP {role.upper()} BRIEF — {run_name}/{lane_name}"
    opening = [READ_ONLY] if wm.is_main(lane) and role != "worker" else []
    brief_file.write_text("\n".join((
        *opening,
        header,
        f"Objective: {run['objective']}",
        f"Acceptance: {run['acceptance']}",
        f"Owned paths: {', '.join(lane['paths'])}",
        *([f"Shared paths: {', '.join(shared_of(run))}\nShared paths: any lane may edit them. Append only; never restructure or reorder existing lines. Regenerate generated files (for example the API contract and its web types) instead of merging them by hand. When a lane you build on is reviewed, rebase onto its branch and resolve shared-path conflicts in your worktree."] if shared_of(run) else []),
        *place_lines(run, run_name, lane_name, lane, role, command),
        f"Environment: export COLLOID_RUN={run_name} COLLOID_LANE={lane_name} COMPOSE_PROJECT_NAME={wd.project_name(run_name, lane_name)}. Label what only this lane uses with --label colloid.run={run_name} --label colloid.lane={lane_name} (or that compose project name); label what the whole run shares, such as one Postgres, with --label colloid.run={run_name} only. The controller reaps lane-labelled resources when this lane ends and run-labelled ones at teardown; it never touches anything else, including containers a test framework starts with its own labels — leave that framework's reaper on.",
        *([f"Exclusive: {', '.join(lane['exclusive'])} — held while this lane is active and freed at submit; the lead dispatches the next holder, and what you started stays until reap or teardown."] if lane.get("exclusive") else []),
        *([WORKING_PRACTICE.read_text().strip()] if role in {"worker", "qa"} else []),
        f"Progress: {command} heartbeat {run_name} {lane_name} --agent <AGENT_ID> --progress '<what is running, e.g. e2e 12/40>' — a lane that is slow reads as slow, not dead.",
        "Do not edit outside owned or shared paths. Preserve unrelated work. Record executable evidence before handoff.",
        "Commits follow .agents/playbooks/commits.md: split along seams, each one building and passing its checks.",
        supervised,
        f"State: {command} status {run_name}",
        f"Claim: {command} claim {run_name} {lane_name} --agent <AGENT_ID> — use the AGENT_ID your host injected at your start; messages for this lane then reach you between tool calls.",
        f"Worker handoff: {command} submit {run_name} {lane_name} --evidence '<command and observed result>'",
        f"Reviewer handoff: {command} review {run_name} {lane_name} --reference '<canonical-review-path>#<finding>' --result accept",
        "A finding must live in its canonical review report; use --result reopen to require a correction cycle.",
    )) + "\n")
    # The gate that recognises a lane cell reads the header line of the prompt,
    # and a READ-ONLY marker before it outranks the header.
    return "\n".join((*opening, header, f"Read the full brief at {brief_file} before anything else; it holds your scope, your commands and your handoff."))
