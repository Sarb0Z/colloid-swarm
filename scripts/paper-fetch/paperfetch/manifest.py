"""Read the CSV that lists the papers."""

from __future__ import annotations

import csv
import re
from pathlib import Path

from .model import Paper

# The key names a folder, so it must not be able to name a path.
KEY = re.compile(r"[a-z0-9][a-z0-9-]*")
REQUIRED_COLUMNS = ("key", "doi")


class ManifestError(ValueError):
    """The manifest cannot be read or holds a row the tool cannot act on."""


def select(papers: list[Paper], only: frozenset[str] | None) -> list[Paper]:
    """The papers `--only` names, or all of them."""
    return [paper for paper in papers if only is None or paper.key in only]


def read_manifest(path: Path) -> list[Paper]:
    if not path.is_file():
        raise ManifestError(f"{path}: no such file")
    with path.open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        missing = [name for name in REQUIRED_COLUMNS if name not in (reader.fieldnames or [])]
        if missing:
            raise ManifestError(f"{path}: missing column {', '.join(missing)}")
        papers: list[Paper] = []
        problems: list[str] = []
        first_row: dict[str, int] = {}
        for number, row in enumerate(reader, start=2):  # row 1 is the header
            cells = {name: (value or "") for name, value in row.items() if name is not None}
            key, doi = cells["key"].strip(), cells["doi"].strip()
            if not KEY.fullmatch(key):
                problems.append(f"row {number}: key {key!r} must match [a-z0-9][a-z0-9-]*")
            elif key in first_row:
                problems.append(f"row {number}: key {key!r} repeats row {first_row[key]}")
            else:
                first_row[key] = number
            if not doi:
                problems.append(f"row {number}: empty doi")
            papers.append(Paper(key=key, doi=doi, row=cells))
    if problems:
        raise ManifestError(f"{path}: " + "; ".join(problems))
    return papers
