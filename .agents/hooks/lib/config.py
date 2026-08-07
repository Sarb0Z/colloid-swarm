#!/usr/bin/env python3
"""Read scaffold toggles out of .agents/config.json.

Usage: config.py <config-path> <dotted.key>=<default> ...

Prints one line per key, in the order given. A `true` or `false` default makes
the key a toggle and prints `yes` or `no`, so the caller compares a word instead
of reasoning about JSON. Any other default prints as it stands.

A toggle that defaults on is off only when the file says exactly `false`, and a
toggle that defaults off is on only when the file says exactly `true`. An
absent file, unreadable JSON, or a key whose parent is not an object all yield
the default: config.json states the exceptions, and its absence is not one.
"""

import json
import sys


def default_of(text):
    if text == "true":
        return True
    if text == "false":
        return False
    return text


def read(settings, path, default):
    node = settings
    for name in path.split("."):
        if not isinstance(node, dict) or name not in node:
            return default
        node = node[name]
    if isinstance(default, bool):
        return node is not False if default else node is True
    return node


def main():
    if len(sys.argv) < 3:
        raise SystemExit("config.py: usage: config.py <config-path> <key>=<default> ...")
    try:
        with open(sys.argv[1], encoding="utf-8") as source:
            settings = json.load(source)
    except (OSError, ValueError):
        settings = {}
    if not isinstance(settings, dict):
        settings = {}
    for argument in sys.argv[2:]:
        key, _, raw = argument.partition("=")
        default = default_of(raw)
        value = read(settings, key, default)
        print(("yes" if value else "no") if isinstance(default, bool) else value)
    return 0


if __name__ == "__main__":
    sys.exit(main())
