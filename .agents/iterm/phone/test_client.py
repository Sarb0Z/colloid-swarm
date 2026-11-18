#!/usr/bin/env python3
"""Tests for client.py: the permission hook's wait, steps 1-8 of the spec's "Permission prompts".

Seams:
  (a) `run` with its effects passed in: a stand-in for the service's
      connection that says what the service sends and when, a clock that moves
      only when the hook waits, a process table as a dictionary, and
      transcripts written by `fixtures.py`. Catches a decision printed that the
      phone did not give, a hook that waits on after the Mac settled its call
      or its session ended, a subagent's call watched in the wrong file, raw
      tool input in the registration, and a deadline that is not 60 s short of
      Claude Code's. Misses real sockets and real time.
  (b) `run` with the real `ServiceLink` against no service and against
      `phone_link.serve` in a thread. Catches a hook that hangs or prints when
      phone-link is stopped, and a decision lost between the service and
      stdout. Misses Claude Code, which the live checkpoint shows.
  (c) `preview` over literal tool inputs. Catches a preview that shows the
      wrong lines or more than ten.
"""

import contextlib
import io
import json
import os
import shutil
import socket
import sys
import tempfile
import threading
import time
import unittest
from datetime import timedelta, timezone
from pathlib import Path
from unittest import mock

import client
import fake_signal_cli as fake
import log
import phone_link
import sessions
import signal_client
import transcript
from fixtures import Transcript

START = "Wed Nov 18 08:06:05 2026"
PUSH = {"command": "git push origin main", "description": "Push"}
T0 = 1794992400.0


class Service:
    """Stands in for the hook socket. `script` maps a time to the messages the service sends
    then; `read` moves the test's clock, so a wait costs no real time."""

    def __init__(self, test, script):
        self.test, self.script, self.sent, self.closed = test, dict(script), [], False
        self.ends_at = None  # when the service goes away

    def send(self, message):
        self.sent.append((round(self.test.now - T0, 3), message))

    def read(self, seconds):
        due = [at for at in self.script if at <= self.test.now + max(0.0, seconds)]
        if self.ends_at is not None and self.ends_at <= self.test.now + max(0.0, seconds):
            self.test.now = max(self.test.now, self.ends_at)
            return None
        if due:
            at = min(due)
            self.test.now = max(self.test.now, at)
            return self.script.pop(at)
        self.test.now += max(0.0, seconds)
        for at, action in list(self.test.at.items()):
            if at <= self.test.now:
                del self.test.at[at]
                action()
        return []

    def close(self):
        self.closed = True

    def of(self, kind):
        return [(at, message) for at, message in self.sent if message["type"] == kind]


class Hook(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.folder)
        self.repo = self.folder / "colloid-swarm"
        (self.repo / ".agents").mkdir(parents=True)
        (self.repo / ".agents" / "AGENTS.md").write_text("# harness\n")
        self.config = self.folder / ".claude-guest"
        self.path = str(self.config / "projects" / "-p" / "5e55.jsonl")
        os.makedirs(os.path.dirname(self.path))
        self.now = T0
        self.at = {}  # time -> what happens on the Mac then
        self.written = Transcript(self.path, clock=lambda: self.now)
        self.running = {4242: START}
        self.out, self.err = [], []
        self.service = None
        self.connected_to = None

    def payload(self, **fields):
        return {"session_id": "5e55", "transcript_path": self.path, "cwd": str(self.repo), "prompt_id": "prompt-1",
                "permission_mode": "default", "hook_event_name": "PermissionRequest", "tool_name": "Bash",
                "tool_input": PUSH, **fields}

    def effects(self, script):
        test = self
        self.service = Service(self, script)

        class Fakes:
            @staticmethod
            def connect(path):
                test.connected_to = path
                return test.service

            @staticmethod
            def clock():
                return test.now

            @staticmethod
            def alive(pid):
                return pid in test.running

            @staticmethod
            def starts(pids):
                return {pid: test.running[pid] for pid in pids if pid in test.running}

            @staticmethod
            def claude():
                return (4242, START) if 4242 in test.running else None

        return Fakes

    def run_hook(self, script=None, payload=None, environ=None):
        script = {T0 + 0.01: [{"type": "registered", "id": "m-abcde", "call": "toolu_1"}]} if script is None else script
        environ = {"HOME": str(self.folder), "CLAUDE_PROFILE": "guest", **(environ or {})}
        code = client.run(payload or self.payload(), environ, self.effects(script), self.out.append, self.err.append)
        self.assertEqual(code, 0)
        return round(self.now - T0, 3)

    def registration(self):
        return self.service.of("permission")[0][1]


