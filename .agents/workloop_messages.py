"""Commands for the peer inbox of a supervised run: send, inbox, ack-message, archive, watch and digest."""

from __future__ import annotations

import argparse

from workloop_cells import cells_of
from workloop_paths import canonical_reference, reference_roots
from workloop_state import (
    ReadStore,
    Store,
    age_text,
    event_id,
    fail,
    lane_of,
    now,
    record,
    replayed,
    run_of,
    silence,
    state_path,
)


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
        reference = canonical_reference(args.reference, reference_roots(run, sender)) if args.reference else ""
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


def silent_agents(run: dict, threshold: int) -> list[tuple[str, str, dict]]:
    """Active lanes and cells out whose last sign of life, the hook's stamp or a heartbeat, is older than `threshold`."""
    found = [(name, "lane", lane) for name, lane in run["lanes"].items()
             if lane["state"] == "active" and silence(lane, "claimed_at")[1] > threshold]
    found += [(name, "cell", cell) for name, cell in cells_of(run).items()
              if cell["state"] == "out" and silence(cell, "out_since")[1] > threshold]
    return found


def cmd_watch(args: argparse.Namespace) -> None:
    with ReadStore(state_path(args.state)) as data:
        run = run_of(data, args.run)
        stale = silent_agents(run, args.stale_seconds)
        print(f"watch scan: lanes={len(run['lanes'])} cells={len(cells_of(run))} messages={len(run['messages'])} cost=O(lanes+cells+messages)")
        for name, kind, agent in stale:
            out, quiet = silence(agent, "claimed_at" if kind == "lane" else "out_since")
            last = f", last {agent['activity']}" if agent.get("activity") else ""
            if kind == "lane":
                print(f"RESTART REQUEST — {args.run}/{name}: resume or reconcile {agent.get('claimed_by', 'unclaimed')} silent {age_text(quiet)}{last}; inspect inbox and workloop status. Host delivery is required.")
            else:
                print(f"SILENT CELL — {args.run}/{name}: out {age_text(out)}, silent {age_text(quiet)}{last}; look at it, or record it with returned {args.run} {name} --failed '<why>'.")
        if not stale: print("no silent agents")


def cmd_digest(args: argparse.Namespace) -> None:
    """One line per agent: name, role, state, silence, last action. Silence and action read `-` when the agent is not out."""
    with ReadStore(state_path(args.state)) as data:
        run = run_of(data, args.run)
        agents = [(name, lane["worker"], lane["state"], "active", "claimed_at", lane) for name, lane in sorted(run["lanes"].items())]
        agents += [(name, cell["role"], cell["state"], "out", "out_since", cell) for name, cell in sorted(cells_of(run).items())]
        for name, role, state, live, since_key, agent in agents:
            out = state == live and agent.get(since_key)
            quiet = age_text(silence(agent, since_key)[1]) if out else "-"
            print(f"{name}\t{role}\t{state}\t{quiet}\t{(agent.get('activity') or '-') if out else '-'}")


def cmd_archive(args: argparse.Namespace) -> None:
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        if not run["supervised"]: fail("archive requires init --supervised")
        retained, archived = [], []
        for message in run["messages"]:
            # Chatter goes; so does an acknowledged message to a lane whose
            # review cycle is over. A required acknowledgement that never
            # came stays: it is a completion blocker, and archive is not the
            # way past one.
            chatter = not message["requires_ack"] and message["kind"] in {"status", "evidence-ready"}
            answered = bool(message.get("acknowledged_at")) or not message["requires_ack"]
            settled = answered and run["lanes"].get(message["to"], {}).get("state") == "reviewed"
            if chatter or settled:
                archived.append(message["id"])
            else:
                retained.append(message)
        run["messages"] = retained
        record(args.run, run, "archive", detail=",".join(archived))
    print(f"archived {len(archived)} messages; retained {len(retained)}")
