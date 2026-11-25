#!/usr/bin/env python3
"""Plain text of a saved source, for exact-quote checks.

Usage:
    python3 -I source_text.py <source file> [<regular expression>]

Without an expression the whole text is printed; with one, each match is
printed with the text around it. Saved sources are untrusted downloads, so this
module reads them as data with the standard library only and runs under `-I`.

Every kind of source becomes one line with single spaces, plain hyphens and
plain quotation marks, so a quote compares character for character:

    fulltext.md, *.txt             the text
    page.html, *.xml               the text between the tags, without scripts and style sheets
    *.json                         the string values, in file order

A source is a file, or a folder that holds exactly one of SOURCE_FILES.
"""

from __future__ import annotations

import json
import re
import sys
import unicodedata
from html.parser import HTMLParser
from pathlib import Path

SOURCE_FILES = ("fulltext.md", "fulltext.xml", "article.xml", "page.html", "record.json", "study.json")
SKIPPED_ELEMENTS = {"script", "style", "noscript", "template"}
# NFKC folds ligatures, non-breaking and thin spaces and full-width forms; these are what it leaves.
PLAIN_CHARACTERS = str.maketrans({
    "​": "", "﻿": "", "­": "",
    "‐": "-", "‑": "-", "‒": "-", "–": "-", "—": "-", "−": "-",
    "‘": "'", "’": "'", "“": '"', "”": '"',
})


class SourceProblem(Exception):
    """A source that cannot be found, is ambiguous, or is of a kind this module cannot read."""


def normalize(text: str) -> str:
    """Single spaces, plain hyphens and plain quotation marks."""
    return re.sub(r"\s+", " ", unicodedata.normalize("NFKC", text).translate(PLAIN_CHARACTERS)).strip()


class _TextCollector(HTMLParser):
    """Collects the text between tags, leaving out scripts and style sheets."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self._skipping: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in SKIPPED_ELEMENTS:
            self._skipping.append(tag)
        self.parts.append(" ")

    def handle_endtag(self, tag: str) -> None:
        if self._skipping and self._skipping[-1] == tag:
            self._skipping.pop()
        self.parts.append(" ")

    def handle_data(self, data: str) -> None:
        if not self._skipping:
            self.parts.append(data)


def markup_text(raw: str) -> str:
    """The text of an HTML page or an XML article."""
    collector = _TextCollector()
    collector.feed(raw)
    collector.close()
    return normalize("".join(collector.parts))


def _string_values(node: object):
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for value in node.values():
            yield from _string_values(value)
    elif isinstance(node, list):
        for value in node:
            yield from _string_values(value)


def json_text(raw: str) -> str:
    """Every string value of a JSON document, markup removed, in file order."""
    return markup_text(" ".join(_string_values(json.loads(raw))))


def source_file(directory: Path, source: str) -> Path:
    """The one file that holds the text of `source`: `directory/source` itself, or the only
    SOURCE_FILES entry of the folder `directory/source`."""
    root = directory.resolve()
    candidate = (root / source).resolve()
    if not candidate.is_relative_to(root):
        raise SourceProblem(f"source {source!r} is outside the sources folder")
    if candidate.is_file():
        return candidate
    if not candidate.is_dir():
        raise SourceProblem(f"no source named {source!r} in {directory}")
    found = [candidate / name for name in SOURCE_FILES if (candidate / name).is_file()]
    if len(found) > 1:
        raise SourceProblem(f"source {source!r} holds two text files, {' and '.join(path.name for path in found)}; keep one")
    if not found:
        raise SourceProblem(f"source {source!r} holds none of {', '.join(SOURCE_FILES)}; convert a PDF to text first")
    if not found[0].resolve().is_relative_to(root):
        raise SourceProblem(f"source {source!r}: {found[0].name} points outside the sources folder")
    return found[0]


def source_text(path: Path) -> str:
    """The normalized text of one saved source file."""
    if path.suffix == ".pdf":
        raise SourceProblem(f"{path.name} is a PDF; convert it to text first")
    raw = path.read_text(encoding="utf-8", errors="replace")
    if path.suffix == ".json":
        return json_text(raw)
    if path.suffix in (".html", ".htm", ".xml"):
        return markup_text(raw)
    if path.suffix in (".md", ".txt"):
        return normalize(raw)
    raise SourceProblem(f"{path.name}: no text reader for this kind of file")


def main(argv: list[str]) -> None:
    if len(argv) not in (2, 3):
        sys.exit(__doc__)
    text = source_text(Path(argv[1]))
    if len(argv) == 2:
        print(text)
        return
    matches = list(re.finditer(argv[2], text))
    for match in matches:
        start, end = max(0, match.start() - 220), min(len(text), match.end() + 420)
        print(f"@{match.start()}: ...{text[start:end]}...\n")
    print(f"{len(matches)} matches in {len(text)} characters")


if __name__ == "__main__":
    main(sys.argv)
