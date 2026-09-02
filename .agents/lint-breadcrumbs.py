#!/usr/bin/env python3
"""Gate the shape of .agents/breadcrumbs.md.

The file is a queue, and SessionStart pastes ten of it into every session. Two
properties keep that affordable for whoever reads it next, model or person:

  - One entry, one line, opening with a bolded subject. session-start.sh emits
    each `- ` match as one item, so a wrapped entry arrives as several; and an
    entry that opens with prose has to be read in full before its topic is
    known, ten times a session.
  - A word ceiling. Over it, the note is not deferred work — it is a standing
    tradeoff (debt-log.md), an external observation (knowledge/), or a plan
    (docs/handoff/). The cap is what routes it there instead of here.

Usage: lint-breadcrumbs.py [path]
"""

import re
import sys
from pathlib import Path

MAX_WORDS = 40
SHAPE = re.compile(r"^- \*\*(?P<subject>[^*].*?)\*\* — \S")


def main():
    path = Path(sys.argv[1] if len(sys.argv) > 1 else
                Path(__file__).resolve().parent / "breadcrumbs.md")
    if not path.exists():
        return 0                      # a satellite may carry no queue yet
    lines = path.read_text().splitlines()
    entries, problems = 0, []
    for number, line in enumerate(lines, 1):
        if not line.startswith("- "):
            continue
        entries += 1
        words = len(line.split())
        if not SHAPE.match(line):
            problems.append((number, "must open `- **subject** — `", line))
        elif words > MAX_WORDS:
            problems.append((
                number,
                f"{words} words, over the {MAX_WORDS}-word cap — this is a standing "
                "tradeoff (debt-log.md), an observation (knowledge/), or a plan "
                "(docs/handoff/), not a breadcrumb",
                line))
    for number, reason in ((n, r) for n, r, _ in problems):
        print(f"breadcrumbs.md:{number}: {reason}", file=sys.stderr)
    if problems:
        print(f"\n{len(problems)} entr{'y' if len(problems) == 1 else 'ies'} "
              f"out of shape in {path}", file=sys.stderr)
        return 1
    print(f"breadcrumbs: {entries} entries, all within {MAX_WORDS} words")
    return 0


if __name__ == "__main__":
    sys.exit(main())
