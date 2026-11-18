#!/usr/bin/env python3
"""Tests for phone_link.py: the routing between waiting hooks and the phone.

Seams:
  (a) `Link` with its effects passed in: hook connections that record what
      they are sent, a Signal sender that records texts and ends each send as
      the test says, a clock the test moves, a process table and registry as
      dictionaries, and transcripts written by `fixtures.py` in Claude Code's
      observed rows. One case for each offline line of acceptance 1-19 that
      the service decides. Catches an answer given to the wrong hook, a reply
      sent before the transcript shows the ending, an ending credited to the
      wrong party, an alert lost or sent out of order under the rate limit, an
      old or repeated message acting, and anything kept of another chat.
      Misses socket framing, real time and Claude Code itself.
  (b) `Signal` against `fake_signal_cli.py` over a real Unix socket. Catches a
      lost connection that is never opened again and an outage that fills the
      error log. Misses signal-cli itself.
  (c) `serve` over a real hook socket in a thread. Catches a line split across
      reads, a socket other users can open and a hook left without its end of
      file when the service stops. Misses launchd.
"""

import itertools
import json
import os
import selectors
import shutil
import socket
import stat
import tempfile
import threading
import time
import unittest
from datetime import timedelta, timezone
from pathlib import Path
from unittest import mock

import fake_signal_cli as fake
import log
import phone_link
import sessions
import signal_client
import transcript
from fixtures import Transcript

NOW = log.epoch_of("2026-11-18T13:43:00Z")
START = "Wed Nov 18 08:06:05 2026"
PKT = timezone(timedelta(hours=5), "PKT")
PUSH = {"command": "git push origin main", "description": "Push"}
ME = {"number": fake.NUMBER, "aci": fake.ACI}
IDS = ["m-abcde", "m-fghij", "m-kmnop", "m-qrstu", "m-vwxyz"]


class Conn:
    """A hook's connection as the link sees it."""

    def __init__(self):
        self.lines, self.closed, self.gone = [], False, False

    def send(self, message):
        if self.gone or self.closed:
            return False
        self.lines.append(message)
        return True

    def close(self):
        self.closed = True

    def of(self, kind):
        return [line for line in self.lines if line["type"] == kind]


class Sender:
    """Stands in for `phone_link.Signal`. `ending` is how the next sends end: '' delivers,
    a text fails with it, None leaves the send waiting for `finish`. `stamps[n]` is the Signal
    timestamp of `texts[n]`, which a delivered send reports."""

    def __init__(self):
        self.account, self.texts, self.stamps, self.waiting, self.ending = dict(ME), [], [], [], ""

    def send(self, text, done):
        self.texts.append(text)
        self.stamps.append(1794992400000 + len(self.texts))
        stamp = self.stamps[-1]
        if self.ending is None:
            self.waiting.append(lambda error: done(error, None if error else stamp))
        else:
            done(self.ending, None if self.ending else stamp)

    def finish(self, error=""):
        self.waiting.pop(0)(error)

    def tick(self):
        pass

    def next_due(self):
        return None


class Service(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.folder)
        self.state = self.folder / "state"
        log.prepare(self.state)
        self.now = NOW
        self.running, self.registry = {}, {}
        self.path = str(self.folder / "5e55.jsonl")
        self.written = Transcript(self.path, clock=lambda: self.now)
        self.signal = Sender()
        self.link = self.new_link()

    def new_link(self):
        # The ids of IDS first, then every other five-letter id in turn.
        letters = itertools.chain("abcdefghijkmnopqrstuvwxyz",
                                  itertools.chain.from_iterable(itertools.product(log.ID_LETTERS, repeat=5)))
        errors = log.Errors(self.state / "errors.log", clock=lambda: self.now)
        link = phone_link.Link(
            events=log.Events(self.state / "events.jsonl", errors, choose=lambda _letters: next(letters)),
            messages=log.Messages(self.state / "messages.jsonl", errors), errors=errors,
            sessions=sessions.Sessions(self.state / "sessions.json", errors,
                                       starts=lambda pids: {p: self.running[p] for p in pids if p in self.running},
                                       registry=lambda config, pid: self.registry.get(pid)),
            signal=self.signal, zone=PKT, clock=lambda: self.now)
        link.start()
        return link

    # What a hook's registration line holds, as client.py sends it.
    def registration(self, session="s1", pid=501, tool="Bash", preview="git push origin main", calls=("toolu_1",),
                     agent=None, file=None, name="colloid-swarm-c1", tool_input=None):
        self.running[pid] = START
        self.registry.setdefault(pid, {"sessionId": session, "name": name})
        return {"type": "permission",
                "session": {"id": session, "agent": agent, "pid": pid, "start": START, "config_dir": "/c/.claude",
                            "cwd": "/p/colloid-swarm", "project": "colloid-swarm", "account": "work",
                            "transcript": self.path},
                "turn": "prompt-1", "tool": tool, "preview": preview, "masked": 0, "cut": 0, "calls": list(calls),
                "digest": transcript.call_digest(tool, PUSH if tool_input is None else tool_input),
                "file": file or self.path, "deadline": self.now + 3540}

    def hook(self, **fields):
        conn = Conn()
        self.link.hook_line(conn, self.registration(**fields))
        return conn

    def waiting_hook(self, call="toolu_1", **fields):
        """A hook whose call waits in the transcript."""
        self.written.use(call, "Bash", PUSH)
        return self.hook(calls=(call,), **fields)

    def phone(self, text, age=1.0, device=1, stamp=None, quote=None):
        """`text` typed on the phone `age` seconds ago; with `quote`, as a Signal reply to the
        message of that Signal timestamp."""
        stamp = stamp if stamp is not None else int((self.now - age) * 1000)
        self.link.received(fake.phone_message(text, stamp, device, quote=quote))
        return stamp

    def later(self, seconds):
        self.now += seconds
        self.link.tick()

    def event(self, event_id=IDS[0]):
        return self.link.events.events[event_id]

    def file(self, name):
        path = self.state / name
        return path.read_text() if path.exists() else ""

    def records(self):
        return [json.loads(line) for line in self.file("messages.jsonl").splitlines()]


class Alerts(Service):
    def test_acceptance_1_a_prompt_alerts_at_once_with_project_machine_account_handle_command_and_deadline(self):
        conn = self.waiting_hook()
        self.assertEqual(conn.lines, [{"type": "registered", "id": "m-abcde", "call": "toolu_1"}])
        self.assertEqual(self.signal.texts, ["\n".join([
            "[m-abcde] colloid-swarm · Mac · work · colloid-swarm-c1",
            "Permission: Bash · answer within 59 min (by 19:42 PKT)",
            "git push origin main",
            "Reply: yes, or tell Claude what to do instead",
        ])])

    def test_the_event_holds_the_session_the_turn_the_call_and_the_masked_preview(self):
        self.waiting_hook()
        self.assertEqual(self.event(), {
            "v": 1, "id": "m-abcde", "machine": "mac", "kind": "permission",
            "session": {"id": "s1", "agent": None, "handle": "colloid-swarm-c1", "project": "colloid-swarm",
                        "account": "work", "cwd": "/p/colloid-swarm"},
            "turn": "prompt-1", "row": None, "call": "toolu_1", "created": "2026-11-18T13:43:00Z",
            "deadline": "2026-11-18T14:42:00Z", "text": None,
            "detail": {"tool": "Bash", "preview": "git push origin main", "masked": 0, "cut": 0}, "attachments": [], "source": None,
            "state": "open", "answer": None,
        })

    def test_acceptance_13_a_credential_in_a_preview_does_not_reach_the_log_or_the_phone(self):
        token = "ghp_" + "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8"
        self.hook(preview=f"git push https://{token}@github.com/o/r")
        self.assertNotIn(token, self.file("events.jsonl"))
        self.assertNotIn(token, self.signal.texts[0])
        self.assertEqual(self.event()["detail"]["preview"], "git push https://[REDACTED]@github.com/o/r")

    def test_the_alert_says_how_many_values_the_hook_and_the_link_masked_and_what_was_cut(self):
        token = "ghp_" + "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8"
        line = {**self.registration(preview=f"deploy [REDACTED] {token} nnn[… 40 more characters]"),
                "masked": 1, "cut": 40}
        self.link.hook_line(Conn(), line)
        self.assertEqual((self.event()["detail"]["masked"], self.event()["detail"]["cut"]), (2, 40))
        self.assertEqual(self.signal.texts[0].split("\n")[3], "masked: 2 values · cut: 40 more characters")

    def test_acceptance_19_the_alert_names_the_sessions_account(self):
        for number, account in enumerate(("work", "personal", "family", "guest")):
            line = self.registration(session=f"s{number}", pid=600 + number, name=f"n{number}")
            line["session"]["account"] = account
            self.link.hook_line(Conn(), line)
            self.assertEqual(self.signal.texts[-1].split("\n")[0],
                             f"[{IDS[number]}] colloid-swarm · Mac · {account} · n{number}")

    def test_a_malformed_registration_is_refused_and_reported(self):
        broken_lines = ({"session": None}, {"calls": "toolu_1"}, {"deadline": None}, {"preview": None},
                        {"masked": None}, {"cut": -1}, {"masked": True}, {"digest": None})
        for broken in broken_lines:
            conn = Conn()
            self.link.hook_line(conn, {**self.registration(), **broken})
            self.assertEqual([line["type"] for line in conn.lines], ["refused"], broken)
        self.assertEqual(self.signal.texts, [])
        self.assertEqual(self.file("events.jsonl"), "")
        self.assertEqual(len(self.file("errors.log").splitlines()), len(broken_lines))


