from __future__ import annotations

import unittest

from fetchcase import CHALLENGE, KEYS, OK_CONVERTER, FetchCase, converter_text, source_text
from helpers import PDF, FakeServer, drop_midway, serve, write_plugin

from paperfetch.ledger import FETCH, latest, read_rows


class FetchFlowTests(FetchCase):
    def test_a_source_and_a_converter_take_a_paper_from_pending_to_converted(self) -> None:
        with FakeServer({"/a.pdf": serve(200, PDF)}) as server:
            write_plugin(self.plugins, "sources", "one.py", source_text("one", {"alpha-1": server.base + "/a.pdf"}))
            write_plugin(self.plugins, "converters", "text.py", converter_text("text", OK_CONVERTER))
            run = self.fetch()
        self.assertEqual(run.code, 0, run.err)
        self.assertEqual((self.layout.original("alpha-1", "pdf")).read_bytes(), PDF)
        self.assertEqual(self.layout.fulltext("alpha-1").read_text(), "TEXT of original.pdf %PDF-1.4")
        self.assertEqual(self.checker_files("alpha-1"), ["fulltext.md"])
        self.assertEqual(self.states(), {"alpha-1": "converted", "beta-2": "awaiting-inbox", "gamma-3": "awaiting-inbox"})
        self.assertEqual(run.out[-1], "done: converted 1, awaiting-inbox 2")
        awaiting = [line for line in run.out if line.startswith("! awaiting-inbox beta-2")][0]
        self.assertIn("data/raw/papers/beta-2.pdf", awaiting)

    def test_a_converter_receives_the_paper_so_it_can_check_the_identity(self) -> None:
        body = 'return paper.key + " " + paper.doi'
        with FakeServer({"/a.pdf": serve(200, PDF)}) as server:
            write_plugin(self.plugins, "sources", "one.py", source_text("one", {"alpha-1": server.base + "/a.pdf"}))
            write_plugin(self.plugins, "converters", "text.py", converter_text("text", body))
            self.fetch("--only", "alpha-1")
        self.assertEqual(self.layout.fulltext("alpha-1").read_text(), "alpha-1 10.1/alpha-1")

    def test_without_a_converter_the_paper_stays_fetched_and_says_why(self) -> None:
        with FakeServer({"/a.pdf": serve(200, PDF)}) as server:
            write_plugin(self.plugins, "sources", "one.py", source_text("one", {"alpha-1": server.base + "/a.pdf"}))
            run = self.fetch("--only", "alpha-1")
        self.assertEqual(self.states(), {"alpha-1": "fetched"})
        self.assertTrue(any("no converter accepts pdf" in line for line in run.out))
        self.assertFalse(self.layout.fulltext("alpha-1").exists())

    def test_a_rerun_makes_no_request_and_writes_no_row(self) -> None:
        with FakeServer({"/a.pdf": serve(200, PDF)}) as server:
            write_plugin(self.plugins, "sources", "one.py", source_text("one", {"alpha-1": server.base + "/a.pdf"}))
            write_plugin(self.plugins, "converters", "text.py", converter_text("text", OK_CONVERTER))
            self.fetch("--only", "alpha-1")
            rows, requests = len(read_rows(self.layout.ledger)), len(server.requests)
            run = self.fetch("--only", "alpha-1")
            self.assertEqual(len(server.requests), requests)
        self.assertEqual(len(read_rows(self.layout.ledger)), rows)
        self.assertIn("= skip    alpha-1 (converted)", run.out)

    def test_a_cut_off_download_leaves_no_file_and_records_a_failure(self) -> None:
        with FakeServer({"/a.pdf": drop_midway}) as server:
            write_plugin(self.plugins, "sources", "one.py", source_text("one", {"alpha-1": server.base + "/a.pdf"}))
            self.fetch("--only", "alpha-1")
        self.assertEqual(self.states(), {"alpha-1": "failed"})
        self.assertEqual(self.layout.originals("alpha-1"), [])
        folder = self.layout.paper_dir("alpha-1")
        self.assertEqual(list(folder.glob("*")) if folder.exists() else [], [])
        detail = latest(read_rows(self.layout.ledger))[("alpha-1", FETCH)].detail
        self.assertIn("cut off", detail)

    def test_a_challenge_page_is_blocked_and_a_tiny_or_html_body_is_failed(self) -> None:
        routes = {
            "/challenge.pdf": serve(200, CHALLENGE),
            "/tiny.pdf": serve(200, b"%PDF-1.4"),
            "/login.pdf": serve(200, b"<html>Please sign in</html>" * 60),
        }
        urls = {"alpha-1": "/challenge.pdf", "beta-2": "/tiny.pdf", "gamma-3": "/login.pdf"}
        with FakeServer(routes) as server:
            full = {key: server.base + path for key, path in urls.items()}
            write_plugin(self.plugins, "sources", "one.py", source_text("one", full))
            self.fetch()
        self.assertEqual(self.states(), {"alpha-1": "blocked", "beta-2": "failed", "gamma-3": "failed"})
        for key in KEYS:
            self.assertEqual(self.layout.originals(key), [])

    def test_a_paper_is_blocked_when_one_candidate_is_blocked_and_a_later_one_failed(self) -> None:
        routes = {"/forbidden.pdf": serve(403, b"no"), "/missing.pdf": serve(404, b"no")}
        with FakeServer(routes) as server:
            write_plugin(self.plugins, "sources", "a.py", source_text("aaa", {"alpha-1": server.base + "/forbidden.pdf"}))
            write_plugin(self.plugins, "sources", "b.py", source_text("bbb", {"alpha-1": server.base + "/missing.pdf"}))
            self.fetch("--only", "alpha-1")
        self.assertEqual(self.states(), {"alpha-1": "blocked"})

    def test_a_source_that_raises_is_reported_and_the_next_source_still_runs(self) -> None:
        with FakeServer({"/a.pdf": serve(200, PDF)}) as server:
            write_plugin(self.plugins, "sources", "a.py", "NAME = 'aaa'\ndef locate(paper, http):\n    raise ValueError('api down')\n")
            write_plugin(self.plugins, "sources", "b.py", source_text("bbb", {"alpha-1": server.base + "/a.pdf"}))
            run = self.fetch("--only", "alpha-1")
        self.assertEqual(self.states(), {"alpha-1": "fetched"})
        self.assertTrue(any("source aaa raised" in line and "api down" in line for line in run.out))

    def test_sources_option_chooses_and_orders_the_sources(self) -> None:
        with FakeServer({"/first.pdf": serve(200, PDF), "/second.pdf": serve(200, PDF)}) as server:
            write_plugin(self.plugins, "sources", "a.py", source_text("aaa", {"alpha-1": server.base + "/first.pdf"}))
            write_plugin(self.plugins, "sources", "b.py", source_text("bbb", {"alpha-1": server.base + "/second.pdf"}))
            self.fetch("--only", "alpha-1", "--sources", "bbb,aaa")
            self.assertEqual(server.requests, [("GET", "/second.pdf")])

    def test_unknown_source_and_unknown_key_are_usage_errors_that_name_them(self) -> None:
        write_plugin(self.plugins, "sources", "a.py", source_text("aaa", {}))
        run = self.fetch("--sources", "nope")
        self.assertEqual(run.code, 2)
        self.assertIn("nope", run.err[0])
        self.assertIn("aaa", run.err[0])
        run = self.fetch("--only", "no-such-key")
        self.assertEqual(run.code, 2)
        self.assertIn("no-such-key", run.err[0])

    def test_a_source_that_returns_junk_is_reported_not_trusted(self) -> None:
        write_plugin(self.plugins, "sources", "a.py", "NAME = 'aaa'\ndef locate(paper, http):\n    return ['not a candidate']\n")
        run = self.fetch("--only", "alpha-1")
        self.assertEqual(self.states(), {"alpha-1": "failed"})
        self.assertTrue(any("not a Candidate" in line for line in run.out))


