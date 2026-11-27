#!/usr/bin/env python3
"""Name each memory file Claude Code loads into every session that is over the size cap.

Claude Code reads `CLAUDE.local.md` in the session's folder and every
`CLAUDE.md` and `CLAUDE.local.md` in the folders above it, in full, before any
work. A file git tracks is a contract with its own size check
(lint-contract.py) — the checkout's own `CLAUDE.md` seen from a nested
worktree, or an enclosing checkout's — so it is skipped; the untracked notes
have no check and only grow. Folders at or above the home folder are not
checked: a file there is the operator's machine-wide memory, not a product's.

Usage: memory_size.py <session folder> <home>
Prints one `<shown path>\t<KB, rounded up>` line per file over the cap, nearest first.
"""

import math
import subprocess
import sys
from pathlib import Path

CAP_BYTES = 8192
ABOVE = ("CLAUDE.md", "CLAUDE.local.md")


def oversized(repo: Path, home: Path, size_of, tracked) -> list[tuple[Path, int]]:
    """(path, bytes) for each untracked loaded memory file over the cap; `size_of` returns None for a missing file."""
    candidates = [repo / "CLAUDE.local.md"]
    folder = repo.parent
    while home in folder.parents:
        candidates += [folder / name for name in ABOVE]
        folder = folder.parent
    found = [(path, size_of(path)) for path in candidates]
    return [
        (path, size)
        for path, size in found
        if size is not None and size > CAP_BYTES and not tracked(path)
    ]


def shown(path: Path, home: Path) -> str:
    return f"~/{path.relative_to(home)}" if home in path.parents else str(path)


def file_size(path: Path):
    return path.stat().st_size if path.is_file() else None


def git_tracks(path: Path) -> bool:
    # Exit 1 both for an untracked file and for a folder outside any repository.
    result = subprocess.run(
        ["git", "-C", str(path.parent), "ls-files", "--error-unmatch", "--", path.name],
        capture_output=True,
    )
    return result.returncode == 0


def main(argv) -> int:
    # Both resolved, so a symlinked home or temporary folder still compares as an ancestor.
    repo, home = Path(argv[0]).resolve(), Path(argv[1]).resolve()
    for path, size in oversized(repo, home, file_size, git_tracks):
        print(f"{shown(path, home)}\t{math.ceil(size / 1024)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
