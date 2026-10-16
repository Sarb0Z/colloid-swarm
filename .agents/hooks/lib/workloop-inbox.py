#!/usr/bin/env python3
"""What a workloop participant needs to hear right now, as one block of text.

Usage: workloop-inbox.py <state-path> <seen-dir> <session> <event> <agent-id>

Prints the block, or nothing when there is nothing new. The state file is
the controller's own; this reads it and never writes it. Delivery is
remembered per agent in <seen-dir>/.inbox-seen-<session>-<agent>, so a
message is injected once and its acknowledgement still goes through
`ack-message`.

A subagent hears: its host agent id at start, so it can claim its lane with
that id; and, once it has claimed, every unread message addressed to its
lane. The main agent hears a digest of every run not torn down: lanes
awaiting review, lanes carrying attention, lanes whose heartbeat is stale.
"""

from __future__ import annotations

import calendar
import json
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
try:
    import workloop_docker as wd  # noqa: E402
except ImportError:  # a trimmed export without the controller still gets the digest
    wd = None  # type: ignore[assignment]

STALE_SECONDS = 900
# Hook output is capped by the host and discarded on timeout, and the seen
# file is written before the host reads the block, so a delivery must never
# be larger than what is sure to arrive; the rest stays unseen for next time.
MAX_DELIVER = 8

# A lane past any of these is warned about, never refused: one behaviour per
# lane keeps review and merge small.
MAX_CHANGED_LINES = 800
MAX_LANE_PATHS = 15
WIDEN_LIMIT = 2
OPEN_RUN_SECONDS = 24 * 3600
GIT_TIMEOUT = 5
SPLIT_REMEDY = "split what remains into a new lane after this one is reviewed"


