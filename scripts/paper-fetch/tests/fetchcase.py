"""A base class and plugin builders for the fetch tests."""

from __future__ import annotations

import tempfile
import textwrap
import unittest
from pathlib import Path

from helpers import run_cli, write_manifest

from paperfetch.layout import CHECKER_NAMES, Layout
from paperfetch.ledger import FETCH, latest, read_rows
from paperfetch.transport import urllib_transport

CHALLENGE = b"<html><head><title>Just a moment...</title></head><body>cf-ray</body></html>"
KEYS = ("alpha-1", "beta-2", "gamma-3")
OK_CONVERTER = 'return "TEXT of " + path.name + " " + path.read_bytes()[:8].decode()'


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
        f"def convert(paper, path, run):\n{indented}\n"
    )


class FetchCase(unittest.TestCase):
    def setUp(self) -> None:
        self._scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self._scratch.cleanup)
        self.base = Path(self._scratch.name)
        self.root = self.base / "project"
        self.root.mkdir()
        self.plugins = self.base / "plugins"
        self.plugins.mkdir()
        self.layout = Layout(self.root.resolve())
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
