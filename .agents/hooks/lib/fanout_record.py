#!/usr/bin/env python3
"""Record the lead's read-only cells in a per-session workloop fan-out run.

Usage: fanout_record.py record <repo>      # the gate's PostToolUse Agent payload on stdin
       fanout_record.py returned <repo>    # the gate's SubagentStop payload on stdin

Decision D4 (ruling R4): read-only cells record themselves. Every Agent
dispatch of the lead that carries a READ-ONLY or NOTES-ONLY marker, or names a
reading persona (FANOUT_READERS), and no `WORKLOOP … BRIEF` header becomes a
cell of the run `fanout-<session>`, created at its first cell. Writers are not
recorded: the parallel-writers gate holds them, and a multi-writer delegation
opens its own run. The run lives in the main checkout's workloop state, and
every change goes through the controller's own commands (`init`, `add-cell`,
`returned`) in <repo>/.agents/workloop.py, so its locking and history apply.

A cell is named by its dispatch's tool_use_id, lowercased: the one id both
the dispatch and, through the cell's `meta.json` `toolUseId`, its SubagentStop
can name. A foreground cell's PostToolUse comes after its SubagentStop, with
the cell's result, so it is recorded and marked returned at once; a background
cell's PostToolUse comes at launch (`status` `async_launched`), and its
SubagentStop marks it returned.

A recorder, never a gate: every failure is reported on stderr and exits 0.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys

FANOUT_READERS = ("explorer", "researcher", "reviewer", "explore")
ROLES = {"reviewer": "review"}
LAUNCHED = "async_launched"


def run_name(session: str) -> str:
    return "fanout-" + re.sub(r"[^a-z0-9_-]", "", session.lower())


def cell_name(tool_use_id: str) -> str:
    return re.sub(r"[^a-z0-9_-]", "", tool_use_id.lower())


def main_checkout(project: str) -> str:
    """The main working tree of the project's repository: workloop runs live in its state."""
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    done = subprocess.run(["git", "-C", project, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                          capture_output=True, text=True, env=env, timeout=5)
    common = done.stdout.strip()
    if done.returncode != 0 or not common.endswith(os.sep + ".git"):
        raise RuntimeError(f"{project} is in no Git checkout with a .git folder ({done.stderr.strip() or common})")
    return os.path.dirname(common)


def controller(repo: str, checkout: str, *args: str) -> subprocess.CompletedProcess:
    state = os.path.join(checkout, ".agents", ".workloop-state.json")
    return subprocess.run([sys.executable, os.path.join(repo, ".agents", "workloop.py"), "--state", state, *args],
                          capture_output=True, text=True, cwd=checkout, timeout=60)


def recorded_cell(checkout: str, run: str, name: str) -> dict | None:
    try:
        with open(os.path.join(checkout, ".agents", ".workloop-state.json"), encoding="utf-8") as source:
            data = json.load(source)
    except FileNotFoundError:
        return None
    cell = (((data.get("runs") or {}).get(run) or {}).get("cells") or {}).get(name)
    return cell if isinstance(cell, dict) else None


def must(done: subprocess.CompletedProcess, what: str) -> None:
    if done.returncode != 0:
        raise RuntimeError(f"{what} failed: {(done.stderr or done.stdout).strip()}")


def reading(payload: dict) -> bool:
    """A read-only dispatch with no run header, by marker or by persona."""
    tool_input = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    prompt = str(tool_input.get("prompt") or "")
    if re.search(r"WORKLOOP (?:WORKER|REVIEWER|QA|CELL) BRIEF", prompt):
        return False
    persona = str(tool_input.get("subagent_type") or "").lower()
    return bool(re.match(r"\s*(READ-ONLY|NOTES-ONLY)\b", prompt)) or persona in FANOUT_READERS


def record(repo: str, payload: dict) -> None:
    if payload.get("agent_id") or not reading(payload):
        return
    session, tool_use_id = str(payload.get("session_id") or ""), str(payload.get("tool_use_id") or "")
    if not session or not cell_name(tool_use_id):
        raise RuntimeError("the dispatch carries no session_id or tool_use_id to record it under")
    checkout = main_checkout(str(payload.get("project_dir") or "."))
    run, name = run_name(session), cell_name(tool_use_id)
    tool_input = payload["tool_input"]
    if recorded_cell(checkout, run, name) is None:
        init = controller(repo, checkout, "init", run, "--repo", checkout,
                          "--objective", f"the read-only cells session {session} dispatched outside any run",
                          "--acceptance", "every cell is back")
        if init.returncode != 0 and "already exists" not in init.stderr + init.stdout:
            must(init, f"init {run}")
        persona = str(tool_input.get("subagent_type") or "general-purpose").lower()
        must(controller(repo, checkout, "add-cell", run, name, "--role", ROLES.get(persona, "research"),
                        "--model", str(tool_input.get("model") or "inherit")), f"add-cell {run} {name}")
    if str(payload.get("agent_status") or "") != LAUNCHED:
        returned(repo, checkout, run, name)


def returned(repo: str, checkout: str, run: str, name: str) -> None:
    cell = recorded_cell(checkout, run, name)
    if cell is not None and cell.get("state") == "out":
        must(controller(repo, checkout, "returned", run, name, "--result", "reply"), f"returned {run} {name}")


def stopped(repo: str, payload: dict) -> None:
    """A cell's SubagentStop: its meta.json names the dispatch it came from."""
    session, agent_id = str(payload.get("session_id") or ""), str(payload.get("agent_id") or "")
    transcript = str(payload.get("transcript_path") or "")
    if not session or not agent_id or not transcript:
        return
    checkout = main_checkout(str(payload.get("project_dir") or "."))
    run = run_name(session)
    meta = os.path.join(os.path.dirname(transcript), session, "subagents", f"agent-{agent_id}.meta.json")
    try:
        with open(meta, encoding="utf-8") as source:
            tool_use_id = json.load(source).get("toolUseId") or ""
    except FileNotFoundError:
        return  # not a cell this session dispatched through the Agent tool
    returned(repo, checkout, run, cell_name(str(tool_use_id)))


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] not in ("record", "returned"):
        print("fanout_record.py: usage: fanout_record.py record|returned <repo>  # payload on stdin", file=sys.stderr)
        return 0
    try:
        payload = json.loads(sys.stdin.read() or "{}")
        if not isinstance(payload, dict):
            raise ValueError("the payload is no JSON object")
        (record if argv[1] == "record" else stopped)(argv[2], payload)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"fanout_record.py: the fan-out record was not updated: {error}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