class Harness(Hook):
    def test_acceptance_19_a_session_outside_the_harness_gets_no_alert_and_no_output(self):
        plain = self.folder / "plain" / "deep"
        plain.mkdir(parents=True)
        self.written.use("toolu_1", "Bash", PUSH)
        self.run_hook(payload=self.payload(cwd=str(plain)))
        self.assertEqual((self.connected_to, self.out, self.err), (None, [], []))

    def test_acceptance_19_a_folder_below_the_harness_root_is_covered(self):
        deep = self.repo / "src" / "a" / "b"
        deep.mkdir(parents=True)
        self.written.use("toolu_1", "Bash", PUSH)
        self.run_hook({T0 + 0.01: [{"type": "dropped"}]}, payload=self.payload(cwd=str(deep)))
        self.assertEqual(self.registration()["session"]["project"], "colloid-swarm")
        self.assertEqual(self.registration()["session"]["cwd"], str(deep))

    def test_a_satellites_own_harness_names_the_satellite(self):
        satellite = self.folder / "claims-org" / "claims-app"
        (satellite / ".agents").mkdir(parents=True)
        (satellite / ".agents" / "AGENTS.md").write_text("# harness\n")
        self.run_hook({T0 + 0.01: [{"type": "dropped"}]}, payload=self.payload(cwd=str(satellite)))
        self.assertEqual(self.registration()["session"]["project"], "claims-app")

    def test_the_question_tool_and_plan_approval_are_left_to_the_mac(self):
        for tool in ("AskUserQuestion", "ExitPlanMode"):
            self.run_hook(payload=self.payload(tool_name=tool))
            self.assertEqual((self.connected_to, self.out, self.err), (None, [], []))


