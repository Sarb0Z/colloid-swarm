#!/usr/bin/env python3
"""Append one row to the sources evidence trail.

Usage: sources-ledger.py           # payload on stdin

Reads {"project_dir", "agent", "tool_name", "tool_input"}, classifies a
supported lookup, and appends
`ts \t agent \t kind \t value` to .agents/.sources-ledger.

A Scrapling call that names a browser session writes a `browse` value of
`<page> session=<id> [host=<id>] [<address> ...]`: the page is the address of
the session's last `browser_fetch`, the only call that navigates (`-` when
none), `host=` names the host session the payload carries, and the addresses
are every http or https address in a `browser_actions` or `browser_evaluate`
call's input. Nothing else of a script or an action list is written.

An address is a trail of one token: userinfo is dropped, since it is a
credential and not part of the page, and a space is written `%20`. Only the
session branch writes a second token, so the page lookup reads nothing else.

The trail is capped rather than unbounded. Rolling at the append is the only
place that knows a row was added; the check is one stat call, so the rewrite
happens on roughly one lookup in a thousand and never on a small ledger.

A trail, never a gate: every failure path says why on stderr, records nothing
and exits 0.
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
# An address ends where script text can begin: whitespace, a quote, a backtick,
# a bracket, a brace, `;`, `,` or a template `${`. A leading `//host` is not one.
ADDRESS = re.compile(r"https?://(?:(?!\$\{)[^\s\"'`<>\\()\[\]{};,])+", re.IGNORECASE)
USERINFO = re.compile(r"^(https?://)[^/?#]*@", re.IGNORECASE)
# The same pattern as SESSION_ID_PATTERN in scrapling-mcp.py; a test compares them.
SESSION_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


def text(value, default=""):
    """A non-string field is a missing field, not a crash."""
    return value if isinstance(value, str) else default


def clean_url(value):
    """One token: no userinfo, no space. The query string stays."""
    return USERINFO.sub(r"\1", value.strip()).replace(" ", "%20")


def web_addresses(value):
    """Every http or https address in the strings of a call's input, in order, once each.

    Walks the whole structure but keeps only what matches an address, so a
    script body or a typed value never reaches the trail beyond its URLs.
    """
    if isinstance(value, str):
        found = [clean_url(match.rstrip(".:!?")) for match in ADDRESS.findall(value)]
    elif isinstance(value, dict):
        found = [a for item in value.values() for a in web_addresses(item)]
    elif isinstance(value, list):
        found = [a for item in value for a in web_addresses(item)]
    else:
        found = []
    return list(dict.fromkeys(found))


def page_of(ledger, session, host):
    """The page recorded for a browser session, or None.

    Reads only rows the session branch wrote: a `browse` row whose second token
    is `session=<id>` (every other value is one token). A row names a host
    session with `host=<id>`; with a host the row must carry the same one, and
    without a host the browser session alone matches. Only the tail of the trail is read.
    debt: scrapling-session-limits
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
        if len(tokens) < 2 or tokens[1] != "session=" + session:
            continue
        if host and "host=" + host not in tokens[2:3]:
            continue
        return tokens[0]
    return None


def session_row(tool_input, host, addresses, page):
    """The browse value `<page> session=<id> [host=<id>] [<address> ...]`, or None without a session."""
    session = text(tool_input.get("session_id")).strip()
    if not SESSION_ID.match(session):
        return None
    marks = ["session=" + session] + (["host=" + host] if host else [])
    return " ".join([page or "-"] + marks + addresses)


def source_row(payload, last_page):
    """Return (kind, value) for a supported lookup, or None.

    `last_page(session, host)` names the page recorded for a browser session.
    """
    tool = text(payload.get("tool_name"))
    raw_input = payload.get("tool_input")
    tool_input = raw_input if isinstance(raw_input, dict) else {}
    host = text(payload.get("session_id")).strip()
    host = host if SESSION_ID.match(host) else ""

    if tool.endswith(("__browser_actions", "__browser_evaluate")):
        session = text(tool_input.get("session_id")).strip()
        called = web_addresses({k: v for k, v in tool_input.items() if k != "session_id"})
        value = session_row(tool_input, host, called, last_page(session, host))
        return ("browse", value) if value else None
    if tool.endswith("__browser_fetch"):
        url = clean_url(text(tool_input.get("url")))
        return "browse", (url and session_row(tool_input, host, [], url)) or url

    if tool == "WebSearch":
        return "search", text(tool_input.get("query"))
    if tool in {"WebFetch", "FetchURL"} or tool.endswith("__fetch_readable"):
        return "fetch", clean_url(text(tool_input.get("url")))
    if tool.endswith(("__browser_navigate", "__browser_fetch_once")):
        return "browse", clean_url(text(tool_input.get("url")))
    if tool.endswith("__resolve_open_access"):
        return "search", text(tool_input.get("query"))
    if tool.endswith(("__resolve-library-id", "__query-docs")):
        return "search", text(tool_input.get("query"))
    if tool.startswith("mcp__plugin_exa_exa__"):
        url = clean_url(text(tool_input.get("url")))
        return ("fetch", url) if url else ("search", text(tool_input.get("query")))
    return None


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError as error:
        print(f"sources-ledger: the payload is not JSON, so nothing was recorded: {error}", file=sys.stderr)
        return 0
    if not isinstance(payload, dict):
        print("sources-ledger: the payload is not a JSON object, so nothing was recorded", file=sys.stderr)
        return 0

    project = text(payload.get("project_dir")) or os.environ.get("CLAUDE_PROJECT_DIR") or "."
    ledger = os.path.join(project, ".agents", ".sources-ledger")
    row = source_row(payload, lambda session, host: page_of(ledger, session, host))
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
            trail.write(f"{stamp}\t{agent}\t{kind}\t{value}\n")
        roll(ledger)
    except OSError as error:
        print(f"sources-ledger: could not record a {kind} row in {ledger}: {error}", file=sys.stderr)
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
    temporary = f"{ledger}.roll.{os.getpid()}"
    with open(temporary, "w", encoding="utf-8") as rolled:
        rolled.writelines(rows[-KEEP_ROWS:])
    os.replace(temporary, ledger)


if __name__ == "__main__":
    sys.exit(main())
