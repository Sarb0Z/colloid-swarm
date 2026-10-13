#!/usr/bin/env python3
"""Warn when the root AGENTS.md grows past its byte budget.

Every session of every host loads the root contract verbatim, so each byte is
paid on every turn. Codex reads instruction files only up to 32 KiB, counted
from the root down to its working folder, and drops the rest without a word:
past about 22,500 root bytes, a Codex session in the deepest skill loses the
end of its nested AGENTS.md. Growth past the budget is therefore a decision
the warning puts in front of the author, not a failure (decision
`contract-size-warns-not-fails`).
"""

from pathlib import Path
import sys

BUDGET = 24_000
CODEX_LIMIT = 32 * 1024
ROOT = Path(__file__).resolve().parent.parent / "AGENTS.md"


def main() -> int:
    size = len(ROOT.read_bytes())
    if size > BUDGET:
        print(
            f"lint-contract: warning: AGENTS.md is {size} bytes, over the {BUDGET}-byte budget. "
            f"Codex stops reading instruction files at {CODEX_LIMIT} bytes, counted from the root "
            "down to its working folder, and drops the rest silently; move situational detail "
            "into a playbook the root points to.",
            file=sys.stderr,
        )
        return 0
    print(f"lint-contract: AGENTS.md {size}/{BUDGET} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
