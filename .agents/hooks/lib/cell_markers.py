#!/usr/bin/env python3
"""Which marker a dispatched cell carries — READ-ONLY or NOTES-ONLY from its
prompt's opening, or OUTSIDE when its prompt placed it outside the checkout (a
workloop lane, a WORKSPACE line) — and what that marker lets the cell write.

Usage: cell_markers.py record <project> <session> <tool_use_id> <marker>
       cell_markers.py decide <repo> <project> <session> <transcript_path> <agent_id>
       cell_markers.py marked <project> <session> <transcript_path> <agent_id>

The parallel-writers gate sees a marker once, at dispatch (PreToolUse on the
Agent tool, which carries the prompt and a `tool_use_id`), but must enforce it
later, when the cell itself writes. SubagentStart carries no dispatch id, so
the link runs through Claude Code's own record of the cell:
`<dirname(transcript_path)>/<session>/subagents/agent-<agent_id>.meta.json`
holds a `toolUseId` equal to the dispatching call's id. `record` keeps
`<tool_use_id> <marker>` in `.agents/.cell-markers-<session>`, which
session-start.sh clears with the rest of the gate's state. It exits 1, with
one stderr line, when the id is empty once cleaned or the ledger cannot be
written: a marked dispatch with no record would run as a writer. Both sides of
the join pass through `clean`.

`decide` reads the cell's PreToolUse payload on stdin and prints the reason
to deny the write, or nothing. It exits 3 when the cell is marked, so the gate
takes it off the live writers, and 0 otherwise:
  unmarked   a writer; no decision.
  unknown    a registered writer gets a stderr notice and no decision; any
             other cell is denied, since only a marked cell can be an
             unregistered non-reader.
  READ-ONLY  denied, wherever the target is.
  NOTES-ONLY denied unless the product folder holds every target
             (product_folder.py).
  OUTSIDE    denied when any target lies inside the checkout.

`marked` exits 3 when the cell carries a marker and 0 otherwise, unreadable
metadata included; the gate asks it when a registered cell stops before its
first write.
"""

import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import product_folder  # noqa: E402
import write_targets  # noqa: E402

MARKERS = ("READ-ONLY", "NOTES-ONLY", "OUTSIDE")
MARKED = 3

READ_ONLY_DENIAL = (
    "This cell was dispatched READ-ONLY, so it writes nothing, wherever the target is. Return the content as "
    "the reply, or have the lead dispatch a NOTES-ONLY cell to write notes in the product folder.")
NOTES_ONLY_DENIAL = (
    "This cell was dispatched NOTES-ONLY, so it writes only in the product folder (hooks.product_folder.enabled), "
    "never in a checkout, a hidden folder, an instruction file, a tools, backups, node_modules or __pycache__ "
    "folder, or a .py, .sh, .js or .mjs file. Return the content as the reply, or have the lead dispatch a writer.")
OUTSIDE_DENIAL = (
    "This cell was dispatched to work outside this checkout (a workloop lane or a WORKSPACE line), so it may not "
    "write in it. Make the change in the directory you were given; if the task needs this checkout, stop and report "
    "that to your lead.")


def clean(tool_use_id):
    return re.sub(r"[^A-Za-z0-9_-]", "", tool_use_id)


def ledger(project, session):
    return os.path.join(project, ".agents", f".cell-markers-{session}")


def meta_path(transcript_path, session, agent_id):
    return os.path.join(os.path.dirname(transcript_path), session, "subagents", f"agent-{agent_id}.meta.json")


def record(project, session, tool_use_id, marker):
    """Keeps the marker against the cleaned id; False when the id cleans to nothing."""
    tool_use_id = clean(tool_use_id)
    if not tool_use_id:
        print("cell_markers.py: the dispatch carries no tool_use_id to record its marker under.", file=sys.stderr)
        return False
    try:
        with open(ledger(project, session), "a", encoding="utf-8") as out:
            out.write(f"{tool_use_id}\t{marker}\n")
    except OSError as error:
        print(f"cell_markers.py: {ledger(project, session)} cannot be written ({error.strerror}).", file=sys.stderr)
        return False
    return True


