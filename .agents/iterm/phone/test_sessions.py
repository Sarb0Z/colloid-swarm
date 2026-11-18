#!/usr/bin/env python3
"""Tests for sessions.py: handles, the list's limit, and which sessions still run.

Seams:
  (a) `Sessions` over a scratch sessions.json, with the process table and
      Claude Code's registry given as dictionaries. Catches a handle that
      moves with a rename, two sessions with one handle, a dead session kept,
      a live one dropped, a pid reused by another process taken for the
      session, and a 51st session admitted. Misses `ps` itself.
  (b) `process_starts` and `claude_process` against this test's own process
      and a child started under the name `claude`. Catches a `ps` line read
      wrong on this host. Misses Claude Code's real process tree, which the
      live checkpoint shows.
"""

import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import log
import sessions
from sessions import Sessions

START = "Wed Nov 18 08:06:05 2026"


def hook_session(session_id="5e55-1", pid=1285, start=START, project="colloid-swarm", config="/c/.claude"):
    return {"id": session_id, "pid": pid, "start": start, "config_dir": config, "cwd": f"/p/{project}",
            "project": project, "account": "work", "transcript": f"{config}/projects/x/{session_id}.jsonl"}


class Listed(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.folder)
        self.running = {}  # pid -> start, as ps would give it
        self.registry = {}  # (config dir, pid) -> Claude Code's registry entry
        self.ps_calls = []

    def starts(self, pids):
        self.ps_calls.append(list(pids))
        return {pid: self.running[pid] for pid in pids if pid in self.running}

    def listing(self):
        return Sessions(self.folder / "sessions.json", log.Errors(self.folder / "errors.log"), starts=self.starts,
                        registry=self.entry)

    def entry(self, config, pid):
        found = self.registry.get((config, pid))
        if isinstance(found, Exception):
            raise found
        return found

    def error_lines(self):
        path = self.folder / "errors.log"
        return path.read_text().splitlines() if path.exists() else []

    def run_claude(self, session, name=None):
        self.running[session["pid"]] = session["start"]
        if name is not None:
            self.registry[(session["config_dir"], session["pid"])] = {"sessionId": session["id"], "name": name}
        return session


class Handles(Listed):
    def test_the_handle_is_the_registry_name_made_plain(self):
        listing = self.listing()
        for number, (name, handle) in enumerate((
            ("colloid-swarm-c1", "colloid-swarm-c1"),
            ("Homebrew packages and macOS preferences", "homebrew-packages-and-macos-preferences"),
            # One dash for each of `:`, ` `, ` `, `é`, `_`, ` `, `(`, `)` and `!`; none is merged.
            ("Fix: the é_API (v2)!", "fix--the---api--v2--"),
        )):
            session = self.run_claude(hook_session(f"s{number}", 100 + number), name)
            self.assertEqual(listing.register(session)["handle"], handle)

    def test_a_rename_by_claude_code_does_not_move_the_handle(self):
        listing = self.listing()
        session = self.run_claude(hook_session(), "colloid-swarm-c1")
        self.assertEqual(listing.register(session)["handle"], "colloid-swarm-c1")
        self.registry[("/c/.claude", 1285)]["name"] = "Phone link build"
        self.assertEqual(listing.register(session)["handle"], "colloid-swarm-c1")
        self.assertEqual(self.listing_after_restart().sessions["5e55-1"]["handle"], "colloid-swarm-c1")

    def listing_after_restart(self):
        again = self.listing()
        again.load()
        return again

    def test_a_second_and_a_third_session_of_one_name_get_2_and_3(self):
        listing = self.listing()
        handles = [listing.register(self.run_claude(hook_session(f"s{n}", 200 + n), "Review"))["handle"]
                   for n in range(3)]
        self.assertEqual(handles, ["review", "review-2", "review-3"])
        # The suffix stays when the first one ends, and a later session takes the free name.
        del self.running[200]
        listing.check()
        self.assertEqual(listing.sessions["s1"]["handle"], "review-2")
        self.assertEqual(listing.register(self.run_claude(hook_session("s9", 209), "Review"))["handle"], "review")

    def test_a_suffixed_handle_is_checked_against_every_listed_handle(self):
        listing = self.listing()
        listing.register(self.run_claude(hook_session("a", 301), "review-2"))
        listing.register(self.run_claude(hook_session("b", 302), "review"))
        self.assertEqual(listing.register(self.run_claude(hook_session("c", 303), "review"))["handle"], "review-3")

    def test_a_session_with_no_registry_name_takes_its_project_folders_name(self):
        listing = self.listing()
        absent = self.run_claude(hook_session("h1", 401, project="food-app App"))
        self.assertEqual(listing.register(absent)["handle"], "food-app-core")
        other = self.run_claude(hook_session("h2", 402, project="tax-appeals-app"))
        self.registry[("/c/.claude", 402)] = {"sessionId": "another-session", "name": "Not mine"}
        self.assertEqual(listing.register(other)["handle"], "tax-appeals-app")
        blank = self.run_claude(hook_session("h3", 403, project="ticketing-app"), "   ")
        self.assertEqual(listing.register(blank)["handle"], "ticketing-app")

    def test_the_registry_of_the_sessions_own_account_is_read(self):
        listing = self.listing()
        guest = self.run_claude(hook_session("g1", 501, config="/c/.claude-guest"), "guest-name")
        self.registry[("/c/.claude", 501)] = {"sessionId": "g1", "name": "work-name"}
        self.assertEqual(listing.register(guest)["handle"], "guest-name")


