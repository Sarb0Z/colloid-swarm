from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from helpers import TOOL, make_stamp, run_cli, tree, write_manifest, write_plugin

from paperfetch.layout import Layout
from paperfetch.ledger import FETCH, PUSH, Ledger

ROWS = [
    {"key": "sun-2010", "doi": "10.1016/j.ahj.2010.07.035"},
    {"key": "gao-2009", "doi": "10.1016/j.athoracsur.2009.04.024"},
    {"key": "kim-2023", "doi": "10.1016/j.athoracsur.2022.10.040"},
]


class StatusTests(unittest.TestCase):
    def setUp(self) -> None:
        self._scratch = tempfile.TemporaryDirectory()
        self.base = Path(self._scratch.name)
        self.root = self.base / "project"
        self.root.mkdir()
        self.plugins = self.base / "plugins"
        self.plugins.mkdir()
        self.manifest = write_manifest(self.base, ROWS)
        self.addCleanup(self._scratch.cleanup)

    def status(self):
        return run_cli(["status", "--manifest", str(self.manifest), "--root", str(self.root)], self.plugins)

    def test_with_no_ledger_every_paper_is_pending_and_nothing_is_written(self) -> None:
        before = tree(self.root)
        run = self.status()
        self.assertEqual(run.code, 0)
        self.assertEqual(run.out[-1], "3 papers: pending 3")
        self.assertEqual(len(run.out), 4)
        self.assertEqual(tree(self.root), before)

    def test_states_notes_and_summary_come_from_the_ledger(self) -> None:
        layout = Layout(self.root)
        with Ledger.locked(layout.ledger, make_stamp(), {}) as ledger:
            ledger.append(key="sun-2010", doi="d", stage=FETCH, state="converted", source="inbox")
            ledger.append(key="sun-2010", doi="d", stage=PUSH, state="pushed")
            ledger.append(key="gao-2009", doi="d", stage=FETCH, state="awaiting-inbox")
        run = self.status()
        self.assertEqual(run.code, 0)
        lines = {line.split()[0]: line for line in run.out[:-1]}
        self.assertIn("converted", lines["sun-2010"])
        self.assertIn("pushed", lines["sun-2010"])
        self.assertIn("inbox: data/raw/papers/gao-2009.pdf", lines["gao-2009"])
        self.assertIn("pending", lines["kim-2023"])
        self.assertEqual(run.out[-1], "3 papers: pending 1, converted 1, awaiting-inbox 1")

    def test_bad_project_folder_and_bad_manifest_exit_2_with_a_message(self) -> None:
        run = run_cli(["status", "--manifest", str(self.manifest), "--root", str(self.base / "nope")], self.plugins)
        self.assertEqual(run.code, 2)
        self.assertIn("no such project folder", run.err[0])
        run = run_cli(["status", "--manifest", str(self.base / "absent.csv"), "--root", str(self.root)], self.plugins)
        self.assertEqual(run.code, 2)

    def test_sources_lists_plugins_and_reports_an_empty_folder(self) -> None:
        run = run_cli(["sources", "--plugins", str(self.plugins)], self.plugins)
        self.assertEqual(run.code, 0)
        self.assertEqual(run.out, [f"no plugins loaded from {self.plugins}"])
        write_plugin(self.plugins, "sources", "fake.py", "NAME = 'fake'\n\ndef locate(paper, http):\n    return []\n")
        run = run_cli(["sources", "--plugins", str(self.plugins)], self.plugins)
        self.assertEqual(len(run.out), 1)
        self.assertTrue(run.out[0].startswith("source"))
        self.assertIn("fake", run.out[0])

    def test_a_broken_plugin_exits_2_and_names_the_file(self) -> None:
        path = write_plugin(self.plugins, "sources", "bad.py", "def locate(paper, http):\n    return []\n")
        run = run_cli(["sources", "--plugins", str(self.plugins)], self.plugins)
        self.assertEqual(run.code, 2)
        self.assertIn(str(path), run.err[0])


class EntryPointTests(unittest.TestCase):
    """The real entry point under `python3 -I`, which drops the script folder from the path."""

    def test_isolated_python_runs_status_and_sources(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            base = Path(scratch)
            project = base / "project"
            project.mkdir()
            manifest = write_manifest(base, ROWS)
            status = subprocess.run(
                [sys.executable, "-I", str(TOOL / "papers.py"), "status",
                 "--manifest", str(manifest), "--root", str(project)],
                capture_output=True, text=True, cwd=base, check=False,
            )
            self.assertEqual(status.returncode, 0, status.stderr)
            self.assertIn("3 papers: pending 3", status.stdout)
            sources = subprocess.run(
                [sys.executable, "-I", str(TOOL / "papers.py"), "sources"],
                capture_output=True, text=True, cwd=base, check=False,
            )
            self.assertEqual(sources.returncode, 0, sources.stderr)

    def test_usage_error_exits_2(self) -> None:
        run = subprocess.run(
            [sys.executable, "-I", str(TOOL / "papers.py"), "status"],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(run.returncode, 2)


if __name__ == "__main__":
    unittest.main()
