"""Every path the tool reads or writes, in one place.

The tool writes only under `data/external/paper-<key>/` and to the ledger beside
those folders. It reads the inbox and never changes it.
"""

from __future__ import annotations

import os
import tempfile
from dataclasses import dataclass
from pathlib import Path

from .model import Paper

# The project's quote checker takes exactly one of these per paper folder.
CHECKER_NAMES = (
    "page.html",
    "fulltext.xml",
    "fulltext.md",
    "article.xml",
    "record.json",
    "study.json",
)
INBOX_DIR = Path("data/raw/papers")


class LayoutError(ValueError):
    """A path the manifest names would leave the project."""


@dataclass(frozen=True)
class Layout:
    root: Path

    @property
    def external(self) -> Path:
        return self.root / "data" / "external"

    @property
    def ledger(self) -> Path:
        return self.external / "papers_ledger.csv"

    def paper_dir(self, key: str) -> Path:
        return self.external / f"paper-{key}"

    def original(self, key: str, extension: str) -> Path:
        return self.paper_dir(key) / f"original.{extension}"

    def originals(self, key: str) -> list[Path]:
        folder = self.paper_dir(key)
        return sorted(folder.glob("original.*")) if folder.is_dir() else []

    def fulltext(self, key: str) -> Path:
        return self.paper_dir(key) / "fulltext.md"

    def inbox(self, key: str) -> Path:
        return self.root / INBOX_DIR / f"{key}.pdf"

    def inbox_paths(self, paper: Paper) -> list[Path]:
        """The files an operator may have saved by hand for this paper."""
        paths = [self.inbox(paper.key)]
        save_as = paper.row.get("save_as", "").strip()
        if save_as:
            target = (self.root / save_as).resolve()
            if not target.is_relative_to(self.root.resolve()):
                raise LayoutError(f"{paper.key}: save_as {save_as!r} leaves the project")
            paths.append(target)
        return paths


def write_atomic(path: Path, data: bytes) -> None:
    """Write beside the target and rename, so a killed run leaves no half file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".part")
    try:
        with os.fdopen(handle, "wb") as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise
