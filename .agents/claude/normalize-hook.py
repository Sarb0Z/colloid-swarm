#!/usr/bin/env python3
"""Normalize a Claude Code hook payload into the shared policy contract.

Usage: normalize-hook.py <policy.sh> <repo> [--agent <selector>]
       # Claude payload on stdin

Prints the JSON the named policy expects. Exits 3 when the agent selector does
not match, which the adapter reads as "this policy does not run here"; every
other failure leaves the policy to run, because a broken gate must never
silently disable a safety policy.

The selector reads `agent_id`, the one field a spawned subagent carries and a
`claude --agent <name>` main session does not:

    main      -> the main agent, `--agent` launch included (no agent_id)
    subagent  -> any spawned subagent (agent_id present)
    <Type>    -> spawned subagents of the named type(s), '|'-separated
"""

import json
import os
import sys

SKIP = 3


def gate(payload, selector):
    """True when the policy runs for this invocation."""
    kind = (payload.get("agent_type") or "").strip()
    spawned = bool((payload.get("agent_id") or "").strip())
    if selector == "main":
        return not spawned
    if selector == "subagent":
        return spawned
    return spawned and kind in selector.split("|")


def written_paths(tool_input):
    """Every path a write-shaped tool input names, in the order it names them."""
    files = []
    for key in ("file_path", "path", "notebook_path"):
        value = tool_input.get(key)
        if isinstance(value, str):
            files.append(value)
    for edit in tool_input.get("edits") or []:
        if isinstance(edit, dict) and isinstance(edit.get("file_path"), str):
            files.append(edit["file_path"])
    return files


def normalize(payload, policy, repo):
    tool_input = payload.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        tool_input = {}
    out = {"project_dir": os.environ.get("CLAUDE_PROJECT_DIR") or payload.get("cwd") or repo}

    if policy == "guard-destructive.sh":
        out["command"] = tool_input.get("command", "")
    # colloid-only
    elif policy == "genome-guard.sh":
        # Task/Agent dispatch input: the subagent's prompt and its type.
        out["prompt"] = tool_input.get("prompt", "")
        out["subagent_type"] = tool_input.get("subagent_type", "")
    elif policy == "genome-inject.sh":
        # SubagentStart fires inside the spawned cell, which names its own type
        # at the top level rather than in a tool input.
        out["subagent_type"] = payload.get("agent_type", "")
    # /colloid-only
    elif policy == "sources-capture.sh":
        # Web lookup -> evidence trail. Map the tool to a kind and the source
        # value; agent_type tags a researcher cell's rows apart from the main
        # agent's.
        tool = payload.get("tool_name") or ""
        agent = payload.get("agent_type")
        out["agent"] = (agent if isinstance(agent, str) else "main").strip() or "main"
        if tool == "WebSearch" or tool.endswith("__resolve_open_access"):
            out["kind"], out["value"] = "search", tool_input.get("query", "")
        elif tool == "WebFetch" or tool.endswith("__fetch_readable"):
            out["kind"], out["value"] = "fetch", tool_input.get("url", "")
        else:                                  # browser_navigate carries a url
            out["kind"], out["value"] = "browse", tool_input.get("url", "")
    elif policy in ("post-edit-check.sh", "grader-lock.sh"):
        # One reads them after the write, the other decides before it; both need
        # every path the tool input names.
        out["files"] = written_paths(tool_input)
    elif policy == "session-wrap.sh":
        out["stop_hook_active"] = bool(payload.get("stop_hook_active", False))
        out["transcript_path"] = payload.get("transcript_path", "")
        out["session_id"] = payload.get("session_id", "")
    elif policy == "stop-investigate.sh":
        out["stop_hook_active"] = bool(payload.get("stop_hook_active", False))
        out["transcript_path"] = payload.get("transcript_path", "")
        message = payload.get("last_assistant_message")
        out["last_assistant_message"] = message if isinstance(message, str) else ""
    elif policy == "session-start.sh":
        out["source"] = payload.get("source", "")
        # Identity, for seeding session-wrap's baseline before turn 1 runs.
        out["session_id"] = payload.get("session_id", "")
        out["transcript_path"] = payload.get("transcript_path", "")
    elif policy == "research-prime.sh":
        out["prompt"] = payload.get("prompt", "")
    elif policy == "pre-compact.sh":
        out["trigger"] = payload.get("trigger", "")
    return out


def main():
    if len(sys.argv) < 3:
        raise SystemExit("normalize-hook.py: usage: normalize-hook.py <policy.sh> <repo> [--agent <selector>]")
    policy, repo = sys.argv[1], sys.argv[2]
    selector = sys.argv[4] if len(sys.argv) > 4 and sys.argv[3] == "--agent" else ""

    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        payload = {}                           # unreadable payload -> run the policy
    if not isinstance(payload, dict):
        payload = {}

    if selector and not gate(payload, selector):
        return SKIP
    sys.stdout.write(json.dumps(normalize(payload, policy, repo)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
