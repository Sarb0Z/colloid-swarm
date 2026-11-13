#!/usr/bin/env python3
"""What a workloop participant needs to hear right now, as one block of text.

Usage: workloop-inbox.py <state-path> <seen-dir> <session> <event> <agent-id> [<start-source> <host>]

The start source and host are session-start.sh's (startup, resume, clear,
compact; `claude` on Claude Code). Prints the block, or nothing when there is
nothing new. The state file is the controller's own; this reads it and never
writes it. Delivery is remembered per agent in
<seen-dir>/.inbox-seen-<session>-<agent>, so a message is injected once and
its acknowledgement still goes through `ack-message`.

A subagent hears: its host agent id at start, so it can claim its lane with
that id; and, once it has claimed, every unread message addressed to its
lane. The main agent hears a digest of every run not torn down: lanes
awaiting review, lanes carrying attention, lanes whose heartbeat is stale,
lanes and cells whose agent died. Run or no run, at every Claude Code start
and prompt it hears the agents of this checkout waiting on the operator
(agent_waits.py) and its dead agents (agent_deaths.py), and
at a prompt, when the turn that just ended dispatched two or more cells
outside any run, read once from the parallel-writers gate's ledger
<seen-dir>/.outside-runs-<session> (ruling 36).

The digest judges a composed result from state on every prompt, comparing the
integration record to each lane's accepted tip; `check` judges from Git, also
comparing live branch tips and the base head. A stale integration can
therefore read "ready for QA" here until `check` says otherwise. Lane-size
notes live in workloop_size.py.
"""

from __future__ import annotations

import json
import re
import sys
import time
from pathlib import Path

# Imported before the controller's folder joins the path below, so each resolves beside this script.
import agent_deaths
import agent_effects
import agent_verdicts as av
import worktree_records as wr
from agent_silence import parse, silence

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
try:
    import workloop_docker as wd  # noqa: E402
except ImportError:  # a trimmed export without the controller still gets the digest
    wd = None  # type: ignore[assignment]

from workloop_size import GitBudget, size_notes  # noqa: E402

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
    # Current also means the shared paths and rebuild commands it merged with
    # are the run's now (a record from before them reads as none).
    same_rules = record and record.get("rebuilt", {}) == run.get("rebuild", {}) and record.get("shared", []) == run.get("shared", [])
    return record if record and same_rules and record.get("lane_heads") == tips else None


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


def cell_notes(run_name: str, run: dict, ended: bool, verdicts: dict) -> list[str]:
    """Cells still out, with the remedy that fits the moment: a cell whose agent died is
    resumed or sent out again; while their session may still run them the lead records
    each as it comes back; once that session's process has ended (`ended`), no cell
    outlives it, so each is failed or sent out again."""
    cells = run.get("cells") or {}
    dead = {name: av.dead_since(verdicts, cell.get("agent_id"), parse(cell.get("out_since")))
            for name, cell in sorted(cells.items()) if cell.get("state") == "out"}
    notes = [f"cell {name}'s agent {how}: {remedy}, or brief {run_name} {name} --again"
             for name, verdict in dead.items() if verdict for how, remedy in [av.fate(verdict)]]
    out = [name for name, verdict in dead.items() if not verdict]
    if not out:
        # A run declared without --verify is finished once every cell is back (ruling 35).
        # debt: fanout-rule-copies -- completion_problems and the lead-less close read this rule too.
        back = cells and not run.get("verify") and not notes
        return notes + ([f"every cell is back; check {run_name}, then teardown {run_name}"] if back else [])
    name = out[0] if len(out) == 1 else "<name>"
    remedy = (f"no cell outlives its session: returned {run_name} {name} --failed '<why>', or brief {run_name} {name} --again"
              if ended else f"returned {run_name} {name} when {'it' if len(out) == 1 else 'each'} comes back")
    return notes + [f"{len(out)} cell{'s' if len(out) > 1 else ''} out ({', '.join(out)}); {remedy}"]