class Registration(Hook):
    def test_the_line_carries_the_session_the_process_the_tool_and_the_deadline(self):
        self.written.use("toolu_1", "Bash", PUSH)
        self.run_hook({T0 + 0.01: [{"type": "dropped"}]})
        self.assertEqual(self.connected_to, str(self.folder / ".local/state/phone-link/hook.sock"))
        self.assertEqual(self.registration(), {
            "type": "permission",
            "session": {"id": "5e55", "agent": None, "pid": 4242, "start": START, "config_dir": str(self.config),
                        "cwd": str(self.repo), "project": "colloid-swarm", "account": "guest",
                        "transcript": self.path},
            "turn": "prompt-1", "tool": "Bash", "preview": "git push origin main", "calls": ["toolu_1"],
            "file": self.path, "deadline": T0 + 3540,
        })

    def test_acceptance_13_the_line_holds_the_masked_preview_and_never_the_raw_input(self):
        token = "ghp_" + "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8"
        aws = "AKIA" + "Q7ZP2M4XK9TB6WDN"
        command = {"command": f"deploy --gh {token} --aws {aws} --note {'n' * 700}", "description": "Deploy"}
        self.written.use("toolu_1", "Bash", command)
        self.run_hook({T0 + 0.01: [{"type": "dropped"}]}, payload=self.payload(tool_input=command))
        sent = json.dumps(self.service.sent)
        self.assertNotIn(token, sent)
        self.assertNotIn(aws, sent)
        self.assertNotIn("Deploy", sent)  # the input's other fields stay here too
        line = self.registration()
        # Acceptance 15: both credentials masked, 600 characters kept, the rest counted.
        self.assertTrue(line["preview"].startswith("deploy --gh [REDACTED] --aws [REDACTED] --note nnn"))
        self.assertTrue(line["preview"].endswith("[… 147 more characters]"), line["preview"][-40:])
        self.assertEqual(line["calls"], ["toolu_1"])

    def test_the_state_folder_and_the_account_come_from_the_environment(self):
        self.run_hook({T0 + 0.01: [{"type": "dropped"}]},
                      environ={"PHONE_LINK_STATE": "/tmp/pl-state", "CLAUDE_PROFILE": "family"})
        self.assertEqual(self.connected_to, "/tmp/pl-state/hook.sock")
        self.assertEqual(self.registration()["session"]["account"], "family")

    def test_of_equal_calls_the_latest_is_offered_first_and_settled_ones_not_at_all(self):
        self.written.use("toolu_1", "Bash", PUSH)
        self.written.allowed_at_mac("toolu_1")
        self.written.use("toolu_2", "Bash", PUSH)
        self.written.use("toolu_3", "Bash", PUSH)
        self.run_hook({T0 + 0.01: [{"type": "dropped"}]})
        self.assertEqual(self.registration()["calls"], ["toolu_3", "toolu_2"])

    def test_a_subagents_call_is_sought_in_the_agents_own_file(self):
        agent_file = transcript.call_file(self.path, "a1b2")
        os.makedirs(os.path.dirname(agent_file))
        Transcript(agent_file, agent="a1b2", clock=lambda: self.now).use("toolu_a", "Bash", PUSH)
        self.written.use("toolu_main", "Bash", PUSH)  # the same call text in the session's file is another call
        self.run_hook({T0 + 0.01: [{"type": "dropped"}]}, payload=self.payload(agent_id="a1b2", agent_type="general-purpose"))
        line = self.registration()
        self.assertEqual((line["calls"], line["file"], line["session"]["agent"]), (["toolu_a"], agent_file, "a1b2"))


