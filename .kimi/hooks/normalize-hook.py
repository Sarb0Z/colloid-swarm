#!/usr/bin/env python3
"""Normalize a Kimi CLI hook payload into the shared policy contract.

Usage: normalize-hook.py <policy.sh> <repo>    # Kimi payload on stdin

Prints two lines: the sanitized session id, then the JSON the named policy
expects. The id leads because the adapter needs it to name a per-session file,
and the JSON is the one field that may hold anything.

The payload arrives on stdin rather than in the environment, so a large edit
cannot push the hook past ARG_MAX.
"""

import json
import os
import re
import sys


def normalize(payload, policy, repo):
    tool_input = payload.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        tool_input = {}
    out = {"project_dir": payload.get("cwd") or repo}

    if policy == "guard-destructive.sh":
        out["command"] = tool_input.get("command", "")
    elif policy == "sources-capture.sh":
        out["agent"] = "unknown"               # Tool payloads carry no agent tag.
        out["tool_name"] = payload.get("tool_name") or ""
        out["tool_input"] = tool_input
    elif policy == "post-edit-check.sh":
        files = []
        for key in ("file_path", "path"):
            value = tool_input.get(key)
            if isinstance(value, str):
                files.append(value)
        out["files"] = files
    elif policy == "edit-record.sh":
        out["event"] = payload.get("hook_event_name", "")
        # The reference names no call id; without one, a session's concurrent
        # shell calls share one HEAD snapshot.
        call = payload.get("tool_use_id", payload.get("tool_call_id"))
        out["tool_use_id"] = call if isinstance(call, str) else ""
        out["session_id"] = payload.get("session_id", "")
        out["tool_name"] = payload.get("tool_name") or ""
        out["files"] = [tool_input[key] for key in ("file_path", "path")
                        if isinstance(tool_input.get(key), str)]
        command = tool_input.get("command")
        out["command"] = command if isinstance(command, str) else ""
        # Kimi's hook reference does not name the output field; without one,
        # workloop integrate's PASS line is unreadable here.
        response = payload.get("tool_response", payload.get("tool_output"))
        if isinstance(response, dict):
            response = "\n".join(str(response[key]) for key in ("stdout", "stderr", "output")
                                  if isinstance(response.get(key), str))
        out["tool_response"] = response if isinstance(response, str) else ""
    elif policy == "session-wrap.sh":
        out["stop_hook_active"] = bool(payload.get("stop_hook_active", False))
        out["session_id"] = payload.get("session_id", "")
    elif policy == "session-start.sh":
        if payload.get("hook_event_name") == "PostCompact":
            out["source"] = "compact"
        else:
            out["source"] = payload.get("source", "")
        # Identity, for seeding session-wrap's baseline before turn 1 runs. Same
        # session_id the Stop payload carries, so the seed lands in the file the
        # wrap reads; empty would mean no seed and a baseline one turn late,
        # not a wrong one.
        out["session_id"] = payload.get("session_id", "")
    elif policy in ("research-prime.sh", "done-prime.sh"):
        prompt = payload.get("prompt")
        if isinstance(prompt, list):           # Kimi: array of content parts
            prompt = " ".join(part.get("text", "") for part in prompt
                              if isinstance(part, dict))
        out["prompt"] = prompt if isinstance(prompt, str) else ""
    elif policy == "teardown-gate.sh":
        # The PostToolUse reminder is discarded under Kimi like every other
        # PostToolUse output, but the recording it does is a file write, so the
        # Stop block still sees everything the session started.
        event = payload.get("hook_event_name", "")
        out["event"] = "Stop" if event in ("Stop", "SubagentStop") else "PostToolUse"
        out["session_id"] = payload.get("session_id", "")
        out["tool_name"] = payload.get("tool_name") or ""
        out["tool_input"] = tool_input
        out["stop_hook_active"] = bool(payload.get("stop_hook_active", False))
    elif policy == "pre-compact.sh":
        out["trigger"] = payload.get("trigger", "") or "auto"
    return out


def main():
    if len(sys.argv) != 3:
        raise SystemExit("normalize-hook.py: usage: normalize-hook.py <policy.sh> <repo>")
    policy, repo = os.path.basename(sys.argv[1]), sys.argv[2]
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    session = payload.get("session_id", "nosession")
    print(re.sub(r"[^A-Za-z0-9_-]", "", session if isinstance(session, str) else "nosession"))
    sys.stdout.write(json.dumps(normalize(payload, policy, repo)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
