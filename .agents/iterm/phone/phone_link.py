#!/usr/bin/env python3
"""phone-link: the service between Claude Code's permission hooks and the operator's phone.

  phone_link.py --zone <IANA zone> [--state <folder>]

One process for the machine, started by launchd. It owns `<state>/hook.sock`,
where each waiting permission hook (`client.py`) holds a connection, and it is
a client of `signal-cli`'s socket `<state>/signal/socket`. `--zone` is the
phone's time zone, in which an alert states its deadline.

What it does with a permission prompt (spec `docs/notes/2026-11-17-phone-link-spec.md`,
"Permission prompts"):

  1. A hook registers: the link lists the session, opens an event, binds it to
     the hook's call when no other waiting hook holds that call, and sends the
     alert to Note to Self at once, six a minute at most; the rest wait their
     turn and none is dropped. An alert that cannot be sent ends the hook
     with no decision, so the dialog on the Mac behaves as without the link.
     A hook that does not find its call waits 10 minutes, not 59: when its
     alert already went out, one line tells the phone the new deadline.
  2. A message from the phone answers one event: the one whose message it
     quotes as a Signal reply (the link keeps the Signal timestamp of every
     message it sends about an event, in memory), else the one whose id is
     its first or second word, else that of the newest message the link sent
     about an event (alert, deadline line or reply), by Signal timestamp and
     counted from the send's attempt. A quote it does not know is refused,
     and so is an id other than the quoted event's; a plain answer typed
     before the newest message, or within 5 s after it while another event
     is open, is refused, since it may mean another event. It never falls
     back to an older event. The event's adapter (`adapters.py`) turns the text
     into the hook's line: an approval allows, any other text denies with
     the text as typed. The reply waits until the transcript shows how the
     call ended: `done` when it ended by this decision, `refused: settled at
     the Mac` when the Mac's dialog answered first, and `refused: the Mac
     allowed it first` for a denial of a call that ran. A message that
     answers no known event (too old, not built, no such event, no open
     alert) gets one refusal a minute; the rest of that minute fold into one
     summary reply at the next, and each is still recorded.
  3. A hook that ends by itself says why (the Mac settled its call, its
     deadline passed, its session's process is gone). A hook that goes away
     without a word was stopped: the link reads the transcript for a No or an
     Esc at the dialog, and otherwise closes the event.

Before each reply and each change of an event's state the link reads the
transcript again (`transcript.py`); the log (`log.py`) records and never
decides. `Link` is the routing, with every effect passed in; `serve` is the
socket loop around it.

Messages on the hook socket are JSON lines. From a hook: `permission` (its
registration), `bind`, `deadline`, `settled`, `expired`, `gone`. To a hook:
`registered`, `bound`, `decision`, `failed`, `dropped`, `refused`.

While a Signal TLS proxy is set (`install.sh --tls-proxy`), `proxy_check.py`
reads the proxy's certificate once a day and warns in errors.log and on Signal
when less than 48 h are left.

A failure goes to `<state>/errors.log`. Nothing of a message that is not the
operator's Note to Self is logged or kept (`signal_client.phone_text`).
"""

from __future__ import annotations

import argparse
import collections
import itertools
import json
import os
import selectors
import signal
import socket
import subprocess
import ssl
import sys
import threading
import time
import traceback
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import adapters
import grammar
import log
import mask
import proxy_check
import sessions as session_list
import signal_client
import transcript

HOOK_LIMIT = 20
ALERTS_A_MINUTE = 6
MINUTE = 60
# Acceptance 11: a session with no dialog is denied within 5 s of a send that fails.
SEND_SECONDS = 4
SESSION_CHECK_SECONDS = 30
WATCH_SECONDS = 1
# How long after a hook went away without a word its transcript may still gain the
# rows of a No or an Esc at the dialog.
STOPPED_GRACE_SECONDS = 3
# How long a decision given to a hook that never found its call waits for a hook's
# decision row on a call of the same tool.
UNBOUND_CONFIRM_SECONDS = 30
RECONNECT_SECONDS = 5
# A message that quotes nothing and names no id, typed this soon after the newest message
# about an event, may mean another event that is still open.
NEWER_ALERT_SECONDS = 5
READ_BYTES = 65536
SESSION_KEYS = ("id", "start", "config_dir", "cwd", "project", "account", "transcript")


