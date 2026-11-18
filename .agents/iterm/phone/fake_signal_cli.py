#!/usr/bin/env python3
"""Test support: a stand-in for `signal-cli daemon --socket`, for tests that must not reach Signal.

It listens on a Unix socket and speaks the JSON-RPC lines of signal-cli's
manual page (`signal-cli-jsonrpc(5)`, 0.14.10): `listAccounts` answers one
account, `send` answers a timestamp of its own for each message, and `receive`
notifications go to every connected client. The account's number is in the
range reserved for fiction.

As a library, `FakeSignalCli(path)` records every request in `requests` and
the timestamp of each delivered send in `stamps`, and a test makes messages
arrive with `phone_says` (with `quote`, a Signal reply), `phone_replies` and
`push`.

As a command, for `.agents/test-phone-hooks.sh`:

    fake_signal_cli.py <socket> <record file> <control folder>

It appends each request to the record file as a JSON line, and the test steers
it through files of the control folder: `send` holds how sends end from then
on (`ok`, `error`, `failure` or `silent`); a file `say` is sent as a message
the operator typed on the phone, and a file `reply` as one typed as a Signal
reply to the last message delivered; each is removed once sent.
"""

from __future__ import annotations

import argparse
import errno
import json
import os
import re
import socket
import sys
import threading
import time

NUMBER = "+15555550100"
ACI = "11111111-1111-4111-8111-111111111111"
OTHER = "+15555550199"
ALERT = re.compile(r"^\[([a-z]-[a-z]{5})\] [^\n]*\nPermission: ")


def phone_message(text: str, timestamp: int, device: int = 1, quote=None) -> dict:
    """The `receive` params of a message typed in Note to Self: a sync "sent to self" (probe Q2).
    `quote` makes it a Signal reply to the message of that Signal timestamp, its `quote` in
    the fields of signal-cli's JsonQuote."""
    sent = {"destination": NUMBER, "destinationNumber": NUMBER, "destinationUuid": ACI,
            "timestamp": timestamp, "message": text, "expiresInSeconds": 0, "viewOnce": False}
    if quote is not None:
        sent["quote"] = {"id": quote, "author": NUMBER, "authorNumber": NUMBER, "authorUuid": ACI,
                         "text": "the phone's copy of the quoted message", "attachments": []}
    return {"envelope": {
        "source": NUMBER, "sourceNumber": NUMBER, "sourceUuid": ACI, "sourceName": "Operator",
        "sourceDevice": device, "timestamp": timestamp, "syncMessage": {"sentMessage": sent},
    }, "account": NUMBER}


def other_chat_message(text: str, timestamp: int) -> dict:
    """The `receive` params of a message another person sent to the operator."""
    return {"envelope": {
        "source": OTHER, "sourceNumber": OTHER, "sourceUuid": "22222222-2222-4222-8222-222222222222",
        "sourceName": "Someone", "sourceDevice": 1, "timestamp": timestamp,
        "dataMessage": {"timestamp": timestamp, "message": text, "expiresInSeconds": 0, "viewOnce": False},
    }, "account": NUMBER}


def sent_to_other_chat(text: str, timestamp: int) -> dict:
    """The `receive` params of a message the operator sent to another person from the phone."""
    params = phone_message(text, timestamp)
    params["envelope"]["syncMessage"]["sentMessage"].update(
        destination=OTHER, destinationNumber=OTHER, destinationUuid="22222222-2222-4222-8222-222222222222")
    return params


