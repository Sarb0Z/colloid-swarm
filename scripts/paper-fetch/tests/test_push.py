from __future__ import annotations

import json
import tempfile
import textwrap
import unittest
from pathlib import Path

from helpers import FakeServer, make_stamp, run_cli, serve, tree, write_manifest, write_plugin

from paperfetch.layout import Layout
from paperfetch.ledger import FETCH, PUSH, Ledger, latest, read_rows
from paperfetch.transport import urllib_transport

KEYS = ("alpha-1", "beta-2", "gamma-3", "delta-4")
SECRET = "zk_live_0123456789abcdef"


def sink_text(log: Path, base: str, *, push_body: str, plan_body: str = "", extra: str = "") -> str:
    plan_lines = textwrap.indent(textwrap.dedent(plan_body).strip() or 'return [f"would store {paper.key}"]', "    ")
    push_lines = textwrap.indent(textwrap.dedent(push_body).strip(), "    ")
    return (
        "from pathlib import Path\n"
        f"NAME = 'fake'\nBASE = {base!r}\nLOG = Path({str(log)!r})\n{extra}\n"
        f"def plan(paper, folder, http):\n{plan_lines}\n"
        f"def push(paper, folder, http):\n    LOG.open('a').write('push ' + paper.key + '\\n')\n{push_lines}\n"
    )


OK_PUSH = 'return {"item": "I-" + paper.key}'


class PushCase(unittest.TestCase):
    def setUp(self) -> None:
        self._scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self._scratch.cleanup)
        self.base = Path(self._scratch.name)
        self.root = self.base / "project"
        self.root.mkdir()
        self.plugins = self.base / "plugins"
        self.plugins.mkdir()
        self.log = self.base / "calls.log"
        self.layout = Layout(self.root)
        self.manifest = write_manifest(self.base, [{"key": key, "doi": f"10.1/{key}"} for key in KEYS])
        self.seed({"alpha-1": "converted", "beta-2": "fetched", "gamma-3": "awaiting-inbox", "delta-4": "failed"})

    def seed(self, states: dict[str, str]) -> None:
        with Ledger.locked(self.layout.ledger, make_stamp(), {}) as ledger:
            for key, state in states.items():
                ledger.append(key=key, doi=f"10.1/{key}", stage=FETCH, state=state)
                if state in ("converted", "fetched"):
                    folder = self.layout.paper_dir(key)
                    folder.mkdir(parents=True, exist_ok=True)
                    (folder / "original.pdf").write_bytes(b"%PDF-1.4 fixture")

    def push(self, *extra: str, environ: dict[str, str] | None = None):
        argv = [
            "push", "--manifest", str(self.manifest), "--root", str(self.root), "--plugins", str(self.plugins),
            "--sink", "fake", "--delay-ms", "0", "--jitter-ms", "0", *extra,
        ]
        return run_cli(argv, self.plugins, environ=environ, transport=urllib_transport)

    def calls(self) -> list[str]:
        return self.log.read_text().split() if self.log.exists() else []

    def stage_states(self, stage: str) -> dict[str, str]:
        return {key: row.state for (key, found), row in latest(read_rows(self.layout.ledger)).items() if found == stage}


class DryRunTests(PushCase):
    def test_without_apply_it_prints_the_plan_and_never_calls_push_or_writes_a_row(self) -> None:
        write_plugin(self.plugins, "sinks", "fake.py", sink_text(self.log, "http://unused", push_body=OK_PUSH))
        before = (tree(self.root), self.layout.ledger.read_text())
        run = self.push()
        self.assertEqual(run.code, 0, run.err)
        self.assertIn("~ alpha-1: would store alpha-1", run.out)
        self.assertIn("~ beta-2: would store beta-2", run.out)
        self.assertEqual(self.calls(), [])
        self.assertEqual((tree(self.root), self.layout.ledger.read_text()), before)
        self.assertIn("nothing was written", run.out[-1])

    def test_a_plan_can_read_but_a_write_attempt_is_refused_and_reported(self) -> None:
        with FakeServer({"/lookup": serve(200, b"{}"), "/items": serve(200, b"{}")}) as server:
            plan = f"""
                http.get(BASE + "/lookup")
                http.request("POST", BASE + "/items", body=b"{{}}")
                return ["unreachable"]
            """
            write_plugin(self.plugins, "sinks", "fake.py", sink_text(self.log, server.base, push_body=OK_PUSH, plan_body=plan))
            run = self.push("--only", "alpha-1")
            self.assertEqual(server.requests, [("GET", "/lookup")])
        self.assertTrue(any("plan failed for alpha-1" in line and "read-only" in line for line in run.out))

    def test_a_plan_that_returns_nothing_is_reported_and_the_run_goes_on(self) -> None:
        write_plugin(
            self.plugins, "sinks", "fake.py",
            sink_text(self.log, "http://unused", push_body=OK_PUSH, plan_body="return None"),
        )
        run = self.push()
        self.assertEqual(run.code, 0, run.err)
        self.assertEqual(sum(line.startswith("! plan failed for") for line in run.out), 2)

    def test_a_dry_run_takes_no_lock(self) -> None:
        write_plugin(self.plugins, "sinks", "fake.py", sink_text(self.log, "http://unused", push_body=OK_PUSH))
        with Ledger.locked(self.layout.ledger, make_stamp(), {}):
            self.assertEqual(self.push().code, 0)