class Decision:
    """The phone's answer that was given to a hook: the operator's text, and the hook line its
    adapter made of it, whose `behavior` the transcript must then show the hook decided."""

    def __init__(self, text: str, line: dict):
        self.text, self.line, self.behavior = text, line, line["behavior"]


class Wait:
    """One permission hook that waits, or whose event still waits for its ending."""

    def __init__(self, conn, file: str, digest: str):
        # `digest` is the hook's call's name and input as `transcript.call_digest` gives them.
        self.conn, self.file, self.digest = conn, file, digest
        self.decision = None


class Watch:
    """A reading of a call's transcript after its hook was answered or went away."""

    def __init__(self, file: str, until: float):
        rows, offset = transcript.tail(file)
        self.calls = transcript.Calls()
        self.calls.add(rows)
        self.follow = transcript.Follow(file, offset)
        self.ended_before = set(self.calls.ended())
        self.until = until

    def read(self) -> None:
        self.calls.add(self.follow.read())


class Signal:
    """Note to Self through one signal-cli connection that is opened again when it drops."""

    def __init__(self, connection, errors, clock=time.time):
        self.connection, self.errors, self.clock = connection, errors, clock
        self.account = None
        self.retry_at = 0.0
        self.down_reported = False

    def tick(self) -> None:
        self.connection.expire()
        if self.connection.socket is not None or self.clock() < self.retry_at:
            return
        self.retry_at = self.clock() + RECONNECT_SECONDS
        try:
            self.connection.connect()
        except OSError as error:
            # One line for an outage, not one for each try.
            if not self.down_reported:
                self.errors.write(f"signal-cli's socket {self.connection.path} does not answer: {error}")
                self.down_reported = True
            return
        self.down_reported = False
        try:
            # signal-cli makes its socket under its own umask; the state folder's files are 0600.
            os.chmod(self.connection.path, 0o600)
        except OSError as error:
            self.errors.write(f"signal-cli's socket {self.connection.path} keeps its mode: {error}")
        self.connection.call("listAccounts", {}, self._listed, SEND_SECONDS)

    def _listed(self, result, error: str) -> None:
        if error:
            self.errors.write(f"signal-cli did not list its account: {error}")
            return
        try:
            self.account = signal_client.account_of(result)
        except ValueError as problem:
            self.account = None
            self.errors.write(str(problem))

    def send(self, text: str, done) -> None:
        """Send `text` to Note to Self; `done(error, timestamp)` gets error '' when signal-cli
        delivered it, with the message's Signal timestamp, or None when its result had none."""
        if self.account is None:
            done("signal-cli's account is not known: its socket has not answered", None)
            return
        target = self.account["number"] or self.account["aci"]

        def answered(result, error: str) -> None:
            error = error or signal_client.send_failure(result)
            stamp = None if error else signal_client.sent_timestamp(result)
            if not error and stamp is None:
                self.errors.write(f"signal-cli sent a message ({text.splitlines()[0]}) and gave no timestamp; "
                                  "a Signal reply to it cannot answer")
            done(error, stamp)
        self.connection.call("send", signal_client.send_params(target, text), answered, SEND_SECONDS)

    def next_due(self):
        return self.retry_at if self.connection.socket is None else self.connection.next_limit()