class Answers(Service):
    def test_acceptance_2_yes_reaches_the_hook_and_done_waits_for_the_transcript(self):
        conn = self.waiting_hook()
        self.phone("yes m-abcde")
        self.assertEqual(conn.of("decision"), [{"type": "decision", "behavior": "allow"}])
        self.later(1)
        self.assertEqual(self.signal.texts[1:], [])  # the call has not ended: no reply yet
        self.assertEqual(self.event()["state"], "open")

        self.written.allowed_by_hook("toolu_1")
        self.later(1)
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] done"])
        self.assertEqual((self.event()["state"], self.event()["answer"]),
                         ("answered", {"via": "phone", "text": "yes", "at": "2026-11-18T13:43:02Z"}))

    def test_done_goes_out_at_the_hooks_decision_row_of_a_call_that_still_runs(self):
        self.waiting_hook()
        self.phone("yes m-abcde")
        self.written.hook_decided("toolu_1", "allow")  # the command itself may run for an hour
        self.later(1)
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] done"])

    def test_acceptance_3_text_with_an_id_denies_with_the_text_as_typed_without_the_id(self):
        conn = self.waiting_hook()
        self.phone("no m-abcde too risky")
        self.assertEqual(conn.of("decision"), [{"type": "decision", "behavior": "deny", "message": "no too risky"}])
        self.written.denied_by_hook("toolu_1", "no too risky")
        self.later(1)
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] done"])
        self.assertEqual((self.event()["state"], self.event()["answer"]["text"]), ("answered", "no too risky"))

    def test_an_id_alone_tells_claude_where_the_denial_came_from(self):
        conn = self.waiting_hook()
        self.phone("M-abcde.")
        self.assertEqual(conn.of("decision"),
                         [{"type": "decision", "behavior": "deny", "message": "Denied from the operator's phone."}])

    def test_a_bare_no_with_an_id_denies_with_that_word(self):
        conn = self.waiting_hook()
        self.phone("No m-abcde")
        self.assertEqual(conn.of("decision"), [{"type": "decision", "behavior": "deny", "message": "No"}])

    def test_a_second_answer_while_the_first_waits_for_its_ending_is_refused(self):
        conn = self.waiting_hook()
        self.phone("yes m-abcde", age=2)
        self.phone("no m-abcde changed my mind", age=1)
        self.assertEqual(len(conn.of("decision")), 1)
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] refused: already answered"])

    def test_an_answer_after_the_first_ended_is_refused_as_answered(self):
        self.waiting_hook()
        self.phone("yes m-abcde", age=2)
        self.written.allowed_by_hook("toolu_1")
        self.later(1)
        self.phone("yes m-abcde", age=1)
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] done", "[m-abcde] refused: already answered"])

    def test_an_answer_to_no_event_says_so(self):
        self.phone("yes m-zzzzz")
        self.assertEqual(self.signal.texts, ["[m-zzzzz] refused: no event m-zzzzz"])


class AtTheMac(Service):
    def test_acceptance_4_allow_at_the_mac_then_yes_is_refused_as_settled(self):
        conn = self.waiting_hook()
        self.written.allowed_at_mac("toolu_1")
        self.link.hook_line(conn, {"type": "settled", "by": "mac", "decision": "allow"})  # the hook saw the result
        self.assertEqual((self.event()["state"], self.event()["answer"]),
                         ("settled_at_mac", {"via": "mac", "text": "allow", "at": "2026-11-18T13:43:00Z"}))
        self.assertTrue(conn.closed)
        self.phone("yes m-abcde")
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] refused: settled at the Mac"])
        self.assertEqual(conn.of("decision"), [])

    def test_acceptance_4_allow_at_the_mac_then_no_before_the_hook_saw_it_says_the_mac_allowed_it_first(self):
        conn = self.waiting_hook()
        self.written.allowed_at_mac("toolu_1")  # the hook reads its transcript every 2 s and has not yet
        self.phone("no m-abcde stop")
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] refused: the Mac allowed it first"])
        self.assertEqual((self.event()["state"], self.event()["answer"]["via"], self.event()["answer"]["text"]),
                         ("settled_at_mac", "mac", "allow"))
        # The hook's own word about the same result arrives after: it changes nothing.
        self.link.hook_line(conn, {"type": "settled", "by": "mac", "decision": "allow"})
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] refused: the Mac allowed it first"])

    def test_a_no_long_after_the_mac_allowed_the_call_still_says_that_it_ran(self):
        conn = self.waiting_hook()
        self.written.allowed_at_mac("toolu_1")
        self.link.hook_line(conn, {"type": "settled", "by": "mac", "decision": "allow"})
        self.later(600)
        self.phone("no m-abcde")
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] refused: the Mac allowed it first"])

    def test_a_yes_in_the_same_window_is_refused_as_settled_and_not_done(self):
        self.waiting_hook()
        self.written.allowed_at_mac("toolu_1")
        self.phone("yes m-abcde")
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] refused: settled at the Mac"])
        self.assertEqual(self.event()["state"], "settled_at_mac")

    def test_acceptance_5_a_no_or_an_esc_at_the_mac_stops_the_hook_and_yes_is_refused_as_settled(self):
        conn = self.waiting_hook()
        self.written.rejected_at_mac("toolu_1")
        self.link.hook_closed(conn)  # Claude Code stopped the hook: no word from it
        self.assertEqual((self.event()["state"], self.event()["answer"]["via"], self.event()["answer"]["text"]),
                         ("settled_at_mac", "mac", "deny"))
        self.phone("yes m-abcde")
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] refused: settled at the Mac"])

    def test_the_rejection_rows_may_land_a_moment_after_the_hook_is_stopped(self):
        conn = self.waiting_hook()
        self.link.hook_closed(conn)
        self.assertEqual(self.event()["state"], "open")
        self.later(2)
        self.written.rejected_at_mac("toolu_1")
        self.later(0.5)
        self.assertEqual(self.event()["state"], "settled_at_mac")

    def test_a_hook_that_went_away_with_nothing_in_the_transcript_closes_its_event(self):
        conn = self.waiting_hook()
        self.link.hook_closed(conn)
        self.later(2.9)
        self.assertEqual(self.event()["state"], "open")
        self.later(0.2)
        self.assertEqual((self.event()["state"], self.event()["answer"]["text"]), ("closed", "the hook went away"))
        self.phone("yes m-abcde")
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] refused: closed"])

    def test_an_answer_in_that_moment_settles_what_the_transcript_shows_now(self):
        conn = self.waiting_hook()
        self.link.hook_closed(conn)
        self.phone("yes m-abcde")
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] refused: closed"])
        self.assertEqual(self.event()["state"], "closed")

    def test_an_answer_that_cannot_reach_its_hook_is_refused_by_what_the_transcript_shows(self):
        conn = self.waiting_hook()
        self.written.rejected_at_mac("toolu_1")
        conn.gone = True  # the hook died, and the loop has not seen its end of file yet
        self.phone("yes m-abcde")
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] refused: settled at the Mac"])
        self.assertEqual(self.event()["state"], "settled_at_mac")
        self.link.hook_closed(conn)  # the end of file, later: nothing more happens
        self.assertEqual(len(self.signal.texts), 2)

    def test_a_decision_that_another_party_overrode_is_not_reported_as_done(self):
        # Claude Code applies a deny rule after a hook's allow.
        self.waiting_hook()
        self.phone("yes m-abcde")
        self.written.denied_without_dialog("toolu_1")
        self.later(1)
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] refused: settled at the Mac"])


