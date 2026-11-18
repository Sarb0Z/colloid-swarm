#!/usr/bin/env python3
"""Tests for grammar.py: what a phone message means, and the texts sent to the phone.

Seam: `parse`, `alert`, `reply` and `refusal_for` over literal messages and one
literal event. Catches a message taken for an answer it is not, an answer bound
to the wrong id, an alert whose first line, minutes or zone differ from the
spec's example, and a `no` after a Mac allow told anything but that the call
ran. Misses how a real phone keyboard rewrites what the operator types.
"""

import unittest
from datetime import timedelta, timezone
from zoneinfo import ZoneInfo

import grammar
import log
from grammar import Command

EVENT = {
    "v": 1, "id": "m-qhvkz", "machine": "mac", "kind": "permission",
    "session": {"id": "5e55", "agent": None, "handle": "colloid-swarm-c1", "project": "colloid-swarm",
                "account": "work", "cwd": "/Users/x/Projects/colloid-swarm"},
    "turn": "p1", "row": None, "call": "toolu_1", "created": "2026-11-18T13:43:00Z",
    "deadline": "2026-11-18T14:42:00Z", "text": None,
    "detail": {"tool": "Bash", "preview": "git push origin main"}, "attachments": [], "source": None,
    "state": "open", "answer": None,
}


class Parse(unittest.TestCase):
    def test_yes_with_an_id(self):
        self.assertEqual(grammar.parse("yes m-qhvkz"), Command("yes", "m-qhvkz"))

    def test_no_with_an_id_and_no_reason(self):
        self.assertEqual(grammar.parse("no m-qhvkz"), Command("no", "m-qhvkz", ""))

    def test_no_with_a_reason_keeps_the_reason_as_typed(self):
        self.assertEqual(grammar.parse("no m-qhvkz too risky, Use --dry-run."),
                         Command("no", "m-qhvkz", "too risky, Use --dry-run."))

    def test_what_a_phone_keyboard_does_to_a_message(self):
        self.assertEqual(grammar.parse("Yes m-qhvkz"), Command("yes", "m-qhvkz"))
        self.assertEqual(grammar.parse("  YES  M-QHVKZ. \n"), Command("yes", "m-qhvkz"))
        self.assertEqual(grammar.parse("No m-qhvkz. Too risky"), Command("no", "m-qhvkz", "Too risky"))

    def test_help(self):
        self.assertEqual(grammar.parse("Help"), Command("help"))

    def test_reserved_words_and_later_units_are_known_and_not_built(self):
        for text in ("status", "start colloid-swarm mac w", "mute colloid-swarm-c1", "unmute x",
                     "@colloid-swarm-c1 run the suite"):
            self.assertEqual(grammar.parse(text), Command("unbuilt"), text)
        self.assertEqual(grammar.parse("m-qhvkz yes"), Command("unbuilt", "m-qhvkz"))
        self.assertEqual(grammar.parse("s-tbnaw push it"), Command("unbuilt", "s-tbnaw"))

    def test_anything_else_is_not_understood(self):
        for text in ("", "   ", "yes", "no", "yes please", "yes m-qhvk", "yes m-qhvkzz", "yes mqhvkz",
                     "yes m-qhvkz now", "yes m-qhvkz..", "yes m-qh1kz", "ok m-qhvkz", "help me", "m-qhvkz",
                     "@", "@handle", "yes, m-qhvkz", "approve m-qhvkz"):
            self.assertEqual(grammar.parse(text), Command("unknown"), repr(text))


class Alert(unittest.TestCase):
    def test_acceptance_1_the_alert_of_the_specs_example(self):
        zone = timezone(timedelta(hours=5), "PKT")
        sent_at = log.epoch_of("2026-11-18T13:43:00Z") + 0.4
        self.assertEqual(grammar.alert(EVENT, sent_at, zone), "\n".join([
            "[m-qhvkz] colloid-swarm · Mac · work · colloid-swarm-c1",
            "Permission: Bash · answer within 59 min (by 19:42 PKT)",
            "git push origin main",
            "Reply: yes m-qhvkz   or   no m-qhvkz <reason>",
        ]))

    def test_the_minutes_are_those_left_when_the_alert_goes_out(self):
        zone = ZoneInfo("UTC")
        # 3540 s from creation to deadline; the minutes left, to the nearest minute.
        for seconds_late, minutes in ((0, 59), (29, 59), (31, 58), (60, 58), (3509, 1), (3511, 0), (4000, 0)):
            sent_at = log.epoch_of("2026-11-18T13:43:00Z") + seconds_late
            self.assertIn(f"answer within {minutes} min (by 14:42 UTC)", grammar.alert(EVENT, sent_at, zone))

    def test_the_time_is_in_the_configured_zone(self):
        line = grammar.alert(EVENT, log.epoch_of("2026-11-18T13:43:00Z"), ZoneInfo("Europe/Lisbon")).split("\n")[1]
        self.assertEqual(line, "Permission: Bash · answer within 59 min (by 14:42 WET)")
        line = grammar.alert(EVENT, log.epoch_of("2026-11-18T13:43:00Z"), ZoneInfo("America/New_York")).split("\n")[1]
        self.assertEqual(line, "Permission: Bash · answer within 59 min (by 09:42 EST)")

    def test_a_preview_of_several_lines_stays_between_the_header_and_the_reply_line(self):
        event = {**EVENT, "detail": {"tool": "Edit", "preview": "/repo/a.py\n- old\n+ new"}}
        lines = grammar.alert(event, log.epoch_of("2026-11-18T13:43:00Z"), ZoneInfo("UTC")).split("\n")
        self.assertEqual(lines[1][:16], "Permission: Edit")
        self.assertEqual(lines[2:5], ["/repo/a.py", "- old", "+ new"])
        self.assertEqual(lines[-1], "Reply: yes m-qhvkz   or   no m-qhvkz <reason>")


class Replies(unittest.TestCase):
    def test_a_reply_starts_with_the_event_id_in_brackets(self):
        self.assertEqual(grammar.reply("m-qhvkz", "done"), "[m-qhvkz] done")
        self.assertEqual(grammar.reply("m-qhvkz", grammar.refused("expired")), "[m-qhvkz] refused: expired")

    def test_an_answer_to_an_event_that_is_not_open_gets_the_reason_of_its_state(self):
        for state, reason in (("answered", "already answered"), ("settled_at_mac", "settled at the Mac"),
                              ("expired", "expired"), ("closed", "closed")):
            event = {**EVENT, "state": state, "answer": {"via": "mac", "text": "deny", "at": "x"}}
            self.assertEqual(grammar.refusal_for(event, Command("yes", "m-qhvkz")), reason)
            self.assertEqual(grammar.refusal_for(event, Command("no", "m-qhvkz", "x")), reason)

    def test_a_no_after_the_mac_allowed_the_call_says_that_it_ran(self):
        event = {**EVENT, "state": "settled_at_mac", "answer": {"via": "mac", "text": "allow", "at": "x"}}
        self.assertEqual(grammar.refusal_for(event, Command("no", "m-qhvkz", "x")), "the Mac allowed it first")
        self.assertEqual(grammar.refusal_for(event, Command("yes", "m-qhvkz")), "settled at the Mac")

    def test_the_queue_notice(self):
        self.assertEqual(grammar.waiting_notice(7), "7 more waiting")

    def test_help_lists_what_this_unit_answers(self):
        self.assertEqual(grammar.HELP.split("\n"), [
            "yes <id> — allow the tool call of that alert",
            "no <id> <reason> — deny it; Claude reads the reason",
            "help — this list",
        ])


if __name__ == "__main__":
    unittest.main()
