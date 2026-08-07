#!/usr/bin/env python3
"""Render the two substrates the ratchet check reads, from a message on stdin.

Usage: ratchet-text.py

Prints the prose substrate, a line holding only the split marker, then the
ledger substrate. Both drop fenced blocks and blockquotes, because bulk
citation is never a claim either way. They differ on markdown quoting:

* prose (triggers) — inline code and quoted spans are blanked, so quoting a
  banned phrase does not read as making it.
* ledger (disarm) — the same spans are unwrapped and whitespace is flattened.
  A path is conventionally written `.agents/debt-log.md`, so blanking inline
  code would delete the evidence the disarm looks for.

Single quotes delimit neither: apostrophes would make the check
contraction-dependent, eating the span between "it's" and "I've".
"""

import re
import sys

MARKER = "---RATCHET-SPLIT---"


def main():
    body = sys.stdin.read()
    body = re.sub(r"```.*?```", " ", body, flags=re.S)
    body = re.sub(r"(?m)^\s*>.*$", " ", body)
    prose = re.sub(r"`[^`\n]*`", " ", body)
    prose = re.sub(r"\"[^\"\n]*\"|“[^”\n]*”", " ", prose)
    ledger = re.sub(r"\s+", " ", re.sub(r"[`\"“”]", " ", body))
    print(prose)
    print(MARKER)
    print(ledger)
    return 0


if __name__ == "__main__":
    sys.exit(main())