class SeveralHooks(Service):
    def test_acceptance_6_two_waiting_calls_give_two_alerts_and_yes_to_the_second_answers_only_it(self):
        other = str(self.folder / "other.jsonl")
        Transcript(other, clock=lambda: self.now).use("toolu_9", "Bash", PUSH)
        first = self.waiting_hook()
        second = self.hook(session="s2", pid=502, calls=("toolu_9",), file=other, name="claims-app-84")
        self.assertEqual([text.split("\n")[0] for text in self.signal.texts],
                         ["[m-abcde] colloid-swarm · Mac · work · colloid-swarm-c1",
                          "[m-fghij] colloid-swarm · Mac · work · claims-app-84"])
        self.phone("yes m-fghij")
        self.assertEqual((first.of("decision"), len(second.of("decision"))), ([], 1))
        Transcript(other, clock=lambda: self.now).allowed_by_hook("toolu_9")
        self.later(1)
        self.assertEqual(self.signal.texts[2:], ["[m-fghij] done"])
        self.assertEqual((self.event("m-abcde")["state"], self.event("m-fghij")["state"]), ("open", "answered"))

    def test_two_hooks_with_the_same_call_text_take_different_calls(self):
        self.written.use("toolu_1", "Bash", PUSH)
        self.written.use("toolu_2", "Bash", PUSH)
        first = self.hook(calls=("toolu_2", "toolu_1"))
        second = self.hook(calls=("toolu_2", "toolu_1"))
        self.assertEqual((first.of("registered")[0]["call"], second.of("registered")[0]["call"]),
                         ("toolu_2", "toolu_1"))

    def test_a_call_is_free_again_when_its_hooks_event_ended(self):
        first = self.waiting_hook()
        self.link.hook_line(first, {"type": "expired"})
        second = self.hook(calls=("toolu_1",))
        self.assertEqual(second.of("registered")[0]["call"], "toolu_1")

    def test_acceptance_7_a_subagents_call_alerts_and_its_ending_is_read_in_the_agents_own_file(self):
        agent_file = transcript.call_file(self.path, "a1b2")
        os.makedirs(os.path.dirname(agent_file))
        in_agent = Transcript(agent_file, agent="a1b2", clock=lambda: self.now)
        in_agent.use("toolu_a", "Bash", PUSH)
        conn = self.hook(calls=("toolu_a",), agent="a1b2", file=agent_file)
        self.assertEqual(self.event()["session"]["agent"], "a1b2")
        self.assertEqual(len(self.signal.texts), 1)
        self.phone("yes m-abcde")
        in_agent.allowed_by_hook("toolu_a")
        self.written.other_rows(3)  # the session's own file never holds the agent's call
        self.later(1)
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] done"])
        self.assertEqual(len(conn.of("decision")), 1)

    def test_the_21st_waiting_hook_gets_no_alert_and_one_error_line(self):
        hooks = [self.hook(session=f"s{n}", pid=700 + n, calls=(f"toolu_{n}",), name=f"n{n}") for n in range(20)]
        extra = self.hook(session="s20", pid=720, calls=("toolu_20",), name="n20")
        self.assertEqual(extra.lines, [{"type": "refused", "reason": "20 permission hooks already wait"}])
        self.assertEqual(self.file("errors.log"),
                         "2026-11-18T13:43:00Z 20 permission hooks already wait; one more got no alert\n")
        self.assertEqual(len(self.link.events.events), 20)
        self.link.hook_line(hooks[3], {"type": "expired"})
        admitted = self.hook(session="s20", pid=720, calls=("toolu_20",), name="n20")
        self.assertEqual(admitted.of("registered")[0]["call"], "toolu_20")

    def test_a_hook_of_a_51st_session_is_refused(self):
        for number in range(50):
            self.link.hook_line(Conn(), self.registration(session=f"s{number}", pid=1000 + number,
                                                          calls=(f"toolu_{number}",), name=f"n{number}"))
            self.link.hook_line(self.link.waits[next(reversed(self.link.waits))].conn, {"type": "expired"})
        extra = self.hook(session="s50", pid=1050, name="n50")
        self.assertEqual(extra.lines, [{"type": "refused", "reason": "50 sessions are registered"}])


class Endings(Service):
    def test_acceptance_8_a_hook_whose_deadline_passed_leaves_an_expired_event(self):
        conn = self.waiting_hook()
        self.later(3540)
        self.link.hook_line(conn, {"type": "expired"})
        self.assertEqual((self.event()["state"], self.event()["answer"]),
                         ("expired", {"via": "none", "text": "the hook's deadline passed",
                                      "at": "2026-11-18T14:42:00Z"}))
        self.phone("yes m-abcde")
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] refused: expired"])

    def test_acceptance_9_a_restart_closes_the_open_event(self):
        self.waiting_hook()
        self.later(5)
        self.link = self.new_link()  # the service starts again over the same state folder
        self.assertEqual((self.event()["state"], self.event()["answer"]["text"]), ("closed", "phone-link restarted"))
        self.phone("yes m-abcde")
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] refused: closed"])

    def test_acceptance_10_a_session_that_ended_closes_its_event_and_its_hook_is_told(self):
        conn = self.waiting_hook()
        other = self.hook(session="s2", pid=502, calls=("toolu_9",), name="other")
        del self.running[501]
        self.later(30)
        self.assertEqual(conn.lines[-1], {"type": "dropped"})
        self.assertTrue(conn.closed)
        self.assertEqual((self.event()["state"], self.event()["answer"]["text"]), ("closed", "the session ended"))
        self.assertEqual((self.event("m-fghij")["state"], other.closed), ("open", False))

    def test_a_hook_that_saw_its_sessions_process_end_closes_its_event(self):
        conn = self.waiting_hook()
        self.link.hook_line(conn, {"type": "gone"})
        self.assertEqual((self.event()["state"], self.event()["answer"]["text"]),
                         ("closed", "the session's process ended"))

    def test_a_decision_whose_ending_never_shows_closes_at_the_deadline_and_says_so(self):
        self.waiting_hook()
        self.phone("yes m-abcde")
        self.later(3538)
        self.assertEqual(self.event()["state"], "open")
        self.later(2)
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] refused: closed"])
        self.assertEqual(self.event()["state"], "closed")

    def test_ps_failing_drops_no_session_and_is_reported(self):
        conn = self.waiting_hook()

        def broken(_pids):
            raise OSError("ps: not found")
        self.link.sessions.starts = broken
        self.later(30)
        self.assertEqual((self.event()["state"], conn.closed), ("open", False))
        self.assertEqual(self.file("errors.log"),
                         "2026-11-18T13:43:30Z the session check failed: OSError: ps: not found\n")


