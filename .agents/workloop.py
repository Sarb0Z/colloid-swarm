#!/usr/bin/env python3
"""Durable, provider-neutral coordination for bounded parallel agent work."""

from __future__ import annotations

import argparse
import calendar
import fcntl
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_STATE = ROOT / ".agents/.workloop-state.json"
LANE_STATES = {"ready", "active", "reopened", "reviewed", "blocked"}


def fail(message: str) -> None:
    raise SystemExit(f"workloop: {message}")


def now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def state_path(value: str | None) -> Path:
    return Path(value).resolve() if value else DEFAULT_STATE


def normalize_path(value: str) -> str:
    path = PurePosixPath(value)
    if not value or path.is_absolute() or ".." in path.parts or str(path) == ".":
        fail(f"path must be a repository-relative file or directory: {value!r}")
    return str(path).rstrip("/")


def owned(path: str, declared: list[str]) -> bool:
    return any(path == root or path.startswith(root + "/") for root in declared)


def overlaps(left: list[str], right: list[str]) -> bool:
    return any(owned(path, right) for path in left) or any(owned(path, left) for path in right)


def canonical_reference(value: str, workspace: Path) -> str:
    file_name, separator, anchor = value.partition("#")
    normalized = normalize_path(file_name)
    candidate = (workspace / normalized).resolve()
    try:
        candidate.relative_to(workspace.resolve())
    except ValueError:
        fail(f"review reference escapes the repository: {value!r}")
    if not candidate.is_file():
        fail(f"review reference must name an existing repository file: {value!r}")
    return normalized + ("#" + anchor if separator else "")


def event_id(run: str, action: str, lane: str, detail: str) -> str:
    raw = "\0".join((run, action, lane, detail, now(), str(time.time_ns())))
    return hashlib.sha256(raw.encode()).hexdigest()[:16]


class Store:
    def __init__(self, path: Path):
        self.path = path
        self.lock_path = path.with_suffix(path.suffix + ".lock")

    def __enter__(self) -> dict:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.lock = self.lock_path.open("a+")
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        if not self.path.exists():
            self.data = {"version": 1, "runs": {}}
        else:
            try:
                self.data = json.loads(self.path.read_text())
            except json.JSONDecodeError as exc:
                fail(f"state is invalid JSON: {exc}")
        if self.data.get("version") != 1 or not isinstance(self.data.get("runs"), dict):
            fail("state has an unsupported schema")
        return self.data

    def __exit__(self, *_: object) -> None:
        fd, temporary = tempfile.mkstemp(prefix=self.path.name + ".", dir=self.path.parent)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(self.data, stream, indent=2, sort_keys=True)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
            fcntl.flock(self.lock, fcntl.LOCK_UN)
            self.lock.close()


class ReadStore:
    """Shared-locked state reader that never touches the ledger or lock file."""
    def __init__(self, path: Path): self.path = path
    def __enter__(self) -> dict:
        if not self.path.is_file(): fail("state file does not exist")
        lock_path = self.path.with_suffix(self.path.suffix + ".lock")
        if not lock_path.is_file(): fail("state lock is missing; use a mutating workloop command to recover it")
        self.lock = lock_path.open("r")
        fcntl.flock(self.lock, fcntl.LOCK_SH)
        self.data = json.loads(self.path.read_text())
        if self.data.get("version") != 1 or not isinstance(self.data.get("runs"), dict): fail("state has an unsupported schema")
        return self.data
    def __exit__(self, *_: object) -> None:
        fcntl.flock(self.lock, fcntl.LOCK_UN); self.lock.close()


def run_of(data: dict, name: str) -> dict:
    run = data["runs"].get(name)
    if run is None:
        fail(f"no run named {name!r}; create it with init")
    return run


def lane_of(run: dict, name: str) -> dict:
    lane = run["lanes"].get(name)
    if lane is None:
        fail(f"run has no lane named {name!r}")
    return lane


def replayed(run: dict, supplied: str | None) -> bool:
    return bool(supplied and any(event["id"] == supplied for event in run["events"]))