class Link:
    """The routing. `signal` sends (`send(text, done)`, `account`); a `conn` is a hook's
    connection (`send(message) -> bool`, `close()`)."""

    def __init__(self, *, events, messages, errors, sessions, signal, zone, clock=time.time):
        self.events, self.messages, self.errors = events, messages, errors
        self.sessions, self.signal, self.zone, self.clock = sessions, signal, zone, clock
        self.inbox = signal_client.Inbox(messages)
        self.waits: dict = {}  # event id -> Wait
        self.by_conn: dict = {}  # conn -> event id
        self.watches: dict = {}  # event id -> Watch
        # Signal timestamp of each delivered send -> the id of the event it concerns (None for
        # none), by which a Signal reply binds. In memory only: a restart forgets it and closes
        # the events. `clashed` holds the timestamps signal-cli gave to two messages (`_bind`).
        self.sent_about: dict = {}
        self.clashed: set = set()
        # "Newest": the message about an event — alert, deadline line or reply — of the highest
        # Signal timestamp, which a message that quotes nothing and names no id answers. A send
        # counts from its attempt, at the clock's milliseconds, and takes signal-cli's timestamp
        # when one comes; a send whose outcome is unknown keeps the attempt's. `in_flight`
        # holds the sends not yet answered; `newest` the highest of those answered, as
        # `(timestamp, attempt number, event id)`, the attempt number ordering a tie.
        self.attempts = itertools.count()
        self.in_flight: dict = {}  # attempt number -> (timestamp, attempt number, event id)
        self.newest = None
        self.queue = collections.deque()  # event ids whose alert waits for the rate limit
        self.sent_at = collections.deque()  # when each alert of the last minute went out
        self.noticed_at = float("-inf")
        self.refused_at = float("-inf")  # when the last refusal of a message went out
        self.held_refusals: list = []  # the reasons of the refusals the limit held since then
        self.next_check = 0.0

    def start(self) -> None:
        now = self.clock()
        self.events.start(now)
        self.messages.start(now)
        try:
            self.sessions.load()
        except ValueError as error:
            self.errors.write(f"the session list is not readable and starts empty: {error}")
        self._check_sessions(now)

    # --- from the hooks ---------------------------------------------------

    def hook_line(self, conn, message) -> None:
        kind = message.get("type") if isinstance(message, dict) else None
        if kind == "permission":
            self._register(conn, message)
            return
        event_id = self.by_conn.get(conn)
        wait = self.waits.get(event_id)
        if wait is None or wait.decision is not None:
            # After a decision the transcript says how the call ended, not the hook.
            return
        now = self.clock()
        if kind == "bind" and self.events.events[event_id]["call"] is None:
            call = self._claim(message.get("calls"))
            if call is not None:
                self.events.amend(event_id, call=call)
            conn.send({"type": "bound", "call": call})
        elif kind == "deadline" and isinstance(message.get("deadline"), (int, float)):
            event = self.events.amend(event_id, deadline=log.iso(message["deadline"]))
            # An alert still in the queue states the new deadline when it goes out.
            if event_id not in self.queue:
                self._say(adapters.new_deadline(event, now, self.zone), about=event_id)
        elif kind == "settled" and message.get("decision") in ("allow", "deny"):
            self._end(event_id, "settled_at_mac", "mac", message["decision"], now)
        elif kind == "expired":
            self._end(event_id, "expired", "none", "the hook's deadline passed", now)
        elif kind == "gone":
            self._end(event_id, "closed", "none", "the session's process ended", now)
        else:
            self.errors.write(f"a hook sent a line the link does not know (type {kind!r}) for {event_id}")

    def _register(self, conn, message: dict) -> None:
        problem = "this connection already registered a prompt" if conn in self.by_conn else self._malformed(message)
        if problem:
            self.errors.write(f"a hook's registration was refused: {problem}")
            conn.send({"type": "refused", "reason": problem})
            return
        if sum(1 for wait in self.waits.values() if wait.conn is not None) >= HOOK_LIMIT:
            self.errors.write(f"{HOOK_LIMIT} permission hooks already wait; one more got no alert")
            conn.send({"type": "refused", "reason": f"{HOOK_LIMIT} permission hooks already wait"})
            return
        asked = message["session"]
        try:
            listed = self.sessions.register({key: asked[key] for key in (*SESSION_KEYS, "pid")})
        except session_list.Full as full:
            conn.send({"type": "refused", "reason": str(full)})
            return
        now = self.clock()
        call = self._claim(message["calls"])
        # The hook masked already; a value it let through is masked here and counted too.
        preview, masked_here = mask.masked(message["preview"])
        event = self.events.open_permission(
            session={"id": listed["id"], "agent": asked.get("agent"), "handle": listed["handle"],
                     "project": listed["project"], "account": listed["account"], "cwd": listed["cwd"]},
            turn=message.get("turn"), call=call, tool=message["tool"], preview=preview,
            masked=message["masked"] + masked_here, cut=message["cut"], deadline=message["deadline"], now=now)
        self.waits[event["id"]] = Wait(conn, message["file"], message["digest"])
        self.by_conn[conn] = event["id"]
        conn.send({"type": "registered", "id": event["id"], "call": call})
        self.queue.append(event["id"])
        self._send_alerts(now)

    @staticmethod
    def _malformed(message: dict) -> str:
        """What is wrong with a registration line, or ''. The line comes from another process."""
        asked = message.get("session")
        if not isinstance(asked, dict) or type(asked.get("pid")) is not int \
                or not all(isinstance(asked.get(key), str) for key in SESSION_KEYS):
            return "its session is incomplete"
        if not all(isinstance(message.get(key), str) for key in ("tool", "preview", "file", "digest")):
            return "its tool, preview, digest or file is missing"
        if not isinstance(message.get("calls"), list) or not all(isinstance(c, str) for c in message["calls"]):
            return "its calls are not a list of ids"
        if not isinstance(message.get("deadline"), (int, float)):
            return "its deadline is missing"
        if not all(type(message.get(key)) is int and message[key] >= 0 for key in ("masked", "cut")):
            return "its masked or cut count is not a whole number"
        return ""

    def _claim(self, calls):
        """The first of `calls` that no waiting hook's event holds, or None."""
        held = {self.events.events[event_id]["call"] for event_id in self.waits}
        return next((call for call in calls or [] if isinstance(call, str) and call not in held), None)

    def hook_closed(self, conn) -> None:
        """The hook's connection ended. With no word from the hook, it was stopped."""
        event_id = self.by_conn.pop(conn, None)
        wait = self.waits.get(event_id)
        if wait is None:
            return
        wait.conn = None
        if wait.decision is None:
            self.watches[event_id] = Watch(wait.file, self.clock() + STOPPED_GRACE_SECONDS)
            self._look(event_id, self.clock())

    # --- from the phone ---------------------------------------------------

    def received(self, params) -> None:
        """One `receive` notification of signal-cli. Only the operator's own Note to Self
        message from the phone acts; nothing of any other is kept."""
        if self.signal.account is None:
            return
        now = self.clock()
        taken = self.inbox.take(params, self.signal.account, now)
        if taken is None:
            return
        if taken.kind == "too_old":
            self._refuse_message(grammar.refused("too old"), "too old", now)
            return
        message = grammar.parse(taken.text)
        if message.event and message.event[0] != log.MACHINE_LETTER:
            # Another machine's event: that machine's link answers.
            self.messages.record(taken.timestamp, "ignored: another machine's event", now)
            return
        if message.kind == "help":
            self._say(grammar.HELP)
            result = "accepted"
        elif message.kind == "unbuilt":
            self._refuse_message(grammar.refused("not built yet"), "not built yet", now)
            result = "refused: not built yet"
        else:
            event_id, result = self._which(message, taken, now)
            if event_id is not None:
                result = self._answer(event_id, message.text, now)
        self.messages.record(taken.timestamp, result, now)

    def _which(self, message, taken, now: float):
        """`(event id, '')` for the event an answer answers — the quoted alert's, else the one
        it names, else the newest alert's — or `(None, result)` when it was refused."""
        if taken.reply:
            quoted = self.sent_about.get(taken.quote)
            if quoted is None:
                reason = "not a reply to an open alert"
                self._refuse_message(grammar.refused(reason), reason, now)
                return None, f"refused: {reason}"
            if message.event and message.event != quoted:
                return None, self._refuse(quoted, f"the reply quotes {quoted}")
            return quoted, ""
        if message.event:
            return message.event, ""
        found = max([*self.in_flight.values(), *([self.newest] if self.newest else [])], default=None)
        if found is None:
            reason = "no open alert"
            self._refuse_message(grammar.refused(reason), reason, now)
            return None, f"refused: {reason}"
        sent, _attempt, newest = found
        other_open = any(event_id != newest and self.events.events[event_id]["state"] == "open"
                         for event_id in self.waits)
        # Both timestamps are Signal's: typed before the newest message, or so soon after it
        # that the operator may not have read it, the text may mean another event.
        if taken.timestamp < sent or (taken.timestamp - sent < NEWER_ALERT_SECONDS * 1000 and other_open):
            reason = "a newer alert just arrived — reply to the one you mean"
            self._say(grammar.refused(reason))
            return None, f"refused: {reason}"
        return newest, ""

    def _answer(self, event_id: str, text: str, now: float) -> str:
        """Give the operator's text to the event's hook as its adapter reads it, and return
        the result for the message record."""
        event = self.events.events.get(event_id)
        if event is None:
            reason = f"no event {event_id}"
            self._refuse_message(grammar.reply(event_id, grammar.refused(reason)), "no such event", now)
            return f"refused: {reason}"
        decision = Decision(text, adapters.ADAPTERS[event["kind"]].answer(event, text))
        if event["state"] != "open":
            return self._refuse(event_id, grammar.refusal_for(event, decision.behavior))
        wait = self.waits[event_id]
        if wait.decision is not None:
            return self._refuse(event_id, "already answered")
        if wait.conn is None or not wait.conn.send(decision.line):
            # Its hook went away before the answer could reach it: settle what the
            # transcript shows now, and tell the phone that.
            self.hook_closed(wait.conn)
            if event_id in self.watches:
                self._look(event_id, now, last=True)
            return self._refuse(event_id, grammar.refusal_for(self.events.events[event_id], decision.behavior))
        wait.decision = decision
        until = log.epoch_of(event["deadline"]) if event["call"] else now + UNBOUND_CONFIRM_SECONDS
        self.watches[event["id"]] = Watch(wait.file, until)
        self._look(event["id"], now)
        return "accepted"

    def _refuse_message(self, text: str, reason: str, now: float) -> None:
        """Refuse a message that answers no open or known event: one such reply a minute, and
        the rest of that minute fold into one summary at the next (`_send_held_refusals`).
        A backlog of old messages after a restart then costs one reply a minute."""
        self._send_held_refusals(now)
        if self.held_refusals or now - self.refused_at < MINUTE:
            self.held_refusals.append(reason)
            return
        self.refused_at = now
        self._say(text)

    def _send_held_refusals(self, now: float) -> None:
        if self.held_refusals and now - self.refused_at >= MINUTE:
            self.refused_at = now
            self._say(grammar.refusal_summary(self.held_refusals))
            self.held_refusals = []

    def _refuse(self, event_id: str, reason: str) -> str:
        self._say(grammar.reply(event_id, grammar.refused(reason)), about=event_id)
        return f"refused: {reason}"

    # --- how a call ended ---------------------------------------------------

    def _look(self, event_id: str, now: float, last: bool = False) -> None:
        """Read the transcript of a watched event and end the event when it shows how the
        call ended, or when the watch's time is up (`last` ends it now)."""
        watch, wait, event = self.watches[event_id], self.waits[event_id], self.events.events[event_id]
        watch.read()
        ending = watch.calls.ending(event["call"]) if event["call"] else None
        if wait.decision is not None:
            if ending is None and event["call"] is None:
                ending = self._late_call(event, watch, wait)
            if ending is not None and ending.by == "hook" and ending.decision == wait.decision.behavior:
                self._end(event_id, "answered", "phone", wait.decision.text, now)
                self._say(grammar.reply(event_id, "done"), about=event_id)
            elif ending is not None:
                self._end(event_id, "settled_at_mac", "mac", ending.decision, now)
                self._refuse(event_id, grammar.refusal_for(self.events.events[event_id], wait.decision.behavior))
            elif last or now >= watch.until:
                self._end(event_id, "closed", "none", "the transcript did not show how the call ended", now)
                self._refuse(event_id, "closed" if event["call"] else "not confirmed — check the Mac")
        elif ending is not None:
            self._end(event_id, "settled_at_mac", "mac", ending.decision, now)
        elif event["call"] is None and watch.calls.interrupted_since(log.epoch_of(event["created"])):
            self._end(event_id, "settled_at_mac", "mac", "deny", now)
        elif last or now >= watch.until:
            self._end(event_id, "closed", "none", "the hook went away", now)

    def _late_call(self, event: dict, watch: Watch, wait: Wait):
        """For an event whose hook never found its call: the ending of a call of the same tool
        and input that a hook decided this way after the answer went out. The event takes
        that call."""
        held = {self.events.events[other]["call"] for other in self.waits}
        for call, ending in watch.calls.ended().items():
            if (call not in watch.ended_before and call not in held and ending.by == "hook"
                    and ending.decision == wait.decision.behavior
                    and watch.calls.digests.get(call) == wait.digest):
                self.events.amend(event["id"], call=call)
                return ending
        return None

    def _end(self, event_id: str, state: str, via: str, text: str, now: float) -> None:
        self.events.move(event_id, state, {"via": via, "text": text, "at": log.iso(now)})
        wait = self.waits.pop(event_id)
        self.watches.pop(event_id, None)
        if wait.conn is not None:
            self.by_conn.pop(wait.conn, None)
            wait.conn.close()

    # --- to the phone -------------------------------------------------------

    def _say(self, text: str, about=None) -> None:
        """Send `text`; `about` is the id of the event it concerns, which a Signal reply to it
        then answers."""
        def sent(error: str, stamp) -> None:
            if error:
                self.errors.write(f"a reply was not sent ({text.splitlines()[0]}): {error}")
            else:
                self._bind(stamp, about)
        self._send(text, about, sent)

    def _send(self, text: str, about, done) -> None:
        """Send `text` with `done(error, stamp)` at its end. A message about an event (`about`)
        is the newest from its attempt on (`__init__`)."""
        if about is None:
            self.signal.send(text, done)
            return
        attempt = next(self.attempts)
        self.in_flight[attempt] = (int(self.clock() * 1000), attempt, about)

        def ended(error: str, stamp) -> None:
            attempted, _attempt, _about = self.in_flight.pop(attempt)
            # A failed send may still have reached the phone, so it keeps counting.
            mark = (attempted if stamp is None else stamp, attempt, about)
            self.newest = max(self.newest, mark) if self.newest else mark
            done(error, stamp)
        self.signal.send(text, ended)

    def _bind(self, stamp, about) -> None:
        """Keep the Signal timestamp of a delivered send with the event it concerns (`about`,
        None for none). signal-cli is trusted for unique timestamps nowhere: a timestamp two
        messages share answers no event, since a reply to it cannot say which it quotes."""
        if stamp is None or stamp in self.clashed:
            return
        if stamp in self.sent_about and self.sent_about[stamp] != about:
            self.errors.write(f"signal-cli gave timestamp {stamp} to messages about "
                              f"{self.sent_about[stamp] or 'no event'} and {about or 'no event'}; "
                              "a reply to it answers neither")
            self.clashed.add(stamp)
            self.sent_about[stamp] = None
            return
        self.sent_about[stamp] = about

    def _send_alerts(self, now: float) -> None:
        """Send the queued alerts the rate limit admits now, in order."""
        while self.sent_at and now - self.sent_at[0] >= MINUTE:
            self.sent_at.popleft()
        while self.queue and len(self.sent_at) < ALERTS_A_MINUTE:
            event_id = self.queue.popleft()
            wait = self.waits.get(event_id)
            if wait is None or wait.conn is None:
                continue  # Settled while it waited its turn: its alert would ask about nothing.
            self.sent_at.append(now)
            event = self.events.events[event_id]
            self._send(adapters.ADAPTERS[event["kind"]].alert(event, now, self.zone), event_id,
                       lambda error, stamp, event_id=event_id: self._alert_sent(event_id, error, stamp))
        if len(self.queue) > ALERTS_A_MINUTE and now - self.noticed_at >= MINUTE:
            self.noticed_at = now
            self._say(grammar.waiting_notice(len(self.queue)))

    def _alert_sent(self, event_id: str, error: str, stamp) -> None:
        if not error:
            self._bind(stamp, event_id)
            return
        self.errors.write(f"the alert of {event_id} was not sent: {error}")
        wait = self.waits.get(event_id)
        if wait is not None and wait.decision is None:
            if wait.conn is not None:
                wait.conn.send({"type": "failed", "reason": "the alert could not be sent"})
            self._end(event_id, "closed", "none", "the alert could not be sent", self.clock())

    # --- time ---------------------------------------------------------------

    def tick(self) -> None:
        now = self.clock()
        self.signal.tick()
        self._send_alerts(now)
        self._send_held_refusals(now)
        for event_id in list(self.watches):
            if event_id in self.watches:
                self._look(event_id, now)
        if now >= self.next_check:
            self._check_sessions(now)

    def _check_sessions(self, now: float) -> None:
        self.next_check = now + SESSION_CHECK_SECONDS
        try:
            dropped = {session["id"] for session in self.sessions.check()}
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            # `ps` did not run or did not read: no session was dropped, and the next check tries again.
            self.errors.write(f"the session check failed: {type(error).__name__}: {error}")
            return
        for event_id, wait in list(self.waits.items()):
            if self.events.events[event_id]["session"]["id"] not in dropped:
                continue
            if wait.conn is not None:
                wait.conn.send({"type": "dropped"})
            decided = wait.decision is not None
            self._end(event_id, "closed", "none", "the session ended", now)
            if decided:
                self._refuse(event_id, "closed")

    def next_due(self) -> float:
        """When `tick` is next needed."""
        due = [self.next_check]
        if self.watches:
            due.append(self.clock() + WATCH_SECONDS)
        if self.queue and self.sent_at:
            due.append(self.sent_at[0] + MINUTE)
        if len(self.queue) > ALERTS_A_MINUTE:
            due.append(self.noticed_at + MINUTE)
        if self.held_refusals:
            due.append(self.refused_at + MINUTE)
        if self.signal.next_due() is not None:
            due.append(self.signal.next_due())
        return min(due)


