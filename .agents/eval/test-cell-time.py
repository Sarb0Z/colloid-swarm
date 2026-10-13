#!/usr/bin/env python3
"""Run cell-time.py over a hand-written store and check each figure.

The store, the repository and the state file live in one temporary directory;
HOME points there too, so nothing real is read.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "cell-time.py")
GIT_VARS = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX")
DAY = "2026-10-01T"
GATE_TEXT = ("Blocked: sleeping 90 s holds the session and learns nothing. "
             "Pick the wait that ends with the event")
READ_ONLY_PYTHON = "python3 - <<'EOF'\nfrom pathlib import Path\nprint(Path('src.py').read_text())\nEOF"
VERIFY = "bash .agents/test-all.sh"


def clean_env(**extra):
    env = {k: v for k, v in os.environ.items() if k not in GIT_VARS}
    env.update(extra)
    return env


def git(cwd, *args):
    subprocess.run(["git", "-C", cwd, *args], check=True, capture_output=True, env=clean_env())


def stamp(clock, day=DAY):
    return f"{day}{clock}.000Z"


def use(clock, cwd, tool_id, name, **tool_input):
    block = {"type": "tool_use", "id": tool_id, "name": name, "input": tool_input}
    return {"timestamp": stamp(clock), "type": "assistant", "cwd": cwd, "message": {"content": [block]}}


def result(clock, cwd, tool_id, text="ok", error=False):
    block = {"type": "tool_result", "tool_use_id": tool_id, "content": text, "is_error": error}
    return {"timestamp": stamp(clock), "type": "user", "cwd": cwd, "message": {"content": [block]}}


def say(clock, cwd, role, text, day=DAY):
    block = {"type": "text", "text": text}
    return {"timestamp": stamp(clock, day), "type": role, "cwd": cwd, "message": {"content": [block]}}


def lane_records(repo):
    """One lane cell: every figure appears once, written out of time order."""
    records = [
        say("10:00:00", repo, "user", "WORKLOOP WORKER BRIEF — run1/laneA do the work"),
        use("10:00:10", repo, "b1", "Bash", command="sed -i 's/a/b/' src.py"),
        result("10:00:12", repo, "b1"),
        use("10:00:20", repo, "b2", "Bash", command="sed -i 's/a/b/' /tmp/cell-time-untracked.txt"),
        result("10:00:21", repo, "b2"),
        use("10:00:30", repo, "b3", "Bash", command=READ_ONLY_PYTHON),
        result("10:00:31", repo, "b3"),
        use("10:00:40", repo, "b4", "Bash", command="sleep 60"),
        result("10:01:40", repo, "b4"),
        use("10:01:50", repo, "b5", "Bash", command="sleep 90"),
        result("10:01:51", repo, "b5", GATE_TEXT, error=True),
        use("10:02:00", repo, "b6", "Bash", command=f"cd {repo} && {VERIFY} 2>&1 | tail -3"),
        result("10:03:00", repo, "b6"),
        use("10:03:10", repo, "e1", "Edit", file_path="src.py"),
        result("10:03:11", repo, "e1", "<tool_use_error>File has not been read yet.</tool_use_error>", error=True),
        say("10:03:20", repo, "assistant", "done"),
        say("10:34:20", repo, "user", "next"),
        use("10:35:00", repo, "b7", "Bash", command="cat src.py"),
        result("11:06:00", repo, "b7"),
        say("11:37:00", repo, "assistant", "finished"),
    ]
    return shuffled(records)


def shuffled(records):
    """Odd positions first, then even: a fixed disorder the script must sort out."""
    return records[1::2] + records[0::2]


def write_cell(store, project, session, agent, records, description, extra_lines=()):
    folder = os.path.join(store, project, session, "subagents")
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, f"agent-{agent}.jsonl"), "w", encoding="utf-8") as handle:
        for line in extra_lines:
            handle.write(line + "\n")
        for record in records:
            handle.write(json.dumps(record) + "\n")
    with open(os.path.join(folder, f"agent-{agent}.meta.json"), "w", encoding="utf-8") as handle:
        json.dump({"agentType": "general-purpose", "model": "sonnet", "description": description}, handle)


class CellTime(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = os.path.realpath(tempfile.mkdtemp(prefix="cell-time-test-"))
        cls.repo = os.path.join(cls.root, "repo")
        cls.elsewhere = os.path.join(cls.root, "elsewhere")
        cls.store = os.path.join(cls.root, "store")
        for folder in (cls.repo, cls.elsewhere):
            os.makedirs(folder)
        git(cls.repo, "init", "-q")
        with open(os.path.join(cls.repo, "src.py"), "w", encoding="utf-8") as handle:
            handle.write("a = 1\n")
        git(cls.repo, "add", "src.py")

        write_cell(cls.store, "proj-one", "sess1", "lane", lane_records(cls.repo), "lane cell")
        write_cell(cls.store, "proj-two", "sess1", "lane", lane_records(cls.repo), "lane cell copy")
        gone = os.path.join(cls.root, "removed-worktree")
        write_cell(cls.store, "proj-one", "sess1", "gone",
                   [say("09:00:00", gone, "user", "hello"), say("09:00:05", gone, "assistant", "hi")],
                   "folder removed", extra_lines=["{not json"])
        write_cell(cls.store, "proj-one", "sess2", "other",
                   [say("09:00:00", cls.elsewhere, "user", "WORKLOOP WORKER BRIEF — ghost/x go"),
                    say("09:00:09", cls.elsewhere, "assistant", "ok")], "other repository")
        write_cell(cls.store, "proj-one", "sess3", "old",
                   [say("09:00:00", cls.repo, "user", "old", day="2026-08-01T")], "outside the window")
        write_cell(cls.store, "skipme-local", "sess4", "skipped",
                   [say("09:00:00", cls.repo, "user", "x"), say("09:00:05", cls.repo, "assistant", "y")], "skipped")
        cls.state = os.path.join(cls.root, "state.json")
        with open(cls.state, "w", encoding="utf-8") as handle:
            json.dump({"runs": {"run1": {"verify": VERIFY}}}, handle)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.root)

    def run_script(self, *extra, expect=0):
        command = [sys.executable, SCRIPT, "--store", self.store, "--state", self.state,
                   "--since", "2026-09-30", "--until", "2026-10-02", "--skip", "skipme-*", *extra]
        done = subprocess.run(command, capture_output=True, text=True, env=clean_env(HOME=self.root))
        self.assertEqual(done.returncode, expect, done.stderr)
        return done

    def report(self, *extra):
        return json.loads(self.run_script("--json", *extra).stdout)

    def test_counts_and_problems(self):
        r = self.report()
        self.assertEqual(r["cells"], 3)
        self.assertEqual(r["duplicate_transcripts"], 1)
        self.assertEqual(r["unreadable_lines"], 1)
        self.assertEqual(r["unattributed"], 0)

    def test_time_gaps_by_kind(self):
        t = self.report()["totals"]
        self.assertEqual(t["idle_s"]["lead"], 1860)
        self.assertEqual(t["idle_s"]["tool"], 1860)
        self.assertEqual(t["idle_s"]["model"], 1860)
        self.assertEqual(t["idle_s"]["other"], 0)
        lane = next(c for c in self.report()["cells_detail"] if c["description"] == "lane cell")
        self.assertEqual(lane["span_s"], 5820)
        self.assertEqual(sum(lane["active_s"].values()), 240)

    def test_shell_time_by_kind(self):
        shell = self.report()["totals"]["shell"]
        self.assertEqual((shell["test"]["n"], shell["test"]["s"]), (1, 60))
        self.assertEqual((shell["read"]["n"], shell["read"]["s"]), (1, 1860))
        self.assertEqual(shell["other"]["n"], 5)
        self.assertEqual(shell["git"]["n"], 0)

    def test_longest_command_is_labelled_by_delay(self):
        top = self.report()["longest_commands"][0]
        self.assertEqual(top["result_delay_s"], 1860)
        self.assertEqual(top["command"], "cat src.py")
        self.assertEqual(top["cell"], "lane cell")

    def test_blind_waits_and_gate_refusals(self):
        blind = self.report()["totals"]["blind"]
        self.assertEqual(blind, {"ran": 1, "ran_s": 60, "refusals": 1})

    def test_shell_writes_count_only_tracked_files(self):
        writes = self.report()["totals"]["writes"]
        self.assertEqual(writes["shell_source_writes"], 1)
        self.assertEqual(writes["edit_calls"], 1)
        self.assertEqual(writes["edit_failures"], {"File has not been read yet.": 1})

    def test_lane_composed_test_and_unknown_verify(self):
        lanes = {(lane["run"], lane["lane"]): lane for lane in self.report()["lanes"]}
        self.assertEqual(lanes[("run1", "laneA")]["composed_runs"], 1)
        self.assertTrue(lanes[("run1", "laneA")]["verify_known"])
        self.assertFalse(lanes[("ghost", "x")]["verify_known"])
        self.assertIsNone(lanes[("ghost", "x")]["composed_runs"])

    def test_repo_filter_attributes_and_reports_the_rest(self):
        r = self.report("--repo", self.repo)
        self.assertEqual(r["cells"], 1)
        self.assertEqual(r["unattributed"], 1)
        self.assertEqual(r["excluded_other_repositories"], 1)

    def test_window_excludes_records_outside_it(self):
        done = self.run_script("--json", "--since", "2026-08-01", "--until", "2026-08-01")
        self.assertEqual(json.loads(done.stdout)["cells"], 1)

    def test_text_report_names_each_section(self):
        text = self.run_script().stdout
        for heading in ("TIME", "SHELL TIME BY KIND", "LONGEST COMMANDS", "BLIND WAITS", "SOURCE WRITES", "LANES"):
            self.assertIn(heading, text)

    def test_missing_store_fails_with_a_message(self):
        done = subprocess.run([sys.executable, SCRIPT, "--store", os.path.join(self.root, "nope")],
                              capture_output=True, text=True, env=clean_env(HOME=self.root))
        self.assertEqual(done.returncode, 1)
        self.assertIn("is not a directory", done.stderr)


if __name__ == "__main__":
    unittest.main()
