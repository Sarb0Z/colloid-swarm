#!/usr/bin/env python3
"""When a process started, as `ps` gives it in the C locale and UTC.

A pid is reused, so a pid names a process only together with its start. The
death reader (agent_sessions.py) compares a registry entry's `procStart` with
the start `ps` gives for that pid.
"""

from __future__ import annotations

import calendar
import os
import subprocess
import time

# A reused pid belongs to a process started after the first one ended, so its start differs by
# at least that process's lifetime, far more than this. On Linux `ps` derives the start from the
# boot time, which a clock step moves, so two texts of one start may differ by a step this size.
START_SLACK_SECONDS = 5
LSTART_FORMAT = "%a %b %d %H:%M:%S %Y"


def utc_lstart(pid: int) -> str | None:
    """`ps -o lstart= -p <pid>` under LC_ALL=C TZ=UTC, trimmed: the text Claude Code writes as a
    registry entry's `procStart` and into its worktree locks; None when no such process runs."""
    result = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True,
                            env=dict(os.environ, LC_ALL="C", TZ="UTC"), timeout=5)
    return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else None


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