def record(run_name: str, run: dict, action: str, lane: str = "", detail: str = "", supplied: str | None = None) -> None:
    key = supplied or event_id(run_name, action, lane, detail)
    run["events"].append({"id": key, "at": now(), "action": action, "lane": lane, "detail": detail})


def require_workspace(lane: dict) -> Path:
    workspace = Path(lane["workspace"])
    if not workspace.is_dir():
        fail(f"lane workspace is missing: {workspace}")
    try:
        top = subprocess.check_output(
            ["git", "-C", str(workspace), "rev-parse", "--show-toplevel"], text=True
        ).strip()
    except subprocess.CalledProcessError:
        fail(f"lane workspace is not a Git worktree: {workspace}")
    if Path(top).resolve() != workspace.resolve():
        fail(f"lane workspace must be the worktree root: {workspace}")
    return workspace


def changed_paths(lane: dict, base: str) -> list[str]:
    workspace = require_workspace(lane)
    commands = (
        ["git", "-C", str(workspace), "diff", "--name-only", base],
        ["git", "-C", str(workspace), "ls-files", "--others", "--exclude-standard"],
    )
    seen: set[str] = set()
    for command in commands:
        try:
            output = subprocess.check_output(command, text=True, stderr=subprocess.STDOUT)
        except subprocess.CalledProcessError as exc:
            fail(f"cannot inspect lane diff against {base}: {exc.output.strip()}")
        seen.update(normalize_path(line) for line in output.splitlines() if line)
    return sorted(seen)


def pending_messages(run: dict, lane: str) -> list[dict]:
    return [message for message in run["messages"] if message["to"] == lane and message["requires_ack"] and not message.get("acknowledged_at")]


def parse_stamp(value: str) -> float:
    return float(calendar.timegm(time.strptime(value, "%Y-%m-%dT%H:%M:%SZ")))


def cmd_init(args: argparse.Namespace) -> None:
    if args.max_lanes < 1 or args.message_limit < 1:
        fail("max-lanes and message-limit must be positive")
    with Store(state_path(args.state)) as data:
        if args.run in data["runs"]:
            if replayed(data["runs"][args.run], args.event_id):
                print("replayed event")
                return
            fail(f"run {args.run!r} already exists; init is intentionally not destructive")
        data["runs"][args.run] = {
            "objective": args.objective,
            "acceptance": args.acceptance,
            "base": args.base,
            "max_lanes": args.max_lanes,
            "supervised": args.supervised,
            "message_limit": args.message_limit,
            "lanes": {},
            "messages": [],
            "qa": None,
            "events": [],
        }
        record(args.run, data["runs"][args.run], "init", detail=args.objective, supplied=args.event_id)
    print(f"created workloop {args.run!r}")


def cmd_add_lane(args: argparse.Namespace) -> None:
    paths = [normalize_path(path) for path in args.path]
    if len(set(paths)) != len(paths):
        fail("a lane cannot declare the same path twice")
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        if replayed(run, args.event_id): print("replayed event"); return
        if args.lane in run["lanes"]:
            fail(f"lane {args.lane!r} already exists")
        if len(run["lanes"]) >= run["max_lanes"] and not args.allow_more:
            fail(f"run reached its {run['max_lanes']}-lane limit; use --allow-more with a deliberate lead decision")
        dependencies = args.depends_on or []
        unknown = sorted(set(dependencies) - set(run["lanes"]))
        if unknown:
            fail(f"unknown dependency lanes: {', '.join(unknown)}")
        for name, existing in run["lanes"].items():
            if overlaps(paths, existing["paths"]):
                fail(f"paths overlap lane {name!r}; writing lanes need exclusive ownership")
        workspace = str(Path(args.workspace).resolve())
        run["lanes"][args.lane] = {
            "worker": args.worker,
            "workspace": workspace,
            "paths": paths,
            "depends_on": dependencies,
            "state": "ready",
            "evidence": [],
            "review_refs": [],
            "attention": None,
        }
        record(args.run, run, "add-lane", args.lane, ", ".join(paths), args.event_id)
    print(f"added lane {args.lane!r}")


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
        require_workspace(lane)
        shared = [name for name, other in run["lanes"].items()
                  if name != args.lane and other["state"] == "active" and other["workspace"] == lane["workspace"]]
        if shared:
            fail("concurrent writing lanes need separate Git worktrees; shared with " + ", ".join(shared))
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
        if lane["state"] != "active":
            fail(f"lane is {lane['state']}, not active")
        if pending_messages(run, args.lane):
            fail("lane has acknowledgement-required peer messages; read inbox and acknowledge them first")
        actual = changed_paths(lane, run["base"])
        review_paths = {item["reference"].partition("#")[0] for item in lane["review_refs"]}
        undeclared = [path for path in actual if not owned(path, lane["paths"]) and path not in review_paths]
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
        reference = canonical_reference(args.reference, require_workspace(lane))
        if args.result == "accept":
            lane["state"] = "reviewed"
        else:
            lane["state"] = "reopened"
            lane["attention"] = {"severity": args.severity, "message": args.message, "reference": reference}
        lane["review_refs"].append({"at": now(), "reference": reference, "result": args.result})
        record(args.run, run, "review-" + args.result, args.lane, reference, args.event_id)
    print(f"recorded {args.result} review for lane {args.lane!r}")