class UnexpectedFailureTests(FetchCase):
    def test_one_papers_unexpected_error_is_recorded_and_the_next_paper_still_runs(self) -> None:
        body = (
            "from paperfetch.model import Candidate\nNAME = 'odd'\n"
            "def locate(paper, http):\n"
            "    if paper.key == 'alpha-1':\n        return 5\n"
            f"    return [Candidate(url=URL, kind='pdf', source=NAME)]\n"
        )
        with FakeServer({"/b.pdf": serve(200, PDF)}) as server:
            write_plugin(self.plugins, "sources", "odd.py", f"URL = {server.base + '/b.pdf'!r}\n" + body)
            run = self.fetch("--only", "alpha-1,beta-2")
        self.assertEqual(run.code, 0, run.err)
        self.assertEqual(self.states(), {"alpha-1": "failed", "beta-2": "fetched"})
        detail = latest(read_rows(self.layout.ledger))[("alpha-1", FETCH)].detail
        self.assertIn("unexpected TypeError", detail)

    def test_a_non_ascii_address_fails_that_paper_and_not_the_run_and_is_not_retried(self) -> None:
        with FakeServer({"/b.pdf": serve(200, PDF)}) as server:
            urls = {"alpha-1": f"{server.base}/café.pdf", "beta-2": server.base + "/b.pdf"}
            write_plugin(self.plugins, "sources", "one.py", source_text("one", urls))
            run = self.fetch("--only", "alpha-1,beta-2")
            self.assertEqual(server.requests, [("GET", "/b.pdf")])
        self.assertEqual(run.code, 0, run.err)
        self.assertEqual(self.states(), {"alpha-1": "failed", "beta-2": "fetched"})

    def test_untried_papers_come_before_papers_that_failed_before(self) -> None:
        routes = {f"/{key}.pdf": serve(200, PDF) for key in KEYS}
        with FakeServer(routes) as server:
            urls = {key: f"{server.base}/{key}.pdf" for key in KEYS}
            write_plugin(self.plugins, "sources", "one.py", source_text("one", {"beta-2": urls["beta-2"]}))
            self.fetch("--only", "alpha-1")  # alpha-1 is first in the manifest, is tried and finds nothing
            self.assertEqual(self.states(), {"alpha-1": "awaiting-inbox"})
            write_plugin(self.plugins, "sources", "one.py", source_text("one", urls))
            self.fetch("--limit", "1")
        # Manifest order would give the one slot to alpha-1; an untried paper goes first.
        self.assertEqual(self.states()["beta-2"], "fetched")
        self.assertEqual(self.states()["alpha-1"], "awaiting-inbox")


