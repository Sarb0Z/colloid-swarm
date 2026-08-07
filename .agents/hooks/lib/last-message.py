#!/usr/bin/env python3
"""Print the last assistant message in a JSONL transcript.

Usage: last-message.py <transcript-path>

The Stop payload carries `last_assistant_message` on most engines, but Codex
declares it `string | null`, "if available". This is the fallback that covers
the null: a transcript row the host has already written.
"""

import json
import sys


def text_of(message):
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(block.get("text", "") for block in content
                         if isinstance(block, dict) and block.get("type") == "text")
    return None


def main():
    if len(sys.argv) != 2:
        raise SystemExit("last-message.py: usage: last-message.py <transcript-path>")
    last = ""
    try:
        with open(sys.argv[1], encoding="utf-8") as transcript:
            for line in transcript:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                message = row.get("message") or {}
                if not isinstance(message, dict) or message.get("role") != "assistant":
                    continue
                found = text_of(message)
                if found is not None:
                    last = found
    except OSError:
        return 0
    print(last)
    return 0


if __name__ == "__main__":
    sys.exit(main())