def cmd_attention(args: argparse.Namespace) -> None:
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        if replayed(run, args.event_id): print("replayed event"); return
        lane = lane_of(run, args.lane)
        if lane["state"] not in {"active", "review", "reopened"}:
            fail(f"lane is {lane['state']}; attention applies only to live work")
        reference = canonical_reference(args.reference, require_workspace(lane)) if args.reference else ""
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
    print(f"released stale claim for lane {args.lane!r}")


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
        if problems:
            fail("completion is blocked by " + ", ".join(problems))
    print(f"PASS: {args.run!r} has reviewed lanes and QA evidence")


def cmd_brief(args: argparse.Namespace) -> None:
    with ReadStore(state_path(args.state)) as data:
        run = run_of(data, args.run)
        lane = lane_of(run, args.lane)
    command = f".agents/workloop.py --state {state_path(args.state)}"
    supervised = (f"Peer inbox: {command} inbox {args.run} {args.lane} — check it after claim and before every state-changing handoff." if run["supervised"] else "Peer inbox is disabled for this ordinary workloop.")
    print("\n".join((
        f"WORKLOOP {args.role.upper()} BRIEF — {args.run}/{args.lane}",
        f"Objective: {run['objective']}",
        f"Acceptance: {run['acceptance']}",
        f"Owned paths: {', '.join(lane['paths'])}",
        f"Workspace: {lane['workspace']}",
        "Do not edit outside owned paths. Preserve unrelated work. Record executable evidence before handoff.",
        supervised,
        f"State: {command} status {args.run}",
        f"Worker handoff: {command} submit {args.run} {args.lane} --evidence '<command and observed result>'",
        f"Reviewer handoff: {command} review {args.run} {args.lane} --reference '<canonical-review-path>#<finding>' --result accept",
        "A finding must live in its canonical review report; use --result reopen to require a correction cycle.",
    )))


def cmd_status(args: argparse.Namespace) -> None:
    with ReadStore(state_path(args.state)) as data:
        run = run_of(data, args.run)
        print(f"workloop {args.run}: {run['objective']}")
        for name, lane in sorted(run["lanes"].items()):
            attention = " attention" if lane["attention"] else ""
            pending = len(pending_messages(run, name))
            print(f"{name}\t{lane['state']}{attention}\tpending={pending}\t{lane['worker']}\t{', '.join(lane['paths'])}")
        print("qa\t" + (run["qa"]["evidence"] if run["qa"] else "pending"))