class ConverterOutcomeTests(FetchCase):
    def run_with(self, body: str) -> None:
        with FakeServer({"/a.pdf": serve(200, PDF)}) as server:
            write_plugin(self.plugins, "sources", "one.py", source_text("one", {"alpha-1": server.base + "/a.pdf"}))
            write_plugin(self.plugins, "converters", "c.py", converter_text("conv", body))
            self.fetch("--only", "alpha-1")

    def test_no_text_keeps_the_file_and_says_needs_text(self) -> None:
        self.run_with('raise NoText("a scan, no text layer")')
        self.assertEqual(self.states(), {"alpha-1": "needs-text"})
        self.assertTrue(self.layout.original("alpha-1", "pdf").exists())

    def test_wrong_paper_removes_the_saved_copy_and_records_identity(self) -> None:
        self.run_with('raise WrongPaper("the DOI is not in the text")')
        self.assertEqual(self.states(), {"alpha-1": "failed"})
        self.assertEqual(self.layout.originals("alpha-1"), [])
        row = latest(read_rows(self.layout.ledger))[("alpha-1", FETCH)]
        self.assertIn("identity: the DOI is not in the text", row.detail)

    def test_empty_text_is_needs_text_not_a_blank_fulltext(self) -> None:
        self.run_with('return "   \\n"')
        self.assertEqual(self.states(), {"alpha-1": "needs-text"})
        self.assertFalse(self.layout.fulltext("alpha-1").exists())

    def test_a_converter_that_crashes_leaves_the_paper_fetched_so_the_next_run_does_not_download_again(self) -> None:
        with FakeServer({"/a.pdf": serve(200, PDF)}) as server:
            write_plugin(self.plugins, "sources", "one.py", source_text("one", {"alpha-1": server.base + "/a.pdf"}))
            write_plugin(self.plugins, "converters", "c.py", converter_text("conv", 'raise ValueError("pdftotext missing")'))
            self.fetch("--only", "alpha-1")
            self.assertEqual(self.states(), {"alpha-1": "fetched"})
            self.assertTrue(self.layout.original("alpha-1", "pdf").exists())
            requests = len(server.requests)
            write_plugin(self.plugins, "converters", "c.py", converter_text("conv", OK_CONVERTER))
            self.fetch("--only", "alpha-1")
            self.assertEqual(len(server.requests), requests)
        self.assertEqual(self.states(), {"alpha-1": "converted"})
        crash = [row for row in read_rows(self.layout.ledger) if "pdftotext missing" in row.detail]
        self.assertEqual(len(crash), 1)


