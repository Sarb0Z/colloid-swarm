#!/usr/bin/env python3
"""One reader for unit readouts: the status strip, the session-start note and
a person all read the same files.

A readout is one JSON file directly in `.agents/.readout/`:

    {"strip": "<short line or empty>", "note": "<text or empty>",
     "written_at": "<ISO-8601 UTC>", "session": "<session id>",
     "stale_after": <seconds>}

`session` is absent for a repository-wide readout, which is stored as
`<name>.json`; a session-scoped one is `<name>--<session>.json`, so two
sessions never overwrite each other. A name is lower-case words joined by
single hyphens. A session id keeps only [A-Za-z0-9_-], on write and on read.
`stale_after` (seconds, default 86400) is how long the readout is current;
past it, its strip segment and note carry its age: `(12m old)`, `(30h old)`,
`(3d old)`.

Only `*.json` files are readouts; any other file in the folder is the
writing unit's own ledger. Lifetime: `prune` (run at session start) removes
session-scoped readouts written over 7 days ago, `.write-*.tmp` files over an
hour old, and any non-`*.json` file whose mtime is over 7 days old, so a unit
that keeps a ledger here must touch it at least weekly. Repository-wide
readouts are never pruned; their writer owns them.

Strip text has every control character turned into a space. A note keeps its
newlines, turns other control characters into spaces, and is cut at 12 lines.

A readout is visible to a session when it carries no `session` or the same
one. A file that does not parse, or has no usable `written_at`, is reported as
`<name>: unreadable` rather than skipped, and never makes the reader fail:
the exit status is non-zero only for bad arguments.

Usage:
  readout.py write <name> [--session ID] [--strip TEXT] [--note TEXT]
                      [--stale-after SECONDS] [--repo DIR]
  readout.py strip <repo> <session>
  readout.py note  <repo> <session>
  readout.py show  [--repo DIR] [--session ID] [--all]
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

NAME = re.compile(r"[a-z0-9]+(-[a-z0-9]+)*")
SESSION_DROP = re.compile(r"[^A-Za-z0-9_-]")
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")
CONTROL_KEEPING_NEWLINE = re.compile(r"[\x00-\x09\x0b-\x1f\x7f-\x9f]")
SEGMENT_MAX = 60
NOTE_MAX_LINES = 12
DEFAULT_STALE_AFTER = 86400
PRUNE_SESSION_AFTER = timedelta(days=7)
PRUNE_FILE_AFTER = timedelta(days=7)
PRUNE_TEMP_AFTER = timedelta(hours=1)
SEPARATOR = "  ·  "
DEFAULT_REPO = str(Path(__file__).resolve().parents[3])


def folder(repo):
    return Path(repo) / ".agents" / ".readout"


def clean_session(session):
    """The one session-id form, used on write and on read."""
    return SESSION_DROP.sub("", session or "")


def write(repo, name, *, strip="", note="", session=None, stale_after=DEFAULT_STALE_AFTER):
    """Write one readout atomically and return its path."""
    if not NAME.fullmatch(name):
        raise ValueError(f"readout name {name!r} must be lower-case words joined by single hyphens")
    if stale_after < 0:
        raise ValueError("stale_after must be zero or more seconds")
    record = {
        "strip": strip,
        "note": note,
        "written_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "stale_after": stale_after,
    }
    if session:
        session = clean_session(session)
        if not session:
            raise ValueError("session id has no [A-Za-z0-9_-] character")
        record["session"] = session
    directory = folder(repo)
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / (f"{name}--{record['session']}.json" if session else f"{name}.json")
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
        self.name = CONTROL.sub(" ", path.stem)
        self.stale_after = DEFAULT_STALE_AFTER
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
            self.session = clean_session(str(data.get("session") or ""))
            self.stale_after = int(data.get("stale_after", DEFAULT_STALE_AFTER))
            self.readable = True
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            return
        suffix = f"--{self.session}"
        if self.session and self.name.endswith(suffix):
            self.name = self.name[: -len(suffix)]

    def visible_to(self, session):
        return not self.readable or not self.session or self.session == clean_session(session)

    def age(self, now):
        """` (12m old)`, ` (30h old)` or ` (3d old)` past stale_after, else nothing."""
        elapsed = (now - self.written_at).total_seconds()
        if elapsed <= self.stale_after:
            return ""
        minutes = int(elapsed // 60)
        if minutes < 60:
            return f" ({minutes}m old)"
        hours = minutes // 60
        return f" ({hours}h old)" if hours < 48 else f" ({hours // 24}d old)"


def readouts(repo):
    directory = folder(repo)
    if not directory.is_dir():
        return []
    return [Readout(path) for path in sorted(directory.glob("*.json")) if path.is_file()]


def visible(repo, session, include_all=False):
    return [r for r in readouts(repo) if include_all or r.visible_to(session)]


def cut(text):
    text = CONTROL.sub(" ", text)
    return text if len(text) <= SEGMENT_MAX else text[: SEGMENT_MAX - 1] + "…"


def show_command(session):
    """The command, runnable from the repository root, that shows what a
    session may see; without a session, every readout."""
    session = clean_session(session)
    flag = f"--session {session}" if session else "--all"
    return f"python3 .agents/hooks/lib/readout.py show {flag}"


def note_lines(note, limit, command):
    """The note with control characters (newlines kept) turned into spaces,
    cut to `limit` lines, with `command` named, when a limit is given."""
    lines = CONTROL_KEEPING_NEWLINE.sub(" ", note).split("\n")
    if limit is not None and len(lines) > limit:
        hidden = len(lines) - limit
        lines = lines[:limit] + [f"… {hidden} more lines: {command}"]
    return "\n".join(lines)


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
            lines.append(f"{readout.name}{readout.age(now)}: {note_lines(readout.note, NOTE_MAX_LINES, show_command(session))}")
    return "\n".join(lines)


def show_text(repo, session, include_all):
    now = datetime.now(timezone.utc)
    blocks = []
    for readout in visible(repo, session, include_all):
        if not readout.readable:
            blocks.append(f"{readout.name}: unreadable ({readout.path.name})")
            continue
        scope = f" [session {readout.session}]" if readout.session else ""
        age = readout.age(now) or f" (written {readout.written_at.strftime('%Y-%m-%d %H:%M')}Z)"
        block = [f"{readout.name}{scope}{age}"]
        if readout.strip:
            block.append(f"  strip: {CONTROL.sub(' ', readout.strip)}")
        if readout.note:
            block.append("  note: " + note_lines(readout.note, None, None).replace("\n", "\n    "))
        blocks.append("\n".join(block))
    return "\n".join(blocks)


def prune(repo):
    now = datetime.now(timezone.utc)
    for readout in readouts(repo):
        if readout.readable and readout.session and now - readout.written_at > PRUNE_SESSION_AFTER:
            readout.path.unlink(missing_ok=True)
    directory = folder(repo)
    if not directory.is_dir():
        return
    for path in directory.iterdir():
        if not path.is_file() or path.suffix == ".json":
            continue
        limit = PRUNE_TEMP_AFTER if path.name.startswith(".write-") and path.suffix == ".tmp" else PRUNE_FILE_AFTER
        if now - datetime.fromtimestamp(path.stat().st_mtime, timezone.utc) > limit:
            path.unlink(missing_ok=True)


def main(argv):
    parser = argparse.ArgumentParser(prog="readout.py", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)

    w = sub.add_parser("write")
    w.add_argument("name")
    w.add_argument("--session")
    w.add_argument("--strip", default="")
    w.add_argument("--note", default="")
    w.add_argument("--stale-after", type=int, default=DEFAULT_STALE_AFTER, metavar="SECONDS")
    w.add_argument("--repo", default=DEFAULT_REPO)

    for name in ("strip", "note"):
        p = sub.add_parser(name)
        p.add_argument("repo")
        p.add_argument("session")

    s = sub.add_parser("show")
    s.add_argument("--repo", default=DEFAULT_REPO)
    s.add_argument("--session", default="")
    s.add_argument("--all", action="store_true")

    p = sub.add_parser("prune")
    p.add_argument("repo")

    args = parser.parse_args(argv)
    if args.command == "write":
        try:
            write(args.repo, args.name, strip=args.strip, note=args.note, session=args.session,
                  stale_after=args.stale_after)
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
