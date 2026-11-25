from __future__ import annotations

import tempfile
import textwrap
import unittest
from pathlib import Path

from helpers import (
    PDF,
    FakeServer,
    drop_midway,
    run_cli,
    serve,
    tree,
    write_manifest,
    write_plugin,
)

from paperfetch.layout import CHECKER_NAMES, Layout
from paperfetch.ledger import FETCH, Ledger, latest, read_rows
from paperfetch.transport import urllib_transport

CHALLENGE = b"<html><head><title>Just a moment...</title></head><body>cf-ray</body></html>"
KEYS = ("alpha-1", "beta-2", "gamma-3")


def source_text(name: str, urls: dict[str, str], kind: str = "pdf") -> str:
    return textwrap.dedent(f"""
        from paperfetch.model import Candidate
        NAME = {name!r}
        URLS = {urls!r}
        def locate(paper, http):
            url = URLS.get(paper.key)
            return [Candidate(url=url, kind={kind!r}, source=NAME)] if url else []
    """)


def converter_text(name: str, body: str, accepts: tuple[str, ...] = ("pdf",)) -> str:
    indented = textwrap.indent(textwrap.dedent(body).strip(), "    ")
    return (
        "from paperfetch.model import NoText, WrongPaper\n"
        f"NAME = {name!r}\nACCEPTS = {accepts!r}\n"
        f"def convert(path, run):\n{indented}\n"
    )


OK_CONVERTER = 'return "TEXT of " + path.name + " " + path.read_bytes()[:8].decode()'


class FetchCase(unittest.TestCase):
    def setUp(self) -> None:
        self._scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self._scratch.cleanup)
        self.base = Path(self._scratch.name)
        self.root = self.base / "project"
        self.root.mkdir()
        self.plugins = self.base / "plugins"
        self.plugins.mkdir()
        self.layout = Layout(self.root)
        self.manifest = write_manifest(self.base, [{"key": key, "doi": f"10.1/{key}"} for key in KEYS])

    def fetch(self, *extra: str, manifest: Path | None = None, run=None):
        argv = [
            "fetch", "--manifest", str(manifest or self.manifest), "--root", str(self.root),
            "--plugins", str(self.plugins), "--delay-ms", "0", "--jitter-ms", "0", *extra,
        ]
        kwargs = {"run": run} if run else {}
        return run_cli(argv, self.plugins, transport=urllib_transport, **kwargs)

    def states(self) -> dict[str, str]:
        rows = latest(read_rows(self.layout.ledger))
        return {key: row.state for (key, stage), row in rows.items() if stage == FETCH}

    def checker_files(self, key: str) -> list[str]:
        folder = self.layout.paper_dir(key)
        return [name for name in CHECKER_NAMES if (folder / name).exists()]


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

    def test_a_converter_that_crashes_is_reported_and_the_file_stays(self) -> None:
        self.run_with('raise ValueError("bad pdf")')
        self.assertEqual(self.states(), {"alpha-1": "failed"})
        self.assertTrue(self.layout.original("alpha-1", "pdf").exists())

    def test_empty_text_is_needs_text_not_a_blank_fulltext(self) -> None:
        self.run_with('return "   \\n"')
        self.assertEqual(self.states(), {"alpha-1": "needs-text"})
        self.assertFalse(self.layout.fulltext("alpha-1").exists())


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