class Decisions(Hook):
    def decision(self):
        self.assertEqual(len(self.out), 1)
        return json.loads(self.out[0])

    def test_acceptance_2_yes_prints_allow_and_the_hook_ends_at_once(self):
        self.written.use("toolu_1", "Bash", PUSH)
        ended = self.run_hook({T0 + 0.01: [{"type": "registered", "id": "m-abcde", "call": "toolu_1"}],
                               T0 + 7.3: [{"type": "decision", "behavior": "allow"}]})
        self.assertEqual(self.decision(), {"hookSpecificOutput": {
            "hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}})
        self.assertEqual((ended, self.err), (7.3, []))

    def test_acceptance_3_no_prints_deny_with_the_reason_as_its_message(self):
        self.written.use("toolu_1", "Bash", PUSH)
        self.run_hook({T0 + 0.01: [{"type": "registered", "id": "m-abcde", "call": "toolu_1"}],
                       T0 + 3: [{"type": "decision", "behavior": "deny", "message": "too risky"}]})
        self.assertEqual(self.decision(), {"hookSpecificOutput": {
            "hookEventName": "PermissionRequest", "decision": {"behavior": "deny", "message": "too risky"}}})

    def test_a_line_that_is_no_decision_prints_nothing(self):
        self.written.use("toolu_1", "Bash", PUSH)
        self.run_hook({T0 + 0.01: [{"type": "registered", "id": "m-abcde", "call": "toolu_1"}],
                       T0 + 1: [{"type": "decision", "behavior": "ask"}, {"type": "something-new"}],
                       T0 + 2.5: [{"type": "dropped"}]})
        self.assertEqual(self.out, [])


class SettledAtTheMac(Hook):
    def test_acceptance_4_an_allow_at_the_mac_ends_the_hook_within_one_poll_with_no_decision(self):
        self.written.use("toolu_1", "Bash", PUSH)
        self.at[T0 + 9] = lambda: self.written.allowed_at_mac("toolu_1")
        ended = self.run_hook()
        self.assertEqual(self.out, [])
        self.assertEqual(self.service.of("settled"), [(10.0, {"type": "settled", "by": "mac", "decision": "allow"})])
        self.assertLessEqual(ended - 9, 2)  # no hook is left 5 s after the call's result

    def test_a_rejection_the_hook_lived_to_see_is_settled_as_a_deny(self):
        self.written.use("toolu_1", "Bash", PUSH)
        self.at[T0 + 3] = lambda: self.written.rejected_at_mac("toolu_1")
        self.run_hook()
        self.assertEqual(self.service.of("settled"), [(4.0, {"type": "settled", "by": "mac", "decision": "deny"})])

    def test_a_result_that_was_there_before_the_first_poll_is_seen_at_it(self):
        self.written.use("toolu_1", "Bash", PUSH)
        self.at[T0 + 0.5] = lambda: self.written.allowed_at_mac("toolu_1")
        self.assertEqual(self.run_hook(), 2.0)

    def test_another_calls_result_does_not_end_this_hook(self):
        self.written.use("toolu_1", "Bash", PUSH)
        self.written.use("toolu_2", "Bash", {"command": "ls", "description": "List"})
        self.at[T0 + 3] = lambda: self.written.allowed_at_mac("toolu_2")
        self.at[T0 + 19] = lambda: self.written.allowed_at_mac("toolu_1")
        self.assertEqual(self.run_hook(), 20.0)  # the poll after its own result, not the one at 4 s
        self.assertEqual(len(self.service.of("settled")), 1)

    def test_acceptance_7_a_subagents_call_settles_from_the_agents_file_within_one_poll(self):
        agent_file = transcript.call_file(self.path, "a1b2")
        os.makedirs(os.path.dirname(agent_file))
        in_agent = Transcript(agent_file, agent="a1b2", clock=lambda: self.now)
        in_agent.use("toolu_a", "Bash", PUSH)
        self.at[T0 + 2.5] = lambda: self.written.other_rows(4)  # the session's file moves on: not a result
        self.at[T0 + 5] = lambda: in_agent.allowed_at_mac("toolu_a")
        ended = self.run_hook({T0 + 0.01: [{"type": "registered", "id": "m-abcde", "call": "toolu_a"}]},
                              payload=self.payload(agent_id="a1b2"))
        self.assertEqual(self.service.of("settled"), [(6.0, {"type": "settled", "by": "mac", "decision": "allow"})])
        self.assertLessEqual(ended - 5, 5)


class Ends(Hook):
    def test_acceptance_8_the_hook_ends_60_s_before_claude_codes_timeout_with_no_decision(self):
        self.written.use("toolu_1", "Bash", PUSH)
        ended = self.run_hook()
        self.assertEqual((ended, client.HOOK_TIMEOUT), (3540.0, 3600))
        self.assertEqual(self.service.of("expired"), [(3540.0, {"type": "expired"})])
        self.assertEqual(self.out, [])

    def test_acceptance_9_the_service_going_away_ends_the_hook_with_no_decision_and_one_line(self):
        self.written.use("toolu_1", "Bash", PUSH)
        self.effects({})
        script = {T0 + 0.01: [{"type": "registered", "id": "m-abcde", "call": "toolu_1"}]}
        effects = self.effects(script)
        self.service.ends_at = T0 + 12.5
        client.run(self.payload(), {"HOME": str(self.folder)}, effects, self.out.append, self.err.append)
        self.assertEqual((self.out, round(self.now - T0, 1)), ([], 12.5))
        self.assertEqual(self.err, ["phone-link went away; the permission prompt goes on without the phone"])
        self.assertTrue(self.service.closed)

    def test_acceptance_10_the_sessions_process_ending_ends_the_hook_within_one_poll(self):
        self.written.use("toolu_1", "Bash", PUSH)
        self.at[T0 + 6.5] = lambda: self.running.pop(4242)
        ended = self.run_hook()
        self.assertEqual((ended, self.out), (8.0, []))
        self.assertEqual(self.service.of("gone"), [(8.0, {"type": "gone"})])

    def test_a_pid_that_went_to_another_process_ends_the_hook_at_the_30_s_check(self):
        self.written.use("toolu_1", "Bash", PUSH)
        self.at[T0 + 11] = lambda: self.running.update({4242: "Wed Nov 18 09:59:59 2026"})
        self.assertEqual(self.run_hook(), 30.0)
        self.assertEqual(len(self.service.of("gone")), 1)

    def test_acceptance_11_a_failed_send_ends_the_hook_at_once(self):
        self.written.use("toolu_1", "Bash", PUSH)
        ended = self.run_hook({T0 + 0.01: [{"type": "registered", "id": "m-abcde", "call": "toolu_1"}],
                               T0 + 0.3: [{"type": "failed", "reason": "the alert could not be sent"}]})
        self.assertEqual((ended, self.out), (0.3, []))
        self.assertEqual(self.err, ["phone-link: the alert could not be sent; the permission prompt goes on "
                                    "without the phone"])

    def test_a_refusal_is_one_stderr_line(self):
        self.run_hook({T0 + 0.01: [{"type": "refused", "reason": "50 sessions are registered"}]})
        self.assertEqual(self.err, ["phone-link refused this prompt (50 sessions are registered); it goes on "
                                    "without the phone"])
        self.assertEqual(self.out, [])

    def test_a_service_that_never_answers_the_registration_is_left_after_5_s(self):
        ended = self.run_hook({})
        self.assertEqual(ended, 6.0)  # seen at the poll after 5 s
        self.assertEqual(len(self.err), 1)

    def test_with_no_claude_process_above_it_the_hook_registers_nothing(self):
        self.running.clear()
        self.run_hook()
        self.assertEqual(self.service.sent, [])
        self.assertEqual(len(self.err), 1)


class Unbound(Hook):
    def test_a_call_that_shows_later_is_offered_then(self):
        self.at[T0 + 3] = lambda: self.written.use("toolu_late", "Bash", PUSH)
        self.run_hook({T0 + 0.01: [{"type": "registered", "id": "m-abcde", "call": None}],
                       T0 + 4.1: [{"type": "bound", "call": "toolu_late"}],
                       T0 + 9: [{"type": "decision", "behavior": "allow"}]})
        self.assertEqual(self.registration()["calls"], [])
        self.assertEqual(self.service.of("bind"), [(4.0, {"type": "bind", "calls": ["toolu_late"]})])
        self.assertEqual(self.service.of("deadline"), [])
        self.assertEqual(len(self.out), 1)

    def test_a_call_bound_late_is_watched_from_then_on(self):
        self.at[T0 + 3] = lambda: self.written.use("toolu_late", "Bash", PUSH)
        self.at[T0 + 7] = lambda: self.written.allowed_at_mac("toolu_late")
        ended = self.run_hook({T0 + 0.01: [{"type": "registered", "id": "m-abcde", "call": None}],
                               T0 + 4.1: [{"type": "bound", "call": "toolu_late"}]})
        self.assertEqual(ended, 8.0)
        self.assertEqual(len(self.service.of("settled")), 1)

    def test_a_call_not_found_within_10_s_waits_10_minutes_at_most_and_expires(self):
        ended = self.run_hook({T0 + 0.01: [{"type": "registered", "id": "m-abcde", "call": None}]})
        self.assertEqual(self.service.of("deadline"), [(10.0, {"type": "deadline", "deadline": T0 + 600})])
        self.assertEqual(ended, 600.0)
        self.assertEqual(self.service.of("expired"), [(600.0, {"type": "expired"})])
        self.assertEqual(self.out, [])

    def test_an_unbound_hook_still_prints_the_phones_decision(self):
        self.run_hook({T0 + 0.01: [{"type": "registered", "id": "m-abcde", "call": None}],
                       T0 + 40: [{"type": "decision", "behavior": "deny", "message": "no"}]})
        self.assertEqual(json.loads(self.out[0])["hookSpecificOutput"]["decision"],
                         {"behavior": "deny", "message": "no"})


class Previews(unittest.TestCase):
    def test_a_bash_call_shows_its_command(self):
        self.assertEqual(client.preview("Bash", PUSH), "git push origin main")

    def test_an_edit_shows_its_path_and_the_changed_lines(self):
        edit = {"file_path": "/repo/a.py", "old_string": "x = 1\ny = 2\nz = 3", "new_string": "x = 1\ny = 20\nz = 3",
                "replace_all": False}
        self.assertEqual(client.preview("Edit", edit), "/repo/a.py\n- y = 2\n+ y = 20")

    def test_an_edit_whose_removed_line_starts_with_dashes_shows_it(self):
        edit = {"file_path": "/repo/q.sql", "old_string": "-- old note\nselect 1", "new_string": "select 1"}
        self.assertEqual(client.preview("Edit", edit), "/repo/q.sql\n- -- old note")

    def test_a_write_shows_its_path_and_its_first_10_lines(self):
        content = "\n".join(f"line {n}" for n in range(1, 31))
        self.assertEqual(client.preview("Write", {"file_path": "/repo/new.txt", "content": content}),
                         "/repo/new.txt\n" + "\n".join(f"+ line {n}" for n in range(1, 11)))

    def test_a_notebook_edit_shows_its_path_and_its_new_source(self):
        cell = {"notebook_path": "/repo/n.ipynb", "new_source": "import os\nprint(1)", "cell_id": "c1"}
        self.assertEqual(client.preview("NotebookEdit", cell), "/repo/n.ipynb\n+ import os\n+ print(1)")

    def test_any_other_tool_shows_its_input_as_json(self):
        fetch = {"url": "https://example.com/é", "prompt": "summarise"}
        self.assertEqual(client.preview("WebFetch", fetch), '{"url": "https://example.com/é", "prompt": "summarise"}')
        self.assertEqual(client.preview("Bash", {"cmd": 1}), '{"cmd": 1}')
        self.assertEqual(client.preview("Edit", {"file_path": "/a"}), '{"file_path": "/a"}')


class Entry(unittest.TestCase):
    """`main`, which must end with 0 whatever happens inside: a hook that fails must not block the call."""

    def ended(self, stdin, run=None, argv=("client.py", "permission")):
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, "stdin", io.StringIO(stdin)), contextlib.redirect_stdout(stdout), \
                contextlib.redirect_stderr(stderr), mock.patch.object(client, "run", run or client.run):
            code = client.main(list(argv))
        return code, stdout.getvalue(), stderr.getvalue()

    def test_a_decision_goes_to_stdout_as_one_line(self):
        def decided(payload, environ, effects, out, err):
            out(client.decision_output("allow", None))
            return 0
        code, stdout, stderr = self.ended('{"tool_name": "Bash"}', decided)
        self.assertEqual((code, stderr), (0, ""))
        self.assertEqual(stdout, '{"hookSpecificOutput": {"hookEventName": "PermissionRequest", '
                                 '"decision": {"behavior": "allow"}}}\n')

    def test_a_failure_inside_the_hook_is_reported_on_stderr_and_ends_with_0(self):
        def broken(*_arguments):
            raise RuntimeError("boom")
        code, stdout, stderr = self.ended("{}", broken)
        self.assertEqual((code, stdout), (0, ""))
        self.assertIn("phone-permission: failed, and the permission prompt goes on without the phone", stderr)
        self.assertIn("RuntimeError: boom", stderr)

    def test_a_payload_that_is_not_a_json_object_is_reported_and_ends_with_0(self):
        for stdin in ("", "not json", "[1, 2]"):
            code, stdout, stderr = self.ended(stdin)
            self.assertEqual((code, stdout), (0, ""), stdin)
            self.assertIn("phone-permission: failed", stderr)

    def test_the_operators_ctrl_c_ends_the_hook_with_0_and_no_word(self):
        def interrupted(*_arguments):
            raise KeyboardInterrupt
        self.assertEqual(self.ended("{}", interrupted), (0, "", ""))

    def test_another_argument_is_a_usage_line_and_0(self):
        code, stdout, stderr = self.ended("{}", argv=("client.py", "gate"))
        self.assertEqual((code, stdout), (0, ""))
        self.assertIn("usage: client.py permission", stderr)


class RealSocket(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.folder)
        self.repo = self.folder / "repo"
        (self.repo / ".agents").mkdir(parents=True)
        (self.repo / ".agents" / "AGENTS.md").write_text("# harness\n")
        self.path = str(self.folder / "c" / "projects" / "p" / "5e55.jsonl")
        os.makedirs(os.path.dirname(self.path))
        Transcript(self.path).use("toolu_1", "Bash", PUSH)
        self.state = self.folder / "s"
        self.out, self.err = [], []

    class Real(client.Effects):
        @staticmethod
        def claude():
            return os.getpid(), sessions.process_starts([os.getpid()])[os.getpid()]

    def payload(self):
        return {"session_id": "5e55", "transcript_path": self.path, "cwd": str(self.repo), "prompt_id": "p1",
                "tool_name": "Bash", "tool_input": PUSH}

    def run_hook(self):
        environ = {"HOME": str(self.folder), "PHONE_LINK_STATE": str(self.state), "CLAUDE_PROFILE": "work"}
        return client.run(self.payload(), environ, self.Real, self.out.append, self.err.append)

    def test_acceptance_14_with_phone_link_stopped_the_hook_ends_at_once_with_one_stderr_line(self):
        before = time.time()
        self.assertEqual(self.run_hook(), 0)
        self.assertLess(time.time() - before, 1.0)
        self.assertEqual(self.out, [])
        self.assertEqual(len(self.err), 1)
        self.assertIn("phone-link does not answer", self.err[0])

    def test_a_stale_socket_file_that_nothing_answers_is_the_same(self):
        log.prepare(self.state)
        dead = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        dead.bind(str(self.state / "hook.sock"))
        dead.close()
        before = time.time()
        self.assertEqual(self.run_hook(), 0)
        self.assertLess(time.time() - before, 1.0)
        self.assertEqual((self.out, len(self.err)), ([], 1))

    def test_through_the_real_service_loop_yes_from_the_phone_is_printed_as_allow(self):
        log.prepare(self.state)
        log.prepare(self.state / "signal")
        answered = []

        def answer(text):
            found = fake.ALERT.match(text)
            if found:
                answered.append(found.group(1))
                daemon.phone_says(f"yes {found.group(1)}")
        daemon = fake.FakeSignalCli(str(self.state / "signal" / "socket"), on_send=answer)
        self.addCleanup(daemon.stop)
        errors = log.Errors(self.state / "errors.log")
        link = phone_link.Link(
            events=log.Events(self.state / "events.jsonl", errors),
            messages=log.Messages(self.state / "messages.jsonl", errors), errors=errors,
            sessions=sessions.Sessions(self.state / "sessions.json"),
            signal=phone_link.Signal(signal_client.Connection(str(self.state / "signal" / "socket")), errors),
            zone=timezone(timedelta(0), "UTC"))
        link.start()
        listener = phone_link.listen(self.state / "hook.sock")
        stop = threading.Event()
        thread = threading.Thread(target=phone_link.serve, args=(link, listener, errors, stop.is_set), daemon=True)
        thread.start()

        def shut():
            stop.set()
            # A connection wakes the loop, which then sees the stop.
            with socket.socket(socket.AF_UNIX) as wake:
                wake.connect(str(self.state / "hook.sock"))
                thread.join(5)
            listener.close()
            link.signal.connection.close("test over")
        self.addCleanup(shut)
        limit = time.time() + 5
        while link.signal.account is None and time.time() < limit:
            time.sleep(0.02)

        self.assertEqual(self.run_hook(), 0)
        self.assertEqual(self.err, [])
        self.assertEqual(json.loads(self.out[0]), {"hookSpecificOutput": {
            "hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}})
        self.assertEqual(len(answered), 1)
        self.assertEqual(link.events.events[answered[0]]["session"]["project"], "repo")


if __name__ == "__main__":
    unittest.main()