class Unbound(Service):
    def test_a_hook_that_has_not_found_its_call_alerts_at_once_and_binds_later(self):
        conn = self.hook(calls=())
        self.assertEqual(conn.lines, [{"type": "registered", "id": "m-abcde", "call": None}])
        self.assertEqual(len(self.signal.texts), 1)
        self.link.hook_line(conn, {"type": "bind", "calls": ["toolu_7"]})
        self.assertEqual(conn.lines[-1], {"type": "bound", "call": "toolu_7"})
        self.assertEqual(self.event()["call"], "toolu_7")

    def test_a_bind_to_a_call_another_hook_holds_stays_unbound(self):
        self.waiting_hook()
        conn = self.hook(calls=())
        self.link.hook_line(conn, {"type": "bind", "calls": ["toolu_1"]})
        self.assertEqual(conn.lines[-1], {"type": "bound", "call": None})
        self.assertIsNone(self.event("m-fghij")["call"])

    def test_the_shorter_deadline_of_an_unbound_hook_is_recorded(self):
        conn = self.hook(calls=())
        self.link.hook_line(conn, {"type": "deadline", "deadline": self.now + 600})
        self.assertEqual(self.event()["deadline"], "2026-11-18T13:53:00Z")

    def test_an_alert_already_sent_is_followed_by_the_shorter_deadline(self):
        conn = self.hook(calls=())
        self.now += 10
        self.link.hook_line(conn, {"type": "deadline", "deadline": NOW + 600})
        self.assertEqual(len(self.signal.texts), 2)
        self.assertEqual(self.signal.texts[1], "[m-abcde] answer within 10 min (by 18:53 PKT)")

    def test_yes_to_an_unbound_event_is_done_when_a_hook_decision_lands_on_a_call_of_that_tool(self):
        self.written.use("toolu_old", "Bash", PUSH)
        self.written.allowed_by_hook("toolu_old")  # an earlier call's decision is not this one's
        conn = self.hook(calls=())
        self.phone("yes m-abcde")
        self.assertEqual(len(conn.of("decision")), 1)
        self.later(1)
        self.assertEqual(self.signal.texts[1:], [])
        self.written.use("toolu_late", "Bash", PUSH)
        self.written.allowed_by_hook("toolu_late")
        self.later(1)
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] done"])
        self.assertEqual((self.event()["state"], self.event()["call"]), ("answered", "toolu_late"))

    def test_yes_to_an_unbound_event_is_not_done_by_a_hook_decision_on_a_call_of_that_tool_with_other_input(self):
        conn = self.hook(calls=())
        self.phone("yes m-abcde")
        self.assertEqual(len(conn.of("decision")), 1)
        self.written.use("toolu_other", "Bash", {"command": "rm -rf build", "description": "Clean"})
        self.written.allowed_by_hook("toolu_other")
        self.later(1)
        self.assertEqual(self.signal.texts[1:], [])
        self.assertIsNone(self.event()["call"])
        self.later(29)
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] refused: not confirmed — check the Mac"])

    def test_yes_to_an_unbound_event_with_no_such_row_is_not_confirmed(self):
        self.hook(calls=())
        self.phone("yes m-abcde")
        self.later(29)
        self.assertEqual(self.signal.texts[1:], [])
        self.later(1)
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] refused: not confirmed — check the Mac"])
        self.assertEqual(self.event()["state"], "closed")

    def test_an_unbound_hook_stopped_by_an_interrupt_is_settled_at_the_mac(self):
        self.written.interrupt()  # an interrupt before the prompt is not this prompt's
        self.later(5)
        conn = self.hook(calls=())
        self.link.hook_closed(conn)
        self.assertEqual(self.event()["state"], "open")
        self.later(1)
        self.written.interrupt()
        self.later(1)
        self.assertEqual((self.event()["state"], self.event()["answer"]["text"]), ("settled_at_mac", "deny"))


class SendFailures(Service):
    def test_acceptance_11_a_failed_send_ends_the_hook_at_once_and_writes_one_error_line(self):
        self.signal.ending = "signal-cli: Failed to send message: Connection reset"
        conn = self.waiting_hook()
        self.assertEqual(conn.lines[-1], {"type": "failed", "reason": "the alert could not be sent"})
        self.assertTrue(conn.closed)
        self.assertEqual(self.file("errors.log"),
                         "2026-11-18T13:43:00Z the alert of m-abcde was not sent: signal-cli: Failed to send "
                         "message: Connection reset\n")
        self.assertEqual((self.event()["state"], self.event()["answer"]["text"]),
                         ("closed", "the alert could not be sent"))

    def test_a_send_that_fails_after_a_wait_ends_the_hook_then(self):
        self.signal.ending = None
        conn = self.waiting_hook()
        self.assertEqual([line["type"] for line in conn.lines], ["registered"])
        self.later(4)
        self.signal.finish("signal-cli did not answer in time")
        self.assertEqual(conn.lines[-1]["type"], "failed")
        self.assertEqual(self.event()["state"], "closed")

    def test_a_reply_that_cannot_be_sent_is_reported(self):
        self.waiting_hook()
        self.signal.ending = "signal-cli's socket is not connected"
        self.phone("yes m-zzzzz")
        self.assertEqual(self.file("errors.log"),
                         "2026-11-18T13:43:00Z a reply was not sent ([m-zzzzz] refused: no event m-zzzzz): "
                         "signal-cli's socket is not connected\n")


class FromThePhone(Service):
    def test_acceptance_12_a_message_in_another_chat_gets_no_reply_and_leaves_nothing(self):
        self.waiting_hook()
        before = {name: self.file(name) for name in ("events.jsonl", "messages.jsonl", "errors.log")}
        stamp = int(self.now * 1000)
        for params in (fake.other_chat_message("yes m-abcde", stamp), fake.sent_to_other_chat("yes m-abcde", stamp),
                       {"envelope": {"sourceNumber": fake.OTHER, "typingMessage": {"action": "STARTED"}}},
                       None, "not an object"):
            self.link.received(params)
        self.assertEqual(len(self.signal.texts), 1)
        self.assertEqual({name: self.file(name) for name in before}, before)
        self.assertEqual(self.event()["state"], "open")

    def test_acceptance_16_a_message_older_than_15_minutes_is_refused_as_too_old(self):
        conn = self.waiting_hook()
        self.phone("yes m-abcde", age=15 * 60 + 1)
        self.assertEqual(self.signal.texts[1:], ["refused: too old"])
        self.assertEqual(conn.of("decision"), [])

    def test_acceptance_16_the_same_message_received_twice_acts_once(self):
        conn = self.waiting_hook()
        stamp = self.phone("yes m-abcde")
        self.phone("yes m-abcde", stamp=stamp)
        self.assertEqual(len(conn.of("decision")), 1)
        self.assertEqual(len(self.signal.texts), 1)  # the alert alone: no refusal for the repeat
        self.assertEqual([record["result"] for record in self.records()], ["accepted"])

    def test_acceptance_16_a_refused_message_received_twice_is_refused_once(self):
        stamp = self.phone("yes m-zzzzz")
        self.phone("yes m-zzzzz", stamp=stamp)
        self.later(60)
        old = self.phone("help", age=1000)
        self.phone("help", stamp=old)
        self.assertEqual(self.signal.texts, ["[m-zzzzz] refused: no event m-zzzzz", "refused: too old"])

    def test_acceptance_16_a_message_from_signal_desktop_has_no_effect(self):
        conn = self.waiting_hook()
        self.phone("yes m-abcde", device=2)
        self.assertEqual((conn.of("decision"), len(self.signal.texts), self.records()), ([], 1, []))

    def test_the_record_keeps_a_timestamp_and_a_result_and_no_text(self):
        self.waiting_hook()
        stamp = self.phone("no m-abcde the reason stays out of the record")
        self.assertEqual(self.records(), [{"ts": stamp, "at": "2026-11-18T13:43:00Z", "result": "accepted"}])

    def test_acceptance_9_help_lists_how_an_answer_is_read(self):
        conn = self.waiting_hook()
        self.phone("Help")
        self.assertEqual(self.signal.texts[1:], [phone_link.grammar.HELP])
        self.assertEqual(conn.of("decision"), [])

    def test_acceptance_8_text_with_no_alert_sent_since_the_start_is_refused_as_no_open_alert(self):
        self.phone("approve it")
        self.assertEqual(self.signal.texts, ["refused: no open alert"])
        self.assertEqual(self.records()[0]["result"], "refused: no open alert")

    def test_acceptance_8_an_alert_sent_before_a_restart_is_not_the_newest_alert(self):
        self.waiting_hook()
        self.later(5)
        self.link = self.new_link()
        self.phone("yes")
        self.assertEqual(self.signal.texts[1:], ["refused: no open alert"])

    def test_acceptance_9_reserved_words_alone_and_a_request_to_a_handle_are_not_built_yet(self):
        conn = self.waiting_hook()
        for age, text in enumerate(("status", "Mute", "@colloid-swarm-c1 run the suite", "unmute", "start")):
            self.phone(text, age=age + 1)
        self.assertEqual(self.signal.texts[1:], ["refused: not built yet"])
        self.later(60)
        self.assertEqual(self.signal.texts[2:], ["refused: 4 more messages (4 not built yet)"])
        self.assertEqual([record["result"] for record in self.records()], ["refused: not built yet"] * 5)
        self.assertEqual(conn.of("decision"), [])

    def test_acceptance_10_no_message_is_refused_as_not_understood(self):
        conn = self.waiting_hook()
        self.phone("mute colloid-swarm-c1 please")
        self.assertEqual(conn.of("decision"),
                         [{"type": "decision", "behavior": "deny", "message": "mute colloid-swarm-c1 please"}])
        self.assertNotIn("not understood", "".join(self.signal.texts))

    def test_a_backlog_of_20_old_messages_after_a_restart_gets_one_reply_a_minute(self):
        for number in range(20):
            self.phone(f"yes m-{'abcdefghijkmnopqrstu'[number]}bcde", age=3600 + number)
        self.assertEqual(self.signal.texts, ["refused: too old"])
        self.later(59)
        self.assertEqual(len(self.signal.texts), 1)
        self.later(1)
        self.assertEqual(self.signal.texts[1:], ["refused: 19 more messages (19 too old)"])
        self.later(60)
        self.assertEqual(len(self.signal.texts), 2)
        self.assertEqual([record["result"] for record in self.records()], ["refused: too old"] * 20)

    def test_refusals_fold_in_order_and_answers_to_open_events_are_not_held(self):
        conn = self.waiting_hook()
        self.phone("yes m-abcde", age=1000)
        self.phone("mute", age=10)
        self.phone("yes m-abcde", age=9)
        self.phone("status", age=8)
        self.phone("yes m-zzzzz", age=7)
        self.phone("whatever", age=6, quote=1794992399999)
        self.assertEqual(len(conn.of("decision")), 1)
        self.assertEqual(self.signal.texts[1:], ["refused: too old"])
        self.later(1)
        self.written.allowed_by_hook("toolu_1")
        self.later(1)
        self.assertEqual(self.signal.texts[2:], ["[m-abcde] done"])
        self.later(58)
        self.assertEqual(self.signal.texts[3:], [
            "refused: 4 more messages (2 not built yet, 1 no such event, 1 not a reply to an open alert)"])

    def test_an_answer_to_another_machines_event_gets_no_reply_from_this_one(self):
        stamp = self.phone("yes s-tbnaw")
        self.assertEqual(self.signal.texts, [])
        self.assertEqual(self.records(), [{"ts": stamp, "at": "2026-11-18T13:43:00Z",
                                           "result": "ignored: another machine's event"}])

    def test_nothing_acts_before_the_account_is_known(self):
        conn = self.waiting_hook()
        self.signal.account = None
        self.phone("yes m-abcde")
        self.assertEqual((conn.of("decision"), self.records()), ([], []))


