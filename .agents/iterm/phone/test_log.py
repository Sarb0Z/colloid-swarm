#!/usr/bin/env python3
"""Tests for log.py: the event file, the transition table, the message record.

Seam: `Events`, `Messages` and `Errors` over a scratch folder, read back as the
files they wrote. Catches a state change the table does not allow, an event
that outlives 30 days or stays open over a restart, a second action on one
Signal timestamp, a file another user can read, and an id outside its
alphabet. Misses what the service does between two writes.
"""

import json
import os
import stat
import tempfile
import unittest
from pathlib import Path

import log

NOW = log.epoch_of("2026-11-18T09:00:00Z")
SESSION = {"id": "5e55", "agent": None, "handle": "colloid-swarm-c1", "project": "colloid-swarm",
           "account": "work", "cwd": "/repo"}


def mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)


class Scratch(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(self.folder))
        log.prepare(self.folder)
        self.errors = log.Errors(self.folder / "errors.log", clock=lambda: NOW)

    def events(self, letters="abcdefghijkmnopqrstuvwxyz"):
        """An event file whose ids come from `letters`, five at a time: m-abcde, then m-fghij."""
        feed = iter(letters * 40)
        return log.Events(self.folder / "events.jsonl", self.errors, choose=lambda _alphabet: next(feed))

    def lines(self, name):
        return [json.loads(line) for line in (self.folder / name).read_text().splitlines()]

    def open_one(self, events, now=NOW):
        return events.open_permission(session=SESSION, turn="p1", call="toolu_1", tool="Bash",
                                      preview="git push origin main", deadline=now + 3540, now=now)


class EventFile(Scratch):
    def test_a_new_permission_event_has_every_field_of_version_1(self):
        event = self.open_one(self.events())
        self.assertEqual(event, {
            "v": 1, "id": "m-abcde", "machine": "mac", "kind": "permission", "session": SESSION,
            "turn": "p1", "row": None, "call": "toolu_1", "created": "2026-11-18T09:00:00Z",
            "deadline": "2026-11-18T09:59:00Z", "text": None,
            "detail": {"tool": "Bash", "preview": "git push origin main"}, "attachments": [],
            "source": None, "state": "open", "answer": None,
        })
        self.assertEqual(self.lines("events.jsonl"), [event])

    def test_each_change_appends_the_whole_event_and_the_last_line_is_its_state(self):
        events = self.events()
        event = self.open_one(events)
        events.amend(event["id"], call="toolu_2")
        answer = {"via": "phone", "text": "yes", "at": "2026-11-18T09:00:05Z"}
        events.move(event["id"], "answered", answer)
        written = self.lines("events.jsonl")
        self.assertEqual([(line["call"], line["state"]) for line in written],
                         [("toolu_1", "open"), ("toolu_2", "open"), ("toolu_2", "answered")])
        self.assertEqual(written[-1], {**event, "call": "toolu_2", "state": "answered", "answer": answer})
        self.assertEqual(events.events[event["id"]], written[-1])

    def test_an_id_is_the_machine_letter_and_five_letters_without_l(self):
        events = log.Events(self.folder / "events.jsonl", self.errors)
        ids = {self.open_one(events)["id"] for _ in range(200)}
        self.assertEqual(len(ids), 200)
        for found in ids:
            self.assertRegex(found, r"^m-[a-km-z]{5}$")

    def test_an_id_in_use_is_not_given_again(self):
        events = self.events("aaaaa" + "aaaaa" + "bbbbb")
        self.assertEqual([self.open_one(events)["id"], self.open_one(events)["id"]], ["m-aaaaa", "m-bbbbb"])


class Transitions(Scratch):
    def test_an_open_permission_reaches_each_of_its_four_ends(self):
        for end in ("answered", "settled_at_mac", "expired", "closed"):
            events = self.events()
            event = self.open_one(events)
            self.assertEqual(events.move(event["id"], end, {"via": "none", "text": "", "at": "x"})["state"], end)

    def test_an_event_that_ended_does_not_move_again(self):
        events = self.events()
        event = self.open_one(events)
        events.move(event["id"], "settled_at_mac", {"via": "mac", "text": "allow", "at": "x"})
        for state in ("answered", "open", "expired", "closed", "settled_at_mac"):
            with self.assertRaises(ValueError):
                events.move(event["id"], state, {"via": "phone", "text": "yes", "at": "y"})
        self.assertEqual(events.events[event["id"]]["answer"]["via"], "mac")
        self.assertEqual(len(self.lines("events.jsonl")), 2)

    def test_a_state_outside_the_table_is_refused(self):
        events = self.events()
        event = self.open_one(events)
        for state in ("superseded", "ended", "sent", "done"):
            with self.assertRaises(ValueError):
                events.move(event["id"], state, {"via": "none", "text": "", "at": "x"})

    def test_amend_does_not_change_a_state(self):
        events = self.events()
        event = self.open_one(events)
        with self.assertRaises(ValueError):
            events.amend(event["id"], state="answered")