class FakeSignalCli:
    """`send` is how a send ends: "ok", "error" (signal-cli answers with an error), "failure"
    (a recipient result other than SUCCESS), "untimed" (SUCCESS with no timestamp) or
    "silent" (no answer). `on_send(text)` runs after each answered send."""

    def __init__(self, path: str, send: str = "ok", on_send=None, record=None):
        self.path, self.send, self.on_send, self.record = path, send, on_send, record
        self.requests: list = []
        self.stamps: list = []  # the timestamp each answered send got, in order
        self.clients: list = []
        self.lock = threading.Lock()
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(path)
        self.listener.listen(8)
        threading.Thread(target=self._accept, daemon=True).start()

    def sent(self) -> list:
        """The texts of the messages asked to be sent, in order."""
        with self.lock:
            return [r["params"]["message"] for r in self.requests if r.get("method") == "send"]

    def _accept(self) -> None:
        while True:
            try:
                client, _address = self.listener.accept()
            except OSError:
                return
            with self.lock:
                self.clients.append(client)
            threading.Thread(target=self._serve, args=(client,), daemon=True).start()

    def _serve(self, client) -> None:
        buffer = b""
        while True:
            try:
                data = client.recv(65536)
            except OSError:
                data = b""
            if not data:
                with self.lock:
                    if client in self.clients:
                        self.clients.remove(client)
                client.close()
                return
            *lines, buffer = (buffer + data).split(b"\n")
            for line in lines:
                self._request(client, json.loads(line))

    def _request(self, client, request: dict) -> None:
        with self.lock:
            self.requests.append(request)
            if self.record:
                with open(self.record, "a", encoding="utf-8") as stream:
                    stream.write(json.dumps(request) + "\n")
            method, answer, sending = request.get("method"), None, self.send
            # Signal gives each message its own timestamp: two sends in one millisecond still differ.
            stamp = max(int(time.time() * 1000), self.stamps[-1] + 1 if self.stamps else 0)
            if method == "send" and sending == "ok":
                self.stamps.append(stamp)
        if method == "listAccounts":
            answer = {"result": [{"number": NUMBER, "aci": ACI}]}
        elif method == "send" and sending == "ok":
            answer = {"result": {"timestamp": stamp,
                                 "results": [{"recipientAddress": {"uuid": ACI, "number": NUMBER},
                                              "type": "SUCCESS"}]}}
        elif method == "send" and sending == "failure":
            answer = {"result": {"timestamp": stamp,
                                 "results": [{"recipientAddress": {"uuid": ACI, "number": NUMBER},
                                              "type": "NETWORK_FAILURE"}]}}
        elif method == "send" and sending == "untimed":
            answer = {"result": {"results": [{"recipientAddress": {"uuid": ACI, "number": NUMBER},
                                              "type": "SUCCESS"}]}}
        elif method == "send" and sending == "error":
            answer = {"error": {"code": -1, "message": "Failed to send message: Connection reset", "data": None}}
        elif method != "send":
            answer = {"error": {"code": -32601, "message": "Method not implemented", "data": None}}
        if answer is not None:
            self._write(client, {"jsonrpc": "2.0", **answer, "id": request.get("id")})
            if method == "send" and "result" in answer and self.on_send:
                self.on_send(request["params"]["message"])

    def _write(self, client, message: dict) -> None:
        try:
            client.sendall(json.dumps(message).encode() + b"\n")
        except OSError as error:
            print(f"fake signal-cli: a client went away before a line reached it ({error})", file=sys.stderr)

    def push(self, params: dict) -> None:
        """Deliver a `receive` notification to every connected client."""
        with self.lock:
            clients = list(self.clients)
        for client in clients:
            self._write(client, {"jsonrpc": "2.0", "method": "receive", "params": params})

    def phone_says(self, text: str, timestamp=None, device: int = 1, quote=None) -> int:
        """A message typed on the phone; with `quote`, a reply to the message of that timestamp."""
        timestamp = timestamp if timestamp is not None else int(time.time() * 1000)
        self.push(phone_message(text, timestamp, device, quote))
        return timestamp

    def phone_replies(self, text: str) -> int:
        """A message typed on the phone as a Signal reply to the last message sent to it."""
        with self.lock:
            last = self.stamps[-1]
        return self.phone_says(text, quote=last)

    def drop_clients(self) -> None:
        """Close every connection, as a daemon that stops does."""
        with self.lock:
            clients, self.clients = self.clients, []
        for client in clients:
            try:
                # A shutdown reaches the peer at once; a close alone waits for the reading thread.
                client.shutdown(socket.SHUT_RDWR)
            except OSError as error:
                # A client that closed first has nothing left to drop; anything else is worth a line.
                if error.errno != errno.ENOTCONN:
                    print(f"fake signal-cli: a client could not be dropped ({error})", file=sys.stderr)

    def stop(self) -> None:
        self.listener.close()
        self.drop_clients()
        if os.path.exists(self.path):
            os.unlink(self.path)


def main(argv) -> int:
    parser = argparse.ArgumentParser(description="A stand-in for signal-cli's daemon socket.")
    parser.add_argument("socket")
    parser.add_argument("record")
    parser.add_argument("control")
    args = parser.parse_args(argv[1:])
    fake = FakeSignalCli(args.socket, record=args.record)
    send = os.path.join(args.control, "send")
    phone = {os.path.join(args.control, "say"): fake.phone_says,
             os.path.join(args.control, "reply"): fake.phone_replies}
    while True:
        if os.path.exists(send):
            with open(send, encoding="utf-8") as stream:
                fake.send = stream.read().strip() or "ok"
        for path, says in phone.items():
            if os.path.exists(path):
                with open(path, encoding="utf-8") as stream:
                    text = stream.read().strip()
                os.unlink(path)
                says(text)
        time.sleep(0.05)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
