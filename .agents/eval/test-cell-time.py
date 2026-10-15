#!/usr/bin/env python3
"""Run cell-time.py over a hand-written store and check each figure.

The store, the repository and the state file live in one temporary directory;
HOME points there too, so nothing real is read.
"""

import importlib.util
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
GATE_TEXT = ("PreToolUse:Bash hook error: [/repo/.agents/hooks/wait-gate.sh]: Blocked: sleeping 90 s holds "
             "the session and learns nothing. Pick the wait that ends with the event")
READ_ONLY_PYTHON = "python3 - <<'EOF'\nfrom pathlib import Path\nprint(Path('src.py').read_text())\nEOF"
COPY_TO_TMP = "python3 - <<'EOF'\nfrom pathlib import Path\ntext = Path('src.py').read_text()\nPath('/tmp/out.txt').write_text(text)\nEOF"
WRITE_SRC = "python3 - <<'EOF'\nfrom pathlib import Path\nPath('src.py').write_text('a = 2')\nEOF"
VERIFY = "bash .agents/test-all.sh"
CAPPED_LOOP = "for i in $(seq 110); do grep -q '^exit=' /tmp/claude/x/tasks/abc123.output && break; sleep 5; done"


def clean_env(**extra):
    env = {k: v for k, v in os.environ.items() if k not in GIT_VARS}
    env.update(extra)
    return env


def git(cwd, *args):
    subprocess.run(["git", "-C", cwd, *args], check=True, capture_output=True, env=clean_env())


def stamp(clock, day=DAY):
    return f"{day}{clock}.000Z"


def use(clock, cwd, tool_id, name, mid=None, **tool_input):
    block = {"type": "tool_use", "id": tool_id, "name": name, "input": tool_input}
    message = {"content": [block]}
    if mid:
        message["id"] = mid
    return {"timestamp": stamp(clock), "type": "assistant", "cwd": cwd, "message": message}


def result(clock, cwd, tool_id, text="ok", error=False, outcome=None):
    block = {"type": "tool_result", "tool_use_id": tool_id, "content": text, "is_error": error}
    record = {"timestamp": stamp(clock), "type": "user", "cwd": cwd, "message": {"content": [block]}}
    if outcome is not None:
        record["toolUseResult"] = outcome
    return record


def bash(start, end, cwd, tool_id, command, mid=None, text="ok", error=False, outcome=None, **options):
    return [use(start, cwd, tool_id, "Bash", mid=mid, command=command, **options),
            result(end, cwd, tool_id, text, error, outcome)]


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


def write_cell(store, project, session, agent, records, description, extra_lines=(), meta_text=None, raw=None):
    folder = os.path.join(store, project, session, "subagents")
    os.makedirs(folder, exist_ok=True)
    if raw is not None:
        with open(os.path.join(folder, f"agent-{agent}.jsonl"), "wb") as handle:
            handle.write(raw)
    else:
        with open(os.path.join(folder, f"agent-{agent}.jsonl"), "w", encoding="utf-8") as handle:
            for line in extra_lines:
                handle.write(line + "\n")
            for record in records:
                handle.write(json.dumps(record) + "\n")
    with open(os.path.join(folder, f"agent-{agent}.meta.json"), "w", encoding="utf-8") as handle:
        if meta_text is not None:
            handle.write(meta_text)
        else:
            json.dump({"agentType": "general-purpose", "model": "sonnet", "description": description}, handle)


