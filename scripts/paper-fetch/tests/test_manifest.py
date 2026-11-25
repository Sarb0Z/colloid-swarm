from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from helpers import write_manifest

from paperfetch.manifest import ManifestError, read_manifest


class ManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self._scratch = tempfile.TemporaryDirectory()
        self.folder = Path(self._scratch.name)
        self.addCleanup(self._scratch.cleanup)

    def test_reads_rows_and_keeps_every_column(self) -> None:
        path = write_manifest(
            self.folder,
            [
                {"key": "sun-2010", "doi": "10.1016/j.ahj.2010.07.035", "save_as": "data/raw/papers/sun-2010.md"},
                {"key": "gao-2009", "doi": "10.1016/j.athoracsur.2009.04.024", "save_as": ""},
            ],
        )
        papers = read_manifest(path)
        self.assertEqual([paper.key for paper in papers], ["sun-2010", "gao-2009"])
        self.assertEqual(papers[0].doi, "10.1016/j.ahj.2010.07.035")
        self.assertEqual(papers[0].row["save_as"], "data/raw/papers/sun-2010.md")

    def test_key_that_names_a_path_is_refused_with_its_row(self) -> None:
        path = write_manifest(
            self.folder,
            [{"key": "ok-1", "doi": "10.1/a"}, {"key": "../escape", "doi": "10.1/b"}],
        )
        with self.assertRaises(ManifestError) as caught:
            read_manifest(path)
        self.assertIn("row 3", str(caught.exception))
        self.assertIn("../escape", str(caught.exception))

    def test_upper_case_and_slash_keys_are_refused(self) -> None:
        for key in ("Sun-2010", "a/b", "-lead", "has space", ""):
            with self.subTest(key=key):
                path = write_manifest(self.folder, [{"key": key, "doi": "10.1/a"}])
                with self.assertRaises(ManifestError):
                    read_manifest(path)

    def test_duplicate_key_names_both_rows(self) -> None:
        path = write_manifest(
            self.folder,
            [{"key": "a-1", "doi": "10.1/a"}, {"key": "b-1", "doi": "10.1/b"}, {"key": "a-1", "doi": "10.1/c"}],
        )
        with self.assertRaises(ManifestError) as caught:
            read_manifest(path)
        self.assertIn("row 4", str(caught.exception))
        self.assertIn("repeats row 2", str(caught.exception))

    def test_empty_doi_is_refused(self) -> None:
        path = write_manifest(self.folder, [{"key": "a-1", "doi": "  "}])
        with self.assertRaises(ManifestError) as caught:
            read_manifest(path)
        self.assertIn("empty doi", str(caught.exception))

    def test_missing_column_and_missing_file_are_refused(self) -> None:
        path = write_manifest(self.folder, [{"key": "a-1", "title": "x"}])
        with self.assertRaises(ManifestError) as caught:
            read_manifest(path)
        self.assertIn("missing column doi", str(caught.exception))
        with self.assertRaises(ManifestError):
            read_manifest(self.folder / "absent.csv")


if __name__ == "__main__":
    unittest.main()