class HookConn:
    """A hook's connection on the hook socket."""

    def __init__(self, link_socket):
        self.socket, self.buffer, self.closed = link_socket, b"", False

    def send(self, message: dict) -> bool:
        if self.closed:
            return False
        try:
            self.socket.sendall(json.dumps(message).encode() + b"\n")
            return True
        except OSError:
            return False  # The hook is gone; the loop sees its end of file and tells the link.

    def close(self) -> None:
        self.closed = True


def listen(path: Path):
    """The hook socket, mode 0600. A socket file that nothing answers is a dead service's."""
    if path.exists():
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.connect(str(path))
        except OSError:
            path.unlink()
        else:
            raise SystemExit(f"phone-link: another phone-link already answers on {path}")
        finally:
            probe.close()
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(str(path))
    os.chmod(path, 0o600)
    listener.listen(HOOK_LIMIT * 2)
    return listener


def serve(link: Link, listener, errors, stopped, timers) -> None:
    """The socket loop: hook connections and signal-cli's socket in, `link` out, until
    `stopped()` holds. Each of `timers` (`tick()`, `next_due()`) ticks beside the link."""
    selector = selectors.DefaultSelector()
    selector.register(listener, selectors.EVENT_READ, "listener")
    conns, signal_socket = set(), None

    def drop(conn: HookConn) -> None:
        conns.discard(conn)
        selector.unregister(conn.socket)
        conn.socket.close()

    def follow_signal() -> None:
        """Watch signal-cli's socket of now. Run after anything that may close it: its
        descriptor is free at once, and a hook accepted next in the same batch may get it."""
        nonlocal signal_socket
        now_socket = link.signal.connection.socket
        if now_socket is not signal_socket:
            if signal_socket is not None:
                selector.unregister(signal_socket)
            if now_socket is not None:
                selector.register(now_socket, selectors.EVENT_READ, "signal")
            signal_socket = now_socket

    while not stopped():
        link.tick()
        for timer in timers:
            timer.tick()
        follow_signal()
        due = min([link.next_due(), *(timer.next_due() for timer in timers)])
        for key, _events in selector.select(max(0.0, min(due - link.clock(), SESSION_CHECK_SECONDS))):
            follow_signal()
            if key.data == "listener":
                accepted, _address = listener.accept()
                accepted.settimeout(1)
                conn = HookConn(accepted)
                conns.add(conn)
                selector.register(accepted, selectors.EVENT_READ, conn)
            elif key.data == "signal":
                if key.fileobj is not signal_socket:
                    continue  # The socket this event was for closed earlier in the batch.
                for params in link.signal.connection.readable():
                    link.received(params)
            elif key.data in conns:
                conn = key.data
                try:
                    data = conn.socket.recv(READ_BYTES)
                except OSError as error:
                    # Handled as a hook that went away; the line says it was not an ordinary end.
                    errors.write(f"a hook's connection failed on read ({error}); handled as a hook that went away")
                    data = b""
                if not data:
                    link.hook_closed(conn)
                    drop(conn)
                    continue
                *lines, conn.buffer = (conn.buffer + data).split(b"\n")
                for line in lines:
                    try:
                        message = json.loads(line)
                    except ValueError:
                        errors.write("a hook sent a line that is not JSON; its connection was closed")
                        conn.close()
                        break
                    link.hook_line(conn, message)
        for conn in [conn for conn in conns if conn.closed]:
            link.hook_closed(conn)
            drop(conn)
    for conn in list(conns):
        drop(conn)
    selector.close()


