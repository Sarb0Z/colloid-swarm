#!/usr/bin/env python3
"""Append one row to the sources evidence trail.

Usage: sources-ledger.py           # payload on stdin

Reads {"project_dir", "agent", "kind", "value"} and appends
`ts \t agent \t kind \t value` to .agents/.sources-ledger.

The trail is capped rather than unbounded. Rolling at the append is the only
place that knows a row was added; the check is one stat call, so the rewrite
happens on roughly one lookup in a thousand and never on a small ledger.

A trail, never a gate: every failure path exits 0 and records nothing.
"""

import json
import os
import sys
import time

# Enough to carry several long sessions of lookups, small enough to read.
CAP_BYTES = 256 * 1024
KEEP_ROWS = 2000


def text(value, default=""):
    """A non-string field is a missing field, not a crash."""
    return value if isinstance(value, str) else default


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return 0
    if not isinstance(payload, dict):
        return 0

    value = text(payload.get("value")).strip()
    if not value:
        return 0

    project = text(payload.get("project_dir")) or os.environ.get("CLAUDE_PROJECT_DIR") or "."
    ledger = os.path.join(project, ".agents", ".sources-ledger")
    agent = text(payload.get("agent"), "main").strip() or "main"
    kind = text(payload.get("kind"), "fetch").strip() or "fetch"
    value = value.replace("\t", " ").replace("\n", " ")[:500]
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    try:
        with open(ledger, "a", encoding="utf-8") as trail:
            trail.write("%s\t%s\t%s\t%s\n" % (stamp, agent, kind, value))
        roll(ledger)
    except OSError:
        pass
    return 0


def roll(ledger):
    """Keep the newest rows once the trail passes its cap."""
    if os.path.getsize(ledger) <= CAP_BYTES:
        return
    with open(ledger, encoding="utf-8", errors="replace") as trail:
        rows = trail.readlines()
    if len(rows) <= KEEP_ROWS:
        return
    # Trim by bytes as well as rows: a session of long values would otherwise
    # sit above the cap forever, paying a full read on every append.
    while len(rows) > 1 and sum(len(row) for row in rows[-KEEP_ROWS:]) > CAP_BYTES:
        rows = rows[len(rows) // 2:]
    # Write beside it and rename, so a crash mid-roll cannot leave a torn trail.
    # The name carries the pid: parallel researcher cells capture concurrently,
    # and a fixed name lets two rolls interleave into one corrupt file.
    temporary = "%s.roll.%d" % (ledger, os.getpid())
    with open(temporary, "w", encoding="utf-8") as rolled:
        rolled.writelines(rows[-KEEP_ROWS:])
    os.replace(temporary, ledger)


if __name__ == "__main__":
    sys.exit(main())