def ended_runs(runs: dict, seen_dir: Path, session: str, source: str) -> set[str]:
    """The runs whose cells out no process still runs, at a session start.

    A startup or resume begins a new process, so this session's earlier cells are
    gone; a compaction or /clear ends none. A run another live session leads, by
    the worktree records the session-start sweep reads, keeps its cells, unless
    this session leads it too."""
    if source not in ("startup", "resume"):
        return set()
    me, mine, theirs = wr.session_key(session), set(), set()
    for path in wr.records_dir(seen_dir.parent).glob("*.jsonl"):
        entries = wr.load(path)
        led = {entry["run"] for entry in entries if entry.get("run")}
        if path.stem == me:
            mine |= led
        elif wr.alive(wr.last_host(entries)):
            theirs |= led
    return {name for name in runs if name in mine or name not in theirs}


def active_note(run_name: str, run: dict, lane_name: str, lane: dict, verdicts: dict, now: float) -> str:
    """What an active lane's worker is doing, or how it ended without handing the lane back."""
    claimant = lane.get("claimed_by") or ""
    verdict = verdicts.get(claimant)
    if dead := av.dead_since(verdicts, claimant, None):
        # Its lane's containers stay for the resume.
        how, remedy = av.fate(dead)
        return f"{lane_name}'s worker {claimant} {how} without submitting: {remedy}, or release-stale {run_name} {lane_name}"
    if wd is not None and verdict and verdict.state in ("completed", "stopped"):
        # The worker finished without handing the lane back. What it started in
        # Docker is owned by the lane, so it goes now; the lane itself waits for
        # the lead's release-stale.
        result = wd.reap(run_name, sorted(run["lanes"]), lane_name)
        tail = f"; {wd.summary(result)}" if (wd.removed_count(result) or result["failed"]) else ""
        return f"{lane_name}'s worker {claimant} has stopped without submitting{tail} — release-stale {run_name} {lane_name} to reopen it"
    # A heartbeat is a contract only under --supervised; an ordinary lane that has
    # simply been working for a while is not stale. The hook's stamp counts as a
    # sign of life beside the heartbeat.
    quiet = silence(lane, "claimed_at", now)
    progress = f" — {lane['progress']}" if lane.get("progress") else ""
    if quiet is not None and quiet > STALE_SECONDS:
        minutes = int(quiet // 60)
        if run.get("supervised"):
            return f"{lane_name} stale {minutes}m{progress} (release-stale if its worker is gone)"
        return f"{lane_name} active {minutes}m{progress}"
    return f"{lane_name}{progress}" if progress else ""


def lane_notes(run_name: str, run: dict, verdicts: dict, now: float) -> list[str]:
    notes: list[str] = []
    for lane_name, lane in sorted(run["lanes"].items()):
        if lane.get("state") == "review":
            notes.append(f"{lane_name} awaits review")
        if lane.get("attention"):
            notes.append(f"{lane_name} carries {lane['attention'].get('severity', 'attention')}")
        if lane.get("state") == "active" and (note := active_note(run_name, run, lane_name, lane, verdicts, now)):
            notes.append(note)
        if lane.get("env") == "broken":
            notes.append(f"{lane_name} environment broken (provision {run_name} {lane_name})")
    return notes


def main_block(runs: dict, verdicts: dict, ended: frozenset, git: GitBudget) -> str:
    now = time.time()
    lines: list[str] = []
    for run_name, run in sorted(runs.items()):
        notes = lane_notes(run_name, run, verdicts, now)
        pending = [m["id"] for m in run.get("messages", []) if m["requires_ack"] and not m.get("acknowledged_at")]
        if pending:
            notes.append(f"{len(pending)} message(s) await acknowledgement")
        notes += cell_notes(run_name, run, run_name in ended, verdicts) + closing_notes(run_name, run) + size_notes(git, run, now)
        if notes:
            lines.append(f"WORKLOOP {run_name}: " + "; ".join(notes) + f". Status: .agents/workloop.py status {run_name}")
    orphans = wd.foreign_orphans() if (runs and wd is not None) else []
    if orphans:
        lines.append("Not ours, still running with no reaper: " + "; ".join(orphans[:5]) + (f"; and {len(orphans) - 5} more" if len(orphans) > 5 else ""))
    return "\n".join(lines)


OUTSIDE_RUNS_NOTE = ("WORKLOOP: {count} cells last turn outside any run. A multi-cell delegation is one workloop run: "
                     ".agents/workloop.py init <run> --objective '…' --acceptance '…' (with --verify '<test>' and --lane for a writer), "
                     "then add-cell <run> <name> --role research|review|qa --model <model> and dispatch what it prints.")


def outside_runs_note(seen_dir: Path, session: str) -> str:
    """The turn that just ended, counted from the gate's ledger of dispatches with no run
    header ("<prompt id>\\t<tool use id>" per line) and consumed: the last prompt's distinct
    dispatches, named at two or more (ruling 36). Older lines were a turn already reported."""
    path = seen_dir / f".outside-runs-{session}"
    try:
        lines = [line.split("\t", 1) for line in path.read_text().splitlines() if "\t" in line]
    except OSError:
        return ""
    try:
        path.unlink()
    except OSError as error:
        print(f"workloop-inbox: could not remove {path}: {error}", file=sys.stderr)
    if not lines:
        return ""
    count = len({tool_use for prompt, tool_use in lines if prompt == lines[-1][0]})
    return OUTSIDE_RUNS_NOTE.format(count=count) if count >= 2 else ""


def deliver(runs: dict, seen_dir: Path, safe: str, agent_id: str, event: str) -> str:
    """A subagent's block; what it delivers is remembered so it is delivered once."""
    seen_path = seen_dir / f".inbox-seen-{safe}-{re.sub(r'[^A-Za-z0-9_-]', '', agent_id)}"
    try:
        seen = set(seen_path.read_text().split())
    except OSError:
        seen = set()
    block, delivered = subagent_block(runs, agent_id, event, seen)
    if delivered:
        seen_path.write_text("\n".join(sorted(seen | delivered)) + "\n")
    return block


def lead_block(runs: dict, seen_dir: Path, session: str, event: str, source: str, host: str) -> str:
    # The count stands with no run and no state file: the note is for a lead who opened no run.
    outside = outside_runs_note(seen_dir, re.sub(r"[^A-Za-z0-9_-]", "", session)) if event == "UserPromptSubmit" else ""
    git = GitBudget()
    # Claude Code's records are read at a prompt (a Claude Code hook) and at a Claude Code start.
    claude = event == "UserPromptSubmit" or host == "claude"
    report = agent_effects.read_in_hook(seen_dir.parent, session, runs, git.out) if claude else agent_deaths.Report()
    waiting = agent_effects.waiting_in_hook(seen_dir) if claude else ""
    ended = frozenset(ended_runs(runs, seen_dir, session, source)) if runs else frozenset()
    digest = main_block(runs, report.verdicts, ended, git) if runs else ""
    deaths = report.block(agent_deaths.SHOWN_MAX, event == "SessionStart")
    return "\n".join(part for part in (outside, digest, waiting, deaths) if part)


def main() -> None:
    state_path, seen_dir, session, event, agent_id = (Path(sys.argv[1]), Path(sys.argv[2]), *sys.argv[3:6])
    runs = live_runs(load(state_path))
    start = sys.argv[6:8] if event == "SessionStart" else []
    source, host = (start + ["", ""])[:2]
    if agent_id:
        block = deliver(runs, seen_dir, re.sub(r"[^A-Za-z0-9_-]", "", session), agent_id, event) if runs else ""
    else:
        block = lead_block(runs, seen_dir, session, event, source, host)
    if block:
        print(block)


if __name__ == "__main__":
    main()
