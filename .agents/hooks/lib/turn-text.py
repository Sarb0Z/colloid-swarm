#!/usr/bin/env python3
"""Print every assistant message of the current turn in a JSONL transcript.

Usage: turn-text.py [--turn-id] <transcript-path>

Messages are separated by a line holding only the record separator (U+001E),
so a reader can judge each message on its own. With --turn-id the first line
is the turn's identity: the uuid of the row that started it, or the string
"start" when the transcript holds no typed row.

The turn starts after the last row the user typed: a user row whose content is
a string, or a list holding a text block and no tool result. Tool results are
user rows too, but they are the host answering the model, not the user
speaking, so they never end a turn. Rows the host synthesizes under the user
role (Stop-hook feedback, skill preambles) carry isMeta and are skipped too,
as are sidechain rows, which belong to spawned cells. An interruption stays a
boundary: the user acted.

A Stop payload carries only the last assistant message, and a long turn buries
its claims dozens of messages earlier. This is what lets a policy judge the
turn rather than its final sentence.

The file is read from the end, because a PreToolUse gate calls this on every
tool call and a session transcript reaches tens of megabytes; the cost has to
be the size of the turn, not of the session.
"""

import json
import os
import sys

BLOCK = 1 << 16


def text_of(message):
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(block.get("text", "") for block in content
                         if isinstance(block, dict) and block.get("type") == "text")
    return None


def typed_by_user(message):
    content = message.get("content")
    if isinstance(content, str):
        return True
    if not isinstance(content, list):
        return False
    kinds = {block.get("type") for block in content if isinstance(block, dict)}
    return "text" in kinds and "tool_result" not in kinds


def lines_reversed(path):
    """Yield the file's lines last to first, without loading the whole file."""
    with open(path, "rb") as handle:
        handle.seek(0, os.SEEK_END)
        position = handle.tell()
        tail = b""
        while position > 0:
            step = min(BLOCK, position)
            position -= step
            handle.seek(position)
            chunk = handle.read(step) + tail
            parts = chunk.split(b"\n")
            tail = parts[0]
            for part in reversed(parts[1:]):
                yield part
        yield tail


SEPARATOR = "\n\x1e\n"


def main():
    args = sys.argv[1:]
    with_id = args[:1] == ["--turn-id"]
    if with_id:
        args = args[1:]
    if len(args) != 1:
        raise SystemExit("turn-text.py: usage: turn-text.py [--turn-id] <transcript-path>")
    turn = []
    turn_id = "start"
    try:
        for raw in lines_reversed(args[0]):
            raw = raw.strip()
            if not raw:
                continue
            try:
                row = json.loads(raw)
            except ValueError:
                continue
            if row.get("isSidechain") or row.get("isMeta"):
                continue
            message = row.get("message") or {}
            if not isinstance(message, dict):
                continue
            role = message.get("role")
            if role == "user" and typed_by_user(message):
                turn_id = str(row.get("uuid") or row.get("timestamp") or "start")
                break
            if role == "assistant":
                found = text_of(message)
                if found:
                    turn.append(found)
    except OSError:
        return 0
    if with_id:
        print(turn_id)
    print(SEPARATOR.join(reversed(turn)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