class TransitionTests(FetchCase):
    def test_failed_blocked_and_awaiting_papers_get_a_full_attempt_next_time(self) -> None:
        state = {"ok": False}

        def late(handler) -> None:
            serve(200, PDF)(handler) if state["ok"] else serve(404, b"gone")(handler)

        with FakeServer({"/a.pdf": late}) as server:
            write_plugin(self.plugins, "sources", "one.py", source_text("one", {"alpha-1": server.base + "/a.pdf"}))
            self.fetch("--only", "alpha-1")
            self.assertEqual(self.states(), {"alpha-1": "failed"})
            state["ok"] = True
            self.fetch("--only", "alpha-1")
        self.assertEqual(self.states(), {"alpha-1": "fetched"})

    def test_a_fetched_paper_converts_when_a_converter_appears_without_any_download(self) -> None:
        with FakeServer({"/a.pdf": serve(200, PDF)}) as server:
            write_plugin(self.plugins, "sources", "one.py", source_text("one", {"alpha-1": server.base + "/a.pdf"}))
            self.fetch("--only", "alpha-1")
            self.assertEqual(self.states(), {"alpha-1": "fetched"})
            requests = len(server.requests)
            write_plugin(self.plugins, "converters", "text.py", converter_text("text", OK_CONVERTER))
            self.fetch("--only", "alpha-1")
            self.assertEqual(len(server.requests), requests)
        self.assertEqual(self.states(), {"alpha-1": "converted"})

    def test_force_runs_a_full_attempt_for_a_finished_paper(self) -> None:
        with FakeServer({"/a.pdf": serve(200, PDF)}) as server:
            write_plugin(self.plugins, "sources", "one.py", source_text("one", {"alpha-1": server.base + "/a.pdf"}))
            write_plugin(self.plugins, "converters", "text.py", converter_text("text", OK_CONVERTER))
            self.fetch("--only", "alpha-1")
            self.fetch("--only", "alpha-1", "--force")
            self.assertEqual(len(server.requests), 2)

    def test_a_forced_attempt_that_fails_is_recorded_as_failed(self) -> None:
        with FakeServer({"/a.pdf": serve(200, PDF)}) as server:
            write_plugin(self.plugins, "sources", "one.py", source_text("one", {"alpha-1": server.base + "/a.pdf"}))
            write_plugin(self.plugins, "converters", "text.py", converter_text("text", OK_CONVERTER))
            self.fetch("--only", "alpha-1")
        with FakeServer({"/a.pdf": serve(403, b"no")}) as server:
            write_plugin(self.plugins, "sources", "one.py", source_text("one", {"alpha-1": server.base + "/a.pdf"}))
            self.fetch("--only", "alpha-1", "--force")
        self.assertEqual(self.states(), {"alpha-1": "blocked"})
        self.assertTrue(self.layout.fulltext("alpha-1").exists())  # a failed redo removes nothing it did not replace


if __name__ == "__main__":
    unittest.main()