def main(argv) -> int:
    parser = argparse.ArgumentParser(description="The phone link's service.")
    parser.add_argument("--zone", required=True, help="the phone's time zone, for example Europe/Lisbon")
    parser.add_argument("--state", default=None, help="the state folder (default ~/.local/state/phone-link)")
    args = parser.parse_args(argv[1:])
    try:
        zone = ZoneInfo(args.zone)
    except (ZoneInfoNotFoundError, ValueError) as error:
        print(f"phone-link: --zone {args.zone!r} is not a time zone this system knows ({error})", file=sys.stderr)
        return 2
    state = Path(args.state) if args.state else log.state_dir(os.environ)
    # Every file the service makes, its socket included, is the owner's alone.
    os.umask(0o177)
    log.prepare(state)
    log.prepare(state / "signal")
    errors = log.Errors(state / "errors.log")
    listener = listen(state / "hook.sock")
    link = Link(events=log.Events(state / "events.jsonl", errors),
                messages=log.Messages(state / "messages.jsonl", errors),
                errors=errors, sessions=session_list.Sessions(state / "sessions.json", errors),
                signal=Signal(signal_client.Connection(str(state / "signal" / "socket")), errors),
                zone=zone)
    context = ssl.create_default_context()
    proxy = proxy_check.ProxyCheck(
        state=state, read_expiry=lambda host, port: proxy_check.certificate_expiry(host, port, context),
        start=lambda run: threading.Thread(target=run, daemon=True).start(),
        signal=link.signal, errors=errors, zone=zone, clock=time.time)
    # A handler that only set a flag would leave the loop asleep until its next timer:
    # Python retries an interrupted wait. Leaving through SystemExit ends it now, and
    # each waiting hook reads its end of file as the process ends.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        link.start()
        serve(link, listener, errors, lambda: False, (proxy,))
    except Exception:
        errors.write("phone-link stopped on an error: " + traceback.format_exc())
        raise
    finally:
        listener.close()
        (state / "hook.sock").unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
