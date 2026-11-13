#!/usr/bin/env python3
"""When a process started, read so that no time zone, locale or clock step changes it.

A pid is reused, so a pid names a process only together with its start. The
worktree records (worktree_records.py) stamp a session with its process's start
and compare it at each sweep, the lock check (worktree_removal.py) compares a
lock's start, and the death reader (agent_sessions.py) a registry entry's
`procStart`, the last two as `ps` text in the C locale and UTC.

`read` gives the start in this host's form:

    Linux      {"boot": <boot_id>, "ticks": <field 22 of /proc/<pid>/stat>}: clock
               ticks since boot, which a wall-clock step does not move; equal or not.
    elsewhere  {"epoch": <seconds>} from `ps -o lstart=` under LC_ALL=C TZ=UTC. macOS
               keeps a start as the wall clock read once at fork, so a later step does
               not move it; equal within START_SLACK_SECONDS.

A read has three answers: the start, None when no such process runs, or
CANNOT_TELL when its `/proc` entry or `ps` cannot be read, or what it read does
not parse; `state` also cannot tell when the recorded start is in a form this
host does not read. Cannot tell is never gone: each caller keeps what it would
end, and one stderr line names the pid and the cause. `utc_lstart` alone
raises when `ps` cannot be run, as the death reader expects.
"""

from __future__ import annotations

import calendar
import os
import subprocess
import sys
import time
from pathlib import Path

# A reused pid belongs to a process started after the first one ended, so its start differs by
# at least that process's lifetime, far more than this. On Linux `ps` derives the start from the
# boot time, which a clock step moves, so two texts of one start may differ by a step this size.
START_SLACK_SECONDS = 5
LSTART_FORMAT = "%a %b %d %H:%M:%S %Y"
PS_SECONDS = 5
LIVE, GONE, CANNOT_TELL = "live", "gone", "cannot tell"
LINUX = sys.platform.startswith("linux")
PROC = Path("/proc")
# Field 22 of /proc/<pid>/stat, counted from field 3, the first after the command name, which
# is parenthesised and may itself hold spaces and parentheses.
TICKS_INDEX = 22 - 3


_warned: set[int] = set()


def warn(pid: int, why: str) -> None:
    """One stderr line per pid in a process: a sweep may read one stamp more than once."""
    if pid not in _warned:
        _warned.add(pid)
        print(f"process start: cannot tell whether pid {pid} still runs: {why}", file=sys.stderr)


def utc_lstart(pid: int) -> str | None:
    """`ps -o lstart= -p <pid>` under LC_ALL=C TZ=UTC, trimmed: the text Claude Code writes as a
    registry entry's `procStart` and into its worktree locks; None when no such process runs."""
    result = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True,
                            env=dict(os.environ, LC_ALL="C", TZ="UTC"), timeout=PS_SECONDS)
    return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else None


def utc_text(pid: int):
    """utc_lstart's text or None, or CANNOT_TELL when `ps` cannot be run or does not answer in time."""
    try:
        return utc_lstart(pid)
    except (subprocess.TimeoutExpired, OSError) as error:
        warn(pid, f"ps could not be run ({error})")
        return CANNOT_TELL


def epoch_of(text) -> int | None:
    """Seconds since the epoch of a C-locale UTC `lstart` text; None when it does not parse."""
    try:
        return calendar.timegm(time.strptime(text.strip(), LSTART_FORMAT))
    except (ValueError, TypeError, AttributeError):
        return None


def same_start(recorded: str | None, seen: str | None) -> bool:
    """Whether two C-locale UTC `lstart` texts name the same process start: equal as text, or
    both parse and lie within START_SLACK_SECONDS of each other."""
    if recorded == seen:
        return True
    first, second = epoch_of(recorded), epoch_of(seen)
    return first is not None and second is not None and abs(first - second) <= START_SLACK_SECONDS


def read(pid: int):
    """The process's start in this host's form, None when no such process runs, or CANNOT_TELL."""
    if not LINUX:
        text = utc_text(pid)
        if text is None or text == CANNOT_TELL:
            return text
        epoch = epoch_of(text)
        if epoch is None:
            warn(pid, f"ps gives {text!r} for its start, which does not parse")
            return CANNOT_TELL
        return {"epoch": epoch}
    try:
        stat = (PROC / str(pid) / "stat").read_text()
    except (FileNotFoundError, ProcessLookupError):
        return None
    except OSError as error:
        warn(pid, f"its /proc entry does not read ({error})")
        return CANNOT_TELL
    try:
        boot = (PROC / "sys" / "kernel" / "random" / "boot_id").read_text().strip()
        ticks = int(stat[stat.rindex(")") + 2:].split()[TICKS_INDEX])
    except (OSError, ValueError, IndexError) as error:
        warn(pid, f"its start in /proc does not read ({error})")
        return CANNOT_TELL
    return {"boot": boot, "ticks": ticks}


def form(start) -> str | None:
    """The host form a start is in, "epoch" or "proc"; None for anything else."""
    if isinstance(start, dict) and set(start) == {"epoch"} and type(start["epoch"]) is int:
        return "epoch"
    if isinstance(start, dict) and set(start) == {"boot", "ticks"} and isinstance(start["boot"], str) \
            and type(start["ticks"]) is int:
        return "proc"
    return None


def state(pid: int, recorded) -> str:
    """LIVE when the pid runs with the recorded start, GONE when no such process runs or it
    started at another time (a Linux start of another boot included), else CANNOT_TELL."""
    seen = read(pid)
    if seen is None or seen == CANNOT_TELL:
        return GONE if seen is None else CANNOT_TELL
    if form(recorded) != form(seen):
        warn(pid, f"its record holds the start {recorded!r}, which this host does not compare")
        return CANNOT_TELL
    if form(seen) == "epoch":
        return LIVE if abs(recorded["epoch"] - seen["epoch"]) <= START_SLACK_SECONDS else GONE
    return LIVE if recorded == seen else GONE