def cmd_send(args: argparse.Namespace) -> None:
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        if not run["supervised"]:
            fail("peer messages require init --supervised; ordinary workloops stay unchanged")
        if replayed(run, args.event_id): print("replayed event"); return
        sender = lane_of(run, args.from_lane)
        recipient = lane_of(run, args.to_lane)
        if args.from_lane == args.to_lane:
            fail("a lane cannot send a peer message to itself")
        if sender.get("claimed_by") != args.agent:
            fail("sender agent must be the current claimant of the sender lane")
        if recipient["state"] == "reviewed":
            fail("cannot send a peer message to a reviewed lane")
        if len(run["messages"]) >= run["message_limit"]:
            fail(f"message limit {run['message_limit']} reached; archive or complete the run before adding more")
        reference = canonical_reference(args.reference, require_workspace(sender)) if args.reference else ""
        key = args.event_id or event_id(args.run, "message", args.to_lane, args.message)
        run["messages"].append({"id": key, "at": now(), "from": args.from_lane, "to": args.to_lane,
                                "agent": args.agent, "kind": args.kind, "message": args.message,
                                "reference": reference, "requires_ack": args.requires_ack})
        record(args.run, run, "message-" + args.kind, args.to_lane, key)
    print(f"sent {key} to lane {args.to_lane!r}")


def cmd_inbox(args: argparse.Namespace) -> None:
    with ReadStore(state_path(args.state)) as data:
        run = run_of(data, args.run)
        lane_of(run, args.lane)
        messages = [message for message in run["messages"] if message["to"] == args.lane and not message.get("acknowledged_at")]
    for message in messages:
        print(f"{message['id']}\tfrom={message['from']}\tkind={message['kind']}\tack={message['requires_ack']}\t{message['message']}\t{message['reference']}")
    if not messages:
        print("inbox empty")


def cmd_ack_message(args: argparse.Namespace) -> None:
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        if replayed(run, args.event_id): print("replayed event"); return
        recipient = lane_of(run, args.lane)
        if recipient.get("claimed_by") != args.agent:
            fail("only the current claimant of the recipient lane can acknowledge its message")
        message = next((item for item in run["messages"] if item["id"] == args.message_id), None)
        if message is None:
            fail(f"no message named {args.message_id!r}")
        if message["to"] != args.lane or message["from"] == args.lane:
            fail("message does not belong to this recipient lane")
        if message.get("acknowledged_at"):
            fail("message is already acknowledged")
        message["acknowledged_at"] = now(); message["acknowledged_by"] = args.agent
        record(args.run, run, "ack-message", args.lane, args.message_id, args.event_id)
    print(f"acknowledged {args.message_id}")


def cmd_heartbeat(args: argparse.Namespace) -> None:
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run); lane = lane_of(run, args.lane)
        if not run["supervised"] or lane.get("claimed_by") != args.agent:
            fail("heartbeat requires a supervised lane claimed by this agent")
        lane["heartbeat_at"] = now(); record(args.run, run, "heartbeat", args.lane, args.agent, args.event_id)
    print(f"heartbeat recorded for {args.lane!r}")


def cmd_watch(args: argparse.Namespace) -> None:
    with ReadStore(state_path(args.state)) as data:
        run = run_of(data, args.run)
        if not run["supervised"]: fail("watch requires init --supervised")
        stale = [(name, lane) for name, lane in run["lanes"].items() if lane["state"] == "active" and time.time() - parse_stamp(lane.get("heartbeat_at", lane["claimed_at"])) > args.stale_seconds]
        print(f"watch scan: lanes={len(run['lanes'])} messages={len(run['messages'])} cost=O(lanes+messages)")
        for name, lane in stale:
            print(f"RESTART REQUEST — {args.run}/{name}: resume or reconcile {lane.get('claimed_by', 'unclaimed')} from {lane.get('heartbeat_at', lane.get('claimed_at'))}; inspect inbox and workloop status. Host delivery is required.")
        if not stale: print("no stale lanes")


