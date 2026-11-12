"""Commands for the peer inbox of a supervised run: send, inbox, ack-message, archive, watch and digest."""

from __future__ import annotations

import argparse

from workloop_cells import cells_of
from workloop_paths import canonical_reference, reference_roots
from workloop_state import (
    ReadStore,
    Store,
    age_text,
    clock_text,
    event_id,
    fail,
    lane_of,
    last_sign,
    now,
    parse_stamp,
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


def quiet_agents(run: dict, threshold: int) -> list[tuple[str, str, dict, float, float | None]]:
    """Active lanes and cells out that are past `threshold` seconds: name, kind, agent, seconds out and
    seconds since the last sign of life, the hook's stamp or a heartbeat. That silence is None for an
    agent that shows neither; it is listed once it has been out past `threshold`."""
    found = []
    for kind, agents, live, since_key in (("lane", run["lanes"], "active", "claimed_at"), ("cell", cells_of(run), "out", "out_since")):
        for name, agent in agents.items():
            if agent["state"] != live:
                continue
            out, quiet = silence(agent, since_key)
            if (out if quiet is None else quiet) > threshold:
                found.append((name, kind, agent, out, quiet))
    return found


def cmd_watch(args: argparse.Namespace) -> None:
    with ReadStore(state_path(args.state)) as data:
        run = run_of(data, args.run)
        quiet_now = quiet_agents(run, args.stale_seconds)
        print(f"watch scan: lanes={len(run['lanes'])} cells={len(cells_of(run))} messages={len(run['messages'])} cost=O(lanes+cells+messages)")
        for name, kind, agent, out, quiet in quiet_now:
            if quiet is None:
                print(f"UNSTAMPED {kind.upper()} — {args.run}/{name}: out {age_text(out)} and carries no stamp: it was dispatched without the printed prompt, or is stuck before its first tool call; look at it.")
                continue
            last = f", last {agent['activity']}" if agent.get("activity") else ""
            if kind == "lane":
                print(f"RESTART REQUEST — {args.run}/{name}: resume or reconcile {agent.get('claimed_by', 'unclaimed')} silent {age_text(quiet)}{last}; inspect inbox and workloop status. Host delivery is required.")
            else:
                print(f"SILENT CELL — {args.run}/{name}: out {age_text(out)}, silent {age_text(quiet)}{last}; look at it, or record it with returned {args.run} {name} --failed '<why>'.")
        if not quiet_now: print("no silent agents")


def cmd_digest(args: argparse.Namespace) -> None:
    """One line per agent: name, role, state, out since, last stamp, last action. The times are UTC
    times of day, so the same agents in the same state print the same text on every pass; `unstamped`
    stands for an agent with no stamp and no heartbeat, and the last three columns read `-` when the agent is not out."""
    with ReadStore(state_path(args.state)) as data:
        run = run_of(data, args.run)
        agents = [(name, lane["worker"], lane["state"], "active", "claimed_at", lane) for name, lane in sorted(run["lanes"].items())]
        agents += [(name, cell["role"], cell["state"], "out", "out_since", cell) for name, cell in sorted(cells_of(run).items())]
        for name, role, state, live, since_key, agent in agents:
            if state != live or not agent.get(since_key):
                print(f"{name}\t{role}\t{state}\t-\t-\t-")
                continue
            sign = last_sign(agent)
            stamp = f"stamp {clock_text(sign)}" if sign is not None else "unstamped"
            print(f"{name}\t{role}\t{state}\tout {clock_text(parse_stamp(agent[since_key]))}\t{stamp}\t{agent.get('activity') or '-'}")


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