class SignalReplies(Service):
    """A message sent as a Signal reply quotes the Signal timestamp of the message it answers."""

    def reply(self, text, to, age=1.0, device=1, stamp=None):
        """`text` typed as a reply to the link's message `to`: an index into what it sent, or
        a timestamp it never sent."""
        quote = self.signal.stamps[to] if to < len(self.signal.stamps) else to
        stamp = stamp if stamp is not None else int((self.now - age) * 1000)
        self.link.received(fake.phone_message(text, stamp, device, quote=quote))
        return stamp

    def test_acceptance_1_yes_as_a_reply_to_the_alert_allows_that_hook(self):
        conn = self.waiting_hook()
        self.reply("Yes", to=0)
        self.assertEqual(conn.of("decision"), [{"type": "decision", "behavior": "allow"}])
        self.written.allowed_by_hook("toolu_1")
        self.later(1)
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] done"])
        self.assertEqual((self.event()["state"], self.event()["answer"]["text"]), ("answered", "Yes"))
        self.assertEqual(self.records()[0]["result"], "accepted")

    def test_acceptance_2_text_as_a_reply_denies_with_the_text_as_typed(self):
        conn = self.waiting_hook()
        self.reply("no too risky", to=0)
        self.assertEqual(conn.of("decision"), [{"type": "decision", "behavior": "deny", "message": "no too risky"}])
        self.written.denied_by_hook("toolu_1", "no too risky")
        self.later(1)
        self.assertEqual((self.event()["state"], self.event()["answer"]["text"]), ("answered", "no too risky"))

    def test_a_bare_no_as_a_reply_denies_with_that_word(self):
        conn = self.waiting_hook()
        self.reply("No.", to=0)
        self.assertEqual(conn.of("decision"), [{"type": "decision", "behavior": "deny", "message": "No."}])

    def test_acceptance_4_a_reply_binds_to_the_quoted_alert_when_a_newer_alert_exists(self):
        first = self.waiting_hook()
        second = self.waiting_hook(call="toolu_2", session="s2", pid=502, name="other")
        self.later(10)
        self.reply("no, push to main instead", to=0)
        self.assertEqual(first.of("decision"),
                         [{"type": "decision", "behavior": "deny", "message": "no, push to main instead"}])
        self.assertEqual(second.of("decision"), [])

    def test_a_reply_answers_the_hook_of_the_alert_it_quotes_and_no_other(self):
        first = self.waiting_hook()
        second = self.waiting_hook(call="toolu_2", session="s2", pid=502, name="other")
        self.reply("yes", to=1)
        self.assertEqual((first.of("decision"), second.of("decision")),
                         ([], [{"type": "decision", "behavior": "allow"}]))

    def test_two_sends_that_signal_cli_gives_one_timestamp_answer_neither_event(self):
        given = self.signal.send

        def one_timestamp(text, done):
            given(text, lambda error, stamp: done(error, None if error else 1794992400000))
        self.signal.send = one_timestamp
        first = self.waiting_hook()
        second = self.waiting_hook(call="toolu_2", session="s2", pid=502, name="other")
        self.link.received(fake.phone_message("yes", int((self.now - 1) * 1000), quote=1794992400000))
        self.assertEqual((first.of("decision"), second.of("decision")), ([], []))
        self.assertEqual(self.signal.texts[2:], ["refused: not a reply to an open alert"])
        self.assertEqual(self.file("errors.log"),
                         "2026-11-18T13:43:00Z signal-cli gave timestamp 1794992400000 to messages "
                         "about m-abcde and m-fghij; a reply to it answers neither\n")

    def test_acceptance_3_a_reply_to_the_deadline_line_answers_the_same_event(self):
        conn = self.hook(calls=())
        self.now += 10
        self.link.hook_line(conn, {"type": "deadline", "deadline": NOW + 600})
        self.assertEqual(self.signal.texts[1], "[m-abcde] answer within 10 min (by 18:53 PKT)")
        self.reply("yes", to=1)
        self.assertEqual(conn.of("decision"), [{"type": "decision", "behavior": "allow"}])

    def test_acceptance_3_a_reply_to_a_later_reply_about_the_event_binds_the_same_event(self):
        self.waiting_hook()
        self.phone("yes m-abcde", age=3)
        self.written.allowed_by_hook("toolu_1")
        self.later(1)
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] done"])
        self.reply("no", to=1)
        self.assertEqual(self.signal.texts[2:], ["[m-abcde] refused: already answered"])
        self.reply("no", to=2, age=0.5)
        self.assertEqual(self.signal.texts[3:], ["[m-abcde] refused: already answered"])

    def test_acceptance_4_a_reply_quoting_a_message_the_link_did_not_send_about_an_event_is_refused(self):
        conn = self.waiting_hook()
        self.reply("yes", to=1794992399999)
        self.assertEqual(self.signal.texts[1:], ["refused: not a reply to an open alert"])
        self.assertEqual((conn.of("decision"), self.event()["state"]), ([], "open"))
        self.assertEqual(self.records()[0]["result"], "refused: not a reply to an open alert")
        self.later(60)
        self.reply("yes", to=1)  # the refusal itself is about no event
        self.assertEqual(self.signal.texts[2:], ["refused: not a reply to an open alert"])
        self.assertEqual(conn.of("decision"), [])

    def test_acceptance_4_a_reply_whose_quote_names_no_message_is_refused(self):
        conn = self.waiting_hook()
        params = fake.phone_message("yes", int((self.now - 1) * 1000), quote=1)
        params["envelope"]["syncMessage"]["sentMessage"]["quote"]["id"] = str(self.signal.stamps[0])
        self.link.received(params)
        self.assertEqual(self.signal.texts[1:], ["refused: not a reply to an open alert"])
        self.assertEqual(conn.of("decision"), [])

    def test_acceptance_5_a_reply_naming_another_events_id_is_refused_and_answers_neither(self):
        first = self.waiting_hook()
        second = self.waiting_hook(call="toolu_2", session="s2", pid=502, name="other")
        self.reply("yes m-fghij", to=0)
        self.assertEqual(self.signal.texts[2:], ["[m-abcde] refused: the reply quotes m-abcde"])
        self.assertEqual((first.of("decision"), second.of("decision")), ([], []))
        self.assertEqual(self.records()[0]["result"], "refused: the reply quotes m-abcde")
        self.reply("no m-zzzzz stop", to=0, age=0.5)
        self.assertEqual(self.signal.texts[3:], ["[m-abcde] refused: the reply quotes m-abcde"])

    def test_a_reply_naming_the_quoted_events_own_id_answers_it(self):
        conn = self.waiting_hook()
        self.reply("no m-abcde not now", to=0)
        self.assertEqual(conn.of("decision"), [{"type": "decision", "behavior": "deny", "message": "no not now"}])

    def test_acceptance_7_after_a_restart_a_reply_to_an_old_alert_is_refused(self):
        self.waiting_hook()
        self.later(5)
        self.link = self.new_link()
        self.reply("yes", to=0)
        self.assertEqual(self.signal.texts[1:], ["refused: not a reply to an open alert"])
        self.assertEqual(self.event()["state"], "closed")

    def test_acceptance_8_a_reply_from_signal_desktop_or_in_another_chat_has_no_effect(self):
        conn = self.waiting_hook()
        self.reply("yes", to=0, device=2)
        other = fake.sent_to_other_chat("yes", int(self.now * 1000))
        other["envelope"]["syncMessage"]["sentMessage"]["quote"] = {"id": self.signal.stamps[0]}
        self.link.received(other)
        self.assertEqual((conn.of("decision"), len(self.signal.texts), self.records()), ([], 1, []))

    def test_acceptance_8_a_reply_older_than_15_minutes_is_refused_as_too_old(self):
        conn = self.waiting_hook()
        self.later(15 * 60 + 2)
        self.reply("yes", to=0, age=15 * 60 + 1)
        self.assertEqual(self.signal.texts[1:], ["refused: too old"])
        self.assertEqual(conn.of("decision"), [])

    def test_acceptance_8_the_same_reply_received_twice_acts_once(self):
        conn = self.waiting_hook()
        stamp = self.reply("yes", to=0)
        self.reply("yes", to=0, stamp=stamp)
        self.assertEqual(len(conn.of("decision")), 1)
        self.assertEqual(len(self.signal.texts), 1)
        self.assertEqual([record["result"] for record in self.records()], ["accepted"])

    def test_a_reply_that_is_not_yes_or_no_is_read_as_a_message(self):
        self.waiting_hook()
        self.reply("help", to=0)
        self.assertEqual(self.signal.texts[1], phone_link.grammar.HELP)

    def test_a_failed_alert_binds_no_reply(self):
        self.signal.ending = "signal-cli: Failed to send message: Connection reset"
        self.waiting_hook()
        self.signal.ending = ""
        self.reply("yes", to=0)
        self.assertEqual(self.signal.texts[1:], ["refused: not a reply to an open alert"])