class Limit(Listed):
    def test_the_51st_session_is_refused_and_a_listed_one_still_registers(self):
        listing = self.listing()
        for number in range(50):
            listing.register(self.run_claude(hook_session(f"s{number}", 1000 + number), f"n{number}"))
        with self.assertRaises(sessions.Full):
            listing.register(self.run_claude(hook_session("s50", 1050), "n50"))
        self.assertEqual(len(listing.sessions), 50)
        self.assertEqual(listing.register(hook_session("s7", 1007))["handle"], "n7")
        # One ends: the next new session is admitted.
        del self.running[1003]
        listing.check()
        self.assertEqual(listing.register(self.run_claude(hook_session("s50", 1050), "n50"))["handle"], "n50")


class Liveness(Listed):
    def three(self):
        listing = self.listing()
        for number in range(3):
            listing.register(self.run_claude(hook_session(f"s{number}", 700 + number), f"n{number}"))
        return listing

    def test_live_sessions_stay_and_one_ps_call_serves_the_whole_list(self):
        listing = self.three()
        self.ps_calls.clear()
        self.assertEqual(listing.check(), [])
        self.assertEqual(self.ps_calls, [[700, 701, 702]])
        self.assertEqual(sorted(listing.sessions), ["s0", "s1", "s2"])

    def test_a_session_whose_pid_stopped_is_dropped(self):
        listing = self.three()
        del self.running[701]
        self.assertEqual([session["id"] for session in listing.check()], ["s1"])
        self.assertEqual(sorted(listing.sessions), ["s0", "s2"])

    def test_a_pid_that_went_to_another_process_is_dropped(self):
        listing = self.three()
        self.running[702] = "Wed Nov 18 09:30:00 2026"
        self.assertEqual([session["id"] for session in listing.check()], ["s2"])

    def test_a_registry_file_that_names_another_session_drops_the_session(self):
        listing = self.three()
        self.registry[("/c/.claude", 700)] = {"sessionId": "after-clear", "name": "n0"}
        self.assertEqual([session["id"] for session in listing.check()], ["s0"])

    def test_a_missing_registry_file_drops_nothing(self):
        listing = self.three()
        del self.registry[("/c/.claude", 700)]
        self.assertEqual(listing.check(), [])
        self.assertEqual(self.error_lines(), [])

    def test_a_registry_file_that_does_not_read_drops_nothing_and_writes_one_error_line(self):
        listing = self.three()
        self.registry[("/c/.claude", 700)] = sessions.Unreadable("/c/.claude/sessions/700.json: not JSON")
        self.assertEqual(listing.check(), [])
        self.assertEqual(listing.check(), [])  # the next check, 30 s later, adds no second line
        self.assertEqual(len(self.error_lines()), 1)
        self.assertIn("/c/.claude/sessions/700.json: not JSON", self.error_lines()[0])

    def test_a_registry_file_that_does_not_read_gives_the_project_handle_and_an_error_line(self):
        session = self.run_claude(hook_session(pid=900))
        self.registry[("/c/.claude", 900)] = sessions.Unreadable("/c/.claude/sessions/900.json: not JSON")
        self.assertEqual(self.listing().register(session)["handle"], "colloid-swarm")
        self.assertEqual(len(self.error_lines()), 1)


    def test_ps_failing_drops_nothing_and_the_error_reaches_the_caller(self):
        listing = self.three()

        def broken(_pids):
            raise subprocess.TimeoutExpired("ps", 5)
        listing.starts = broken
        with self.assertRaises(subprocess.TimeoutExpired):
            listing.check()
        self.assertEqual(len(listing.sessions), 3)

    def test_an_empty_list_runs_no_ps(self):
        self.assertEqual(self.listing().check(), [])
        self.assertEqual(self.ps_calls, [])

    def test_a_resumed_session_keeps_its_handle_and_takes_the_new_process(self):
        listing = self.three()
        resumed = self.run_claude(hook_session("s1", 799, start="Wed Nov 18 10:00:00 2026"), "another name")
        self.assertEqual(listing.register(resumed)["handle"], "n1")
        del self.running[701]
        self.assertEqual(listing.check(), [])


