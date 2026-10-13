#!/usr/bin/env python3
"""Warn when the root AGENTS.md grows past its byte budget.

Every session of every host loads the root contract verbatim, so each byte is
paid on every turn. Codex reads instruction files only up to 32 KiB, counted
from the root down to its working folder, and drops the rest without a word,
so a Codex session in a deeply nested folder loses the end of its nearest
AGENTS.md first. Growth past the budget is a decision the warning puts in
front of the author, not a failure (decision `contract-size-warns-not-fails`);
under GitHub Actions the warning is an annotation on the run, where a green
step's log would hide it.
"""

from pathlib import Path
import os
import sys

BUDGET = 24_000
CODEX_LIMIT = 32 * 1024
ROOT = Path(__file__).resolve().parent.parent / "AGENTS.md"


def main() -> int:
    size = len(ROOT.read_bytes())
    if size > BUDGET:
        message = (
            f"AGENTS.md is {size} bytes, over the {BUDGET}-byte budget. "
            f"Codex stops reading instruction files at {CODEX_LIMIT} bytes, counted from the root "
            "down to its working folder, and drops the rest silently; move situational detail "
            "into a playbook the root points to."
        )
        if os.environ.get("GITHUB_ACTIONS") == "true":
            print(f"::warning file=AGENTS.md::{message}")
        print(f"lint-contract: warning: {message}", file=sys.stderr)
        return 0
    print(f"lint-contract: AGENTS.md {size}/{BUDGET} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
