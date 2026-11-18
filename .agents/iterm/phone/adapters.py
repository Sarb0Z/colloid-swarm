#!/usr/bin/env python3
"""One adapter for each kind of alert: the text it sends the phone, and what the
operator's answer means to the hook that waits.

An adapter has two methods:

    alert(event, now, zone) -> str   the Signal text of the event's alert
    answer(event, text) -> dict      the line the event's hook gets for the
                                     operator's text, its event id removed

`phone_link.py` decides which event a message answers and sends the hook the
line `answer` returns as it is; the line's `behavior` (`allow` or `deny`) is
what the transcript must then show the hook decided. `ADAPTERS` maps an event's
`kind` to its adapter.

The operator's words go to the session's model (spec "Messages from the
phone"): a permission answer whose every word is an approval, with no question
mark, allows the call, and any other text denies it with that text as typed as
the hook's deny message, which Claude reads as the call's result.

An alert's preview is already masked and cut by the hook that built it
(`mask.outbound`): this module composes, it does not mask. An alert whose
preview lost values to the mask or characters to the cut says so on a line of
its own, `masked: <n> values · cut: <n> more characters`.
"""

from __future__ import annotations

import math
import re
import unicodedata
from datetime import datetime

import grammar
import log

MACHINE_NAMES = {"mac": "Mac"}
THUMB = "\N{THUMBS UP SIGN}"
APPROVALS = frozenset(("yes", "y", "yep", "ok", "okay", "sure", "go", "allow", "approve", "approved", THUMB))
VARIATION_SELECTORS = ("\N{VARIATION SELECTOR-15}", "\N{VARIATION SELECTOR-16}")
# A skin tone on a thumbs up; a skin tone anywhere else is a character of the text.
THUMB_SKIN = re.compile(f"{THUMB}[\N{EMOJI MODIFIER FITZPATRICK TYPE-1-2}-\N{EMOJI MODIFIER FITZPATRICK TYPE-6}]")
DENIED_BLANK = "Denied from the operator's phone."
# A question mark, as a phone keyboard may type it, makes an answer a question.
QUESTION_MARKS = ("?", "\N{FULLWIDTH QUESTION MARK}", "\N{INVERTED QUESTION MARK}")


def _within(event: dict, now: float, zone) -> str:
    """`answer within <n> min (by HH:MM <zone>)` for the event's deadline."""
    deadline = log.epoch_of(event["deadline"])
    # To the nearest minute: an alert sent half a second into a 59-minute wait says 59.
    minutes = max(0, math.floor((deadline - now) / 60 + 0.5))
    by = datetime.fromtimestamp(deadline, zone).strftime("%H:%M %Z")
    return f"answer within {minutes} min (by {by})"


def _plural(count: int, word: str) -> str:
    return f"{count} {word}" if count == 1 else f"{count} {word}s"


def _not_shown(detail: dict) -> list:
    """The line that says the preview is not the whole call, or no line when it is."""
    parts = [f"masked: {_plural(detail['masked'], 'value')}" if detail["masked"] else "",
             f"cut: {_plural(detail['cut'], 'more character')}" if detail["cut"] else ""]
    said = " · ".join(part for part in parts if part)
    return [said] if said else []


def words_of(text: str) -> list:
    """The words of `text` once case, punctuation, emoji variation selectors, a thumbs up's
    skin tone and invisible format characters are dropped."""
    kept = "".join(char for char in text.lower()
                   if char not in VARIATION_SELECTORS and unicodedata.category(char)[0] != "P"
                   and unicodedata.category(char) != "Cf")
    return THUMB_SKIN.sub(THUMB, kept).split()


def is_question(text: str) -> bool:
    return any(mark in text for mark in QUESTION_MARKS)


def is_approval(text: str) -> bool:
    """Whether every word of `text` is an approval word or a thumbs up, with no question mark
    anywhere: `yes?` asks, it does not approve."""
    words = words_of(text)
    return bool(words) and not is_question(text) and all(word in APPROVALS for word in words)


class Permission:
    """A permission prompt: the hook's `PermissionRequest` decision. An answer of approvals
    alone allows; one with no words and no question mark left denies with `DENIED_BLANK`,
    so Claude reads where the denial came from; any other answer denies with the
    operator's text as typed."""

    @staticmethod
    def alert(event: dict, now: float, zone) -> str:
        """Composed when it is sent, so the minutes are those left."""
        session = event["session"]
        return "\n".join([
            f"[{event['id']}] {session['project']} · {MACHINE_NAMES[event['machine']]} · "
            f"{session['account']} · {session['handle']}",
            f"Permission: {event['detail']['tool']} · {_within(event, now, zone)}",
            event["detail"]["preview"],
            *_not_shown(event["detail"]),
            "Reply: yes, or tell Claude what to do instead",
        ])

    @staticmethod
    def answer(event: dict, text: str) -> dict:
        if is_approval(text):
            return {"type": "decision", "behavior": "allow"}
        return {"type": "decision", "behavior": "deny", "message": text if is_question(text) or words_of(text) else DENIED_BLANK}


def new_deadline(event: dict, now: float, zone) -> str:
    """The line that follows a permission alert when its hook's deadline moved closer."""
    return grammar.reply(event["id"], _within(event, now, zone))


ADAPTERS = {"permission": Permission()}
