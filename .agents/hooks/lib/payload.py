#!/usr/bin/env python3
"""Pull named fields out of a hook payload arriving on stdin.

Usage: payload.py <field>[=<default>] ...

Prints one line per field, in the order given. A `true` or `false` default makes
the field a flag and prints `yes` or `no`. Any other default stands in when the
field is absent or holds something other than a string.

Every field except the last is flattened to one line, so the caller reads the
leading fields positionally. The last field keeps its newlines, which is where a
prompt or an assistant message goes.

The payload arrives on stdin rather than in the environment. A single edit can
carry hundreds of kilobytes, and an environment past ARG_MAX aborts the hook
with E2BIG — which turns the gate off exactly on the largest changes.
"""

import json
import sys


def render(value, default):
    if isinstance(default, bool):
        return "yes" if value else "no"
    return value if isinstance(value, str) else default


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    fields = sys.argv[1:]
    for index, argument in enumerate(fields):
        name, _, raw = argument.partition("=")
        default = True if raw == "true" else False if raw == "false" else raw
        text = render(payload.get(name, default), default)
        if index == len(fields) - 1:
            sys.stdout.write(text)
        else:
            print(text.replace("\n", " "))
    return 0


if __name__ == "__main__":
    sys.exit(main())