class Kept(Listed):
    def test_the_list_survives_a_restart_and_the_dead_are_dropped_at_the_first_check(self):
        listing = self.listing()
        listing.register(self.run_claude(hook_session("s0", 800), "n0"))
        listing.register(self.run_claude(hook_session("s1", 801), "n1"))
        del self.running[800]

        again = self.listing()
        again.load()
        self.assertEqual(sorted(again.sessions), ["s0", "s1"])
        self.assertEqual([session["id"] for session in again.check()], ["s0"])
        self.assertEqual([s["id"] for s in json.loads((self.folder / "sessions.json").read_text())], ["s1"])

    def test_sessions_json_is_0600(self):
        before = os.umask(0o022)
        self.addCleanup(os.umask, before)
        self.listing().register(self.run_claude(hook_session(), "n"))
        self.assertEqual(stat.S_IMODE(os.stat(self.folder / "sessions.json").st_mode), 0o600)

    def test_no_file_is_an_empty_list_and_a_broken_one_is_an_error(self):
        listing = self.listing()
        listing.load()
        self.assertEqual(listing.sessions, {})
        (self.folder / "sessions.json").write_text('[{"id": "s0"}]')
        with self.assertRaises(ValueError):
            listing.load()
        (self.folder / "sessions.json").write_text("{not json")
        with self.assertRaises(ValueError):
            listing.load()


class ReadRegistry(unittest.TestCase):
    def setUp(self):
        self.config = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.config)
        (self.config / "sessions").mkdir()

    def test_an_absent_file_is_no_entry(self):
        self.assertIsNone(sessions.read_registry(str(self.config), 77))

    def test_a_file_that_reads_is_its_entry(self):
        (self.config / "sessions" / "77.json").write_text('{"sessionId": "s", "name": "n"}')
        self.assertEqual(sessions.read_registry(str(self.config), 77), {"sessionId": "s", "name": "n"})

    def test_a_file_that_exists_and_does_not_read_raises_unreadable_naming_it(self):
        for content in ("{not json", "[1, 2]"):
            (self.config / "sessions" / "77.json").write_text(content)
            with self.assertRaises(sessions.Unreadable) as raised:
                sessions.read_registry(str(self.config), 77)
            self.assertIn("77.json", str(raised.exception))


class RealProcesses(unittest.TestCase):
    def test_this_process_has_a_start_and_a_pid_that_does_not_run_has_none(self):
        child = subprocess.Popen([sys.executable, "-c", "pass"])
        child.wait()
        starts = sessions.process_starts([os.getpid(), child.pid])
        self.assertEqual(list(starts), [os.getpid()])
        self.assertRegex(starts[os.getpid()], r"^[A-Z][a-z]{2} [A-Z][a-z]{2} [ \d]\d \d\d:\d\d:\d\d \d{4}$")
        self.assertEqual(sessions.process_starts([os.getpid()]), starts)

    def test_the_claude_process_above_a_hook_is_found_through_a_shell(self):
        folder = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, folder)
        # A process whose command name is `claude`: a shell reached through a link of that name.
        claude = os.path.join(folder, "claude")
        os.symlink("/bin/sh", claude)
        probe = ("import os, sys; sys.path.insert(0, sys.argv[1]); import sessions; "
                 "print(sessions.claude_process(os.getppid()))")
        # claude -> sh (the hook command's shell) -> python (the hook)
        script = f'/bin/sh -c \'"{sys.executable}" -c "{probe}" "{os.path.dirname(sessions.__file__)}"\'; echo "$$"'
        out = subprocess.run([claude, "-c", script], capture_output=True, text=True, timeout=30)
        self.assertEqual(out.stderr, "")
        found, claude_pid = out.stdout.strip().split("\n")
        pid, start = eval(found)  # the tuple the child printed
        self.assertEqual(pid, int(claude_pid))
        self.assertRegex(start, r"^[A-Z][a-z]{2} [A-Z][a-z]{2} [ \d]\d \d\d:\d\d:\d\d \d{4}$")

    def test_a_process_with_no_claude_above_it_has_none(self):
        self.assertIsNone(sessions.claude_process(1))


if __name__ == "__main__":
    unittest.main()
