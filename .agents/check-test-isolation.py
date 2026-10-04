#!/usr/bin/env python3
"""Fail when a scaffold test runs git without first clearing the GIT_* variables.

`git rebase -x '<checks>'` runs its checks with GIT_DIR exported. A test that
then runs `git init` or `git commit` in a temporary directory acts on the
repository being rebased instead: it commits there and can set core.bare.
"""

import pathlib
import re
import sys

here = pathlib.Path(__file__).resolve().parent
# A shell line that runs git, or a Python argument list that starts with it.
# A git command inside a test payload string is data, not a call.
RUNS_GIT = {
    ".sh": re.compile(r"^\s*(?:\w+=\S*\s+)*git\s|\$\(\s*git\s", re.M),
    ".py": re.compile(r"\[\s*[\"']git[\"']\s*,"),
}
CLEARS = re.compile(r"GIT_DIR")

tests = sorted(p for p in here.glob("test-*") if p.suffix in (".sh", ".py"))
missing = [p.name for p in tests if RUNS_GIT[p.suffix].search(p.read_text()) and not CLEARS.search(p.read_text())]
for name in missing:
    print(f"FAIL: {name} runs git but does not clear GIT_DIR and the other GIT_* variables first", file=sys.stderr)
if missing:
    sys.exit(1)
print(f"test isolation: {len(tests)} tests checked")
