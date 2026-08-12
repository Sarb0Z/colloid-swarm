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
    elif policy == "research-prime.sh":
        prompt = payload.get("prompt")
        if isinstance(prompt, list):           # Kimi: array of content parts
            prompt = " ".join(part.get("text", "") for part in prompt
                              if isinstance(part, dict))
        out["prompt"] = prompt if isinstance(prompt, str) else ""
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
