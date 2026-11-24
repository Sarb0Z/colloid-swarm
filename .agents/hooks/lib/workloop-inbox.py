#!/usr/bin/env python3
"""What a workloop participant needs to hear right now, as one block of text.

Usage: workloop-inbox.py <state-path> <seen-dir> <session> <event> <agent-id> [<start-source> <host>]

The start source and host are session-start.sh's (startup, resume, clear,
compact; `claude` on Claude Code). Prints the block, or nothing when there is
nothing new. The state file is the controller's own; this reads it and never
writes it. Delivery is remembered per agent in
<seen-dir>/.inbox-seen-<session>-<agent>, so a message is injected once and
its acknowledgement still goes through `ack-message`.

A subagent hears: its host agent id at start, while a lane is claimable, so a
lane's writer can claim with that id (the lane's brief, which only a writer
receives, tells it to: a SubagentStart hook cannot see the prompt, probe P6);
and, once it has claimed, every unread message addressed to its lane. The main
agent hears a digest of every run not torn down: lanes awaiting review, lanes
carrying attention, lanes whose heartbeat is stale, lanes and cells whose agent
died. Run or no run, at every Claude Code start and prompt it hears the agents
of this checkout waiting on the operator (agent_waits.py) and its dead agents
(agent_deaths.py). At a prompt it also runs the hourly dead-session check
(worktree_sweep.hourly) and lists what it removed and each `dead session` line
the operator must answer.

The digest judges a composed result from state on every prompt, comparing the
integration record to each lane's accepted tip; `check` judges from Git, also
comparing live branch tips and the base head. A stale integration can
therefore read "ready for QA" here until `check` says otherwise. Lane-size
notes live in workloop_size.py.
"""

from __future__ import annotations

import json
import re
import subprocess
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

try:
    from workloop_state import waiting_agents  # noqa: E402
except ImportError:  # a trimmed export without the controller reads no writer as waiting
    waiting_agents = None  # type: ignore[assignment]

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
        lines.append(f"AGENT_ID: {agent_id} — pass --agent {agent_id} wherever a workloop command asks for your agent id.")
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
        # land runs a one-writer run's composed test at its accepted commit.
        if current is not None and current.get("result") != "pass":
            return ["the composed test failed at the accepted commit; see status"]
    elif current is None:
        return [f"all lanes reviewed; integrate {run_name}"]
    elif current.get("result") != "pass":
        return ["the composed test failed at integrate; see status"]
    if not run.get("qa"):
        return [f"ready for QA; record it with qa {run_name} --evidence '…'"]
    # Accepted and not landed: land verifies on the source branch and closes the run.
    return [f"land {run_name}"]


def cell_notes(run_name: str, run: dict, ended: bool, verdicts: dict) -> list[str]:
    """Cells still out, with the remedy that fits the moment: a cell whose agent died is
    resumed or sent out again; while their session may still run them the lead records
    each as it comes back; once that session's process has ended (`ended`), no cell
    outlives it, so each is resumed from its AGENT DIED line, or dismissed and sent out again."""
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
    their = "its" if len(out) == 1 else "each one's"
    remedy = (f"no cell outlives its session: {their} AGENT DIED line says how to resume it in the session that owns it; "
              f"to send it again instead, dismiss that line, then brief {run_name} {name} --again"
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
    # A writer whose last turn started a background command is neither stale
    # nor gone; release-stale refuses it.
    if claimant and waiting_agents is not None and claimant in waiting_agents(Path(run.get("repo") or "/nonexistent")):
        return f"{lane_name}'s worker {claimant} is waiting on its own background work{progress}"
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
        # A parked lane, or one a restart left without its folder: its branch
        # and saved work wait in git (one stat per lane).
        if lane.get("place") != "main" and lane.get("state") != "reviewed" and lane.get("workspace") and not Path(lane["workspace"]).is_dir():
            notes.append(f"{lane_name}'s worktree is gone; resume {run_name} re-adds it with its saved work")
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


DEAD_SESSIONS_NOTE = ("WORKTREES (hooks/lib/worktree_sweep.py, checked at most once an hour): put each `dead session` "
                      "line to the operator through the question tool with its three answers, and run the one they choose:")


def dead_sessions(seen_dir: Path, session: str) -> str:
    """The hourly dead-session check (worktree_sweep.hourly, spec Unit 1.5) at a lead's prompt,
    under the teardown gate's toggle; nothing while the hour since the last check runs, or in
    an export that ships no sweep, as session-start.sh reads it."""
    agents = Path(__file__).resolve().parents[2]
    if not Path(__file__).with_name("worktree_sweep.py").is_file():
        return ""
    import config
    import worktree_sweep
    if not config.read(config.load(str(agents / "config.json")), "hooks.teardown_gate.enabled", True):
        return ""
    lines: list[str] = []
    try:
        worktree_sweep.hourly(seen_dir.parent, session, agents / "workloop.py", lines.append)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"workloop-inbox: the dead-session check failed: {error}", file=sys.stderr)
        lines.append(f"the dead-session check failed ({error}); the next one runs within the hour")
    return "\n".join([DEAD_SESSIONS_NOTE, *lines]) if lines else ""


def lead_block(runs: dict, seen_dir: Path, session: str, event: str, source: str, host: str) -> str:
    git = GitBudget()
    # Claude Code's records are read at a prompt (a Claude Code hook) and at a Claude Code start.
    claude = event == "UserPromptSubmit" or host == "claude"
    report = agent_effects.read_in_hook(seen_dir.parent, session, runs, git.out) if claude else agent_deaths.Report()
    waiting = agent_effects.waiting_in_hook(seen_dir) if claude else ""
    ended = frozenset(ended_runs(runs, seen_dir, session, source)) if runs else frozenset()
    digest = main_block(runs, report.verdicts, ended, git) if runs else ""
    deaths = report.block(agent_deaths.SHOWN_MAX, event == "SessionStart")
    # A start runs the check in session-start.sh's sweep; a prompt runs it here.
    worktrees = dead_sessions(seen_dir, session) if event == "UserPromptSubmit" else ""
    return "\n".join(part for part in (digest, waiting, deaths, worktrees) if part)


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