def write_main(store, project, session, records):
    os.makedirs(os.path.join(store, project), exist_ok=True)
    with open(os.path.join(store, project, f"{session}.jsonl"), "w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record) + "\n")


def heartbeat(cwd):
    """A main-session record every 15 minutes from 09:00 to 12:00, so the store is never silent."""
    clocks = [f"{h:02d}:{m:02d}:00" for h in range(9, 12) for m in (0, 15, 30, 45)] + ["12:00:00"]
    return [say(clock, cwd, "user", "ping") for clock in clocks]


def load_script():
    spec = importlib.util.spec_from_file_location("cell_time", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CLASSIFIER = (
    ("pytest tests/a.py", "test"),
    ("cd x && uv run pytest", "test"),
    ("uv run pytest tests/a.py -k x", "test"),
    ("uv run --with rich pytest", "test"),
    ("bun run verify", "test"),
    ("bun test", "test"),
    ("npx vitest", "test"),
    ("npx -y vitest run", "test"),
    ("npx --yes jest", "test"),
    ("npx playwright test", "test"),
    ("uvx pytest", "test"),
    ("pnpm exec vitest", "test"),
    ("bun x vitest", "test"),
    ("pnpm --filter web test", "test"),
    ("pnpm --filter=web test", "test"),
    ("npm --prefix web test", "test"),
    ("pnpm -C web test", "test"),
    ("yarn workspace web test", "test"),
    ("deno test", "test"),
    ("./gradlew test", "test"),
    ("mvn test", "test"),
    ("xcodebuild test -scheme A", "test"),
    ("make test", "test"),
    ("make -C sub test", "test"),
    ("docker compose run --rm web pytest -k x", "test"),
    ("docker compose -f x.yml exec -T web npm test", "test"),
    ("docker-compose run web pytest", "test"),
    ("bash .agents/test-all.sh", "test"),
    ("python3 -m pytest", "test"),
    ("cargo test", "test"),
    ("make build", "build"),
    ("make", "build"),
    ("docker compose build", "build"),
    ("npm install", "build"),
    ("pnpm --filter web install", "build"),
    ("uv sync", "build"),
    ("docker compose up -d", "other"),
    ("docker compose run web ls", "other"),
    ("docker ps", "other"),
    ("pnpm build", "build"),
    ("uv run pytest tests/", "test"),
    (".agents/test-workloop.sh 2>&1 | tail -3", "test"),
    ("for t in .agents/test-a.sh .agents/test-b.sh; do \"$t\"; done", "test"),
    ("sleep 1", "wait"),
    ("sleep 90; tail -5 /tmp/x/pytest.log", "wait"),
    ("for i in $(seq 30); do curl -sf localhost:3000 && break; sleep 2; done", "wait"),
    ("gh run watch 123", "wait"),
    ("npx eslint src", "check"),
    ("pnpm lint", "check"),
    ("pnpm typecheck", "check"),
    ("python3 -m mypy app", "check"),
    ("python3 .agents/check-layout.py", "check"),
    ("tsc --noEmit", "check"),
    ("ruff format .", "other"),
    ("prettier --check .", "check"),
    ("node shot.mjs", "browser"),
    ("node -e \"require('playwright').chromium.launch()\"", "browser"),
    ("chromium --headless --screenshot x.png", "browser"),
    ("cd /tmp/pw && node - <<'JS'\nconst { chromium } = require('playwright');\nJS", "browser"),
    ("cat > shot.mjs <<'JS'\nimport { chromium } from 'playwright';\nJS", "read"),
    ("rg -n puppeteer src", "read"),
    ("sed -i s/a/b/ a.txt", "other"),
    ("git -C x status", "read"),
    ("git status", "read"),
    ("git commit -m x", "git"),
    ("rg foo", "read"),
    ("rg -n foo src | head", "read"),
    ("sed -n 1p a.txt", "read"),
)


class CellTime(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = os.path.realpath(tempfile.mkdtemp(prefix="cell-time-test-"))
        cls.repo = os.path.join(cls.root, "repo")
        cls.elsewhere = os.path.join(cls.root, "elsewhere")
        cls.store = os.path.join(cls.root, "store")
        for folder in (cls.repo, cls.elsewhere, os.path.join(cls.repo, "sub")):
            os.makedirs(folder)
        git(cls.repo, "init", "-q")
        for name in ("src.py", os.path.join("sub", "a.py")):
            with open(os.path.join(cls.repo, name), "w", encoding="utf-8") as handle:
                handle.write("a = 1\n")
            git(cls.repo, "add", name)

        write_cell(cls.store, "proj-one", "sess1", "lane", lane_records(cls.repo), "lane cell")
        write_cell(cls.store, "proj-two", "sess1", "lane", lane_records(cls.repo), "lane cell copy")
        cls.gone = os.path.join(cls.root, "removed-worktree")
        write_cell(cls.store, "proj-one", "sess1", "gone",
                   [say("09:00:00", cls.gone, "user", "hello"), say("09:00:05", cls.gone, "assistant", "hi")],
                   "folder removed", extra_lines=["{not json"])
        write_cell(cls.store, "proj-one", "sess2", "other",
                   [say("09:00:00", cls.elsewhere, "user", "WORKLOOP WORKER BRIEF — ghost/x go"),
                    say("09:00:09", cls.elsewhere, "assistant", "ok")], "other repository")
        write_cell(cls.store, "proj-one", "sess3", "old",
                   [say("09:00:00", cls.repo, "user", "old", day="2026-08-01T")], "outside the window")
        write_cell(cls.store, "skipme-local", "sess4", "skipped",
                   [say("09:00:00", cls.repo, "user", "x"), say("09:00:05", cls.repo, "assistant", "y")], "skipped")
        write_main(cls.store, "proj-hb", "hb", heartbeat(cls.elsewhere))
        cls.state = os.path.join(cls.root, "state.json")
        with open(cls.state, "w", encoding="utf-8") as handle:
            json.dump({"runs": {"run1": {"verify": VERIFY}, "run2": {"verify": "uv run pytest"}}}, handle)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.root)

    def run_script(self, *extra, store=None, expect=0):
        command = [sys.executable, SCRIPT, "--store", store or self.store, "--state", self.state,
                   "--since", "2026-09-30", "--until", "2026-10-02", "--skip", "skipme-*", *extra]
        done = subprocess.run(command, capture_output=True, text=True, env=clean_env(HOME=self.root))
        self.assertEqual(done.returncode, expect, done.stderr)
        return done

    def report(self, *extra, store=None):
        return json.loads(self.run_script("--json", *extra, store=store).stdout)

    def fresh(self, cells=(), mains=()):
        """A new store holding only the given cells (project, session, agent, records) and main sessions."""
        store = tempfile.mkdtemp(dir=self.root)
        for project, session, agent, records in cells:
            write_cell(store, project, session, agent, records, f"cell {agent}")
        for project, session, records in mains:
            write_main(store, project, session, records)
        return store

    def single(self, records, **kw):
        """The one cell's report for a store holding just these records."""
        r = self.report(store=self.fresh([("p", "s", "a", records)], **kw))
        return r, r["totals"]

    # ---- counts, time, and the original figures

    def test_counts_and_problems(self):
        r = self.report()
        self.assertEqual(r["cells"], 3)
        self.assertEqual(r["duplicate_transcripts"], 1)
        self.assertEqual(r["unreadable_lines"], 1)
        self.assertEqual(r["unattributed"], 0)
        self.assertEqual(r["silence"]["windows"], [])

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
        self.assertEqual(shell["other"]["n"], 3)
        self.assertEqual(shell["wait"]["n"], 2)
        self.assertEqual(shell["git"]["n"], 0)

    def test_longest_command_is_labelled_by_execution_and_delay(self):
        top = self.report()["longest_commands"][0]
        self.assertEqual((top["execution_s"], top["result_delay_s"]), (1860, 1860))
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

    def test_text_report_names_each_section_and_its_scope(self):
        text = self.run_script().stdout
        for heading in ("TIME", "SHELL TIME BY KIND", "execution: delay minus store-wide silence and sibling waits",
                        "LONGEST COMMANDS", "BLIND WAITS", "SOURCE WRITES", "LANES",
                        "Codex cells are outside this report; days are UTC."):
            self.assertIn(heading, text)

    def test_missing_store_fails_with_a_message(self):
        done = subprocess.run([sys.executable, SCRIPT, "--store", os.path.join(self.root, "nope")],
                              capture_output=True, text=True, env=clean_env(HOME=self.root))
        self.assertEqual(done.returncode, 1)
        self.assertIn("is not a directory", done.stderr)

    # ---- the classifier

    def test_classifier_table(self):
        shell, _ = load_script().build_shell()
        for command, kind in CLASSIFIER:
            with self.subTest(command=command):
                self.assertEqual(shell.kind(shell.programs(command), command), kind)

    # ---- composed-test runs

    def test_composed_run_compares_programs_not_substrings(self):
        r1 = self.repo
        records = (
            [say("10:00:00", r1, "user", "WORKLOOP WORKER BRIEF — run2/laneB go")]
            + bash("10:00:10", "10:00:20", r1, "c1", "uv run pytest tests/a.py -k x")
            + bash("10:00:30", "10:00:40", r1, "c2", 'grep -r "uv run pytest" docs')
            + bash("10:00:50", "10:01:00", r1, "c3", "cd wt && uv run pytest")
            + bash("10:01:10", "10:01:20", r1, "c4", "FOO=1 uv run pytest 2>&1 | tail -3")
        )
        r, _ = self.single(records)
        self.assertEqual(r["lanes"][0]["composed_runs"], 2)

    def test_composed_run_after_cd_matches_the_verify_command(self):
        records = ([say("10:00:00", self.repo, "user", "WORKLOOP WORKER BRIEF — run1/laneA go")]
                   + bash("10:00:10", "10:00:20", self.repo, "c1", "cd wt && bash .agents/test-all.sh")
                   + bash("10:00:30", "10:00:40", self.repo, "c2", "bash .agents/test-all.sh --fast")
                   + bash("10:00:50", "10:01:00", self.repo, "c3", 'grep "bash .agents/test-all.sh" notes.md'))
        r, _ = self.single(records)
        self.assertEqual(r["lanes"][0]["composed_runs"], 1)

    # ---- shell source writes

    def test_shell_writes_that_land_in_tracked_files(self):
        commands = [
            "echo x>src.py", "cd sub && sed -i '' 's/a/b/' a.py", "cp /tmp/new.py src.py",
            "printf x | tee src.py", WRITE_SRC, "python3 -c \"open('src.py','w').write('x')\"",
            "mv /tmp/n sub/a.py", "cd sub; echo y >> a.py", "sed -i.bak -e 's/a/b/' src.py",
            "cp -t sub /tmp/a.py",
        ]
        records = []
        for index, command in enumerate(commands):
            records += bash(f"10:00:{index * 2:02d}", f"10:00:{index * 2 + 1:02d}", self.repo, f"w{index}", command)
        _, totals = self.single(records)
        self.assertEqual(totals["writes"]["shell_source_writes"], len(commands))

    def test_shell_commands_that_only_read_tracked_files_are_not_writes(self):
        commands = [
            COPY_TO_TMP, "cat src.py > /tmp/copy.txt", "cp src.py /tmp/", "grep a src.py | tee /tmp/o.txt",
            "sed -n 1p src.py", "sed 's/a/b/' src.py > /tmp/o", 'echo "a>b"', "ls src.py 2>&1",
            "echo x > /dev/null", "cp src.py sub/copy.py", "cd /tmp && cp src.py out.py",
        ]
        records = []
        for index, command in enumerate(commands):
            records += bash(f"10:00:{index * 2:02d}", f"10:00:{index * 2 + 1:02d}", self.repo, f"r{index}", command)
        _, totals = self.single(records)
        self.assertEqual(totals["writes"]["shell_source_writes"], 0)

    # ---- gate refusals and blind waits

    def test_only_a_gate_block_from_the_hook_is_a_refusal(self):
        records = (
            bash("10:00:00", "10:00:01", self.repo, "g1", "sleep 90", text=GATE_TEXT, error=True)
            + bash("10:00:10", "10:00:11", self.repo, "g2", "grep wait-gate notes", error=True,
                   text="Blocked: sleeping 90 s holds the session; see wait-gate.sh")
            + bash("10:00:20", "10:00:21", self.repo, "g3", "ls", error=True,
                   text="PreToolUse:Bash hook error: [wait-gate.sh]: crashed")
            + bash("10:00:30", "10:00:31", self.repo, "g4", "ls", error=True,
                   text="PreToolUse:Bash hook error: [guard-publish.sh]: Blocked: sleeping 90 s holds")
        )
        _, totals = self.single(records)
        self.assertEqual(totals["blind"]["refusals"], 1)

    def test_a_capped_poll_on_a_task_output_is_not_a_blind_wait(self):
        records = bash("10:00:00", "10:08:00", self.repo, "p1", CAPPED_LOOP, timeout=600000)
        records += bash("10:08:10", "10:09:10", self.repo, "p2", "sleep 60")
        _, totals = self.single(records)
        self.assertEqual(totals["blind"]["ran"], 1)
        self.assertEqual(totals["blind"]["ran_s"], 60)

    # ---- long calls, timeouts, background

    def test_long_calls_timeouts_and_background_calls(self):
        r = self.repo
        records = (
            bash("10:00:00", "10:11:40", r, "t1", "npm run build", timeout=900000)
            + bash("10:12:00", "10:14:10", r, "t2", "npm run build")
            + bash("10:14:20", "10:14:25", r, "t3", "npm run build", run_in_background=True)
            + bash("10:14:30", "10:16:30", r, "t4", "npm run build", outcome={"timedOutAfterMs": 120000})
            + bash("10:16:40", "10:16:50", r, "t5", "npm run build", text="Command did not complete within its timeout")
        )
        _, totals = self.single(records)
        self.assertEqual(totals["bash"], {"over_600s": 1, "over_timeout": 1, "timed_out": 2})
        self.assertEqual(totals["background"], {"n": 1, "delay_s": 5})
        self.assertEqual(totals["shell"]["build"]["n"], 4)
        self.assertEqual(totals["shell"]["build"]["delay_s"], 700 + 130 + 120 + 10)

    # ---- execution against delay

    def test_store_wide_silence_is_cut_from_a_delay_and_reported(self):
        records = [say("10:00:00", self.repo, "user", "go")] + bash("10:00:10", "12:00:10", self.repo, "s1", "npm run build")
        records.append(say("12:00:20", self.repo, "assistant", "done"))
        main = [("p", "lead", [say("10:30:00", self.elsewhere, "user", "still here")])]
        r, totals = self.single(records, mains=main)
        build = totals["shell"]["build"]
        self.assertEqual((build["delay_s"], build["s"]), (7200, 1790))
        self.assertEqual(r["silence"]["total_s"], 5410)
        self.assertEqual(len(r["silence"]["windows"]), 1)
        self.assertEqual(totals["active_s"]["tool"], 1790)
        self.assertEqual(totals["idle_s"]["tool"], 0)
        self.assertEqual(r["longest_commands"][0]["execution_s"], 1790)

    def test_a_call_that_waited_on_an_earlier_sibling_does_not_count_the_wait(self):
        r = self.repo
        records = [use("10:00:00", r, "a", "Bash", mid="m1", command="npm run build"),
                   use("10:00:01", r, "b", "Bash", mid="m1", command="npm run build"),
                   result("10:10:00", r, "a"), result("10:10:01", r, "b")]
        _, totals = self.single(records)
        build = totals["shell"]["build"]
        self.assertEqual((build["delay_s"], build["s"]), (1200, 601))

    def test_calls_of_different_messages_do_not_share_waits(self):
        r = self.repo
        records = [use("10:00:00", r, "a", "Bash", mid="m1", command="npm run build"),
                   use("10:00:01", r, "b", "Bash", mid="m2", command="npm run build"),
                   result("10:10:00", r, "a"), result("10:10:01", r, "b")]
        _, totals = self.single(records)
        self.assertEqual(totals["shell"]["build"]["s"], 1200)

    # ---- a call that never returns

    def test_a_missing_result_does_not_label_later_gaps_as_inside_a_tool_call(self):
        r = self.repo
        records = [say("10:00:00", r, "user", "go"),
                   use("10:00:05", r, "lost", "Bash", mid="m1", command="npm test"),
                   use("10:00:06", r, "kept", "Bash", mid="m2", command="npm run build"),
                   result("10:00:10", r, "kept"),
                   say("10:00:20", r, "assistant", "next"),
                   say("10:50:00", r, "user", "continue")]
        elsewhere = [say(clock, self.elsewhere, "user", "ping") for clock in ("10:15:00", "10:30:00", "10:45:00")]
        _, totals = self.single(records, mains=[("p", "other", elsewhere)])
        self.assertEqual(totals["idle_s"]["lead"], 2980)
        self.assertEqual(totals["idle_s"]["tool"], 0)

    # ---- attribution and duplicates

    def test_duplicate_copies_keep_the_one_whose_folder_exists(self):
        a = [say("10:00:00", self.gone, "user", "x"), say("10:00:05", self.gone, "assistant", "y")]
        b = [say("10:00:00", self.repo, "user", "x"), say("10:00:05", self.repo, "assistant", "y")]
        store = self.fresh([("proj-a", "sessD", "d", a), ("proj-b", "sessD", "d", b)])
        for extra in ((), ("--repo", self.repo)):
            r = self.report(*extra, store=store)
            self.assertEqual((r["cells"], r["duplicate_transcripts"], r["unattributed"]), (1, 1, 0))
            self.assertEqual(r["cells_detail"][0]["project"], "proj-b")

    def test_a_cell_whose_folder_is_gone_is_attributed_by_its_leads_folder(self):
        gone = [say("10:00:00", self.gone, "user", "x"), say("10:00:05", self.gone, "assistant", "y")]
        store = self.fresh([("proj", "sessL", "g", gone), ("proj", "sessM", "g", gone)],
                           mains=[("proj", "sessL", [say("10:00:00", self.repo, "user", "lead")])])
        r = self.report("--repo", self.repo, store=store)
        self.assertEqual((r["cells"], r["unattributed"]), (1, 1))
        self.assertEqual(r["cells_detail"][0]["session"], "sessL")

    # ---- robustness

    def test_bad_files_are_reported_by_name_and_the_run_goes_on(self):
        store = self.fresh()
        good = [say("10:00:00", self.repo, "user", "go")] + bash("10:00:10", "10:00:20", self.repo, "u1", 'echo "abc')
        write_cell(store, "p", "s", "meta", good, "x", meta_text="{broken")
        write_cell(store, "p", "s", "text", [], "x", raw=b"\xff\xfe\x00 not utf-8\n")
        r = self.report(store=store)
        self.assertEqual(r["cells"], 1)
        listed = "\n".join(r["unreadable_files"])
        self.assertIn("agent-meta.meta.json", listed)
        self.assertIn("agent-text.jsonl", listed)
        self.assertEqual(r["unsplit_segments"], 1)


if __name__ == "__main__":
    unittest.main()
