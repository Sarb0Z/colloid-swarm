#!/usr/bin/env python3
"""One reader for unit readouts: the status strip, the session-start note and
a person all read the same files.

A readout is one JSON file directly in `.agents/.readout/`:

    {"strip": "<short line or empty>", "note": "<text or empty>",
     "written_at": "<ISO-8601 UTC>", "session": "<session id>"}

`session` is absent for a repository-wide readout, which is stored as
`<name>.json`; a session-scoped one is `<name>--<session>.json`, so two
sessions never overwrite each other. Only `*.json` files are readouts; any
other file in the folder belongs to the unit that put it there.

A readout is visible to a session when it carries no `session` or the same
one. A file that does not parse, or has no usable `written_at`, is reported as
`<name>: unreadable` rather than skipped, and never makes the reader fail:
the exit status is non-zero only for bad arguments.

Usage:
  readout.py write <name> [--session ID] [--strip TEXT] [--note TEXT] [--repo DIR]
  readout.py strip <repo> <session>
  readout.py note  <repo> <session>
  readout.py show  <repo> [<session>] [--all]
  readout.py prune <repo>
"""
import argparse
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

NAME = re.compile(r"[a-z0-9][a-z0-9-]*")
SESSION = re.compile(r"[A-Za-z0-9_-]+")
SEGMENT_MAX = 60
OLD_AFTER = timedelta(hours=24)
PRUNE_AFTER = timedelta(days=7)
SEPARATOR = "  ·  "


def folder(repo):
    return Path(repo) / ".agents" / ".readout"


def write(repo, name, *, strip="", note="", session=None):
    """Write one readout atomically and return its path."""
    if not NAME.fullmatch(name):
        raise ValueError(f"readout name {name!r} must match [a-z0-9][a-z0-9-]*")
    if session is not None and not SESSION.fullmatch(session):
        raise ValueError(f"session id {session!r} must match [A-Za-z0-9_-]+")
    record = {
        "strip": strip,
        "note": note,
        "written_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    if session is not None:
        record["session"] = session
    directory = folder(repo)
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / (f"{name}--{session}.json" if session else f"{name}.json")
    handle, temp = tempfile.mkstemp(dir=directory, prefix=".write-", suffix=".tmp")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            json.dump(record, out)
            out.write("\n")
        os.replace(temp, target)
    except BaseException:
        Path(temp).unlink(missing_ok=True)
        raise
    return target


class Readout:
    def __init__(self, path):
        self.path = path
        self.name = path.stem
        self.strip = ""
        self.note = ""
        self.session = None
        self.written_at = None
        self.readable = False
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            self.written_at = datetime.fromisoformat(str(data["written_at"]).replace("Z", "+00:00"))
            if self.written_at.tzinfo is None:
                self.written_at = self.written_at.replace(tzinfo=timezone.utc)
            self.strip = str(data.get("strip") or "")
            self.note = str(data.get("note") or "")
            self.session = data.get("session")
            self.readable = True
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            return
        suffix = f"--{self.session}"
        if self.session and self.name.endswith(suffix):
            self.name = self.name[: -len(suffix)]

    def visible_to(self, session):
        return not self.readable or not self.session or self.session == session

    def age(self, now):
        """` (30h old)` or ` (3d old)` past a day, else nothing."""
        elapsed = now - self.written_at
        if elapsed <= OLD_AFTER:
            return ""
        hours = int(elapsed.total_seconds() // 3600)
        return f" ({hours}h old)" if hours < 48 else f" ({hours // 24}d old)"


def readouts(repo):
    directory = folder(repo)
    if not directory.is_dir():
        return []
    return [Readout(path) for path in sorted(directory.glob("*.json")) if path.is_file()]


def visible(repo, session, include_all=False):
    return [r for r in readouts(repo) if include_all or r.visible_to(session)]


def cut(text):
    return text if len(text) <= SEGMENT_MAX else text[: SEGMENT_MAX - 1] + "…"


def strip_line(repo, session):
    now = datetime.now(timezone.utc)
    segments = []
    for readout in visible(repo, session):
        if not readout.readable:
            segments.append(f"{readout.name}: unreadable")
        elif readout.strip:
            segments.append(cut(readout.strip) + readout.age(now))
    return SEPARATOR.join(segments)


def note_text(repo, session):
    now = datetime.now(timezone.utc)
    lines = []
    for readout in visible(repo, session):
        if not readout.readable:
            lines.append(f"{readout.name}: unreadable")
        elif readout.note:
            lines.append(f"{readout.name}{readout.age(now)}: {readout.note}")
    return "\n".join(lines)


def show_text(repo, session, include_all):
    now = datetime.now(timezone.utc)
    blocks = []
    for readout in visible(repo, session, include_all):
        if not readout.readable:
            blocks.append(f"{readout.name}: unreadable ({readout.path.name})")
            continue
        scope = f" [session {readout.session}]" if readout.session else ""
        age = readout.age(now) or f" ({readout.written_at.strftime('%Y-%m-%d %H:%M')}Z)"
        block = [f"{readout.name}{scope}{age}"]
        if readout.strip:
            block.append(f"  strip: {readout.strip}")
        if readout.note:
            block.append("  note: " + readout.note.replace("\n", "\n    "))
        blocks.append("\n".join(block))
    return "\n".join(blocks)


def prune(repo):
    now = datetime.now(timezone.utc)
    for readout in readouts(repo):
        if readout.readable and readout.session and now - readout.written_at > PRUNE_AFTER:
            readout.path.unlink(missing_ok=True)


def main(argv):
    parser = argparse.ArgumentParser(prog="readout.py", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)

    w = sub.add_parser("write")
    w.add_argument("name")
    w.add_argument("--session")
    w.add_argument("--strip", default="")
    w.add_argument("--note", default="")
    w.add_argument("--repo", default=str(Path(__file__).resolve().parents[3]))

    for name in ("strip", "note"):
        p = sub.add_parser(name)
        p.add_argument("repo")
        p.add_argument("session")

    s = sub.add_parser("show")
    s.add_argument("repo")
    s.add_argument("session", nargs="?", default="")
    s.add_argument("--all", action="store_true")

    p = sub.add_parser("prune")
    p.add_argument("repo")

    args = parser.parse_args(argv)
    if args.command == "write":
        try:
            write(args.repo, args.name, strip=args.strip, note=args.note, session=args.session)
        except ValueError as error:
            parser.error(str(error))
    elif args.command == "strip":
        line = strip_line(args.repo, args.session)
        if line:
            print(line)
    elif args.command == "note":
        text = note_text(args.repo, args.session)
        if text:
            print(text)
    elif args.command == "show":
        text = show_text(args.repo, args.session, args.all)
        if text:
            print(text)
    else:
        prune(args.repo)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
