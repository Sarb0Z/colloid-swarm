#!/usr/bin/env python3
"""Tests for transcript.py: finding a waiting call, and reading how a call ended.

Seam: `tail`, `Follow` and `Calls` over transcript files that `fixtures.py`
writes in Claude Code's observed row shapes. Catches a call matched by name
alone, a settled call taken for a waiting one, an ending read as the wrong
party's, a row read while half written, and a subagent's call sought in the
session's file. Misses a row shape Claude Code has not written in the probed
sessions.
"""

import os
import shutil
import tempfile
import unittest

import transcript
from fixtures import Transcript
from transcript import Calls, Ending, Follow

PUSH = {"command": "git push origin main", "description": "Push"}


class Files(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.folder)
        self.path = os.path.join(self.folder, "session.jsonl")
        self.now = 1794992400.0
        self.written = Transcript(self.path, clock=self.tick)

    def tick(self):
        self.now += 1
        return self.now

    def calls(self, wanted=None, path=None):
        calls = Calls(wanted)
        rows, _offset = transcript.tail(path or self.path)
        calls.add(rows)
        return calls


class CallFile(unittest.TestCase):
    def test_a_session_call_is_in_the_session_transcript(self):
        self.assertEqual(transcript.call_file("/c/projects/p/5e55.jsonl", None), "/c/projects/p/5e55.jsonl")

    def test_an_agent_call_is_in_the_agent_file_beside_it(self):
        self.assertEqual(transcript.call_file("/c/projects/p/5e55.jsonl", "a8dd0c32357e878bd"),
                         "/c/projects/p/5e55/subagents/agent-a8dd0c32357e878bd.jsonl")


class Waiting(Files):
    def test_the_pending_call_is_found_by_name_and_input(self):
        self.written.prompt("push it")
        self.written.use("toolu_1", "Bash", PUSH)
        self.assertEqual(self.calls(("Bash", PUSH)).waiting(), ["toolu_1"])

    def test_another_input_or_another_tool_is_not_the_call(self):
        self.written.use("toolu_1", "Bash", {"command": "git push origin dev", "description": "Push"})
        self.written.use("toolu_2", "Write", PUSH)
        self.assertEqual(self.calls(("Bash", PUSH)).waiting(), [])

    def test_a_call_that_ended_does_not_wait(self):
        for end in ("allowed_by_hook", "denied_by_hook", "allowed_at_mac", "rejected_at_mac",
                    "denied_without_dialog"):
            with self.subTest(end):
                os.path.exists(self.path) and os.remove(self.path)
                self.written.use("toolu_1", "Bash", PUSH)
                getattr(self.written, end)("toolu_1")
                self.assertEqual(self.calls(("Bash", PUSH)).waiting(), [])

    def test_a_call_a_hook_decided_does_not_wait_before_its_result(self):
        self.written.use("toolu_1", "Bash", PUSH)
        self.written.hook_decided("toolu_1", "allow")
        self.assertEqual(self.calls(("Bash", PUSH)).waiting(), [])

    def test_of_two_equal_calls_the_latest_is_first_and_a_settled_one_is_left_out(self):
        self.written.use("toolu_1", "Bash", PUSH)
        self.written.allowed_at_mac("toolu_1")
        self.written.use("toolu_2", "Bash", PUSH)
        self.written.use("toolu_3", "Bash", PUSH)
        self.assertEqual(self.calls(("Bash", PUSH)).waiting(), ["toolu_3", "toolu_2"])

    def test_only_the_last_200_rows_are_read(self):
        self.written.use("toolu_old", "Bash", PUSH)
        self.written.other_rows(200)
        self.assertEqual(self.calls(("Bash", PUSH)).waiting(), [])
        os.remove(self.path)
        self.written.use("toolu_new", "Bash", PUSH)
        self.written.other_rows(199)
        self.assertEqual(self.calls(("Bash", PUSH)).waiting(), ["toolu_new"])

    def test_rows_longer_than_a_read_chunk_are_read_whole(self):
        before = transcript.CHUNK
        transcript.CHUNK = 256
        self.addCleanup(setattr, transcript, "CHUNK", before)
        big = {"command": "echo " + "x" * 2000, "description": "Big"}
        self.written.other_rows(3)
        self.written.use("toolu_big", "Bash", big)
        self.written.other_rows(5)
        self.assertEqual(self.calls(("Bash", big)).waiting(), ["toolu_big"])

    def test_no_file_is_no_calls(self):
        rows, offset = transcript.tail(os.path.join(self.folder, "absent.jsonl"))
        self.assertEqual((rows, offset), ([], 0))

    def test_a_subagent_call_is_in_its_own_file_and_not_the_sessions(self):
        agent_path = transcript.call_file(self.path, "a1b2")
        os.makedirs(os.path.dirname(agent_path))
        self.written.prompt("start an agent")
        Transcript(agent_path, agent="a1b2", clock=self.tick).use("toolu_agent", "Bash", PUSH)
        self.assertEqual(self.calls(("Bash", PUSH)).waiting(), [])
        self.assertEqual(self.calls(("Bash", PUSH), agent_path).waiting(), ["toolu_agent"])


