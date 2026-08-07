#!/usr/bin/env python3
"""Wrap a context body arriving on stdin as a hook's additionalContext object.

Usage: emit-context.py <hook-event-name>

Prints the JSON object the host reads as context to add to the conversation.
The body arrives on stdin, so a long context cannot push the hook past ARG_MAX.
"""

import json
import sys


def main():
    if len(sys.argv) != 2:
        raise SystemExit("emit-context.py: usage: emit-context.py <hook-event-name>")
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": sys.argv[1],
            "additionalContext": sys.stdin.read().strip(),
        }
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
