#!/usr/bin/env python3
"""Tests for signal_client.py: which received messages are the operator's phone, and how a send ends.

Seams:
  (a) `phone_text` and `Inbox` over literal `receive` params in the shape probe
      Q2 found and the shapes of everything else a linked device receives.
      Catches a message of another chat, another device or another account
      taken for an answer, an old or repeated message acting, and message text
      written to the record. Misses an envelope shape signal-cli has not shown.
  (b) `Connection` against `fake_signal_cli.py` over a real Unix socket.
      Catches a request signal-cli's manual does not describe, an answer given
      to the wrong call or twice, and a send reported as delivered when it was
      not. Misses signal-cli itself and the network, which the live checkpoint
      shows.
"""

import json
import os
import select
import shutil
import tempfile
import time
import unittest
from pathlib import Path

import fake_signal_cli as fake
import log
import signal_client
from signal_client import Connection, Inbox, Taken, phone_text

ME = {"number": fake.NUMBER, "aci": fake.ACI}
NOW = 1794992400.0
STAMP = int(NOW * 1000) - 2000


class PhoneText(unittest.TestCase):
    def test_a_message_typed_in_note_to_self_on_the_phone_passes(self):
        self.assertEqual(phone_text(fake.phone_message("yes m-qhvkz", STAMP), ME), (STAMP, "yes m-qhvkz"))

    def test_signal_desktop_and_every_other_device_do_not_pass(self):
        for device in (2, 3, 0, "1", True, None, 1.0):
            params = fake.phone_message("yes m-qhvkz", STAMP)
            params["envelope"]["sourceDevice"] = device
            self.assertIsNone(phone_text(params, ME), repr(device))

    def test_a_message_from_another_person_does_not_pass(self):
        self.assertIsNone(phone_text(fake.other_chat_message("yes m-qhvkz", STAMP), ME))

    def test_a_message_the_operator_sent_to_another_chat_does_not_pass(self):
        self.assertIsNone(phone_text(fake.sent_to_other_chat("yes m-qhvkz", STAMP), ME))

    def test_a_message_the_operator_sent_to_a_group_does_not_pass(self):
        params = fake.phone_message("yes m-qhvkz", STAMP)
        params["envelope"]["syncMessage"]["sentMessage"]["groupInfo"] = {"groupId": "g", "type": "DELIVER"}
        self.assertIsNone(phone_text(params, ME))

    def test_a_note_to_self_event_with_no_text_does_not_pass(self):
        for message in (None, "", "   ", 7):
            params = fake.phone_message("x", STAMP)
            params["envelope"]["syncMessage"]["sentMessage"]["message"] = message
            self.assertIsNone(phone_text(params, ME), repr(message))

    def test_a_message_of_another_local_account_does_not_pass(self):
        params = fake.phone_message("yes m-qhvkz", STAMP)
        params["account"] = fake.OTHER
        self.assertIsNone(phone_text(params, ME))

    def test_someone_else_cannot_pass_as_the_sender(self):
        params = fake.phone_message("yes m-qhvkz", STAMP)
        params["envelope"].update(source=fake.OTHER, sourceNumber=fake.OTHER, sourceUuid="2222")
        self.assertIsNone(phone_text(params, ME))

    def test_what_is_no_message_does_not_pass(self):
        receipt = {"envelope": {"source": fake.NUMBER, "sourceNumber": fake.NUMBER, "sourceDevice": 1,
                                "timestamp": STAMP, "receiptMessage": {"when": STAMP, "isDelivery": True}},
                   "account": fake.NUMBER}
        read_sync = {"envelope": {"source": fake.NUMBER, "sourceNumber": fake.NUMBER, "sourceDevice": 1,
                                  "timestamp": STAMP, "syncMessage": {"readMessages": []}},
                     "account": fake.NUMBER}
        no_stamp = fake.phone_message("yes m-qhvkz", STAMP)
        del no_stamp["envelope"]["syncMessage"]["sentMessage"]["timestamp"]
        for params in (receipt, read_sync, no_stamp, {}, {"envelope": None}, None, "text", []):
            self.assertIsNone(phone_text(params, ME), repr(params)[:60])

    def test_an_account_without_a_number_is_matched_by_its_account_id(self):
        params = fake.phone_message("yes m-qhvkz", STAMP)
        params["account"] = fake.ACI
        for key in ("source", "sourceNumber"):
            params["envelope"][key] = None
        for key in ("destination", "destinationNumber"):
            params["envelope"]["syncMessage"]["sentMessage"][key] = None
        self.assertEqual(phone_text(params, {"number": None, "aci": fake.ACI}), (STAMP, "yes m-qhvkz"))
        self.assertIsNone(phone_text(params, {"number": None, "aci": "3333"}))