def load(path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return data.get("runs", {}) if isinstance(data, dict) else {}


def stamp(value: str | None) -> float | None:
    if not value:
        return None
    try:
        return float(calendar.timegm(time.strptime(value, "%Y-%m-%dT%H:%M:%SZ")))
    except ValueError:
        return None


def live_runs(runs: dict) -> dict:
    return {name: run for name, run in runs.items() if not run.get("torn_down")}


def subagent_block(runs: dict, agent_id: str, event: str, seen: set[str]) -> tuple[str, set[str]]:
    lines: list[str] = []
    # The id matters to a cell that can act on it: one with a lane to claim,
    # or one that already holds a lane.
    claimable = any(lane.get("state") in ("ready", "reopened") or lane.get("claimed_by") == agent_id
                    for run in runs.values() for lane in run["lanes"].values())
    if event == "SubagentStart" and claimable:
        lines.append(f"AGENT_ID: {agent_id} — claim your workloop lane and send or acknowledge messages with --agent {agent_id}.")
    delivered: set[str] = set()
    for run_name, run in runs.items():
        mine = [name for name, lane in run["lanes"].items() if lane.get("claimed_by") == agent_id]
        for lane_name in mine:
            for message in run.get("messages", []):
                if message["to"] != lane_name or message.get("acknowledged_at") or message["id"] in seen:
                    continue
                if len(delivered) >= MAX_DELIVER:
                    lines.append(f"WORKLOOP: more messages wait for {run_name}/{lane_name}; they follow after your next tool call.")
                    return "\n".join(lines), delivered
                ack = f" — acknowledge before your next handoff: .agents/workloop.py ack-message {run_name} {lane_name} {message['id']} --agent {agent_id}" if message["requires_ack"] else ""
                ref = f" ({message['reference']})" if message.get("reference") else ""
                lines.append(f"WORKLOOP MESSAGE {run_name}/{lane_name} from {message['from']} [{message['kind']}]: {message['message']}{ref}{ack}")
                delivered.add(message["id"])
    return "\n".join(lines), delivered


def cells_path(seen_dir: Path, session: str) -> Path:
    return seen_dir / f".cells-{re.sub(r'[^A-Za-z0-9_-]', '', session)}"


def record_cell(seen_dir: Path, session: str, agent_id: str, event: str) -> None:
    """Keep the session's own record of which subagents are running.

    Every subagent, reader or writer, is listed from its start to its stop —
    the parallel-writers gate tracks writers only and tells an operator to
    delete its file, so it is not a liveness source. `started` survives a
    stop, so a claimant that came and went is still known to be ours.
    """
    path = cells_path(seen_dir, session)
    try:
        lines = [line for line in path.read_text().splitlines() if line]
    except OSError:
        lines = []
    entries = dict(line.split("\t", 1) for line in lines if "\t" in line)
    if event == "SubagentStart":
        entries[agent_id] = "live"
    elif event == "SubagentStop" and agent_id in entries:
        entries[agent_id] = "stopped"
    else:
        return
    path.write_text("".join(f"{key}\t{value}\n" for key, value in sorted(entries.items())))


def dead_claimants(seen_dir: Path, session: str) -> tuple[set[str], set[str]]:
    """Agent ids this session started, and the subset still live."""
    try:
        lines = [line for line in cells_path(seen_dir, session).read_text().splitlines() if "\t" in line]
    except OSError:
        return set(), set()
    entries = dict(line.split("\t", 1) for line in lines)
    return set(entries), {key for key, value in entries.items() if value == "live"}


def composed_result(run: dict) -> dict | None:
    """The run's current composed-test record, or None when absent or stale.

    A one-writer run records it as `verified`; a worktree run as
    `integration`. Current means it covers each lane's accepted tip.
    """
    lanes = run["lanes"]
    tips = {name: lane.get("accepted_tip") for name, lane in lanes.items()}
    if all(lane.get("place") == "main" for lane in lanes.values()):
        record = run.get("verified")
        return record if record and record.get("lane_tips") == tips and record.get("verify") == run.get("verify") else None
    record = run.get("integration")
    return record if record and record.get("lane_heads") == tips else None


def closing_notes(run_name: str, run: dict) -> list[str]:
    """The next closing step once every lane is reviewed, from state alone."""
    lanes = run["lanes"]
    if not lanes or not all(lane.get("state") == "reviewed" for lane in lanes.values()):
        return []
    current = composed_result(run)
    if all(lane.get("place") == "main" for lane in lanes.values()):
        if current is None or current.get("result") != "pass":
            return [f"lane reviewed; check {run_name} runs the composed test"]
    elif current is None:
        return [f"all lanes reviewed; integrate {run_name}"]
    elif current.get("result") != "pass":
        return ["the composed test failed at integrate; see status"]
    if not run.get("qa"):
        return [f"ready for QA; record it with qa {run_name} --evidence '…'"]
    return [f"check {run_name}, then teardown {run_name}"]


def git_out(repo: Path, *args: str) -> str | None:
    """Git's stdout, or None with a note on stderr: a missing figure is dropped, not fatal."""
    try:
        result = subprocess.run(["git", "-C", str(repo), *args], text=True, capture_output=True, timeout=GIT_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"workloop-inbox: git {args[0]} in {repo} dropped: {error}", file=sys.stderr)
        return None
    if result.returncode != 0:
        print(f"workloop-inbox: git {args[0]} in {repo} dropped: {result.stderr.strip()}", file=sys.stderr)
        return None
    return result.stdout


def changed_lines(lane: dict, run: dict) -> int | None:
    workspace = Path(lane.get("workspace") or "")
    origin = lane.get("start") if lane.get("place") == "main" else run.get("base")
    if not origin or not workspace.is_dir():
        return None
    paths = [*lane.get("paths", []), *run.get("shared", [])]
    out = git_out(workspace, "diff", "--numstat", origin, "--", *paths)
    if out is None:
        return None
    # Binary files report "-" and count as no lines.
    return sum(int(count) for row in out.splitlines() for count in row.split("\t")[:2] if count.isdigit())


def commits_behind(run: dict) -> tuple[int, str] | None:
    """Commits on the default branch past the run base, with that branch's name."""
    repo = Path(run.get("repo") or "")
    if not repo.is_dir() or not run.get("base"):
        return None
    # for-each-ref exits 0 with no output for a ref that is absent, so a repository
    # without origin/HEAD, main or master falls through quietly.
    for pattern, field in (("refs/remotes/origin/HEAD", "symref"), ("refs/heads/main", "refname"), ("refs/heads/master", "refname")):
        found = git_out(repo, "for-each-ref", f"--format=%({field}:short)", pattern)
        if found is None:
            return None
        branch = found.strip().splitlines()[0] if found.strip() else ""
        if branch:
            out = git_out(repo, "rev-list", "--count", f"{run['base']}..{branch}")
            return (int(out), branch) if out and out.strip().isdigit() else None
    return None


def size_notes(run_name: str, run: dict, now: float) -> list[str]:
    """Warnings for a lane not yet reviewed whose size says it holds more than one behaviour."""
    widens: dict[str, int] = {}
    opened = None
    for event in run.get("events", []):
        if event.get("action") == "widen":
            widens[event.get("lane")] = widens.get(event.get("lane"), 0) + 1
        elif event.get("action") == "init":
            opened = stamp(event.get("at"))
    old_worktree_run = opened is not None and now - opened > OPEN_RUN_SECONDS and any(lane.get("place") != "main" for lane in run["lanes"].values())
    behind = commits_behind(run) if old_worktree_run else None
    notes: list[str] = []
    for lane_name, lane in sorted(run["lanes"].items()):
        if lane.get("state") == "reviewed":
            continue
        lines = changed_lines(lane, run)
        if lines is not None and lines > MAX_CHANGED_LINES:
            notes.append(f"{lane_name} has {lines:,} changed lines (over {MAX_CHANGED_LINES}): {SPLIT_REMEDY}")
        owned = len(lane.get("paths", []))
        if owned > MAX_LANE_PATHS:
            notes.append(f"{lane_name} owns {owned} paths (over {MAX_LANE_PATHS}): {SPLIT_REMEDY}")
        if widens.get(lane_name, 0) >= WIDEN_LIMIT:
            notes.append(f"{lane_name} was widened {widens[lane_name]} times (the second widen is the limit): {SPLIT_REMEDY}")
        if behind and behind[0] and lane.get("place") != "main":
            notes.append(f"{lane_name}'s run has been open over a day and {behind[1]} has {behind[0]} commit(s) past its base: {SPLIT_REMEDY}")
    return notes


def main_block(runs: dict, seen_dir: Path | None = None, session: str = "") -> str:
    now = time.time()
    lines: list[str] = []
    ours, live = dead_claimants(seen_dir, session) if seen_dir else (set(), set())
    for run_name, run in sorted(runs.items()):
        notes: list[str] = []
        for lane_name, lane in sorted(run["lanes"].items()):
            state = lane.get("state")
            if state == "review":
                notes.append(f"{lane_name} awaits review")
            if lane.get("attention"):
                notes.append(f"{lane_name} carries {lane['attention'].get('severity', 'attention')}")
            if state == "active":
                claimant = lane.get("claimed_by") or ""
                if wd is not None and claimant in ours and claimant not in live:
                    # The worker stopped without handing the lane back. What it
                    # started in Docker is owned by the lane, so it goes now;
                    # the lane itself waits for the lead's release-stale.
                    result = wd.reap(run_name, sorted(run["lanes"]), lane_name)
                    tail = f"; {wd.summary(result)}" if (wd.removed_count(result) or result["failed"]) else ""
                    notes.append(f"{lane_name}'s worker {claimant} has stopped without submitting{tail} — release-stale {run_name} {lane_name} to reopen it")
                    continue
                # A heartbeat is a contract only under --supervised; an ordinary
                # lane that has simply been working for a while is not stale.
                beat = stamp(lane.get("heartbeat_at") or lane.get("claimed_at"))
                progress = f" — {lane['progress']}" if lane.get("progress") else ""
                if beat is not None and now - beat > STALE_SECONDS:
                    minutes = int((now - beat) // 60)
                    if run.get("supervised"):
                        notes.append(f"{lane_name} stale {minutes}m{progress} (release-stale if its worker is gone)")
                    else:
                        notes.append(f"{lane_name} active {minutes}m{progress}")
                elif progress:
                    notes.append(f"{lane_name}{progress}")
            if lane.get("env") == "broken":
                notes.append(f"{lane_name} environment broken (provision {run_name} {lane_name})")
        pending = [m["id"] for m in run.get("messages", []) if m["requires_ack"] and not m.get("acknowledged_at")]
        if pending:
            notes.append(f"{len(pending)} message(s) await acknowledgement")
        notes += closing_notes(run_name, run) + size_notes(run_name, run, now)
        if notes:
            lines.append(f"WORKLOOP {run_name}: " + "; ".join(notes) + f". Status: .agents/workloop.py status {run_name}")
    orphans = wd.foreign_orphans() if (runs and wd is not None) else []
    if orphans:
        lines.append("Not ours, still running with no reaper: " + "; ".join(orphans[:5]) + (f"; and {len(orphans) - 5} more" if len(orphans) > 5 else ""))
    return "\n".join(lines)


def main() -> None:
    state_path, seen_dir, session, event, agent_id = (Path(sys.argv[1]), Path(sys.argv[2]), *sys.argv[3:6])
    if agent_id:
        record_cell(seen_dir, session, agent_id, event)
    runs = live_runs(load(state_path))
    if not runs:
        return
    safe = re.sub(r"[^A-Za-z0-9_-]", "", session)
    if agent_id:
        seen_path = seen_dir / f".inbox-seen-{safe}-{re.sub(r'[^A-Za-z0-9_-]', '', agent_id)}"
        try:
            seen = set(seen_path.read_text().split())
        except OSError:
            seen = set()
        block, delivered = subagent_block(runs, agent_id, event, seen)
        if delivered:
            seen_path.write_text("\n".join(sorted(seen | delivered)) + "\n")
    else:
        block = main_block(runs, seen_dir, session)
    if block:
        print(block)


if __name__ == "__main__":
    main()