class HandSuppliedTests(FetchCase):
    def hand_save(self, key: str, name: str, text: str) -> Path:
        path = self.layout.paper_dir(key) / name
        path.parent.mkdir(parents=True)
        path.write_text(text, encoding="utf-8")
        return path

    def test_a_fulltext_saved_by_hand_is_recorded_and_never_overwritten_even_with_force(self) -> None:
        hand = self.hand_save("alpha-1", "fulltext.md", "Curated by a person. 14 events.")
        with FakeServer({"/a.pdf": serve(200, PDF)}) as server:
            write_plugin(self.plugins, "sources", "one.py", source_text("one", {"alpha-1": server.base + "/a.pdf"}))
            write_plugin(self.plugins, "converters", "text.py", converter_text("text", OK_CONVERTER))
            self.fetch("--only", "alpha-1")
            self.fetch("--only", "alpha-1", "--force")
            self.assertEqual(server.requests, [])
        self.assertEqual(hand.read_text(), "Curated by a person. 14 events.")
        row = latest(read_rows(self.layout.ledger))[("alpha-1", FETCH)]
        self.assertEqual((row.state, row.source), ("converted", "hand"))

    def test_another_checker_file_saved_by_hand_blocks_the_tool_from_adding_a_second(self) -> None:
        self.hand_save("alpha-1", "page.html", "<html>the paper</html>")
        with FakeServer({"/a.pdf": serve(200, PDF)}) as server:
            write_plugin(self.plugins, "sources", "one.py", source_text("one", {"alpha-1": server.base + "/a.pdf"}))
            write_plugin(self.plugins, "converters", "text.py", converter_text("text", OK_CONVERTER))
            self.fetch("--only", "alpha-1", "--force")
        self.assertEqual(self.checker_files("alpha-1"), ["page.html"])

    def test_a_tool_written_file_that_a_person_then_edits_becomes_theirs(self) -> None:
        with FakeServer({"/a.pdf": serve(200, PDF)}) as server:
            write_plugin(self.plugins, "sources", "one.py", source_text("one", {"alpha-1": server.base + "/a.pdf"}))
            write_plugin(self.plugins, "converters", "text.py", converter_text("text", OK_CONVERTER))
            self.fetch("--only", "alpha-1")
            self.layout.fulltext("alpha-1").write_text("Corrected by hand.", encoding="utf-8")
            self.fetch("--only", "alpha-1", "--force")
        self.assertEqual(self.layout.fulltext("alpha-1").read_text(), "Corrected by hand.")


class InboxTests(FetchCase):
    def test_a_pdf_in_the_inbox_is_used_without_any_source_request(self) -> None:
        inbox = self.layout.inbox("alpha-1")
        inbox.parent.mkdir(parents=True)
        inbox.write_bytes(PDF)
        write_plugin(self.plugins, "converters", "text.py", converter_text("text", OK_CONVERTER))
        run = self.fetch("--only", "alpha-1")
        self.assertEqual(run.code, 0, run.err)
        self.assertEqual(self.states(), {"alpha-1": "converted"})
        row = [r for r in read_rows(self.layout.ledger) if r.state == "fetched"][0]
        self.assertEqual(row.source, "inbox")
        self.assertEqual(inbox.read_bytes(), PDF)  # the inbox file is only read

    def test_the_manifests_save_as_path_is_an_inbox_and_text_there_becomes_fulltext(self) -> None:
        manifest = write_manifest(
            self.base, [{"key": "alpha-1", "doi": "10.1/a", "save_as": "data/raw/papers/alpha-1.md"}]
        )
        saved = self.root / "data/raw/papers/alpha-1.md"
        saved.parent.mkdir(parents=True)
        saved.write_text("Table 3. Events 14 of 100.", encoding="utf-8")
        run = self.fetch(manifest=manifest)
        self.assertEqual(run.code, 0, run.err)
        self.assertEqual(self.layout.fulltext("alpha-1").read_text(), "Table 3. Events 14 of 100.")
        row = latest(read_rows(self.layout.ledger))[("alpha-1", FETCH)]
        self.assertEqual((row.state, row.source), ("converted", "inbox"))
        self.assertEqual(self.checker_files("alpha-1"), ["fulltext.md"])

    def test_a_save_as_path_that_leaves_the_project_is_a_usage_error(self) -> None:
        manifest = write_manifest(self.base, [{"key": "alpha-1", "doi": "10.1/a", "save_as": "../../etc/passwd"}])
        run = self.fetch(manifest=manifest)
        self.assertEqual(run.code, 2)
        self.assertIn("leaves the project", run.err[0])

    def test_an_inbox_file_that_is_not_a_pdf_is_left_in_place_and_named(self) -> None:
        inbox = self.layout.inbox("alpha-1")
        inbox.parent.mkdir(parents=True)
        inbox.write_text("this is a web page, not a PDF " * 100)
        run = self.fetch("--only", "alpha-1")
        self.assertEqual(self.states(), {"alpha-1": "failed"})
        self.assertTrue(inbox.exists())
        self.assertTrue(any(str(inbox) in line for line in run.out))

    def test_with_no_source_and_no_inbox_the_paper_awaits_the_inbox_file(self) -> None:
        run = self.fetch("--only", "alpha-1")
        self.assertEqual(self.states(), {"alpha-1": "awaiting-inbox"})
        self.assertTrue(any("data/raw/papers/alpha-1.pdf" in line for line in run.out))


