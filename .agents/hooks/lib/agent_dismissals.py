"""The operator's dismissals of dead agents: the one record the death reader keeps of its own.

`.agents/.agents-dismissed` (gitignored) holds one line per dismissal,
`<ISO time>\t<agent id>\t<death time>\t<reason>`. The death time is the epoch
seconds of the verdict dismissed: a dismissal covers that death and any judged
no later, so an agent resumed and dead again shows again. `workloop.py dismiss`
appends under an `fcntl` lock on `.agents/.agents-dismissed.lock`, and in the
same hold rewrites the file without lines older than 30 days; by then the agent
is out of the reader's 7-day window and its cache, so nothing would show it
again unless it works again. The reader reads without the lock: an append and
the rewrite's atomic replace each leave a whole file.
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


def _entries(agents_dir: Path) -> list[list[str]]:
    try:
        text = (agents_dir / FILE).read_text()
    except FileNotFoundError:
        return []
    return [line.split("\t", 3) for line in text.splitlines() if line.count("\t") >= 3]


def dismissed(agents_dir: Path) -> dict[str, float]:
    """Each dismissed agent's newest dismissed death time."""
    found: dict[str, float] = {}
    for entry in _entries(agents_dir):
        try:
            died = float(entry[2])
        except ValueError as error:
            raise ValueError(f"{agents_dir / FILE} has a line whose death time {entry[2]!r} is no number; fix or delete it") from error
        found[entry[1]] = max(died, found.get(entry[1], died))
    return found


def covers(dismissals: dict[str, float], agent_id: str, died: float) -> bool:
    """Whether a dismissal covers the agent's death judged at `died`."""
    return agent_id in dismissals and died <= dismissals[agent_id]


def _age(entry: list[str], now: float, path: Path) -> float:
    try:
        return now - calendar.timegm(time.strptime(entry[0], STAMP))
    except ValueError as error:
        raise ValueError(f"{path} has a line whose time {entry[0]!r} is not {STAMP}; fix or delete it") from error


def dismiss(agents_dir: Path, agent_id: str, died: float, reason: str, now: float) -> None:
    """Record one dismissal of the death judged at `died`, and drop the ones older than
    KEEP_SECONDS, under the lock. The file is rewritten whole and replaced, so a reader never
    sees half of it."""
    reason = " ".join(reason.split())
    with open(agents_dir / f"{FILE}.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        kept = [entry for entry in _entries(agents_dir) if _age(entry, now, agents_dir / FILE) < KEEP_SECONDS]
        kept.append([time.strftime(STAMP, time.gmtime(now)), agent_id, repr(float(died)), reason])
        handle, temporary = tempfile.mkstemp(prefix=f"{FILE}.", dir=agents_dir)
        try:
            with os.fdopen(handle, "w") as stream:
                stream.write("".join("\t".join(entry) + "\n" for entry in kept))
            os.replace(temporary, agents_dir / FILE)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
