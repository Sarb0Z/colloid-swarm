#!/usr/bin/env python3
"""What a phone message is, and the link's own texts to the phone.

The operator's words go to the session's model, so the link holds an answer to
no word list (spec "Messages from the phone"). `parse` tells only these apart:

    help                 alone: list how an answer is read
    status, start,       alone: reserved for R30, `refused: not built yet`
    mute, unmute
    @<handle> <text>     a request (unit 3d), `refused: not built yet`
    anything else        an answer, with the event id it names, if any

"Alone" allows trailing punctuation: `Help.`, `status?`. An answer names an
event when its first or second word is an event id — a machine letter, a
hyphen and five letters of the id alphabet — in any case, alone or inside
brackets or other punctuation (`[m-qhvkz]`). The answer's text is the message
as typed, outer space trimmed, without that one word and the spaces and tabs
after it. What the text does to the event is
its adapter's (`adapters.py`); which event it answers is `phone_link.py`'s.

To the phone, every message about an event starts with its id in brackets
(`reply`).
"""

from __future__ import annotations

import itertools
import re
import unicodedata
from typing import NamedTuple

import log

# The Mac's letter `m` and the server's `s`, then five letters of the alphabet `log` draws ids from.
MACHINE_LETTERS = "ms"
EVENT_ID = re.compile(f"[{MACHINE_LETTERS}]-[{log.ID_LETTERS}]{{5}}")
RESERVED = ("status", "start", "mute", "unmute")
HELP = ("yes, ok or \N{THUMBS UP SIGN} — allow the call\n"
        "any other words — deny it; Claude reads them as you typed them\n"
        "a reply answers the alert it quotes; an id in the first two words answers that alert; "
        "otherwise the newest alert\n"
        "help — this list")
# What a phone answer to an event that is not open is told, by the event's state.
REFUSALS = {
    "answered": "already answered",
    "settled_at_mac": "settled at the Mac",
    "expired": "expired",
    "closed": "closed",
}


class Message(NamedTuple):
    kind: str  # "help", "unbuilt" or "answer"
    event: str = ""  # for "answer": the event id it names, or ''
    text: str = ""  # for "answer": the text as typed, without the id


def _is_punctuation(char: str) -> bool:
    return unicodedata.category(char)[0] == "P"


def _is_around_an_id(char: str) -> bool:
    """Punctuation, an invisible format character (a zero-width space or joiner, a
    direction isolate) or an emoji variation mark: what a phone may put around a word."""
    return _is_punctuation(char) or unicodedata.category(char) == "Cf" or char in "︎️"


def _event_id(word: str) -> str:
    """The event id that `word` is, alone or inside brackets, other punctuation or invisible
    characters, or ''."""
    found = word.lower()
    while found and _is_around_an_id(found[-1]):
        found = found[:-1]
    while found and _is_around_an_id(found[0]):
        found = found[1:]
    return found if EVENT_ID.fullmatch(found) else ""


def parse(text: str) -> Message:
    words = text.split()
    alone = words[0].lower() if len(words) == 1 else ""
    while alone and _is_punctuation(alone[-1]):
        alone = alone[:-1]
    if alone == "help":
        return Message("help")
    if alone in RESERVED:
        return Message("unbuilt")
    if len(words) >= 2 and len(words[0]) > 1 and words[0].startswith("@"):
        return Message("unbuilt")
    for word in itertools.islice(re.finditer(r"\S+", text), 2):
        event = _event_id(word.group())
        if event:
            # The id goes with the spaces and tabs after it, so `no <id> too risky` reads
            # `no too risky`; a line break after it is the operator's and stays.
            return Message("answer", event, (text[:word.start()] + text[word.end():].lstrip(" \t")).strip())
    return Message("answer", "", text.strip())


def reply(event_id: str, text: str) -> str:
    return f"[{event_id}] {text}"


def refused(reason: str) -> str:
    return f"refused: {reason}"


def refusal_for(event: dict, behavior: str) -> str:
    """Why an answer to an event that is not open is refused; `behavior` is what the answer
    would have told the hook. A denial of a call the Mac allowed says so in its own words,
    because that call ran."""
    if behavior == "deny" and event["state"] == "settled_at_mac" and (event.get("answer") or {}).get("text") == "allow":
        return "the Mac allowed it first"
    return REFUSALS[event["state"]]


def refusal_summary(reasons: list) -> str:
    """One reply for the refusals held back by the one-a-minute limit: how many, and how many
    of each reason, the reasons in the order they first came."""
    counts: dict = {}
    for reason in reasons:
        counts[reason] = counts.get(reason, 0) + 1
    each = ", ".join(f"{count} {reason}" for reason, count in counts.items())
    noun = "message" if len(reasons) == 1 else "messages"
    return refused(f"{len(reasons)} more {noun} ({each})")


def waiting_notice(count: int) -> str:
    return f"{count} more waiting"