class DryRunTests(FetchCase):
    def test_a_dry_run_prints_what_the_sources_offer_and_writes_nothing(self) -> None:
        with FakeServer({"/a.pdf": serve(200, PDF)}) as server:
            write_plugin(self.plugins, "sources", "one.py", source_text("one", {"alpha-1": server.base + "/a.pdf"}))
            before = tree(self.root)
            run = self.fetch("--dry-run")
            self.assertEqual(server.requests, [])  # the source returned addresses; nothing was downloaded
        self.assertEqual(tree(self.root), before)
        self.assertTrue(any(line.startswith("  candidate pdf") and "/a.pdf" in line for line in run.out))
        self.assertEqual(run.code, 0)

    def test_a_dry_run_cannot_write_through_its_client(self) -> None:
        body = textwrap.dedent("""
            NAME = 'writer'
            def locate(paper, http):
                http.request('POST', 'http://127.0.0.1:9/x', body=b'{}')
                return []
        """)
        write_plugin(self.plugins, "sources", "w.py", body)
        run = self.fetch("--dry-run", "--only", "alpha-1")
        self.assertTrue(any("read-only" in line for line in run.out))


class RunLimitTests(FetchCase):
    def test_the_host_cap_stops_the_run_and_leaves_later_papers_untouched(self) -> None:
        keys = [f"p-{n:02d}" for n in range(30)]
        manifest = write_manifest(self.base, [{"key": key, "doi": f"10.1/{key}"} for key in keys])
        routes = {f"/{key}.pdf": serve(200, PDF) for key in keys}
        with FakeServer(routes) as server:
            urls = {key: f"{server.base}/{key}.pdf" for key in keys}
            write_plugin(self.plugins, "sources", "one.py", source_text("one", urls))
            run = self.fetch(manifest=manifest)
            self.assertEqual(len(server.requests), 25)
        self.assertEqual(run.code, 3)
        self.assertTrue(any("25" in line and "cap" in line for line in run.out))
        states = self.states()
        self.assertEqual(len(states), 25)
        self.assertNotIn("p-25", states)
        self.assertEqual(run.out[-2:][0].startswith("! stopped"), True)

    def test_limit_stops_after_that_many_papers_reach_a_source(self) -> None:
        routes = {f"/{key}.pdf": serve(200, PDF) for key in KEYS}
        with FakeServer(routes) as server:
            urls = {key: f"{server.base}/{key}.pdf" for key in KEYS}
            write_plugin(self.plugins, "sources", "one.py", source_text("one", urls))
            run = self.fetch("--limit", "2")
        self.assertEqual(sorted(self.states()), ["alpha-1", "beta-2"])
        self.assertTrue(any("limit of 2 reached" in line for line in run.out))

    def test_a_second_run_is_refused_while_the_first_holds_the_ledger(self) -> None:
        with Ledger.locked(self.layout.ledger, lambda: "t", {}):
            run = self.fetch()
        self.assertEqual(run.code, 4)
        self.assertIn("papers_ledger.csv", run.err[0])


class SecretTests(FetchCase):
    def test_a_credential_in_a_candidate_address_never_reaches_output_or_the_ledger(self) -> None:
        with FakeServer({"/a.pdf": serve(404, b"gone")}) as server:
            url = f"{server.base}/a.pdf?api_key=SUPERSECRET123&page=2"
            write_plugin(self.plugins, "sources", "one.py", source_text("one", {"alpha-1": url}))
            run = self.fetch("--only", "alpha-1")
        everything = "\n".join(run.out + run.err) + self.layout.ledger.read_text()
        self.assertNotIn("SUPERSECRET123", everything)
        self.assertIn("page=2", everything)


if __name__ == "__main__":
    unittest.main()
