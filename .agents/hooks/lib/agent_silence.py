"""How long a background agent has been silent, in one place.

The controller (`workloop_state.py`), the stamping hook (`agent_activity.py`)
and the lead's prompt note (`workloop-inbox.py`) all measure silence here. A
sign of life is the hook's stamp (`activity_at`), a lane's own heartbeat
(`heartbeat_at`), or the moment the agent went out (`claimed_at` for a lane,
`out_since` for a cell); silence runs from the newest of them. An agent with
neither a stamp nor a heartbeat has shown no sign of life since it went out.
"""

from __future__ import annotations

import calendar
import time

SIGNS = ("activity_at", "heartbeat_at")


def parse(value: str | None) -> float | None:
    """Seconds since the epoch for a `%Y-%m-%dT%H:%M:%SZ` stamp, or None when absent or malformed."""
    if not value:
        return None
    try:
        return float(calendar.timegm(time.strptime(value, "%Y-%m-%dT%H:%M:%SZ")))
    except ValueError:
        return None


def last_sign(agent: dict) -> float | None:
    """The newest stamp or heartbeat, or None for an agent that has shown neither since it went out."""
    signs = [parse(agent.get(key)) for key in SIGNS]
    known = [sign for sign in signs if sign is not None]
    return max(known) if known else None


def stamped(agent: dict) -> bool:
    return last_sign(agent) is not None


def silence(agent: dict, since_key: str, at: float) -> float | None:
    """Seconds since the newest sign of life, or None when the agent carries no usable time at all."""
    known = [sign for sign in (last_sign(agent), parse(agent.get(since_key))) if sign is not None]
    return at - max(known) if known else None
