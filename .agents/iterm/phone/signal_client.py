#!/usr/bin/env python3
"""The phone link's side of signal-cli's JSON-RPC socket.

`signal-cli daemon --socket <state>/signal/socket` runs without `-a`, so it
serves every local account and each request names one. The link asks it which
account that is (`listAccounts`) and never keeps the number anywhere.

Sending. Every message goes to Note to Self as a normal message
(`noteToSelf` with `notifySelf`), which the phone shows as incoming; the other
mode shows on the operator's own side and cannot notify
(`.agents/knowledge/research/2026-11-18-signal-note-to-self-send-modes.md`).
A send failed when signal-cli answers with an error, reports a recipient result
other than SUCCESS, does not answer within the caller's limit, or its socket is
not connected.

Receiving. A linked device gets every message of the account. `phone_text`
passes only what the operator typed in Note to Self on the phone: a sync
"sent" message from the account to itself, with text, whose `sourceDevice` is
the phone's, 1. Signal Desktop is another device and does not pass. Everything
else is dropped here, unlogged: no caller sees it. `Inbox.take` then refuses a
timestamp it has seen (a redelivery acts once) and a message older than 15
minutes.
"""

from __future__ import annotations

import json
import select
import socket
import time
from typing import NamedTuple

PHONE_DEVICE = 1
MAX_AGE_SECONDS = 15 * 60
CONNECT_SECONDS = 2
READ_BYTES = 65536


def send_params(account: str, text: str) -> dict:
    return {"account": account, "message": text, "noteToSelf": True, "notifySelf": True}


def send_failure(result) -> str:
    """Why a `send` that signal-cli answered did not reach the account, or '' when it did."""
    results = result.get("results") if isinstance(result, dict) else None
    failed = [str(entry.get("type")) for entry in results or []
              if isinstance(entry, dict) and entry.get("type") != "SUCCESS"]
    return f"signal-cli reports {', '.join(failed)}" if failed else ""


def account_of(result) -> dict:
    """The one local account from a `listAccounts` result, as {"number", "aci"}."""
    accounts = [entry for entry in result if isinstance(entry, dict)] if isinstance(result, list) else []
    if len(accounts) != 1:
        raise ValueError(f"signal-cli holds {len(accounts)} accounts; the phone link needs exactly one linked account")
    account = {"number": accounts[0].get("number"), "aci": accounts[0].get("aci")}
    if not (account["number"] or account["aci"]):
        raise ValueError("signal-cli's account has neither a number nor an account id")
    return account


def phone_text(params, account: dict):
    """(Signal timestamp, text) when `params` of a `receive` notification is a message the
    operator typed in Note to Self on the phone; None for everything else."""
    mine = {account.get("number"), account.get("aci")} - {None}
    envelope = params.get("envelope") if isinstance(params, dict) else None
    if not isinstance(envelope, dict) or params.get("account") not in (None, *mine):
        return None
    sync = envelope.get("syncMessage")
    sent = sync.get("sentMessage") if isinstance(sync, dict) else None
    if not isinstance(sent, dict) or "groupInfo" in sent:
        return None
    from_me = {envelope.get("sourceNumber"), envelope.get("sourceUuid")} & mine
    to_me = {sent.get("destinationNumber"), sent.get("destinationUuid")} & mine
    device, stamp, text = envelope.get("sourceDevice"), sent.get("timestamp"), sent.get("message")
    if not (from_me and to_me and type(device) is int and device == PHONE_DEVICE
            and type(stamp) is int and isinstance(text, str) and text.strip()):
        return None
    return stamp, text


class Taken(NamedTuple):
    kind: str  # "message", or "too_old" for one the link must refuse
    timestamp: int
    text: str


class Inbox:
    """The replay and age filters over `phone_text`. `messages` is the link's record of the
    timestamps it acted on (log.Messages); the caller records what it does with a "message"."""

    def __init__(self, messages):
        self.messages = messages

    def take(self, params, account: dict, now: float):
        found = phone_text(params, account)
        if found is None or self.messages.seen(found[0]):
            return None
        if now - found[0] / 1000 > MAX_AGE_SECONDS:
            self.messages.record(found[0], "refused: too old", now)
            return Taken("too_old", *found)
        return Taken("message", *found)


class Connection:
    """One connection to the daemon's socket. `call` sends a request and gives its answer to
    `done(result, error)` exactly once, with error '' on success; `readable` returns the
    `receive` notifications that arrived."""

    def __init__(self, path: str, clock=time.time):
        self.path, self.clock = path, clock
        self.socket = None
        self.buffer = b""
        self.pending: dict = {}
        self.last_id = 0

    def connect(self) -> None:
        """Raises OSError while the daemon's socket is not there or does not accept."""
        link = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        link.settimeout(CONNECT_SECONDS)
        try:
            link.connect(self.path)
        except OSError:
            link.close()
            raise
        self.socket, self.buffer = link, b""

    def fileno(self) -> int:
        return self.socket.fileno()

    def close(self, why: str) -> None:
        """Drop the connection and fail every call that still waits."""
        if self.socket is not None:
            self.socket.close()
            self.socket = None
        waiting, self.pending = self.pending, {}
        for done, _limit in waiting.values():
            done(None, why)

    def call(self, method: str, params: dict, done, seconds: float) -> None:
        if self.socket is None:
            done(None, "signal-cli's socket is not connected")
            return
        self.last_id += 1
        self.pending[self.last_id] = (done, self.clock() + seconds)
        request = {"jsonrpc": "2.0", "method": method, "params": params, "id": self.last_id}
        try:
            self.socket.sendall(json.dumps(request).encode() + b"\n")
        except OSError as error:
            self.close(f"signal-cli's socket failed: {error}")

    def readable(self) -> list:
        """Read what arrived; answer the calls it settles; return the `receive` params."""
        if not select.select([self.socket], [], [], 0)[0]:
            return []  # Nothing arrived after all; the connection stands.
        try:
            data = self.socket.recv(READ_BYTES)
        except OSError as error:
            self.close(f"signal-cli's socket failed: {error}")
            return []
        if not data:
            self.close("signal-cli closed its socket")
            return []
        *lines, self.buffer = (self.buffer + data).split(b"\n")
        received = []
        for line in lines:
            try:
                message = json.loads(line)
            except ValueError:
                continue  # Not a JSON-RPC line; its content may be another chat's, so it is not kept.
            if not isinstance(message, dict):
                continue
            if message.get("method") == "receive":
                received.append(message.get("params"))
            elif message.get("id") in self.pending:
                done, _limit = self.pending.pop(message["id"])
                error = message.get("error")
                if error is not None:
                    done(None, f"signal-cli: {error.get('message') if isinstance(error, dict) else error}")
                else:
                    done(message.get("result"), "")
        return received

    def expire(self) -> None:
        """Fail each call whose time is up."""
        now = self.clock()
        for rpc_id in [rpc_id for rpc_id, (_done, limit) in self.pending.items() if limit <= now]:
            done, _limit = self.pending.pop(rpc_id)
            done(None, "signal-cli did not answer in time")

    def next_limit(self):
        """When the next waiting call times out, or None."""
        return min((limit for _done, limit in self.pending.values()), default=None)