class NewestAlert(Service):
    """A message that quotes nothing and names no id answers the newest alert the link sent."""

    def second_hook(self):
        return self.waiting_hook(call="toolu_2", session="s2", pid=502, name="other")

    def test_acceptance_1_an_approval_typed_plainly_allows_the_newest_alert(self):
        texts = ("ok", "Yes", "\N{THUMBS UP SIGN}",
                 "yes.\N{ZERO WIDTH SPACE}\N{VARIATION SELECTOR-16}\N{POP DIRECTIONAL ISOLATE}")
        for number, text in enumerate(texts):
            conn = self.waiting_hook(call=f"toolu_{number}", session=f"s{number}", pid=700 + number, name=f"n{number}")
            self.later(6)
            self.phone(text, age=0)
            self.assertEqual(conn.of("decision"), [{"type": "decision", "behavior": "allow"}], repr(text))

    def test_acceptance_2_a_plain_no_with_words_denies_with_exactly_that_message(self):
        conn = self.waiting_hook()
        self.phone("no, push to main instead")
        self.assertEqual(conn.of("decision"),
                         [{"type": "decision", "behavior": "deny", "message": "no, push to main instead"}])

    def test_acceptance_3_an_approval_with_more_words_denies_with_the_text(self):
        conn = self.waiting_hook()
        self.phone("yes but skip the tests")
        self.assertEqual(conn.of("decision"),
                         [{"type": "decision", "behavior": "deny", "message": "yes but skip the tests"}])
        self.written.denied_by_hook("toolu_1", "yes but skip the tests")
        self.later(1)
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] done"])

    def test_the_newest_alert_is_answered_and_not_an_older_open_one(self):
        first = self.waiting_hook()
        self.later(10)
        second = self.second_hook()
        self.later(6)
        self.phone("ok", age=0)
        self.assertEqual((first.of("decision"), second.of("decision")),
                         ([], [{"type": "decision", "behavior": "allow"}]))

    def test_acceptance_5_a_message_naming_an_id_binds_that_event_even_just_after_a_newer_alert(self):
        first = self.waiting_hook()
        self.later(10)
        second = self.second_hook()
        self.phone("M-abcde ok", age=0)
        self.assertEqual((first.of("decision"), second.of("decision")),
                         ([{"type": "decision", "behavior": "allow"}], []))

    def test_the_id_in_brackets_as_the_alert_writes_it_names_that_event_and_not_the_newest(self):
        first = self.waiting_hook()
        self.later(10)
        second = self.second_hook()
        self.later(6)
        self.phone("[m-abcde] no", age=0)
        self.assertEqual((first.of("decision"), second.of("decision")),
                         ([{"type": "decision", "behavior": "deny", "message": "no"}], []))

    def test_a_word_shaped_like_an_id_of_no_machine_answers_the_newest_alert_and_is_not_dropped(self):
        conn = self.waiting_hook()
        self.later(1)
        self.phone("a t-shirt, not a push", age=0)
        self.assertEqual(conn.of("decision"),
                         [{"type": "decision", "behavior": "deny", "message": "a t-shirt, not a push"}])

    def test_an_id_with_nothing_but_punctuation_after_it_denies_with_where_the_denial_came_from(self):
        conn = self.waiting_hook()
        self.phone("m-abcde !!", age=0)
        self.assertEqual(conn.of("decision"),
                         [{"type": "decision", "behavior": "deny", "message": "Denied from the operator's phone."}])

    def test_help_or_a_reserved_word_with_trailing_punctuation_answers_no_event(self):
        conn = self.waiting_hook()
        self.later(6)
        self.phone("Help.", age=1)
        self.phone("status?", age=0)
        self.assertEqual(self.signal.texts[1:], [phone_link.grammar.HELP, "refused: not built yet"])
        self.assertEqual(conn.of("decision"), [])

    def test_acceptance_6_when_the_newest_alert_is_settled_its_state_answers_and_no_older_event(self):
        first = self.waiting_hook()
        self.later(10)
        second = self.second_hook()
        self.written.allowed_at_mac("toolu_2")
        self.link.hook_line(second, {"type": "settled", "by": "mac", "decision": "allow"})
        self.later(6)
        self.phone("yes", age=0)
        self.assertEqual(self.signal.texts[2:], ["[m-fghij] refused: settled at the Mac"])
        self.phone("stop, that was the wrong one", age=-0.5)
        self.assertEqual(self.signal.texts[3:], ["[m-fghij] refused: the Mac allowed it first"])
        self.assertEqual(first.of("decision"), [])
        self.assertEqual(self.event(IDS[0])["state"], "open")

    def test_acceptance_6_when_the_newest_alert_was_answered_a_second_plain_answer_is_refused(self):
        conn = self.waiting_hook()
        self.phone("yes", age=2)
        self.phone("no wait", age=1)
        self.assertEqual(len(conn.of("decision")), 1)
        self.assertEqual(self.signal.texts[1:], ["[m-abcde] refused: already answered"])

    def test_acceptance_7_plain_text_within_5_s_of_a_newer_alert_while_an_older_is_open_is_refused(self):
        first = self.waiting_hook()
        self.later(10)
        second = self.second_hook()
        self.later(4)
        stamp = self.phone("yes", age=0)
        self.assertEqual(self.signal.texts[2:],
                         ["refused: a newer alert just arrived — reply to the one you mean"])
        self.assertEqual((first.of("decision"), second.of("decision")), ([], []))
        self.assertEqual(self.records(), [{"ts": stamp, "at": log.iso(self.now),
                                           "result": "refused: a newer alert just arrived — reply to the one you mean"}])
        # Typed before the newer alert reached the phone: the same refusal.
        self.phone("no", age=6)
        self.assertEqual(self.signal.texts[3:],
                         ["refused: a newer alert just arrived — reply to the one you mean"])

    def test_acceptance_7_five_seconds_after_the_newer_alert_plain_text_answers_it(self):
        first = self.waiting_hook()
        self.later(10)
        second = self.second_hook()
        self.later(5)
        self.phone("yes", age=0)
        self.assertEqual((first.of("decision"), second.of("decision")),
                         ([], [{"type": "decision", "behavior": "allow"}]))

    def test_acceptance_7_with_no_older_event_open_a_fresh_alert_takes_a_plain_answer_at_once(self):
        conn = self.waiting_hook()
        self.phone("yes", age=0)
        self.assertEqual(conn.of("decision"), [{"type": "decision", "behavior": "allow"}])

    def test_the_newest_alert_is_the_one_signal_cli_delivered_last(self):
        first = self.waiting_hook()
        self.signal.ending = "signal-cli: Failed to send message: Connection reset"
        self.later(10)
        self.second_hook()
        self.signal.ending = ""
        self.later(6)
        self.phone("yes", age=0)
        self.assertEqual(first.of("decision"), [{"type": "decision", "behavior": "allow"}])


