#!/usr/bin/env python3
"""Tests for grammar.py: what a phone message is, and the link's own texts to the phone.

Seam: `parse`, `reply` and `refusal_for` over literal messages and one literal
event. Catches a command taken for an answer or an answer for a command, an id
read from the wrong word or left in the answer's text, a text changed on its
way to Claude, and a denial after a Mac allow told anything but that the call
ran. Misses what an answer does to a hook, which `adapters.py` decides.
"""

import unittest

import grammar
from grammar import Message

EVENT = {
    "v": 1, "id": "m-qhvkz", "machine": "mac", "kind": "permission",
    "session": {"id": "5e55", "agent": None, "handle": "colloid-swarm-c1", "project": "colloid-swarm",
                "account": "work", "cwd": "/Users/x/Projects/colloid-swarm"},
    "turn": "p1", "row": None, "call": "toolu_1", "created": "2026-11-18T13:43:00Z",
    "deadline": "2026-11-18T14:42:00Z", "text": None,
    "detail": {"tool": "Bash", "preview": "git push origin main", "masked": 0, "cut": 0}, "attachments": [], "source": None,
    "state": "open", "answer": None,
}


class Parse(unittest.TestCase):
    def test_help_alone(self):
        self.assertEqual(grammar.parse("help"), Message("help"))
        self.assertEqual(grammar.parse("  Help \n"), Message("help"))

    def test_reserved_words_alone_and_a_request_to_a_handle_are_not_built(self):
        for text in ("status", "Start", "mute", "unmute", "@colloid-swarm-c1 run the suite"):
            self.assertEqual(grammar.parse(text), Message("unbuilt"), text)

    def test_acceptance_10_any_other_text_is_an_answer_as_typed(self):
        for text in ("yes", "approve it", "no, push to main instead", "yes but skip the tests", "help me",
                     "status of the build?", "start over with a smaller change", "@", "@handle", "Yes."):
            self.assertEqual(grammar.parse(text), Message("answer", "", text), text)

    def test_the_text_keeps_its_case_punctuation_and_lines_and_loses_only_its_outer_space(self):
        self.assertEqual(grammar.parse("  No, Too risky.\nUse --dry-run!  "),
                         Message("answer", "", "No, Too risky.\nUse --dry-run!"))

    def test_acceptance_5_an_id_in_the_first_or_second_word_names_its_event_and_leaves_the_text(self):
        self.assertEqual(grammar.parse("yes m-qhvkz"), Message("answer", "m-qhvkz", "yes"))
        self.assertEqual(grammar.parse("m-qhvkz yes"), Message("answer", "m-qhvkz", "yes"))
        self.assertEqual(grammar.parse("no m-qhvkz too risky, Use --dry-run."),
                         Message("answer", "m-qhvkz", "no too risky, Use --dry-run."))
        self.assertEqual(grammar.parse("m-qhvkz"), Message("answer", "m-qhvkz", ""))
        self.assertEqual(grammar.parse("s-tbnaw push it"), Message("answer", "s-tbnaw", "push it"))

    def test_the_id_matches_in_any_case_with_trailing_punctuation(self):
        self.assertEqual(grammar.parse("Yes M-QHVKZ."), Message("answer", "m-qhvkz", "Yes"))
        self.assertEqual(grammar.parse("M-qhvkz: no, not now"), Message("answer", "m-qhvkz", "no, not now"))
        self.assertEqual(grammar.parse("ok m-qhvkz!!"), Message("answer", "m-qhvkz", "ok"))

    def test_an_id_past_the_second_word_or_not_an_id_names_no_event(self):
        for text in ("yes please m-qhvkz", "yes m-qhvk", "yes m-qhvkzz", "yes mqhvkz", "yes m-qh1kz",
                     "yes (m-qhvkz)"):
            self.assertEqual(grammar.parse(text), Message("answer", "", text), text)

    def test_a_reserved_word_or_help_with_more_words_is_an_answer(self):
        self.assertEqual(grammar.parse("help m-qhvkz"), Message("answer", "m-qhvkz", "help"))
        self.assertEqual(grammar.parse("mute colloid-swarm-c1"), Message("answer", "", "mute colloid-swarm-c1"))


class Replies(unittest.TestCase):
    def test_a_reply_starts_with_the_event_id_in_brackets(self):
        self.assertEqual(grammar.reply("m-qhvkz", "done"), "[m-qhvkz] done")
        self.assertEqual(grammar.reply("m-qhvkz", grammar.refused("expired")), "[m-qhvkz] refused: expired")

    def test_an_answer_to_an_event_that_is_not_open_gets_the_reason_of_its_state(self):
        for state, reason in (("answered", "already answered"), ("settled_at_mac", "settled at the Mac"),
                              ("expired", "expired"), ("closed", "closed")):
            event = {**EVENT, "state": state, "answer": {"via": "mac", "text": "deny", "at": "x"}}
            self.assertEqual(grammar.refusal_for(event, "allow"), reason)
            self.assertEqual(grammar.refusal_for(event, "deny"), reason)

    def test_a_denial_after_the_mac_allowed_the_call_says_that_it_ran(self):
        event = {**EVENT, "state": "settled_at_mac", "answer": {"via": "mac", "text": "allow", "at": "x"}}
        self.assertEqual(grammar.refusal_for(event, "deny"), "the Mac allowed it first")
        self.assertEqual(grammar.refusal_for(event, "allow"), "settled at the Mac")

    def test_the_summary_of_held_refusals(self):
        self.assertEqual(grammar.refusal_summary(["too old"] * 5 + ["no open alert"] * 2),
                         "refused: 7 more messages (5 too old, 2 no open alert)")
        self.assertEqual(grammar.refusal_summary(["no open alert", "too old", "no open alert"]),
                         "refused: 3 more messages (2 no open alert, 1 too old)")
        self.assertEqual(grammar.refusal_summary(["too old"]), "refused: 1 more message (1 too old)")

    def test_the_queue_notice(self):
        self.assertEqual(grammar.waiting_notice(7), "7 more waiting")

    def test_help_lists_how_an_answer_is_read(self):
        self.assertEqual(grammar.HELP.split("\n"), [
            "yes, ok or \N{THUMBS UP SIGN} — allow the call",
            "any other words — deny it; Claude reads them as you typed them",
            "a reply answers the alert it quotes; an id in the first two words answers that alert; "
            "otherwise the newest alert",
            "help — this list",
        ])


if __name__ == "__main__":
    unittest.main()
