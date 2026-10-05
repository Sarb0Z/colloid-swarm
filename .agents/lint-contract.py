#!/usr/bin/env python3
"""Hold the root AGENTS.md under a byte budget.

Every session of every host loads the root contract verbatim, so each byte is
paid on every turn. Situational detail belongs in a playbook the root points
to; this check makes growth a decision rather than drift. Raise LIMIT only with
the reason in the commit that raises it.
"""

from pathlib import Path
import sys

LIMIT = 18_800  # measured 17,056 bytes on 2026-10-05, plus 10% headroom
ROOT = Path(__file__).resolve().parent.parent / "AGENTS.md"


def main() -> int:
    size = len(ROOT.read_bytes())
    if size > LIMIT:
        print(
            f"lint-contract: AGENTS.md is {size} bytes, over the {LIMIT}-byte budget; "
            "move situational detail into a playbook the root points to",
            file=sys.stderr,
        )
        return 1
    print(f"lint-contract: AGENTS.md {size}/{LIMIT} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
