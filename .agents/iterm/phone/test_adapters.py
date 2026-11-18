#!/usr/bin/env python3
"""Tests for adapters.py: an alert kind's text to the phone and its answer to the hook.

Seam: `ADAPTERS["permission"]`'s `alert` and `answer` over one literal event and
literal phone texts. Catches an alert whose first line, minutes, zone or reply
line differ from the spec's example, a text taken for an approval it is not,
an approval lost to a phone keyboard's invisible characters, and a denial whose
message is not the operator's text as typed. Misses which event a message
answers, which `phone_link.py` decides.
"""

import unittest
from datetime import timedelta, timezone
from zoneinfo import ZoneInfo

import adapters
import log

EVENT = {
    "v": 1, "id": "m-qhvkz", "machine": "mac", "kind": "permission",
    "session": {"id": "5e55", "agent": None, "handle": "colloid-swarm-c1", "project": "colloid-swarm",
                "account": "work", "cwd": "/Users/x/Projects/colloid-swarm"},
    "turn": "p1", "row": None, "call": "toolu_1", "created": "2026-11-18T13:43:00Z",
    "deadline": "2026-11-18T14:42:00Z", "text": None,
    "detail": {"tool": "Bash", "preview": "git push origin main", "masked": 0, "cut": 0}, "attachments": [], "source": None,
    "state": "open", "answer": None,
}
PERMISSION = adapters.ADAPTERS["permission"]
REPLY_LINE = "Reply: yes, or tell Claude what to do instead"
ALLOW = {"type": "decision", "behavior": "allow"}
THUMB, THUMB_DOWN = "\N{THUMBS UP SIGN}", "\N{THUMBS DOWN SIGN}"
EMOJI_STYLE, TEXT_STYLE = "\N{VARIATION SELECTOR-16}", "\N{VARIATION SELECTOR-15}"
LIGHT_SKIN, MEDIUM_SKIN = "\N{EMOJI MODIFIER FITZPATRICK TYPE-1-2}", "\N{EMOJI MODIFIER FITZPATRICK TYPE-4}"
ZERO_WIDTH, BYTE_ORDER, SOFT_HYPHEN = "\N{ZERO WIDTH SPACE}", "\N{ZERO WIDTH NO-BREAK SPACE}", "\N{SOFT HYPHEN}"
ISOLATE, ISOLATE_END = "\N{FIRST STRONG ISOLATE}", "\N{POP DIRECTIONAL ISOLATE}"


def deny(message):
    return {"type": "decision", "behavior": "deny", "message": message}


