#!/usr/bin/env python3
"""What the phone may say to the link, and what the link says to the phone.

From the phone, the grammar is closed. This unit builds its permission part:

    yes <id>            allow the tool call of the alert <id>
    no <id> [<reason>]  deny it; Claude reads the reason
    help                list the grammar

`status`, `start`, `mute` and `unmute` are reserved, and `<id> <text>` (a gate
answer) and `@<handle> <text>` (a request) belong to later units: `parse` knows
each as `unbuilt`, and the link answers `refused: not built yet`. Anything else
is `unknown`.

A phone keyboard capitalises the first word and may end a line with a period,
so the verb and the id match in any case and the id may carry one trailing
`.`, `,` or `!`. Nothing else is forgiven.

To the phone, every message about an event starts with its id in brackets
(`alert`, `reply`). An alert's preview is already masked and cut by the hook
that built it (`mask.outbound`): this module composes, it does not mask. An
alert whose preview lost values to the mask or characters to the cut says so
on a line of its own, `masked: <n> values · cut: <n> more characters`; it
still takes `yes`.
"""

from __future__ import annotations

import math
import re
from datetime import datetime
from typing import NamedTuple

import log

EVENT_ID = re.compile(r"[a-z]-[a-z]{5}")
RESERVED = ("status", "start", "mute", "unmute")
MACHINE_NAMES = {"mac": "Mac"}
HELP = ("yes <id> — allow the tool call of that alert\n"
        "no <id> <reason> — deny it; Claude reads the reason\n"
        "help — this list")
# What a phone answer to an event that is not open is told, by the event's state.
REFUSALS = {
    "answered": "already answered",
    "settled_at_mac": "settled at the Mac",
    "expired": "expired",
    "closed": "closed",
}


class Command(NamedTuple):
    kind: str  # "yes", "no", "help", "unbuilt" or "unknown"
    event: str = ""  # the event id the message names, when it names one
    reason: str = ""  # for "no"


def _event_id(word: str) -> str:
    found = word.lower()
    if found[-1:] in (".", ",", "!"):
        found = found[:-1]
    return found if EVENT_ID.fullmatch(found) else ""


def parse(text: str) -> Command:
    words = text.split()
    if not words:
        return Command("unknown")
    verb = words[0].lower()
    if verb == "help" and len(words) == 1:
        return Command("help")
    if verb in RESERVED:
        return Command("unbuilt")
    if verb == "yes" and len(words) == 2 and _event_id(words[1]):
        return Command("yes", _event_id(words[1]))
    if verb == "no" and len(words) >= 2 and _event_id(words[1]):
        # The reason as typed: only the id may have lost a period.
        return Command("no", _event_id(words[1]), " ".join(words[2:]))
    if len(words) >= 2 and EVENT_ID.fullmatch(verb):
        return Command("unbuilt", verb)
    if len(verb) > 1 and verb.startswith("@") and len(words) >= 2:
        return Command("unbuilt")
    return Command("unknown")


def _within(event: dict, now: float, zone) -> str:
    """`answer within <n> min (by HH:MM <zone>)` for the event's deadline."""
    deadline = log.epoch_of(event["deadline"])
    # To the nearest minute: an alert sent half a second into a 59-minute wait says 59.
    minutes = max(0, math.floor((deadline - now) / 60 + 0.5))
    by = datetime.fromtimestamp(deadline, zone).strftime("%H:%M %Z")
    return f"answer within {minutes} min (by {by})"


def alert(event: dict, now: float, zone) -> str:
    """The alert of a permission event, composed when it is sent, so the minutes are those left."""
    session = event["session"]
    return "\n".join([
        f"[{event['id']}] {session['project']} · {MACHINE_NAMES[event['machine']]} · "
        f"{session['account']} · {session['handle']}",
        f"Permission: {event['detail']['tool']} · {_within(event, now, zone)}",
        event["detail"]["preview"],
        *_not_shown(event["detail"]),
        f"Reply: yes {event['id']}   or   no {event['id']} <reason>",
    ])


def _plural(count: int, word: str) -> str:
    return f"{count} {word}" if count == 1 else f"{count} {word}s"


def _not_shown(detail: dict) -> list:
    """The line that says the preview is not the whole call, or no line when it is."""
    parts = [f"masked: {_plural(detail['masked'], 'value')}" if detail["masked"] else "",
             f"cut: {_plural(detail['cut'], 'more character')}" if detail["cut"] else ""]
    said = " · ".join(part for part in parts if part)
    return [said] if said else []


def new_deadline(event: dict, now: float, zone) -> str:
    """The line that follows an alert when its hook's deadline moved closer."""
    return reply(event["id"], _within(event, now, zone))


def reply(event_id: str, text: str) -> str:
    return f"[{event_id}] {text}"


def refused(reason: str) -> str:
    return f"refused: {reason}"


def refusal_for(event: dict, command: Command) -> str:
    """Why an answer to an event that is not open is refused. A `no` to a call the Mac allowed
    says so in its own words, because that call ran."""
    if command.kind == "no" and event["state"] == "settled_at_mac" and (event.get("answer") or {}).get("text") == "allow":
        return "the Mac allowed it first"
    return REFUSALS[event["state"]]


def waiting_notice(count: int) -> str:
    return f"{count} more waiting"