class RateLimit(Service):
    def hooks(self, count):
        return [self.hook(session=f"s{n}", pid=800 + n, calls=(f"toolu_{n}",), name=f"n{n}") for n in range(count)]

    def firsts(self):
        return [text.split("\n")[0].split(" ")[-1] if text.startswith("[") else text for text in self.signal.texts]

    def test_acceptance_18_ten_alerts_six_at_once_and_four_in_the_next_minute_in_order(self):
        self.hooks(10)
        self.assertEqual(self.firsts(), ["n0", "n1", "n2", "n3", "n4", "n5"])
        self.later(59)
        self.assertEqual(len(self.signal.texts), 6)
        self.later(1)
        self.assertEqual(self.firsts(), [f"n{n}" for n in range(10)])
        self.assertEqual(len(self.link.queue), 0)

    def test_the_window_slides_with_each_alert_sent(self):
        self.hooks(3)
        self.later(30)
        late = [self.hook(session=f"t{n}", pid=900 + n, calls=(f"toolu_t{n}",), name=f"t{n}") for n in range(5)]
        self.assertEqual(self.firsts(), ["n0", "n1", "n2", "t0", "t1", "t2"])
        self.later(30)  # the first three are a minute old: three places are free
        self.assertEqual(self.firsts()[6:], ["t3", "t4"])
        self.assertEqual(len(late), 5)

    def test_a_minute_passes_between_the_notices_while_more_than_six_wait(self):
        self.hooks(14)  # six go out; the 13th hook makes seven wait, which is the first time more than six do
        self.assertEqual(self.firsts()[6:], ["7 more waiting"])
        self.later(30)
        self.assertEqual(len(self.signal.texts), 7)
        self.later(30)  # six more go out, two wait: no notice for two
        self.assertEqual(self.firsts()[7:], [f"n{n}" for n in range(6, 12)])
        self.later(60)
        self.assertEqual(self.firsts()[13:], ["n12", "n13"])
        self.assertEqual(sorted(event["state"] for event in self.link.events.events.values()), ["open"] * 14)

    def test_the_notice_repeats_each_minute_with_the_count_of_that_minute(self):
        self.hooks(20)  # six go out, fourteen wait
        self.later(60)  # six more go out, eight wait
        self.later(60)  # six more go out, two wait
        self.assertEqual([text for text in self.firsts() if text.endswith("waiting")],
                         ["7 more waiting", "8 more waiting"])

    def test_a_shorter_deadline_before_the_alert_went_out_goes_into_the_alert_and_no_line_of_its_own(self):
        conns = self.hooks(7)
        waiting = conns[6].of("registered")[0]["id"]
        self.now += 10
        self.link.hook_line(conns[6], {"type": "deadline", "deadline": NOW + 600})
        self.assertEqual(len(self.signal.texts), 6)
        self.later(50)
        self.assertEqual(len(self.signal.texts), 7)
        self.assertTrue(self.signal.texts[6].startswith(f"[{waiting}] "), self.signal.texts[6])
        self.assertIn("answer within 9 min (by 18:53 PKT)", self.signal.texts[6])

    def test_the_alert_minutes_are_those_left_when_it_goes_out(self):
        self.hooks(7)
        self.later(60)
        self.assertIn("answer within 58 min (by 19:42 PKT)", self.signal.texts[-1])

    def test_an_event_settled_while_its_alert_waited_sends_none(self):
        hooks = self.hooks(8)
        self.link.hook_line(hooks[6], {"type": "settled", "by": "mac", "decision": "allow"})
        self.later(60)
        self.assertEqual(self.firsts()[6:], ["n7"])

    def test_the_service_asks_to_be_woken_when_the_next_alert_may_go(self):
        self.hooks(7)
        self.assertEqual(self.link.next_due(), NOW + 30)  # the session check comes first
        self.later(30)
        self.assertEqual(self.link.next_due(), NOW + 60)


class SignalAdapter(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.folder)
        self.path = str(self.folder / "s")
        self.now = 100.0
        self.errors = log.Errors(self.folder / "errors.log", clock=lambda: NOW)
        self.signal = phone_link.Signal(signal_client.Connection(self.path, clock=lambda: self.now), self.errors,
                                        clock=lambda: self.now)
        self.ends, self.stamps = [], []

    def end(self, error, stamp):
        self.ends.append(error)
        self.stamps.append(stamp)

    def daemon(self, send="ok"):
        daemon = fake.FakeSignalCli(self.path, send=send)
        self.addCleanup(daemon.stop)
        return daemon

    def pump(self, until, seconds=5.0):
        limit = time.time() + seconds
        while not until() and time.time() < limit:
            if self.signal.connection.socket is not None:
                self.signal.connection.readable()
            time.sleep(0.01)
        self.assertTrue(until())

    def test_it_learns_the_account_from_the_daemon_and_sends_to_note_to_self(self):
        daemon = self.daemon()
        self.addCleanup(self.signal.connection.close, "test over")
        self.signal.tick()
        self.pump(lambda: self.signal.account)
        self.assertEqual(self.signal.account, ME)
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o600)
        self.signal.send("[m-abcde] done", self.end)
        self.pump(lambda: self.ends)
        self.assertEqual((self.ends, self.stamps), ([""], daemon.stamps))
        self.assertEqual(daemon.requests[-1]["params"], {"account": fake.NUMBER, "message": "[m-abcde] done",
                                                         "noteToSelf": True, "notifySelf": True})

    def test_a_send_before_the_daemon_answered_fails_at_once(self):
        self.signal.send("x", self.end)
        self.assertEqual((self.ends, self.stamps),
                         (["signal-cli's account is not known: its socket has not answered"], [None]))

    def test_an_outage_is_one_error_line_and_the_connection_comes_back(self):
        for _ in range(4):
            self.signal.tick()
            self.now += 5
        lines = (self.folder / "errors.log").read_text().splitlines()
        self.assertEqual(len(lines), 1)
        self.assertIn("does not answer", lines[0])
        self.daemon()
        self.addCleanup(self.signal.connection.close, "test over")
        self.signal.tick()
        self.pump(lambda: self.signal.account)
        self.assertEqual(self.signal.account, ME)

    def test_it_tries_again_only_every_five_seconds(self):
        self.signal.tick()
        self.assertEqual(self.signal.next_due(), 105.0)
        self.daemon()
        self.addCleanup(self.signal.connection.close, "test over")
        self.now = 104.9
        self.signal.tick()
        self.assertIsNone(self.signal.connection.socket)
        self.now = 105.0
        self.signal.tick()
        self.assertIsNotNone(self.signal.connection.socket)
        self.pump(lambda: self.signal.account)

    def test_a_send_the_daemon_never_answers_fails_after_four_seconds(self):
        self.daemon(send="silent")
        self.addCleanup(self.signal.connection.close, "test over")
        self.signal.tick()
        self.pump(lambda: self.signal.account)
        self.signal.send("x", self.end)
        self.now += 3.9
        self.signal.tick()
        self.assertEqual(self.ends, [])
        self.now += 0.1
        self.signal.tick()
        self.assertEqual(self.ends, ["signal-cli did not answer in time"])

    def test_a_recipient_failure_is_a_failed_send(self):
        self.daemon(send="failure")
        self.addCleanup(self.signal.connection.close, "test over")
        self.signal.tick()
        self.pump(lambda: self.signal.account)
        self.signal.send("x", self.end)
        self.pump(lambda: self.ends)
        self.assertEqual((self.ends, self.stamps), (["signal-cli reports NETWORK_FAILURE"], [None]))

    def test_a_delivered_send_with_no_timestamp_is_reported_and_binds_nothing(self):
        self.daemon(send="untimed")
        self.addCleanup(self.signal.connection.close, "test over")
        self.signal.tick()
        self.pump(lambda: self.signal.account)
        self.signal.send("[m-abcde] done", self.end)
        self.pump(lambda: self.ends)
        self.assertEqual((self.ends, self.stamps), ([""], [None]))
        self.assertIn("signal-cli sent a message ([m-abcde] done) and gave no timestamp",
                      (self.folder / "errors.log").read_text())