class ApplyTests(PushCase):
    def test_apply_pushes_eligible_papers_and_stores_the_ids_in_a_push_row(self) -> None:
        write_plugin(self.plugins, "sinks", "fake.py", sink_text(self.log, "http://unused", push_body=OK_PUSH))
        run = self.push("--apply")
        self.assertEqual(run.code, 0, run.err)
        self.assertEqual(self.calls(), ["push", "alpha-1", "push", "beta-2"])
        self.assertEqual(self.stage_states(PUSH), {"alpha-1": "pushed", "beta-2": "pushed"})
        row = latest(read_rows(self.layout.ledger))[("alpha-1", PUSH)]
        self.assertEqual(json.loads(row.external_ids), {"item": "I-alpha-1"})
        self.assertEqual(row.source, "fake")
        self.assertEqual(run.out[-1], "done: pushed 2, skipped 2")

    def test_papers_with_nothing_to_push_are_skipped_with_the_reason(self) -> None:
        write_plugin(self.plugins, "sinks", "fake.py", sink_text(self.log, "http://unused", push_body=OK_PUSH))
        run = self.push("--apply")
        reasons = {line.split()[2]: line for line in run.out if line.startswith("= skip")}
        self.assertIn("awaiting-inbox", reasons["gamma-3"])
        self.assertIn("failed", reasons["delta-4"])

    def test_a_pushed_paper_is_skipped_next_time_and_force_pushes_it_again(self) -> None:
        write_plugin(self.plugins, "sinks", "fake.py", sink_text(self.log, "http://unused", push_body=OK_PUSH))
        self.push("--apply")
        self.push("--apply")
        self.assertEqual(self.calls(), ["push", "alpha-1", "push", "beta-2"])
        self.push("--apply", "--only", "alpha-1", "--force")
        self.assertEqual(self.calls().count("alpha-1"), 2)

    def test_a_failing_sink_never_changes_the_fetch_state_and_the_next_push_retries(self) -> None:
        write_plugin(self.plugins, "sinks", "fake.py", sink_text(self.log, "http://unused", push_body='raise RuntimeError("quota exceeded")'))
        run = self.push("--apply", "--only", "alpha-1")
        self.assertEqual(self.stage_states(PUSH), {"alpha-1": "failed"})
        self.assertEqual(self.stage_states(FETCH)["alpha-1"], "converted")
        self.assertTrue(any("quota exceeded" in line for line in run.out))
        write_plugin(self.plugins, "sinks", "fake.py", sink_text(self.log, "http://unused", push_body=OK_PUSH))
        self.push("--apply", "--only", "alpha-1")
        self.assertEqual(self.stage_states(PUSH), {"alpha-1": "pushed"})

    def test_a_push_failure_causes_no_download_on_the_next_fetch(self) -> None:
        write_plugin(self.plugins, "sinks", "fake.py", sink_text(self.log, "http://unused", push_body='raise RuntimeError("x")'))
        self.push("--apply", "--only", "alpha-1")
        run = run_cli(
            ["fetch", "--manifest", str(self.manifest), "--root", str(self.root), "--plugins", str(self.plugins),
             "--only", "alpha-1", "--delay-ms", "0", "--jitter-ms", "0"],
            self.plugins,
        )
        self.assertEqual(run.code, 0, run.err)
        self.assertIn("= skip    alpha-1 (converted)", run.out)

    def test_a_sink_that_wrote_remotely_and_also_wrote_in_the_paper_folder_is_pushed_with_a_warning(self) -> None:
        # The remote write happened. Recording `failed` would make the next run write it again.
        body = f'(folder / "fulltext.md").write_text("injected")\nreturn {{"item": "x"}}'
        write_plugin(self.plugins, "sinks", "fake.py", sink_text(self.log, "http://unused", push_body=body))
        run = self.push("--apply", "--only", "alpha-1")
        self.assertEqual(self.stage_states(PUSH), {"alpha-1": "pushed"})
        row = latest(read_rows(self.layout.ledger))[("alpha-1", PUSH)]
        self.assertIn("WARNING", row.detail)
        self.assertIn("wrote in the paper folder: fulltext.md", row.detail)
        self.assertTrue(any(line.startswith("! warning  alpha-1") for line in run.out))

    def test_a_sink_that_rewrites_a_file_in_the_paper_folder_is_caught_by_size_and_time(self) -> None:
        body = f'(folder / "original.pdf").write_bytes(b"%PDF-1.4 rewritten by the sink")\nreturn {{"item": "x"}}'
        write_plugin(self.plugins, "sinks", "fake.py", sink_text(self.log, "http://unused", push_body=body))
        self.push("--apply", "--only", "alpha-1")
        row = latest(read_rows(self.layout.ledger))[("alpha-1", PUSH)]
        self.assertIn("wrote in the paper folder: original.pdf", row.detail)

    def test_ids_that_are_not_strings_are_stored_as_text_with_a_warning(self) -> None:
        write_plugin(self.plugins, "sinks", "fake.py", sink_text(self.log, "http://unused", push_body='return {"version": 5}'))
        self.push("--apply", "--only", "alpha-1")
        row = latest(read_rows(self.layout.ledger))[("alpha-1", PUSH)]
        self.assertEqual((row.state, json.loads(row.external_ids)), ("pushed", {"version": "5"}))
        self.assertIn("not all strings", row.detail)

    def test_a_sink_that_returns_no_dict_of_ids_fails(self) -> None:
        write_plugin(self.plugins, "sinks", "fake.py", sink_text(self.log, "http://unused", push_body='return ["x"]'))
        self.push("--apply", "--only", "alpha-1")
        self.assertEqual(self.stage_states(PUSH), {"alpha-1": "failed"})

    def test_a_second_apply_is_refused_while_the_first_holds_the_ledger(self) -> None:
        write_plugin(self.plugins, "sinks", "fake.py", sink_text(self.log, "http://unused", push_body=OK_PUSH))
        with Ledger.locked(self.layout.ledger, make_stamp(), {}):
            run = self.push("--apply")
        self.assertEqual(run.code, 4)
        self.assertEqual(self.calls(), [])