class InboxFilters(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.folder)
        self.messages = log.Messages(self.folder / "messages.jsonl", log.Errors(self.folder / "errors.log"))
        self.messages.start(NOW)
        self.inbox = Inbox(self.messages)

    def test_a_fresh_message_is_taken(self):
        self.assertEqual(self.inbox.take(fake.phone_message("yes m-qhvkz", STAMP), ME, NOW),
                         Taken("message", STAMP, "yes m-qhvkz"))

    def test_acceptance_16_a_message_received_twice_acts_once(self):
        params = fake.phone_message("yes m-qhvkz", STAMP)
        self.assertEqual(self.inbox.take(params, ME, NOW).kind, "message")
        self.messages.record(STAMP, "accepted", NOW)  # what the link does with a taken message
        self.assertIsNone(self.inbox.take(params, ME, NOW + 1))
        self.assertIsNone(Inbox(self.messages).take(params, ME, NOW + 2))

    def test_acceptance_16_a_message_older_than_15_minutes_is_refused_once(self):
        old = int((NOW - 15 * 60 - 1) * 1000)
        params = fake.phone_message("yes m-qhvkz", old)
        self.assertEqual(self.inbox.take(params, ME, NOW), Taken("too_old", old, "yes m-qhvkz"))
        self.assertIsNone(self.inbox.take(params, ME, NOW + 1))
        self.assertEqual(json.loads((self.folder / "messages.jsonl").read_text()),
                         {"ts": old, "at": "2026-11-18T09:00:00Z", "result": "refused: too old"})

    def test_a_message_of_exactly_15_minutes_is_still_taken(self):
        edge = int((NOW - 15 * 60) * 1000)
        self.assertEqual(self.inbox.take(fake.phone_message("help", edge), ME, NOW).kind, "message")

    def test_acceptance_12_another_chat_leaves_nothing_in_the_record(self):
        for params in (fake.other_chat_message("call me", STAMP), fake.sent_to_other_chat("on my way", STAMP),
                       fake.phone_message("yes m-qhvkz", STAMP, device=2)):
            self.assertIsNone(self.inbox.take(params, ME, NOW))
        self.assertEqual(sorted(os.listdir(self.folder)), [])


class Requests(unittest.TestCase):
    def test_an_alert_is_a_normal_message_to_note_to_self(self):
        self.assertEqual(signal_client.send_params(fake.NUMBER, "[m-qhvkz] done"),
                         {"account": fake.NUMBER, "message": "[m-qhvkz] done", "noteToSelf": True,
                          "notifySelf": True})

    def test_a_send_result_fails_when_a_recipient_result_is_not_success(self):
        ok = {"timestamp": 9, "results": [{"recipientAddress": {}, "type": "SUCCESS"}]}
        self.assertEqual(signal_client.send_failure(ok), "")
        self.assertEqual(signal_client.send_failure({"timestamp": 9}), "")
        bad = {"timestamp": 9, "results": [{"type": "SUCCESS"}, {"type": "NETWORK_FAILURE"}]}
        self.assertEqual(signal_client.send_failure(bad), "signal-cli reports NETWORK_FAILURE")

    def test_the_account_is_the_one_signal_cli_lists(self):
        self.assertEqual(signal_client.account_of([{"number": fake.NUMBER, "aci": fake.ACI}]), ME)
        self.assertEqual(signal_client.account_of([{"number": fake.NUMBER}]), {"number": fake.NUMBER, "aci": None})
        for listed in ([], [{"number": "a"}, {"number": "b"}], None, [{"number": None}]):
            with self.assertRaises(ValueError):
                signal_client.account_of(listed)