class Start(Scratch):
    def test_a_restart_closes_each_open_permission_and_keeps_the_ended_ones(self):
        events = self.events()
        waiting, done = self.open_one(events), self.open_one(events)
        events.move(done["id"], "expired", {"via": "none", "text": "", "at": "x"})

        again = self.events()
        closed = again.start(NOW + 60)
        self.assertEqual([event["id"] for event in closed], [waiting["id"]])
        self.assertEqual(again.events[waiting["id"]]["state"], "closed")
        self.assertEqual(again.events[waiting["id"]]["answer"],
                         {"via": "none", "text": "phone-link restarted", "at": "2026-11-18T09:01:00Z"})
        self.assertEqual(again.events[done["id"]]["state"], "expired")
        self.assertEqual(self.lines("events.jsonl")[-1]["state"], "closed")

    def test_events_older_than_30_days_leave_the_file_and_younger_ones_stay(self):
        events = self.events()
        old = self.open_one(events, now=NOW - 31 * 86400)
        events.move(old["id"], "expired", {"via": "none", "text": "", "at": "x"})
        young = self.open_one(events, now=NOW - 29 * 86400)
        events.move(young["id"], "expired", {"via": "none", "text": "", "at": "x"})

        again = self.events()
        again.start(NOW)
        self.assertEqual(list(again.events), [young["id"]])
        self.assertEqual({line["id"] for line in self.lines("events.jsonl")}, {young["id"]})
        self.assertEqual(len(self.lines("events.jsonl")), 2)

    def test_a_line_cut_short_is_dropped_and_reported_once(self):
        events = self.events()
        event = self.open_one(events)
        events.move(event["id"], "expired", {"via": "none", "text": "", "at": "x"})
        with open(self.folder / "events.jsonl", "a") as stream:
            stream.write('{"v": 1, "id": "m-zzzzz", "kin')

        again = self.events()
        again.start(NOW)
        self.assertEqual(list(again.events), [event["id"]])
        self.assertEqual((self.folder / "errors.log").read_text(),
                         "2026-11-18T09:00:00Z events.jsonl: dropped 1 line(s) that were not an event\n")
        self.assertEqual(len(self.lines("events.jsonl")), 2)

    def test_no_file_is_no_events(self):
        events = self.events()
        self.assertEqual(events.start(NOW), [])
        self.assertFalse((self.folder / "errors.log").exists())


class MessageRecord(Scratch):
    def messages(self):
        return log.Messages(self.folder / "messages.jsonl", self.errors)

    def test_a_recorded_timestamp_is_seen_now_and_after_a_restart(self):
        messages = self.messages()
        messages.start(NOW)
        self.assertFalse(messages.seen(1794992400000))
        messages.record(1794992400000, "refused: too old", NOW)
        self.assertTrue(messages.seen(1794992400000))
        self.assertFalse(messages.seen(1794992400001))

        again = self.messages()
        again.start(NOW + 5)
        self.assertTrue(again.seen(1794992400000))
        self.assertEqual(self.lines("messages.jsonl"),
                         [{"ts": 1794992400000, "at": "2026-11-18T09:00:00Z", "result": "refused: too old"}])

    def test_the_record_holds_no_message_text(self):
        messages = self.messages()
        messages.start(NOW)
        messages.record(1, "accepted", NOW)
        self.assertEqual(set(self.lines("messages.jsonl")[0]), {"ts", "at", "result"})

    def test_records_older_than_30_days_leave_the_file(self):
        messages = self.messages()
        messages.start(NOW)
        messages.record(1, "accepted", NOW - 31 * 86400)
        messages.record(2, "accepted", NOW - 86400)
        again = self.messages()
        again.start(NOW)
        self.assertEqual((again.seen(1), again.seen(2)), (False, True))
        self.assertEqual([line["ts"] for line in self.lines("messages.jsonl")], [2])


class Modes(Scratch):
    def test_acceptance_13_the_folder_is_0700_and_each_file_0600_under_any_umask(self):
        before = os.umask(0o022)
        self.addCleanup(os.umask, before)
        folder = self.folder / "state"
        log.prepare(folder)
        errors = log.Errors(folder / "errors.log", clock=lambda: NOW)
        events = log.Events(folder / "events.jsonl", errors)
        self.open_one(events)
        messages = log.Messages(folder / "messages.jsonl", errors)
        messages.record(1, "accepted", NOW)
        errors.write("a failure")
        want = {"errors.log": "0o600", "events.jsonl": "0o600", "messages.jsonl": "0o600"}
        self.assertEqual(mode(folder), 0o700)
        self.assertEqual({name: oct(mode(folder / name)) for name in sorted(os.listdir(folder))}, want)

        # A file that was readable to others is tightened by the next append to it.
        for name in want:
            (folder / name).chmod(0o644)
        self.open_one(events)
        messages.record(2, "accepted", NOW)
        errors.write("another failure")
        self.assertEqual({name: oct(mode(folder / name)) for name in sorted(os.listdir(folder))}, want)

        # And by a rewrite, which a start with an old event makes.
        (folder / "events.jsonl").chmod(0o644)
        log.Events(folder / "events.jsonl", errors).start(NOW + 31 * 86400)
        self.assertEqual(oct(mode(folder / "events.jsonl")), "0o600")

    def test_prepare_tightens_a_folder_that_was_open(self):
        folder = self.folder / "open"
        folder.mkdir(mode=0o755)
        log.prepare(folder)
        self.assertEqual(mode(folder), 0o700)


class ErrorFile(Scratch):
    def test_one_failure_is_one_line_with_its_time(self):
        self.errors.write("send failed for m-abcde:\n  connection reset")
        self.errors.write("second")
        self.assertEqual((self.folder / "errors.log").read_text(),
                         "2026-11-18T09:00:00Z send failed for m-abcde: connection reset\n"
                         "2026-11-18T09:00:00Z second\n")


class Folder(unittest.TestCase):
    def test_the_state_folder_is_under_home_unless_the_environment_names_one(self):
        self.assertEqual(log.state_dir({"HOME": "/Users/x"}), Path("/Users/x/.local/state/phone-link"))
        self.assertEqual(log.state_dir({"HOME": "/Users/x", "PHONE_LINK_STATE": "/tmp/s"}), Path("/tmp/s"))


if __name__ == "__main__":
    unittest.main()
