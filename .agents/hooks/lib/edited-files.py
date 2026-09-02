#!/usr/bin/env python3
"""Print the edited files this hook is responsible for, one per line.

Usage: edited-files.py <project-dir>    # payload on stdin

One place decides what counts, so the groupers downstream never re-answer the
question and never disagree about it.

Engines send different shapes: Claude Code sends absolute paths, the Codex
adapter sends paths relative to the project. Both become absolute here, or the
walk upward starts nowhere and every checker resolves from the root.

In scope means inside the repository either literally or after following
symlinks — a workspace symlinked out of the tree is still this repository's to
check. The literal form travels onward, so the walk stays within the names the
agent actually edited rather than jumping to wherever they happen to live.
"""

import json
import os
import sys


def main():
    project = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    real_project = os.path.realpath(project)
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return 0
    if not isinstance(payload, dict):
        return 0

    seen = set()
    for entry in payload.get("files") or []:
        if not isinstance(entry, str) or not entry:
            continue
        path = os.path.abspath(os.path.join(project, entry))
        if not path.startswith(project + os.sep):
            # The project dir is physical (pwd -P) while an engine may send the
            # path through a symlink — /tmp for /private/tmp is the everyday one.
            # Re-express it under the project rather than dropping it, so every
            # walk upward downstream has a terminator it will actually reach.
            resolved = os.path.realpath(path)
            if not resolved.startswith(real_project + os.sep):
                continue                      # outside the repo: not ours to check
            path = project + resolved[len(real_project):]
        if "\n" in path:
            # This list travels newline-delimited, so the path cannot be said on
            # it: downstream it splits into two names that do not exist and is
            # dropped by the existence test — silently, which is exactly what the
            # tab guard in post-edit-check.sh exists to prevent. Say it is
            # unusable instead. Every real entry here is absolute, so a line that
            # does not start with a separator is unambiguously this refusal.
            path = "!" + path.replace("\n", "\\n")
        if path not in seen:
            seen.add(path)
            print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