class Wire(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.folder)
        self.path = os.path.join(self.folder, "s")
        self.answers, self.received = [], []

    def daemon(self, send="ok"):
        daemon = fake.FakeSignalCli(self.path, send=send)
        self.addCleanup(daemon.stop)
        return daemon

    def connected(self, clock=time.time):
        connection = Connection(self.path, clock=clock)
        connection.connect()
        self.addCleanup(connection.close, "test over")
        return connection

    def done(self, result, error):
        self.answers.append((result, error))

    def pump(self, connection, until, seconds=5.0):
        """Read from the connection until `until()` holds; the notifications read go to `self.received`."""
        limit = time.time() + seconds
        while not until() and time.time() < limit:
            if connection.socket is None:
                break
            if select.select([connection.socket], [], [], 0.05)[0]:
                self.received += connection.readable()
        self.assertTrue(until(), "the condition did not hold in time")

    def test_list_accounts_gives_the_linked_account(self):
        self.daemon()
        connection = self.connected()
        connection.call("listAccounts", {}, self.done, 5)
        self.pump(connection, lambda: self.answers)
        self.assertEqual(signal_client.account_of(self.answers[0][0]), ME)
        self.assertEqual(self.answers[0][1], "")

    def test_a_send_that_signal_cli_delivers_ends_without_an_error(self):
        daemon = self.daemon()
        connection = self.connected()
        connection.call("send", signal_client.send_params(fake.NUMBER, "[m-qhvkz] done"), self.done, 5)
        self.pump(connection, lambda: self.answers)
        result, error = self.answers[0]
        self.assertEqual((error, signal_client.send_failure(result)), ("", ""))
        self.assertEqual(daemon.requests, [{"jsonrpc": "2.0", "method": "send", "id": 1, "params": {
            "account": fake.NUMBER, "message": "[m-qhvkz] done", "noteToSelf": True, "notifySelf": True}}])

    def test_a_send_that_signal_cli_refuses_ends_with_its_error(self):
        self.daemon(send="error")
        connection = self.connected()
        connection.call("send", signal_client.send_params(fake.NUMBER, "x"), self.done, 5)
        self.pump(connection, lambda: self.answers)
        self.assertEqual(self.answers, [(None, "signal-cli: Failed to send message: Connection reset")])

    def test_a_send_that_gets_no_answer_fails_at_its_limit_and_only_once(self):
        self.daemon(send="silent")
        now = [100.0]
        connection = self.connected(clock=lambda: now[0])
        connection.call("send", signal_client.send_params(fake.NUMBER, "x"), self.done, 4)
        self.assertEqual(connection.next_limit(), 104.0)
        now[0] = 103.9
        connection.expire()
        self.assertEqual(self.answers, [])
        now[0] = 104.0
        connection.expire()
        connection.expire()
        self.assertEqual(self.answers, [(None, "signal-cli did not answer in time")])
        self.assertIsNone(connection.next_limit())

    def test_two_calls_get_their_own_answers(self):
        self.daemon()
        connection = self.connected()
        first, second = [], []
        connection.call("send", signal_client.send_params(fake.NUMBER, "one"), lambda r, e: first.append(e), 5)
        connection.call("nosuchmethod", {}, lambda r, e: second.append(e), 5)
        self.pump(connection, lambda: first and second)
        self.assertEqual((first, second), ([""], ["signal-cli: Method not implemented"]))

    def test_with_no_daemon_a_call_fails_at_once_and_connect_raises(self):
        connection = Connection(self.path)
        with self.assertRaises(OSError):
            connection.connect()
        connection.call("send", {}, self.done, 5)
        self.assertEqual(self.answers, [(None, "signal-cli's socket is not connected")])

    def test_a_daemon_that_stops_fails_the_waiting_calls(self):
        daemon = self.daemon(send="silent")
        connection = self.connected()
        connection.call("send", signal_client.send_params(fake.NUMBER, "x"), self.done, 60)
        self.pump(connection, lambda: daemon.requests)
        daemon.drop_clients()
        self.pump(connection, lambda: self.answers)
        self.assertEqual(self.answers, [(None, "signal-cli closed its socket")])
        self.assertIsNone(connection.socket)

    def test_a_received_message_arrives_as_its_params_and_settles_no_call(self):
        daemon = self.daemon()
        connection = self.connected()
        connection.call("listAccounts", {}, self.done, 5)
        self.pump(connection, lambda: self.answers)
        daemon.phone_says("yes m-qhvkz", STAMP)
        self.pump(connection, lambda: self.received)
        self.assertEqual(phone_text(self.received[0], ME), (STAMP, "yes m-qhvkz"))
        self.assertEqual(len(self.answers), 1)
        # A wake-up with nothing to read is not a failure of the connection.
        self.assertEqual(connection.readable(), [])
        self.assertIsNotNone(connection.socket)


if __name__ == "__main__":
    unittest.main()
