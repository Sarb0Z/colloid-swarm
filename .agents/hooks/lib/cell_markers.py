#!/usr/bin/env python3
"""Which marker a dispatched cell carries — READ-ONLY or NOTES-ONLY from its
prompt's opening, or OUTSIDE when its prompt placed it outside the checkout (a
workloop lane, a WORKSPACE line) — and what that marker lets the cell write.

Usage: cell_markers.py record <project> <session> <tool_use_id> <marker>
       cell_markers.py decide <repo> <project> <session> <transcript_path> <agent_id>
       cell_markers.py marked <project> <session> <transcript_path> <agent_id>
       cell_markers.py sweep <project> <session> <transcript_path> <agent_id>...
       cell_markers.py resumed <session> <transcript_path> <agent_id>:<offset>...

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
  OUTSIDE    denied when any target belongs to the checkout
             (write_targets.in_checkout: a nested lane worktree does not).

`marked` exits 3 when the cell carries a marker, 0 when it carries none and 4
when its metadata cannot be read; the gate asks it when a registered cell stops
or dies. With no marked dispatch recorded this session every cell is unmarked
and no metadata is read.

`sweep` names, of the live writers given, each that no longer counts, one
`<agent_id> <reason>` line apiece, and says nothing of the rest:
  marked            alive, and its metadata now links it to a marker. The
                    metadata does not exist yet at SubagentStart (2.1.299), so a
                    marked cell sharing a writer's type registers there.
  ended-<status>    its own transcript, `agent-<agent_id>.jsonl` beside the
                    metadata, shows it ended without a SubagentStop: the last
                    user or assistant record is `[Request interrupted by user…`
                    (a TaskStop, or the user's Esc while it ran in the
                    foreground, which fires no hook at all). <status> is what
                    `marked` would report. An API-error record is no ending: a
                    cell may recover from one and keep working.
A missing transcript is not an ending; an unreadable one is reported on stderr
and the cell stays live.

`resumed` takes `<agent_id>:<offset>` pairs, each a cell that left the live
writers and the size its transcript had then, and prints each cell whose
transcript past that offset holds a user or assistant record that is neither
an API error nor an interruption: the cell is working again.
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
UNKNOWN = 4
INTERRUPTED = "[Request interrupted by user"
TAIL_BLOCK = 65536

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


def cell_file(transcript_path, session, agent_id, suffix):
    return os.path.join(os.path.dirname(transcript_path), session, "subagents", f"agent-{agent_id}{suffix}")


def meta_path(transcript_path, session, agent_id):
    return cell_file(transcript_path, session, agent_id, ".meta.json")


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


def last_turn(path):
    """The cell transcript's last user or assistant record, read backwards from
    the end; None when there is none. Attachment and system records carry no
    progress, so they are skipped."""
    with open(path, "rb") as source:
        source.seek(0, os.SEEK_END)
        position = source.tell()
        tail = b""
        last = True
        while position > 0:
            step = min(TAIL_BLOCK, position)
            position -= step
            source.seek(position)
            tail = source.read(step) + tail
            lines = tail.split(b"\n")
            # The first piece may be a partial line unless the file's start was read.
            complete = lines if position == 0 else lines[1:]
            for raw in reversed(complete):
                if not raw.strip():
                    continue
                was_last, last = last, False
                try:
                    record = json.loads(raw)
                except ValueError:
                    if was_last:
                        return None  # a record still being written: the cell is at work
                    continue
                if isinstance(record, dict) and record.get("type") in ("user", "assistant"):
                    return record
            tail = lines[0] if position else b""
    return None


def is_interruption(record):
    if record.get("type") != "user":
        return False
    content = (record.get("message") or {}).get("content")
    if isinstance(content, str):
        return content.startswith(INTERRUPTED)
    return isinstance(content, list) and any(
        isinstance(part, dict) and part.get("type") == "text" and str(part.get("text") or "").startswith(INTERRUPTED)
        for part in content)


def resumed(session, transcript_path, pairs):
    """The agent ids, of `<agent_id>:<offset>` pairs, whose transcript shows
    progress past the offset."""
    found = []
    for pair in pairs:
        agent_id, _, offset = pair.partition(":")
        path = cell_file(transcript_path, session, agent_id, ".jsonl")
        try:
            with open(path, "rb") as source:
                source.seek(int(offset))
                added = source.read()
        except (OSError, ValueError) as error:
            print(f"cell_markers.py: {path} cannot be read past {offset} ({error}); {agent_id} stays off the live writers.",
                  file=sys.stderr)
            continue
        for raw in added.split(b"\n"):
            try:
                record = json.loads(raw)
            except ValueError:
                continue  # a partial line, at either end of what was added
            if (isinstance(record, dict) and record.get("type") in ("user", "assistant")
                    and record.get("isApiErrorMessage") is not True and not is_interruption(record)):
                found.append(agent_id)
                break
    return found


def sweep(project, session, transcript_path, agent_ids):
    """(agent_id, reason) for each live writer that no longer counts."""
    found = []
    for agent_id in agent_ids:
        state = status(project, session, transcript_path, agent_id)
        path = cell_file(transcript_path, session, agent_id, ".jsonl")
        try:
            record = last_turn(path)
        except FileNotFoundError:
            # Claude Code writes the transcript asynchronously, so a cell that
            # has just started may have none yet.
            record = None
        except OSError as error:
            print(f"cell_markers.py: {path} cannot be read ({error.strerror}); {agent_id} stays live.", file=sys.stderr)
            record = None
        if record is not None and is_interruption(record):
            found.append((agent_id, f"ended-{state}"))
        elif state == "marked":
            found.append((agent_id, "marked"))
    return found


def status(project, session, transcript_path, agent_id):
    """marked, unmarked or unknown. With no marked dispatch recorded this
    session every cell is unmarked, and no metadata is read."""
    if not os.path.exists(ledger(project, session)):
        return "unmarked"
    marker = marker_of(project, session, transcript_path, agent_id)
    return "marked" if marker in MARKERS else marker


def registered(project, session, agent_id):
    """True when the cell is on the gate's live writers; a line with a `gone`
    column records a cell that left them."""
    try:
        with open(os.path.join(project, ".agents", f".writers-live-{session}"), encoding="utf-8") as source:
            return any(line.split("\t")[0] == agent_id and "gone" not in line.split("\t")[3:4]
                       for line in source.read().splitlines())
    except FileNotFoundError:
        return False


def touches_checkout(project, payload):
    """True when any target the write names belongs to the checkout; a relative path is the checkout's.
    A target in a worktree nested in the checkout, a workloop lane's, is not."""
    root = os.path.realpath(project)
    return any(write_targets.in_checkout(path, root) for path in write_targets.resolved(root, payload.get("tool_input")))


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
        return {"marked": MARKED, "unmarked": 0, "unknown": UNKNOWN}[status(*argv[2:])]
    if command == "sweep" and len(argv) >= 6:
        for agent_id, reason in sweep(argv[2], argv[3], argv[4], argv[5:]):
            print(f"{agent_id}\t{reason}")
        return 0
    if command == "resumed" and len(argv) >= 5:
        for agent_id in resumed(argv[2], argv[3], argv[4:]):
            print(agent_id)
        return 0
    raise SystemExit("cell_markers.py: usage: cell_markers.py record <project> <session> <tool_use_id> <marker> | "
                     "decide <repo> <project> <session> <transcript_path> <agent_id> | "
                     "marked <project> <session> <transcript_path> <agent_id> | "
                     "sweep <project> <session> <transcript_path> <agent_id>... | "
                     "resumed <session> <transcript_path> <agent_id>:<offset>...")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