def cmd_archive(args: argparse.Namespace) -> None:
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        if not run["supervised"]: fail("archive requires init --supervised")
        retained, archived = [], []
        for message in run["messages"]:
            if not message["requires_ack"] and message["kind"] in {"status", "evidence-ready"}:
                archived.append(message["id"])
            else:
                retained.append(message)
        run["messages"] = retained
        record(args.run, run, "archive", detail=",".join(archived))
    print(f"archived {len(archived)} nonblocking messages; retained {len(retained)}")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    root.add_argument("--state", help="state file (default: .agents/.workloop-state.json)")
    root.add_argument("--event-id", help="idempotency key for a mutating command")
    sub = root.add_subparsers(required=True)
    init = sub.add_parser("init"); init.add_argument("run"); init.add_argument("--objective", required=True); init.add_argument("--acceptance", required=True); init.add_argument("--base", default="HEAD"); init.add_argument("--max-lanes", type=int, default=8); init.add_argument("--supervised", action="store_true"); init.add_argument("--message-limit", type=int, default=128); init.set_defaults(func=cmd_init)
    add = sub.add_parser("add-lane"); add.add_argument("run"); add.add_argument("lane"); add.add_argument("--worker", required=True); add.add_argument("--workspace", required=True); add.add_argument("--path", action="append", required=True); add.add_argument("--depends-on", action="append"); add.add_argument("--allow-more", action="store_true"); add.set_defaults(func=cmd_add_lane)
    claim = sub.add_parser("claim"); claim.add_argument("run"); claim.add_argument("lane"); claim.add_argument("--agent", required=True); claim.set_defaults(func=cmd_claim)
    submit = sub.add_parser("submit"); submit.add_argument("run"); submit.add_argument("lane"); submit.add_argument("--evidence", required=True); submit.set_defaults(func=cmd_submit)
    review = sub.add_parser("review"); review.add_argument("run"); review.add_argument("lane"); review.add_argument("--reference", required=True); review.add_argument("--result", choices=("accept", "reopen"), required=True); review.add_argument("--severity", default="P1"); review.add_argument("--message", default="review requested a correction"); review.set_defaults(func=cmd_review)
    attention = sub.add_parser("attention"); attention.add_argument("run"); attention.add_argument("lane"); attention.add_argument("--severity", required=True); attention.add_argument("--message", required=True); attention.add_argument("--reference", default=""); attention.set_defaults(func=cmd_attention)
    ack = sub.add_parser("ack"); ack.add_argument("run"); ack.add_argument("lane"); ack.add_argument("--agent", required=True); ack.set_defaults(func=cmd_ack)
    stale = sub.add_parser("release-stale"); stale.add_argument("run"); stale.add_argument("lane"); stale.add_argument("--reason", required=True); stale.set_defaults(func=cmd_release_stale)
    qa = sub.add_parser("qa"); qa.add_argument("run"); qa.add_argument("--evidence", required=True); qa.set_defaults(func=cmd_qa)
    check = sub.add_parser("check"); check.add_argument("run"); check.set_defaults(func=cmd_check)
    brief = sub.add_parser("brief"); brief.add_argument("run"); brief.add_argument("lane"); brief.add_argument("--role", choices=("worker", "reviewer", "qa"), default="worker"); brief.set_defaults(func=cmd_brief)
    status = sub.add_parser("status"); status.add_argument("run"); status.set_defaults(func=cmd_status)
    send = sub.add_parser("send"); send.add_argument("run"); send.add_argument("--from-lane", required=True); send.add_argument("--to-lane", required=True); send.add_argument("--agent", required=True); send.add_argument("--kind", choices=("finding", "blocked", "evidence-ready", "status"), required=True); send.add_argument("--message", required=True); send.add_argument("--reference", default=""); send.add_argument("--requires-ack", action="store_true"); send.set_defaults(func=cmd_send)
    inbox = sub.add_parser("inbox"); inbox.add_argument("run"); inbox.add_argument("lane"); inbox.set_defaults(func=cmd_inbox)
    ack_message = sub.add_parser("ack-message"); ack_message.add_argument("run"); ack_message.add_argument("lane"); ack_message.add_argument("message_id"); ack_message.add_argument("--agent", required=True); ack_message.set_defaults(func=cmd_ack_message)
    beat = sub.add_parser("heartbeat"); beat.add_argument("run"); beat.add_argument("lane"); beat.add_argument("--agent", required=True); beat.set_defaults(func=cmd_heartbeat)
    watch = sub.add_parser("watch"); watch.add_argument("run"); watch.add_argument("--stale-seconds", type=int, default=900); watch.set_defaults(func=cmd_watch)
    archive = sub.add_parser("archive"); archive.add_argument("run"); archive.set_defaults(func=cmd_archive)
    return root


if __name__ == "__main__":
    args = parser().parse_args()
    args.func(args)
