"""The operator's dismissals of dead agents: the one record the death reader keeps of its own.

`.agents/.agents-dismissed` (gitignored) holds one line per dismissal,
`<ISO time>\t<agent id>\t<reason>`. `workloop.py dismiss` appends under an
`fcntl` lock on `.agents/.agents-dismissed.lock`, and in the same hold rewrites
the file without lines older than 30 days; by then the agent is out of the
reader's 7-day window and its cache, so nothing would show it again unless it
works again. The reader reads without the lock: an append and the rewrite's
atomic replace each leave a whole file.
"""

from __future__ import annotations

import calendar
import fcntl
import os
import tempfile
import time
from pathlib import Path

FILE = ".agents-dismissed"
KEEP_SECONDS = 30 * 86400
STAMP = "%Y-%m-%dT%H:%M:%SZ"


def entries(agents_dir: Path) -> list[list[str]]:
    try:
        text = (agents_dir / FILE).read_text()
    except FileNotFoundError:
        return []
    return [line.split("\t", 2) for line in text.splitlines() if line.count("\t") >= 2]


def dismissed(agents_dir: Path) -> set[str]:
    return {entry[1] for entry in entries(agents_dir)}


def age(entry: list[str], now: float, path: Path) -> float:
    try:
        return now - calendar.timegm(time.strptime(entry[0], STAMP))
    except ValueError as error:
        raise ValueError(f"{path} has a line whose time {entry[0]!r} is not {STAMP}; fix or delete it") from error


def dismiss(agents_dir: Path, agent_id: str, reason: str, now: float) -> None:
    """Record one dismissal, and drop the ones older than KEEP_SECONDS, under the lock.
    The file is rewritten whole and replaced, so a reader never sees half of it."""
    reason = " ".join(reason.split())
    with open(agents_dir / f"{FILE}.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        kept = [entry for entry in entries(agents_dir) if age(entry, now, agents_dir / FILE) < KEEP_SECONDS]
        kept.append([time.strftime(STAMP, time.gmtime(now)), agent_id, reason])
        handle, temporary = tempfile.mkstemp(prefix=f"{FILE}.", dir=agents_dir)
        try:
            with os.fdopen(handle, "w") as stream:
                stream.write("".join("\t".join(entry) + "\n" for entry in kept))
            os.replace(temporary, agents_dir / FILE)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
