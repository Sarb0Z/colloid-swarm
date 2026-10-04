#!/usr/bin/env python3
"""Gate the shape of .agents/decisions.md.

SessionStart pastes the headings only, so an entry is read in full exactly when
someone is about to propose the alternative it declined. An entry missing its
Why or Reopens-when line cannot answer that question.

Every `### <id>` entry carries one line each opening with `- **Decision** — `,
`- **Why** — ` and `- **Reopens when** — `, in that order, once.

Usage: lint-decisions.py [path]
"""

import re
import sys
from pathlib import Path

LABELS = ("Decision", "Why", "Reopens when")
HEADING = re.compile(r"^### [a-z0-9]+(?:-[a-z0-9]+)*$")
FIELD = re.compile(r"^- \*\*(?P<label>[^*]+)\*\* — \S")


def main():
    path = Path(sys.argv[1] if len(sys.argv) > 1 else
                Path(__file__).resolve().parent / "decisions.md")
    if not path.exists():
        return 0                      # a satellite may carry no decisions yet
    entries, problems = [], []
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if line.startswith("### "):
            if not HEADING.match(line):
                problems.append((number, "heading must be `### <kebab-slug>`"))
            entries.append((number, line[4:], []))
        elif entries and (field := FIELD.match(line)):
            entries[-1][2].append(field["label"])
    for number, name, labels in entries:
        if tuple(labels) != LABELS:
            problems.append((
                number,
                f"entry `{name}` has fields {labels or 'none'}; "
                f"expected exactly {list(LABELS)} in that order"))
    for number, reason in sorted(problems):
        print(f"decisions.md:{number}: {reason}", file=sys.stderr)
    if problems:
        return 1
    print(f"decisions.md: {len(entries)} entries ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