class Endings(Files):
    def ending_after(self, end):
        self.written.use("toolu_1", "Bash", PUSH)
        getattr(self.written, end)("toolu_1")
        return self.calls().ending("toolu_1")

    def test_a_hooks_allow(self):
        self.assertEqual(self.ending_after("allowed_by_hook"), Ending("hook", "allow"))

    def test_a_hooks_deny(self):
        self.assertEqual(self.ending_after("denied_by_hook"), Ending("hook", "deny"))

    def test_an_allow_at_the_mac(self):
        self.assertEqual(self.ending_after("allowed_at_mac"), Ending("mac", "allow"))

    def test_a_no_or_an_esc_at_the_mac(self):
        self.assertEqual(self.ending_after("rejected_at_mac"), Ending("mac", "deny"))

    def test_a_denial_where_no_dialog_shows(self):
        self.assertEqual(self.ending_after("denied_without_dialog"), Ending("other", "deny"))

    def test_a_waiting_call_has_no_ending(self):
        self.written.use("toolu_1", "Bash", PUSH)
        self.assertIsNone(self.calls().ending("toolu_1"))

    def test_a_hooks_decision_row_is_an_ending_before_the_result_is_written(self):
        self.written.use("toolu_1", "Bash", PUSH)
        self.written.hook_decided("toolu_1", "allow")
        self.assertEqual(self.calls().ending("toolu_1"), Ending("hook", "allow"))

    def test_a_result_read_from_an_agent_file_without_its_decision_row(self):
        # The result row alone names the hook: `permissionDecision.source`.
        self.written.use("toolu_1", "Bash", PUSH)
        self.written._result("toolu_1", "ok", False, {"stdout": "ok"},
                             permissionDecision={"decision": "accept", "source": "hook", "reasonType": "hook"})
        self.assertEqual(self.calls().ending("toolu_1"), Ending("hook", "allow"))

    def test_each_call_keeps_its_own_ending(self):
        self.written.use("toolu_1", "Bash", PUSH)
        self.written.use("toolu_2", "Bash", PUSH)
        self.written.allowed_at_mac("toolu_1")
        calls = self.calls()
        self.assertEqual((calls.ending("toolu_1"), calls.ending("toolu_2")), (Ending("mac", "allow"), None))
        self.written.denied_by_hook("toolu_2")
        self.assertEqual(self.calls().ended(),
                         {"toolu_1": Ending("mac", "allow"), "toolu_2": Ending("hook", "deny")})

    def test_an_interrupt_counts_from_its_own_time_on(self):
        self.written.use("toolu_1", "Bash", PUSH)
        before = self.now
        self.written.rejected_at_mac("toolu_1")
        calls = self.calls()
        self.assertTrue(calls.interrupted_since(before))
        self.assertTrue(calls.interrupted_since(self.now))
        self.assertFalse(calls.interrupted_since(self.now + 1))

    def test_a_prompt_that_quotes_the_interrupt_text_is_no_interrupt(self):
        self.written.prompt("why does it say [Request interrupted by user for tool use]?")
        self.assertFalse(self.calls().interrupted_since(0))


class Following(Files):
    def test_follow_reads_only_what_the_file_gained(self):
        self.written.use("toolu_1", "Bash", PUSH)
        rows, offset = transcript.tail(self.path)
        follow, calls = Follow(self.path, offset), Calls()
        calls.add(rows)
        self.assertEqual(follow.read(), [])
        self.written.allowed_at_mac("toolu_1")
        gained = follow.read()
        self.assertEqual(len(gained), 1)
        calls.add(gained)
        self.assertEqual(calls.ending("toolu_1"), Ending("mac", "allow"))
        self.assertEqual(follow.read(), [])

    def test_a_row_half_written_is_read_once_it_is_whole(self):
        self.written.use("toolu_1", "Bash", PUSH)
        _rows, offset = transcript.tail(self.path)
        follow = Follow(self.path, offset)
        self.written.allowed_at_mac("toolu_1")
        with open(self.path, "rb") as stream:
            whole = stream.read()
        cut = offset + (len(whole) - offset) // 2
        with open(self.path, "wb") as stream:
            stream.write(whole[:cut])
        self.assertEqual(follow.read(), [])
        self.assertEqual(transcript.tail(self.path)[1], offset)
        with open(self.path, "ab") as stream:
            stream.write(whole[cut:])
        calls = Calls()
        calls.add(follow.read())
        self.assertEqual(calls.ending("toolu_1"), Ending("mac", "allow"))

    def test_a_file_that_appears_later_is_read_from_its_start(self):
        late = os.path.join(self.folder, "agent.jsonl")
        _rows, offset = transcript.tail(late)
        follow = Follow(late, offset)
        self.assertEqual(follow.read(), [])
        Transcript(late, agent="a1", clock=self.tick).use("toolu_9", "Bash", PUSH)
        calls = Calls(("Bash", PUSH))
        calls.add(follow.read())
        self.assertEqual(calls.waiting(), ["toolu_9"])


if __name__ == "__main__":
    unittest.main()
