#!/usr/bin/env python3
"""Name each memory file Claude Code loads into every session that is over the size cap.

Claude Code reads `CLAUDE.local.md` at the repository's root and every
`CLAUDE.md` and `CLAUDE.local.md` in the folders above it, in full, before any
work. The repository's tracked `CLAUDE.md` has its own size check
(lint-contract.py); these files have none and only grow. Folders at or above
the home folder are not checked: a file there is the operator's machine-wide
memory, not a product's.

Usage: memory_size.py <repository> <home>
Prints one `<shown path>\t<KB, rounded up>` line per file over the cap, nearest first.
"""

import math
import sys
from pathlib import Path

CAP_BYTES = 8192
ABOVE = ("CLAUDE.md", "CLAUDE.local.md")


def oversized(repo: Path, home: Path, size_of) -> list[tuple[Path, int]]:
    """(path, bytes) for each loaded memory file over the cap; `size_of` returns None for a missing file."""
    candidates = [repo / "CLAUDE.local.md"]
    folder = repo.parent
    while home in folder.parents:
        candidates += [folder / name for name in ABOVE]
        folder = folder.parent
    found = [(path, size_of(path)) for path in candidates]
    return [(path, size) for path, size in found if size is not None and size > CAP_BYTES]


def shown(path: Path, home: Path) -> str:
    return f"~/{path.relative_to(home)}" if home in path.parents else str(path)


def file_size(path: Path):
    return path.stat().st_size if path.is_file() else None


def main(argv) -> int:
    # Absolute, not resolved: the notice names a file the way the session's folder names it.
    repo, home = Path(argv[0]).absolute(), Path(argv[1]).absolute()
    for path, size in oversized(repo, home, file_size):
        print(f"{shown(path, home)}\t{math.ceil(size / 1024)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
