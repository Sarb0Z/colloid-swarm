"""The ledger: the tool's only memory.

One CSV file, append-only. Each paper has two stages, `fetch` and `push`, and the
latest row for a key and stage is that stage's state. A run holds an exclusive
lock on the file, so two runs never download the same key or double the request
rate to one host. Each row goes out in one `write`, so a reader never sees half
a row.
"""

from __future__ import annotations

import contextlib
import csv
import fcntl
import io
import os
import re
from collections.abc import Callable, Generator, Mapping
from dataclasses import astuple, dataclass
from pathlib import Path

from .scrub import scrub

COLUMNS = (
    "at",
    "key",
    "doi",
    "stage",
    "state",
    "source",
    "url",
    "sha256",
    "bytes",
    "external_ids",
    "detail",
)
FETCH = "fetch"
PUSH = "push"
MAX_DETAIL = 500


class LedgerError(Exception):
    """The ledger file cannot be read or written."""


class LedgerLocked(LedgerError):
    """Another run holds the ledger lock."""


@dataclass(frozen=True)
class Row:
    at: str
    key: str
    doi: str
    stage: str
    state: str
    source: str
    url: str
    sha256: str
    bytes: str
    external_ids: str
    detail: str


def read_rows(path: Path) -> list[Row]:
    if not path.exists():
        return []
    rows: list[Row] = []
    with path.open(encoding="utf-8", newline="") as handle:
        for number, cells in enumerate(csv.reader(handle), start=1):
            if not cells or tuple(cells) == COLUMNS:  # a header may sit anywhere
                continue
            if len(cells) != len(COLUMNS):
                raise LedgerError(f"{path}: row {number} has {len(cells)} fields, not {len(COLUMNS)}")
            rows.append(Row(*cells))
    return rows


def latest(rows: list[Row]) -> dict[tuple[str, str], Row]:
    """The newest row for each (key, stage)."""
    return {(row.key, row.stage): row for row in rows}


def known_hashes(rows: list[Row], key: str) -> set[str]:
    """Every SHA-256 the tool has recorded for one key."""
    return {row.sha256 for row in rows if row.key == key and row.sha256}


def _clean(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


class Ledger:
    """An open, locked ledger. Make one with `Ledger.locked`."""

    def __init__(
        self,
        path: Path,
        descriptor: int,
        stamp: Callable[[], str],
        environ: Mapping[str, str],
    ) -> None:
        self._path = path
        self._descriptor = descriptor
        self._stamp = stamp
        self._environ = environ

    @classmethod
    @contextlib.contextmanager
    def locked(
        cls, path: Path, stamp: Callable[[], str], environ: Mapping[str, str]
    ) -> Generator[Ledger]:
        path.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise LedgerLocked(f"{path}: another run holds the lock") from error
            ledger = cls(path, descriptor, stamp, environ)
            if os.fstat(descriptor).st_size == 0:
                ledger._write(COLUMNS)
            yield ledger
        finally:
            os.close(descriptor)

    def append(
        self,
        *,
        key: str,
        doi: str,
        stage: str,
        state: str,
        source: str = "",
        url: str = "",
        sha256: str = "",
        size: int = 0,
        external_ids: str = "",
        detail: str = "",
    ) -> Row:
        row = Row(
            at=self._stamp(),
            key=key,
            doi=doi,
            stage=stage,
            state=state,
            source=self._safe(source),
            url=self._safe(url),
            sha256=sha256,
            bytes=str(size) if size else "",
            external_ids=self._safe(external_ids),
            detail=self._safe(detail)[:MAX_DETAIL],
        )
        self._write(astuple(row))
        return row

    def _safe(self, text: str) -> str:
        return _clean(scrub(text, self._environ))

    def _write(self, cells: tuple[str, ...]) -> None:
        buffer = io.StringIO()
        csv.writer(buffer, lineterminator="\n").writerow(cells)
        data = buffer.getvalue().encode("utf-8")
        if os.write(self._descriptor, data) != len(data):
            raise LedgerError(f"{self._path}: a row was written in part")
