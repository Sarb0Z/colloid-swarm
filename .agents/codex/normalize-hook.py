#!/usr/bin/env python3
"""Map Codex hook input to the shared policy contracts."""

import json
import shlex
import sys


def patch_paths(command: object) -> tuple[list[str], list[str]]:
    if not isinstance(command, str):
        return [], []

    paths: list[str] = []
    warnings: list[str] = []
    prefixes = ("*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: ")
    for line in command.splitlines():
        prefix = next((value for value in prefixes if line.startswith(value)), None)
        if prefix is None:
            continue
        raw = line[len(prefix):].strip()
        if raw.startswith(('"', "'")):
            try:
                values = shlex.split(raw)
            except ValueError:
                warnings.append("cannot parse quoted apply_patch path")
                continue
            if len(values) != 1:
                warnings.append("apply_patch path must name one file")
                continue
            raw = values[0]
        if not raw or raw.startswith("/") or any(part == ".." for part in raw.split("/")):
            warnings.append("apply_patch path is outside the project")
            continue
        if raw not in paths:
            paths.append(raw)
    if command.strip() and not paths and not warnings:
        warnings.append("apply_patch command contained no recognized file header")
    return paths, warnings


def text(source: dict, key: str) -> str:
    """Codex declares several of these nullable, so a present key can be None."""
    value = source.get(key)
    return value if isinstance(value, str) else ""


def response_text(response: object) -> str:
    """Codex sends a local tool's model-facing output, a string or an object."""
    if isinstance(response, str):
        return response
    if isinstance(response, dict):
        parts = [response.get(key) for key in ("stdout", "stderr", "output")]
        return "\n".join(part for part in parts if isinstance(part, str))
    return ""


def normalize(src: object, policy: str, repo: str) -> dict[str, object]:
    source = src if isinstance(src, dict) else {}
    tool_input = source.get("tool_input")
    tool_input = tool_input if isinstance(tool_input, dict) else {}
    out: dict[str, object] = {"project_dir": source.get("cwd") or repo}

    if policy == "guard-destructive.sh":
        out["command"] = tool_input.get("command", "")
    # colloid-only
    elif policy == "genome-inject.sh":
        out["subagent_type"] = text(source, "agent_type")
    # /colloid-only
    elif policy == "sources-capture.sh":
        out["agent"] = text(source, "agent_type") or "unknown"
        out["tool_name"] = text(source, "tool_name")
        out["tool_input"] = tool_input
    elif policy == "post-edit-check.sh":
        files, warnings = patch_paths(tool_input.get("command"))
        out["files"] = files
        out["warnings"] = warnings
    elif policy == "edit-record.sh":
        tool = text(source, "tool_name")
        command = tool_input.get("command")
        out["event"] = text(source, "hook_event_name")
        out["tool_use_id"] = text(source, "tool_use_id")
        out["session_id"] = text(source, "session_id")
        out["transcript_path"] = text(source, "transcript_path")
        out["tool_name"] = tool
        # apply_patch and Bash both carry tool_input.command: a patch for one,
        # a shell command for the other.
        out["files"] = patch_paths(command)[0] if tool == "apply_patch" else []
        out["command"] = command if tool != "apply_patch" and isinstance(command, str) else ""
        out["tool_response"] = response_text(source.get("tool_response"))
    elif policy in {"session-wrap.sh", "stop-investigate.sh"}:
        out["stop_hook_active"] = bool(source.get("stop_hook_active", False))
        out["transcript_path"] = text(source, "transcript_path")
        if policy == "session-wrap.sh":
            out["session_id"] = text(source, "session_id")
        else:
            out["last_assistant_message"] = text(source, "last_assistant_message")
    elif policy == "session-start.sh":
        out["source"] = text(source, "source")
        out["session_id"] = text(source, "session_id")
        out["transcript_path"] = text(source, "transcript_path")
    elif policy in {"research-prime.sh", "done-prime.sh"}:
        out["prompt"] = text(source, "prompt")
    elif policy == "ui-gate.sh":
        event = text(source, "hook_event_name")
        # An unlabeled payload is judged a Stop only when nothing tool-shaped is
        # present; guessing Stop on a tool event would block mid-tool.
        out["event"] = event or ("Stop" if not (source.get("tool_name") or tool_input) else "PostToolUse")
        out["session_id"] = text(source, "session_id")
        out["tool_name"] = text(source, "tool_name")
        out["files"] = patch_paths(tool_input.get("command"))[0]
        out["stop_hook_active"] = bool(source.get("stop_hook_active", False))
    elif policy == "teardown-gate.sh":
        event = text(source, "hook_event_name")
        # Same reading ui-gate.sh uses for an unlabeled payload: judge it a Stop
        # only when nothing tool-shaped is present, so a missing label never
        # blocks mid-tool.
        out["event"] = (
            "Stop"
            if event in {"Stop", "SubagentStop"}
            else event or ("Stop" if not (source.get("tool_name") or tool_input) else "PostToolUse")
        )
        out["session_id"] = text(source, "session_id")
        out["tool_name"] = text(source, "tool_name")
        out["tool_input"] = tool_input
        out["stop_hook_active"] = bool(source.get("stop_hook_active", False))
        out["cwd"] = text(source, "cwd")
        out["tool_use_id"] = text(source, "tool_use_id")
        out["agent_id"] = text(source, "agent_id")
    elif policy == "session-end.sh":
        out["session_id"] = text(source, "session_id")
        out["reason"] = text(source, "reason")
        out["cwd"] = text(source, "cwd")
    elif policy == "pre-compact.sh":
        out["trigger"] = text(source, "trigger")
    return out


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: normalize-hook.py <policy> <repository>")
    try:
        source = json.load(sys.stdin)
    except json.JSONDecodeError:
        source = {}
    json.dump(normalize(source, sys.argv[1], sys.argv[2]), sys.stdout)


if __name__ == "__main__":
    main()