class Loop(unittest.TestCase):
    """`serve` in a thread, over a real hook socket and the fake daemon."""

    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.folder)
        self.state = self.folder / "state"
        log.prepare(self.state)
        log.prepare(self.state / "signal")
        self.daemon = fake.FakeSignalCli(str(self.state / "signal" / "socket"))
        self.addCleanup(self.daemon.stop)
        self.path = str(self.folder / "5e55.jsonl")
        Transcript(self.path).use("toolu_1", "Bash", PUSH)
        self.stop = threading.Event()
        errors = log.Errors(self.state / "errors.log")
        self.link = phone_link.Link(
            events=log.Events(self.state / "events.jsonl", errors),
            messages=log.Messages(self.state / "messages.jsonl", errors), errors=errors,
            sessions=sessions.Sessions(self.state / "sessions.json", errors, starts=lambda pids: {p: START for p in pids},
                                       registry=lambda config, pid: None),
            signal=phone_link.Signal(signal_client.Connection(str(self.state / "signal" / "socket")), errors),
            zone=PKT)
        self.link.start()
        before = os.umask(0o177)
        self.listener = phone_link.listen(self.state / "hook.sock")
        os.umask(before)
        self.thread = threading.Thread(target=phone_link.serve,
                                       args=(self.link, self.listener, errors, self.stop.is_set), daemon=True)
        self.thread.start()
        self.addCleanup(self.shut)

    def shut(self):
        self.stop.set()
        # A connection wakes the loop, which then sees the stop.
        with socket.socket(socket.AF_UNIX) as wake:
            if (self.state / "hook.sock").exists() and self.thread.is_alive():
                wake.connect(str(self.state / "hook.sock"))
            self.thread.join(5)
        self.listener.close()
        self.link.signal.connection.close("test over")

    def hook(self):
        link = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        link.settimeout(5)
        link.connect(str(self.state / "hook.sock"))
        self.addCleanup(link.close)
        return link, link.makefile("r")

    def registration(self):
        return {"type": "permission",
                "session": {"id": "s1", "agent": None, "pid": 501, "start": START, "config_dir": "/c/.claude",
                            "cwd": "/p/colloid-swarm", "project": "colloid-swarm", "account": "work",
                            "transcript": self.path},
                "turn": "prompt-1", "tool": "Bash", "preview": "git push origin main", "masked": 0, "cut": 0, "calls": ["toolu_1"],
                "digest": transcript.call_digest("Bash", PUSH),
                "file": self.path, "deadline": time.time() + 3540}

    def wait_for(self, condition, seconds=5.0):
        limit = time.time() + seconds
        while not condition() and time.time() < limit:
            time.sleep(0.02)
        self.assertTrue(condition())

    def test_a_registration_split_across_two_writes_is_one_line_and_yes_comes_back_as_a_decision(self):
        self.wait_for(lambda: self.link.signal.account)
        link, lines = self.hook()
        data = json.dumps(self.registration()).encode() + b"\n"
        link.sendall(data[:40])
        time.sleep(0.1)
        link.sendall(data[40:])
        registered = json.loads(lines.readline())
        self.assertEqual((registered["type"], registered["call"]), ("registered", "toolu_1"))
        self.wait_for(lambda: self.daemon.sent())
        self.assertIn(f"[{registered['id']}] colloid-swarm · Mac · work · colloid-swarm", self.daemon.sent()[0])
        self.daemon.phone_says(f"yes {registered['id']}")
        self.assertEqual(json.loads(lines.readline()), {"type": "decision", "behavior": "allow"})
        Transcript(self.path).allowed_by_hook("toolu_1")
        link.close()
        self.wait_for(lambda: len(self.daemon.sent()) == 2, seconds=8)
        self.assertEqual(self.daemon.sent()[1], f"[{registered['id']}] done")

    def test_a_hook_that_takes_signal_clis_closed_descriptor_in_one_batch_is_served(self):
        # serve() in this thread, for one batch in which signal-cli's socket ends first and a
        # hook connects next: the hook's socket then gets the descriptor signal-cli's had.
        self.shut()
        signal = self.link.signal
        # A new connection, read until its listAccounts answer is in, so nothing else is unread.
        signal.retry_at, signal.account = 0.0, None
        signal.tick()
        self.wait_for(lambda: signal.connection.readable() is not None and signal.account)
        listener = phone_link.listen(self.state / "hook.sock")
        self.addCleanup(listener.close)
        old_fd = signal.connection.fileno()
        self.daemon.drop_clients()
        # signal-cli's end of file has arrived before the batch starts.
        self.wait_for(lambda: signal.connection.socket.recv(1, socket.MSG_PEEK | socket.MSG_DONTWAIT) == b"")
        link, lines = self.hook()
        link.sendall(json.dumps(self.registration()).encode() + b"\n")
        time.sleep(0.2)

        hook_fds = []

        class SignalFirst(selectors.DefaultSelector):
            def select(self, timeout=None):
                return sorted(super().select(timeout), key=lambda pair: pair[0].data != "signal")

            def register(self, fileobj, events, data=None):
                if isinstance(data, phone_link.HookConn):
                    hook_fds.append(fileobj.fileno())
                return super().register(fileobj, events, data)

        batches = iter((False, False, True))
        errors = log.Errors(self.state / "errors.log")
        with mock.patch.object(phone_link.selectors, "DefaultSelector", SignalFirst):
            phone_link.serve(self.link, listener, errors, lambda: next(batches))
        self.assertIsNone(signal.connection.socket)
        self.assertEqual(json.loads(lines.readline())["type"], "registered")
        self.assertEqual(hook_fds, [old_fd])

    def test_a_read_error_on_a_hooks_connection_writes_one_error_line_and_closes_it(self):
        class Resetting:
            """A hook's socket whose every read fails as a reset connection does."""

            def __init__(self, inner):
                self.inner = inner

            def fileno(self):
                return self.inner.fileno()

            def recv(self, _size):
                raise ConnectionResetError(54, "Connection reset by peer")

            def sendall(self, data):
                self.inner.sendall(data)

            def close(self):
                self.inner.close()

        class ResettingConn(phone_link.HookConn):
            def __init__(self, link_socket):
                super().__init__(Resetting(link_socket))

        errors_log = self.state / "errors.log"
        with mock.patch.object(phone_link, "HookConn", ResettingConn):
            link, lines = self.hook()
            link.sendall(b"{")
            self.assertEqual(lines.readline(), "")
        self.wait_for(lambda: errors_log.exists() and "Connection reset by peer" in errors_log.read_text())
        self.assertEqual(len([line for line in errors_log.read_text().splitlines() if "reset" in line]), 1)

    def test_acceptance_13_the_hook_socket_is_0600(self):
        self.assertEqual(stat.S_IMODE(os.stat(self.state / "hook.sock").st_mode), 0o600)

    def test_acceptance_9_a_hook_gets_its_end_of_file_when_the_service_stops(self):
        self.wait_for(lambda: self.link.signal.account)
        link, lines = self.hook()
        link.sendall(json.dumps(self.registration()).encode() + b"\n")
        self.assertEqual(json.loads(lines.readline())["type"], "registered")
        self.shut()
        self.assertEqual(lines.readline(), "")

    def test_a_line_that_is_not_json_closes_that_connection_and_is_reported(self):
        link, lines = self.hook()
        link.sendall(b"not json\n")
        self.assertEqual(lines.readline(), "")
        self.assertIn("a hook sent a line that is not JSON", (self.state / "errors.log").read_text())

    def test_a_second_service_on_the_same_socket_refuses_to_start(self):
        with self.assertRaises(SystemExit) as refusal:
            phone_link.listen(self.state / "hook.sock")
        self.assertIn("another phone-link already answers", str(refusal.exception))

    def test_a_dead_services_socket_file_is_taken_over(self):
        stale = self.state / "stale.sock"
        dead = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        dead.bind(str(stale))
        dead.close()
        listener = phone_link.listen(stale)
        self.addCleanup(listener.close)
        self.assertEqual(stat.S_IMODE(os.stat(stale).st_mode), 0o600)


if __name__ == "__main__":
    unittest.main()