class CapAndSecretTests(PushCase):
    def test_a_sink_may_make_far_more_requests_than_a_fetch_is_allowed(self) -> None:
        with FakeServer({"/w": serve(200, b"{}")}) as server:
            body = 'for _ in range(60):\n    http.request("POST", BASE + "/w", body=b"{}")\nreturn {"item": "x"}'
            write_plugin(self.plugins, "sinks", "fake.py", sink_text(self.log, server.base, push_body=body))
            run = self.push("--apply", "--only", "alpha-1")
            self.assertEqual(len(server.requests), 60)
        self.assertEqual(run.code, 0, run.err)
        self.assertEqual(self.stage_states(PUSH), {"alpha-1": "pushed"})

    def test_a_sink_cap_stops_the_run_and_names_it(self) -> None:
        with FakeServer({"/w": serve(200, b"{}")}) as server:
            body = 'for _ in range(10):\n    http.request("POST", BASE + "/w", body=b"{}")\nreturn {"item": "x"}'
            write_plugin(
                self.plugins, "sinks", "fake.py",
                sink_text(self.log, server.base, push_body=body, extra="MAX_REQUESTS_PER_HOST = 5\n"),
            )
            run = self.push("--apply")
            self.assertEqual(len(server.requests), 5)
        self.assertEqual(run.code, 3)
        self.assertTrue(any("5" in line and "cap" in line for line in run.out))
        self.assertEqual(self.stage_states(PUSH), {})
        self.assertTrue(run.out[-1].startswith("stopped early: "))

    def test_a_secret_in_a_sink_error_never_reaches_the_ledger_or_the_console(self) -> None:
        body = f'raise RuntimeError("Zotero rejected {SECRET}")'
        write_plugin(self.plugins, "sinks", "fake.py", sink_text(self.log, "http://unused", push_body=body))
        run = self.push("--apply", "--only", "alpha-1", environ={"ZOTERO_API_KEY": SECRET})
        everything = "\n".join(run.out + run.err) + self.layout.ledger.read_text()
        self.assertNotIn(SECRET, everything)
        self.assertIn("[redacted:ZOTERO_API_KEY]", everything)


class SinkChoiceTests(PushCase):
    def test_an_unknown_sink_is_a_usage_error_that_lists_the_loaded_ones(self) -> None:
        write_plugin(self.plugins, "sinks", "fake.py", sink_text(self.log, "http://unused", push_body=OK_PUSH))
        argv = ["push", "--manifest", str(self.manifest), "--root", str(self.root), "--plugins", str(self.plugins), "--sink", "nope"]
        run = run_cli(argv, self.plugins)
        self.assertEqual(run.code, 2)
        self.assertIn("nope", run.err[0])
        self.assertIn("fake", run.err[0])

    def test_push_requires_a_sink(self) -> None:
        with self.assertRaises(SystemExit) as caught:
            run_cli(["push", "--manifest", str(self.manifest), "--root", str(self.root)], self.plugins)
        self.assertEqual(caught.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