class Alert(unittest.TestCase):
    def test_acceptance_1_the_alert_of_the_specs_example(self):
        zone = timezone(timedelta(hours=5), "PKT")
        sent_at = log.epoch_of("2026-11-18T13:43:00Z") + 0.4
        self.assertEqual(PERMISSION.alert(EVENT, sent_at, zone), "\n".join([
            "[m-qhvkz] colloid-swarm · Mac · work · colloid-swarm-c1",
            "Permission: Bash · answer within 59 min (by 19:42 PKT)",
            "git push origin main",
            REPLY_LINE,
        ]))

    def test_the_minutes_are_those_left_when_the_alert_goes_out(self):
        zone = ZoneInfo("UTC")
        # 3540 s from creation to deadline; the minutes left, to the nearest minute.
        for seconds_late, minutes in ((0, 59), (29, 59), (31, 58), (60, 58), (3509, 1), (3511, 0), (4000, 0)):
            sent_at = log.epoch_of("2026-11-18T13:43:00Z") + seconds_late
            self.assertIn(f"answer within {minutes} min (by 14:42 UTC)", PERMISSION.alert(EVENT, sent_at, zone))

    def test_the_time_is_in_the_configured_zone(self):
        line = PERMISSION.alert(EVENT, log.epoch_of("2026-11-18T13:43:00Z"), ZoneInfo("Europe/Lisbon")).split("\n")[1]
        self.assertEqual(line, "Permission: Bash · answer within 59 min (by 14:42 WET)")
        line = PERMISSION.alert(EVENT, log.epoch_of("2026-11-18T13:43:00Z"), ZoneInfo("America/New_York")).split("\n")[1]
        self.assertEqual(line, "Permission: Bash · answer within 59 min (by 09:42 EST)")

    def test_a_preview_of_several_lines_stays_between_the_header_and_the_reply_line(self):
        event = {**EVENT, "detail": {"tool": "Edit", "preview": "/repo/a.py\n- old\n+ new", "masked": 0, "cut": 0}}
        lines = PERMISSION.alert(event, log.epoch_of("2026-11-18T13:43:00Z"), ZoneInfo("UTC")).split("\n")
        self.assertEqual(lines[1][:16], "Permission: Edit")
        self.assertEqual(lines[2:5], ["/repo/a.py", "- old", "+ new"])
        self.assertEqual(lines[-1], REPLY_LINE)

    def test_an_alert_that_masked_or_cut_its_preview_says_so_above_the_reply_line(self):
        at, zone = log.epoch_of("2026-11-18T13:43:00Z"), ZoneInfo("UTC")
        for masked, cut, said in ((2, 147, "masked: 2 values · cut: 147 more characters"),
                                  (1, 0, "masked: 1 value"), (0, 1, "cut: 1 more character")):
            event = {**EVENT, "detail": {**EVENT["detail"], "masked": masked, "cut": cut}}
            lines = PERMISSION.alert(event, at, zone).split("\n")
            self.assertEqual(lines[2:], ["git push origin main", said, REPLY_LINE], (masked, cut))

    def test_an_alert_that_shows_the_whole_call_has_no_such_line(self):
        lines = PERMISSION.alert(EVENT, log.epoch_of("2026-11-18T13:43:00Z"), ZoneInfo("UTC")).split("\n")
        self.assertEqual(len(lines), 4)

    def test_a_shorter_deadline_is_one_line_about_the_event(self):
        event = {**EVENT, "deadline": "2026-11-18T13:53:00Z"}
        self.assertEqual(adapters.new_deadline(event, log.epoch_of("2026-11-18T13:43:00Z"), ZoneInfo("UTC")),
                         "[m-qhvkz] answer within 10 min (by 13:53 UTC)")


class Answer(unittest.TestCase):
    def test_acceptance_1_each_approval_word_allows(self):
        for text in ("yes", "y", "yep", "ok", "okay", "sure", "go", "allow", "approve", "approved", THUMB):
            self.assertEqual(PERMISSION.answer(EVENT, text), ALLOW, text)

    def test_acceptance_1_what_a_phone_keyboard_adds_to_an_approval_still_allows(self):
        # Emoji and text variation selectors, skin tones, a zero-width space, the isolates
        # iOS puts round pasted text, a byte-order mark and a soft hyphen.
        for text in ("Yes", "OK", "Ok.", "yes.", "Yes!", "  sure  ", "o.k.", "...ok",
                     f"{THUMB}{EMOJI_STYLE}", f"{THUMB}{TEXT_STYLE}", f"{THUMB}{MEDIUM_SKIN}",
                     f"{THUMB}{LIGHT_SKIN}{EMOJI_STYLE}", f"yes.{ZERO_WIDTH}", f"{ISOLATE}yes{ISOLATE_END}",
                     f"{BYTE_ORDER}ok", f"ye{SOFT_HYPHEN}s"):
            self.assertEqual(PERMISSION.answer(EVENT, text), ALLOW, repr(text))

    def test_acceptance_2_and_3_any_other_text_denies_with_the_text_as_typed(self):
        for text in ("no", "No.", "no, push to main instead", "yes but skip the tests", "yes yes",
                     f"ok {THUMB}", f"{THUMB}{THUMB}", THUMB_DOWN, "nope", "yess", "yes please", "go ahead",
                     "help", "y es", f"ok{MEDIUM_SKIN}", MEDIUM_SKIN, "?"):
            self.assertEqual(PERMISSION.answer(EVENT, text), deny(text), repr(text))

    def test_a_message_with_no_words_left_after_the_id_denies_and_says_where_the_denial_came_from(self):
        self.assertEqual(PERMISSION.answer(EVENT, ""), deny("Denied from the operator's phone."))


if __name__ == "__main__":
    unittest.main()
