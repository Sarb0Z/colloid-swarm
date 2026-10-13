#!/usr/bin/env python3
"""Read the parallel-writers gate's payload into the lines the gate reads.

Usage: writers-payload.py   # the gate's payload on stdin

Prints twelve lines, in order: project_dir, event, session_id, prompt_id,
agent_id, agent_type, tool_name, the dispatch's subagent_type, the dispatch's
kind, whether every write target lies outside the checkout (yes|no),
tool_use_id and transcript_path. Ids that name state files keep only
[A-Za-z0-9_-]; every other field is flattened to one line. A payload that is
not a JSON object reads as empty, which the gate ignores.

The kind is, tested in this order, `read-only` or `notes-only` for a prompt
that opens with that marker, `brief` for a workloop brief naming a lane the
controller holds, and `plain` otherwise.
"""

import json
import os
import re
import sys

import write_targets

BRIEF = re.compile(r"WORKLOOP (?:WORKER|REVIEWER|QA) BRIEF[^\w\n]+([\w.-]+)/([\w.-]+)")


def line(value):
    return re.sub(r"[\r\n]", " ", str(value or ""))


def ident(value):
    return re.sub(r"[^A-Za-z0-9_-]", "", str(value or ""))


def real_lane(root, prompt):
    """A header is only text anyone can type; it exempts the dispatch when the
    controller really holds that lane with a worktree outside this checkout."""
    header = BRIEF.search(prompt)
    if not header:
        return False
    try:
        with open(os.path.join(root, ".agents", ".workloop-state.json"), encoding="utf-8") as source:
            lane = json.load(source)["runs"][header.group(1)]["lanes"][header.group(2)]
        workspace = os.path.realpath(lane["workspace"])
    except (OSError, ValueError, KeyError, TypeError):
        return False
    return not write_targets.under(workspace, root)


def kind(root, prompt):
    # An explicit marker outranks a brief: a lane's reviewer opened READ-ONLY
    # writes nothing.
    if re.match(r"\s*READ-ONLY\b", prompt):
        return "read-only"
    if re.match(r"\s*NOTES-ONLY\b", prompt):
        return "notes-only"
    if real_lane(root, prompt):
        return "brief"
    return "plain"


def outside(root, tool_input):
    """An edit whose every target lies outside the checkout cannot collide with
    a cell working in it. A relative path is the checkout's."""
    paths = write_targets.resolved(root, tool_input)
    return "yes" if paths and not any(write_targets.under(path, root) for path in paths) else "no"


def fields(payload):
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = {}
    root = os.path.realpath(str(payload.get("project_dir") or "."))
    prompt = str(tool_input.get("prompt") or "")
    return [
        line(payload.get("project_dir")), line(payload.get("event")),
        ident(payload.get("session_id")), ident(payload.get("prompt_id")),
        ident(payload.get("agent_id")), line(payload.get("agent_type")), line(payload.get("tool_name")),
        line(tool_input.get("subagent_type") or "general-purpose"),
        kind(root, prompt), outside(root, tool_input),
        line(payload.get("tool_use_id")), line(payload.get("transcript_path")),
    ]


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        payload = {}
    print("\n".join(fields(payload if isinstance(payload, dict) else {})))
    return 0


if __name__ == "__main__":
    sys.exit(main())
