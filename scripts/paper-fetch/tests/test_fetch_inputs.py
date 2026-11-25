"""Fetch: files saved by hand, the inbox, the dry run, limits, secrets, the project folder."""

from __future__ import annotations

import contextlib
import textwrap
import unittest
from pathlib import Path

from fetchcase import KEYS, OK_CONVERTER, FetchCase, converter_text, source_text
from helpers import PDF, FakeServer, run_cli, serve, tree, write_manifest, write_plugin

from paperfetch.ledger import FETCH, Ledger, latest, read_rows
from paperfetch.transport import urllib_transport


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

    def test_no_plugin_may_take_a_name_the_ledger_reads_as_a_person_or_the_inbox(self) -> None:
        for name in ("hand", "inbox"):
            with self.subTest(name=name):
                write_plugin(self.plugins, "sources", "x.py", source_text(name, {}))
                run = self.fetch()
                self.assertEqual(run.code, 2)
                self.assertIn("reserved", run.err[0])


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

    def test_the_readme_command_with_a_relative_root_and_a_save_as_column_reaches_awaiting_inbox(self) -> None:
        manifest = write_manifest(
            self.base, [{"key": key, "doi": f"10.1/{key}", "save_as": f"data/raw/papers/{key}.md"} for key in KEYS]
        )
        argv = ["fetch", "--manifest", str(manifest), "--root", ".", "--plugins", str(self.plugins),
                "--delay-ms", "0", "--jitter-ms", "0"]
        with contextlib.chdir(self.root):
            run = run_cli(argv, self.plugins, transport=urllib_transport)
        self.assertEqual(run.code, 0, run.err)
        self.assertEqual(set(self.states().values()), {"awaiting-inbox"})
        self.assertEqual(len(self.states()), 3)

    def test_a_project_folder_reached_through_a_symlink_works_the_same(self) -> None:
        link = self.base / "link"
        link.symlink_to(self.root, target_is_directory=True)
        manifest = write_manifest(self.base, [{"key": "alpha-1", "doi": "10.1/a", "save_as": "data/raw/papers/alpha-1.md"}])
        argv = ["fetch", "--manifest", str(manifest), "--root", str(link), "--plugins", str(self.plugins),
                "--delay-ms", "0", "--jitter-ms", "0"]
        run = run_cli(argv, self.plugins, transport=urllib_transport)
        self.assertEqual(run.code, 0, run.err)
        self.assertEqual(self.states(), {"alpha-1": "awaiting-inbox"})


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

    def test_a_dry_run_honours_limit_and_skips_hand_saved_and_inbox_papers(self) -> None:
        hand = self.layout.paper_dir("alpha-1") / "fulltext.md"
        hand.parent.mkdir(parents=True)
        hand.write_text("by hand")
        inbox = self.layout.inbox("beta-2")
        inbox.parent.mkdir(parents=True)
        inbox.write_bytes(PDF)
        asked: list[str] = []
        with FakeServer({}) as server:
            body = textwrap.dedent(f"""
                from pathlib import Path
                NAME = 'spy'
                def locate(paper, http):
                    Path({str(self.base / 'asked.txt')!r}).open('a').write(paper.key + '\\n')
                    return []
            """)
            write_plugin(self.plugins, "sources", "spy.py", body)
            gamma = write_manifest(self.base, [{"key": key, "doi": f"10.1/{key}"} for key in ("alpha-1", "beta-2", "gamma-3", "delta-4")])
            run = self.fetch("--dry-run", "--limit", "1", manifest=gamma)
        asked = (self.base / "asked.txt").read_text().split()
        self.assertEqual(asked, ["gamma-3"])
        self.assertTrue(any("alpha-1" in line and "saved by hand" in line for line in run.out))
        self.assertTrue(any("inbox file present" in line for line in run.out))
        self.assertTrue(any("limit of 1 reached" in line for line in run.out))


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
        self.assertTrue(run.out[-2].startswith("! stopped"))
        self.assertTrue(run.out[-1].startswith("stopped early: fetched 25"))

    def test_limit_stops_after_that_many_papers_reach_a_source(self) -> None:
        routes = {f"/{key}.pdf": serve(200, PDF) for key in KEYS}
        with FakeServer(routes) as server:
            urls = {key: f"{server.base}/{key}.pdf" for key in KEYS}
            write_plugin(self.plugins, "sources", "one.py", source_text("one", urls))
            run = self.fetch("--limit", "2")
        self.assertEqual(sorted(self.states()), ["alpha-1", "beta-2"])
        self.assertTrue(any("limit of 2 reached" in line for line in run.out))

    def test_a_paper_served_from_the_inbox_does_not_use_up_the_limit(self) -> None:
        inbox = self.layout.inbox("alpha-1")
        inbox.parent.mkdir(parents=True)
        inbox.write_bytes(PDF)
        routes = {f"/{key}.pdf": serve(200, PDF) for key in KEYS}
        with FakeServer(routes) as server:
            urls = {key: f"{server.base}/{key}.pdf" for key in KEYS}
            write_plugin(self.plugins, "sources", "one.py", source_text("one", urls))
            self.fetch("--limit", "1")
        self.assertEqual(self.states(), {"alpha-1": "fetched", "beta-2": "fetched"})

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