def marker_of(project, session, transcript_path, agent_id):
    """READ-ONLY, NOTES-ONLY, OUTSIDE, `unmarked` (metadata read, no record) or
    `unknown` (metadata missing or unreadable, with the reason on stderr)."""
    path = meta_path(transcript_path, session, agent_id)
    try:
        with open(path, encoding="utf-8") as source:
            tool_use_id = json.load(source)["toolUseId"]
        if not isinstance(tool_use_id, str) or not clean(tool_use_id):
            raise ValueError("toolUseId is not a non-empty id")
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"cell_markers.py: {path} gives no toolUseId ({error})", file=sys.stderr)
        return "unknown"
    try:
        with open(ledger(project, session), encoding="utf-8") as source:
            lines = source.read().splitlines()
    except FileNotFoundError:
        return "unmarked"
    for line in lines:
        recorded, _, marker = line.partition("\t")
        if recorded == clean(tool_use_id) and marker in MARKERS:
            return marker
    return "unmarked"


def registered(project, session, agent_id):
    """True when the cell is on the gate's live writers."""
    try:
        with open(os.path.join(project, ".agents", f".writers-live-{session}"), encoding="utf-8") as source:
            return any(line.split("\t")[0] == agent_id for line in source.read().splitlines())
    except FileNotFoundError:
        return False


def touches_checkout(project, payload):
    """True when any target the write names lies in the checkout; a relative path is the checkout's."""
    root = os.path.realpath(project)
    return any(write_targets.under(path, root) for path in write_targets.resolved(root, payload.get("tool_input")))


def decide(repo, project, session, transcript_path, agent_id, payload):
    """(the reason to deny the cell's write or "", whether the cell is marked)."""
    marker = marker_of(project, session, transcript_path, agent_id)
    if marker == "unmarked":
        return "", False
    if marker == "unknown":
        if registered(project, session, agent_id):
            print(f"parallel-writers-gate: no dispatch marker could be read for registered writer {agent_id}; "
                  "leaving it a writer.", file=sys.stderr)
            return "", False
        return (f"This cell is not a registered writer and its dispatch marker could not be read (Claude Code's "
                f"metadata at {meta_path(transcript_path, session, agent_id)}), so the gate cannot tell whether "
                "it may write. Dispatch it as a writer, READ-ONLY, or NOTES-ONLY and retry.", False)
    if marker == "READ-ONLY":
        return READ_ONLY_DENIAL, True
    if marker == "OUTSIDE":
        return (OUTSIDE_DENIAL if touches_checkout(project, payload) else ""), True
    return ("" if product_folder.payload_holds(repo, payload) else NOTES_ONLY_DENIAL), True


def main(argv):
    command = argv[1] if len(argv) > 1 else ""
    if command == "record" and len(argv) == 6:
        project, session, tool_use_id, marker = argv[2:]
        if marker.upper() not in MARKERS:
            raise SystemExit(f"cell_markers.py: {marker} is not one of {', '.join(MARKERS)}")
        return 0 if record(project, session, tool_use_id, marker.upper()) else 1
    if command == "decide" and len(argv) == 7:
        try:
            payload = json.load(sys.stdin)
        except ValueError:
            payload = {}
        reason, marked = decide(*argv[2:], payload if isinstance(payload, dict) else {})
        print(reason, end="")
        return MARKED if marked else 0
    if command == "marked" and len(argv) == 6:
        return MARKED if marker_of(*argv[2:]) in MARKERS else 0
    raise SystemExit("cell_markers.py: usage: cell_markers.py record <project> <session> <tool_use_id> <marker> | "
                     "decide <repo> <project> <session> <transcript_path> <agent_id> | "
                     "marked <project> <session> <transcript_path> <agent_id>")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
