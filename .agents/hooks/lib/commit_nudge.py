#!/usr/bin/env python3
"""Tell a lane's writer when its edits have sat uncommitted too long.

Usage: commit_nudge.py <state-path> <agents-dir> <session> <agent-id> <transcript-path>

The inbox hook runs this at a subagent's tool batch. The agent must hold an
active lane in a live run; a cell with no lane gets nothing, and the lead,
which has no agent id, is never asked. The lane's tree is its `workspace`, or
the run's checkout for a one-writer lane.

The edits are the ones the agent's own transcript records (agent_records.py,
the reader the death report uses), each dated by its record. `git status
--porcelain` in the lane's tree says which of those files are still
uncommitted; a file that is committed, reverted or ignored drops out. When the
oldest remaining edit is over THRESHOLD_SECONDS old, the agent hears one
`COMMIT:` line, and none again within THRESHOLD_SECONDS.

State is `<agents-dir>/.readout/.commit-nudge-<agent>`, a JSON object replaced
atomically under an `fcntl` lock on the one shared `.commit-nudge.lock`: the
transcript offset read so far, the time of the last nudge, and the first time
each uncommitted path was seen edited.

The toggle `hooks.commit_nudge.enabled` is read here, through config.py, after
the lane check, so a cell with no lane costs one Python start and none of the
death reader's modules. Status runs through GitBudget, which passes
`--no-optional-locks`: a status that took `.git/index.lock` would fail another
session's `git add` in the same checkout.
"""

from __future__ import annotations

import fcntl
import json
import os
import sys
import time
from pathlib import Path
from typing import Callable

import agent_activity
import agent_records as ar
import config
from workloop_size import GitBudget, status_paths

THRESHOLD_SECONDS = 30 * 60


def lane_tree(data: dict, agent_id: str) -> Path | None:
    """The tree of the active lane the agent claimed in a live run, or None when it holds none."""
    for run in data.get("runs", {}).values():
        if run.get("torn_down"):
            continue
        for lane in run.get("lanes", {}).values():
            if lane.get("claimed_by") == agent_id and lane.get("state") == "active":
                where = lane.get("workspace") or run.get("repo")
                return Path(where) if where else None
    return None


def git_status(tree: Path, paths: list[str]) -> set[str]:
    """The given paths `git status --porcelain` lists in `tree`: modified, added or untracked."""
    out = GitBudget().out(tree, "status", "--porcelain", "-z", "-uall", "--", *paths)
    if out is None:
        raise OSError(f"git status in {tree} gave no answer")
    return status_paths(out) & set(paths)


def relative(path: str, tree: Path) -> str | None:
    """`path` relative to the tree, or None when it lies outside."""
    real, root = Path(os.path.realpath(path)), Path(os.path.realpath(tree))
    return str(real.relative_to(root)) if real.is_relative_to(root) else None


def _load(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return {"offset": 0, "last_nudge": 0, "first_seen": {}}


def nudge(state: Path, agents_dir: Path, session: str, agent_id: str, transcript_path: str, now: float,
          status: Callable[[Path, list[str]], set[str]]) -> str:
    """The `COMMIT:` line the agent is due, or ''."""
    tree = lane_tree(json.loads(state.read_text()), agent_id)
    if tree is None:
        return ""
    settings = config.load(str(agents_dir / "config.json"))
    if config.unparsed(str(agents_dir / "config.json")):
        print(f"commit_nudge: {agent_id} gets no commit reminder: policy.json or config.json does not parse, "
              "so hooks.commit_nudge.enabled is unknown", file=sys.stderr)
        return ""
    if not config.read(settings, "hooks.commit_nudge.enabled", True):
        return ""
    # Imported here: the death reader's modules come in only for a lane's writer.
    import agent_effects

    transcript = agent_activity.transcript(transcript_path, session, agent_id)
    path = agents_dir / ".readout" / f".commit-nudge-{agent_activity.clean(agent_id)}"
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path.with_name(".commit-nudge.lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        known = _load(path)
        edits, offset = ar.timed_edits_since(transcript, known["offset"])
        first_seen = known["first_seen"]
        for value, edited_at in edits:
            name = relative(value, tree)
            if name is not None:
                first_seen[name] = min(first_seen.get(name, edited_at), edited_at)
        if first_seen:
            listed = status(tree, sorted(first_seen))
            first_seen = {name: at for name, at in first_seen.items() if name in listed}
        oldest = min(first_seen.values(), default=None)
        line = ""
        last_nudge = known["last_nudge"]
        if oldest is not None and now - oldest > THRESHOLD_SECONDS and now - last_nudge >= THRESHOLD_SECONDS:
            line = (f"COMMIT: {len(first_seen)} of your edited files have been uncommitted since "
                    f"{time.strftime('%H:%M', time.localtime(oldest))} ({int((now - oldest) // 60)} min). "
                    "Commit each piece whose acceptance passes, staging by path, "
                    "unless this repository says commits wait for the operator.")
            last_nudge = now
        current = {"offset": offset, "last_nudge": last_nudge, "first_seen": first_seen}
        if current != known:
            agent_effects.write_atomic(path, json.dumps(current, separators=(",", ":")))
    return line


def main() -> None:
    state, agents_dir, session, agent_id, transcript_path = sys.argv[1:6]
    if not agent_id or not transcript_path:
        return
    try:
        line = nudge(Path(state), Path(agents_dir), session, agent_id, transcript_path, time.time(), git_status)
    except (OSError, ValueError) as error:
        print(f"commit_nudge: {agent_id} gets no commit reminder this time: {error}", file=sys.stderr)
        return
    if line:
        print(line)


if __name__ == "__main__":
    main()
