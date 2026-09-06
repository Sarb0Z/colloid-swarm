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
import sys
import time
from pathlib import Path

STALE_SECONDS = 900
# Hook output is capped by the host and discarded on timeout, and the seen
# file is written before the host reads the block, so a delivery must never
# be larger than what is sure to arrive; the rest stays unseen for next time.
MAX_DELIVER = 8


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


def main_block(runs: dict) -> str:
    now = time.time()
    lines: list[str] = []
    for run_name, run in sorted(runs.items()):
        notes: list[str] = []
        for lane_name, lane in sorted(run["lanes"].items()):
            state = lane.get("state")
            if state == "review":
                notes.append(f"{lane_name} awaits review")
            if lane.get("attention"):
                notes.append(f"{lane_name} carries {lane['attention'].get('severity', 'attention')}")
            if state == "active":
                # A heartbeat is a contract only under --supervised; an ordinary
                # lane that has simply been working for a while is not stale.
                beat = stamp(lane.get("heartbeat_at") or lane.get("claimed_at"))
                if beat is not None and now - beat > STALE_SECONDS:
                    minutes = int((now - beat) // 60)
                    if run.get("supervised"):
                        notes.append(f"{lane_name} stale {minutes}m (release-stale if its worker is gone)")
                    else:
                        notes.append(f"{lane_name} active {minutes}m")
            if lane.get("env") == "broken":
                notes.append(f"{lane_name} environment broken (provision {run_name} {lane_name})")
        pending = [m["id"] for m in run.get("messages", []) if m["requires_ack"] and not m.get("acknowledged_at")]
        if pending:
            notes.append(f"{len(pending)} message(s) await acknowledgement")
        if run.get("integration") is None and len(run["lanes"]) > 1 and all(l.get("state") == "reviewed" for l in run["lanes"].values()):
            notes.append(f"all lanes reviewed; integrate {run_name}")
        if notes:
            lines.append(f"WORKLOOP {run_name}: " + "; ".join(notes) + f". Status: .agents/workloop.py status {run_name}")
    return "\n".join(lines)


def main() -> None:
    state_path, seen_dir, session, event, agent_id = (Path(sys.argv[1]), Path(sys.argv[2]), *sys.argv[3:6])
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
        block = main_block(runs)
    if block:
        print(block)


if __name__ == "__main__":
    main()
