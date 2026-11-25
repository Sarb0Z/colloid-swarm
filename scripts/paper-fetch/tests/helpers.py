"""Shared fixtures for the paper-fetch tests."""

from __future__ import annotations

import csv
import itertools
import sys
from dataclasses import dataclass
from pathlib import Path

TOOL = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOL))

from paperfetch.cli import main  # noqa: E402
from paperfetch.effects import Effects  # noqa: E402


@dataclass
class Run:
    code: int
    out: list[str]
    err: list[str]


def make_stamp():
    counter = itertools.count(1)
    return lambda: f"2026-11-25T00:00:{next(counter):02d}+00:00"


def make_effects(out: list[str], err: list[str], environ: dict[str, str] | None = None) -> Effects:
    return Effects(
        out=out.append,
        err=err.append,
        environ=environ or {},
        stamp=make_stamp(),
    )


def run_cli(argv: list[str], plugins: Path, environ: dict[str, str] | None = None) -> Run:
    out: list[str] = []
    err: list[str] = []
    code = main(argv, make_effects(out, err, environ), plugins)
    return Run(code, out, err)


def write_manifest(folder: Path, rows: list[dict[str, str]]) -> Path:
    columns = list(rows[0]) if rows else ["key", "doi"]
    path = folder / "manifest.csv"
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    return path


def tree(folder: Path) -> list[str]:
    return sorted(str(path.relative_to(folder)) for path in folder.rglob("*"))


def write_plugin(folder: Path, kind: str, filename: str, body: str) -> Path:
    path = folder / kind / filename
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    return path
