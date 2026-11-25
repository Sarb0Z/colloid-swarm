from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from helpers import write_plugin

from paperfetch.plugins import PluginError, load_plugins

SOURCE = "NAME = 'fake'\n\ndef locate(paper, http):\n    return []\n"
CONVERTER = "NAME = 'fake-pdf'\nACCEPTS = ('pdf',)\n\ndef convert(path, run):\n    return 'text'\n"
SINK = "NAME = 'fake-sink'\n\ndef plan(paper, folder, http):\n    return []\n\ndef push(paper, folder, http):\n    return {}\n"


class PluginTests(unittest.TestCase):
    def setUp(self) -> None:
        self._scratch = tempfile.TemporaryDirectory()
        self.folder = Path(self._scratch.name)
        self.addCleanup(self._scratch.cleanup)

    def test_loads_each_kind_by_name(self) -> None:
        write_plugin(self.folder, "sources", "fake.py", SOURCE)
        write_plugin(self.folder, "converters", "fake_pdf.py", CONVERTER)
        write_plugin(self.folder, "sinks", "fake_sink.py", SINK)
        plugins = load_plugins(self.folder)
        self.assertEqual(list(plugins.of("sources")), ["fake"])
        self.assertEqual(list(plugins.of("converters")), ["fake-pdf"])
        self.assertEqual(list(plugins.of("sinks")), ["fake-sink"])

    def test_a_folder_with_no_plugins_loads_empty(self) -> None:
        plugins = load_plugins(self.folder)
        self.assertEqual({kind: list(found) for kind, found in plugins.by_kind.items()},
                         {"sources": [], "converters": [], "sinks": []})

    def test_underscore_files_are_templates_and_never_loaded(self) -> None:
        write_plugin(self.folder, "sources", "_template.py", "raise RuntimeError('must not run')\n")
        self.assertEqual(list(load_plugins(self.folder).of("sources")), [])

    def test_missing_name_stops_the_load_and_names_the_file(self) -> None:
        path = write_plugin(self.folder, "sources", "noname.py", "def locate(paper, http):\n    return []\n")
        with self.assertRaises(PluginError) as caught:
            load_plugins(self.folder)
        self.assertIn(str(path), str(caught.exception))
        self.assertIn("NAME", str(caught.exception))

    def test_missing_function_stops_the_load_and_names_the_file(self) -> None:
        path = write_plugin(self.folder, "sinks", "half.py", "NAME = 'half'\n\ndef plan(paper, folder, http):\n    return []\n")
        with self.assertRaises(PluginError) as caught:
            load_plugins(self.folder)
        self.assertIn(str(path), str(caught.exception))
        self.assertIn("push", str(caught.exception))

    def test_two_plugins_of_one_kind_may_not_share_a_name(self) -> None:
        write_plugin(self.folder, "sources", "one.py", SOURCE)
        second = write_plugin(self.folder, "sources", "two.py", SOURCE)
        with self.assertRaises(PluginError) as caught:
            load_plugins(self.folder)
        self.assertIn(str(second), str(caught.exception))

    def test_converter_accepts_must_come_from_the_known_kinds(self) -> None:
        write_plugin(self.folder, "converters", "bad.py", "NAME = 'bad'\nACCEPTS = ('docx',)\n\ndef convert(path, run):\n    return ''\n")
        with self.assertRaises(PluginError) as caught:
            load_plugins(self.folder)
        self.assertIn("ACCEPTS", str(caught.exception))

    def test_a_plugin_that_raises_on_import_is_reported_not_skipped(self) -> None:
        path = write_plugin(self.folder, "sources", "boom.py", "raise ValueError('nope')\n")
        with self.assertRaises(PluginError) as caught:
            load_plugins(self.folder)
        self.assertIn(str(path), str(caught.exception))
        self.assertIn("nope", str(caught.exception))

    def test_host_interval_and_cap_declarations_are_checked(self) -> None:
        write_plugin(self.folder, "sources", "ok.py", SOURCE + "HOST_INTERVALS_MS = {'export.arxiv.org': 3000}\n")
        load_plugins(self.folder)
        write_plugin(self.folder, "sources", "ok.py", SOURCE + "HOST_INTERVALS_MS = {'export.arxiv.org': 0}\n")
        with self.assertRaises(PluginError):
            load_plugins(self.folder)
        write_plugin(self.folder, "sources", "ok.py", SOURCE + "MAX_REQUESTS_PER_HOST = 0\n")
        with self.assertRaises(PluginError):
            load_plugins(self.folder)

    def test_missing_plugin_folder_is_an_error(self) -> None:
        with self.assertRaises(PluginError):
            load_plugins(self.folder / "absent")


if __name__ == "__main__":
    unittest.main()
