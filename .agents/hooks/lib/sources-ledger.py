#!/usr/bin/env python3
"""Append one row to the sources evidence trail.

Usage: sources-ledger.py           # payload on stdin

Reads {"project_dir", "agent", "tool_name", "tool_input"}, classifies a
supported lookup, and appends
`ts \t agent \t kind \t value` to .agents/.sources-ledger.

A Scrapling call that names a browser session writes a `browse` value of
`<page> session=<id> [<address> ...]`: the page is the newest address the trail
holds for that session (`-` when none), and the addresses are every http or
https address in a `browser_actions` or `browser_evaluate` call's input. Nothing
else of a script or an action list is written.

The trail is capped rather than unbounded. Rolling at the append is the only
place that knows a row was added; the check is one stat call, so the rewrite
happens on roughly one lookup in a thousand and never on a small ledger.

A trail, never a gate: every failure path exits 0 and records nothing.
"""

import json
import os
import re
import sys
import time

# Enough to carry several long sessions of lookups, small enough to read.
CAP_BYTES = 256 * 1024
KEEP_ROWS = 2000
# How far back a session's last page is looked up.
TAIL_BYTES = 64 * 1024
ADDRESS = re.compile(r"https?://[^\s\"'`<>\\]+")
SESSION_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


def text(value, default=""):
    """A non-string field is a missing field, not a crash."""
    return value if isinstance(value, str) else default


def web_addresses(value):
    """Every http or https address in the strings of a call's input, in order, once each.

    Walks the whole structure but keeps only what matches an address, so a
    script body or a typed value never reaches the trail beyond its URLs.
    """
    if isinstance(value, str):
        found = [match.rstrip(".,;:!?)]}") for match in ADDRESS.findall(value)]
    elif isinstance(value, dict):
        found = [a for item in value.values() for a in web_addresses(item)]
    elif isinstance(value, list):
        found = [a for item in value for a in web_addresses(item)]
    else:
        found = []
    return list(dict.fromkeys(found))


def page_of(ledger, session):
    """The newest address the ledger recorded for a browser session, or None.

    A session-bearing browse row is `<page> session=<id> [<address> ...]` with
    `-` for a page not yet recorded. Only the tail of the trail is read.
    """
    try:
        with open(ledger, "rb") as trail:
            trail.seek(0, os.SEEK_END)
            trail.seek(max(0, trail.tell() - TAIL_BYTES))
            rows = trail.read().decode("utf-8", errors="replace").splitlines()
    except OSError:
        return None
    for row in reversed(rows):
        fields = row.split("\t")
        if len(fields) != 4 or fields[2] != "browse":
            continue
        tokens = fields[3].split(" ")
        if "session=" + session in tokens[1:2]:
            return tokens[0]
    return None


def session_row(tool_input, addresses, page):
    """The browse value `<page> session=<id> [<address> ...]`, or None without a session."""
    session = text(tool_input.get("session_id")).strip()
    if not SESSION_ID.match(session):
        return None
    return " ".join([page or "-", "session=" + session] + addresses)


def source_row(payload, last_page):
    """Return (kind, value) for a supported lookup, or None.

    `last_page(session)` names the newest address recorded for a browser session.
    """
    tool = text(payload.get("tool_name"))
    raw_input = payload.get("tool_input")
    tool_input = raw_input if isinstance(raw_input, dict) else {}

    if tool.endswith(("__browser_actions", "__browser_evaluate")):
        session = text(tool_input.get("session_id")).strip()
        called = web_addresses({k: v for k, v in tool_input.items() if k != "session_id"})
        value = session_row(tool_input, called, last_page(session))
        return ("browse", value) if value else None
    if tool.endswith("__browser_fetch"):
        url = text(tool_input.get("url")).strip()
        return "browse", (url and session_row(tool_input, [], url)) or url

    if tool == "WebSearch":
        return "search", text(tool_input.get("query"))
    if tool in {"WebFetch", "FetchURL"} or tool.endswith("__fetch_readable"):
        return "fetch", text(tool_input.get("url"))
    if tool.endswith(("__browser_navigate", "__browser_fetch_once")):
        return "browse", text(tool_input.get("url"))
    if tool.endswith("__resolve_open_access"):
        return "search", text(tool_input.get("query"))
    if tool.endswith(("__resolve-library-id", "__query-docs")):
        return "search", text(tool_input.get("query"))
    if tool.startswith("mcp__plugin_exa_exa__"):
        url = text(tool_input.get("url"))
        return ("fetch", url) if url else ("search", text(tool_input.get("query")))
    return None


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return 0
    if not isinstance(payload, dict):
        return 0

    project = text(payload.get("project_dir")) or os.environ.get("CLAUDE_PROJECT_DIR") or "."
    ledger = os.path.join(project, ".agents", ".sources-ledger")
    row = source_row(payload, lambda session: page_of(ledger, session))
    if row is None:
        return 0
    kind, value = row
    value = value.strip()
    if not value:
        return 0

    agent = text(payload.get("agent"), "unknown").strip() or "unknown"
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
