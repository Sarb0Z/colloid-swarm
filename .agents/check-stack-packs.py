#!/usr/bin/env python3
"""Fail when a stack pack is installed in a repository that does not run it.

Usage: .agents/check-stack-packs.py

Colloid carries every pack and chooses between none of them: the export is
uniform, and the agent running the transplant reads the target and deletes what
it does not run. That leaves one failure mode, the inverse of the old one — a
pack nobody deleted, firing framework rules at a repository with no such
framework. A pack whose globs match no tracked file is that pack.

The carrier is exempt. `stack_packs.carrier` is true in this repository's
`config.json.example` and absent from every export, because `export-scaffold.py`
drops the key; an absent key reads as false, so the satellite enforces and the
source does not.
"""

import json
import os
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
PACKS = REPO / ".agents/rules"


def matcher(pattern):
    """A compiled regex with the glob semantics the rule files are written in.

    `fnmatch` cannot serve here: it has no separator, so it translates every
    `*` to `.*`. Under it `app/**/*.tsx` demands a literal second slash and
    misses `app/page.tsx`, while `app/*.tsx` wrongly claims `app/deep/x.tsx`.
    A gate whose whole job is matching globs must use the semantics its own
    rule files are written against — `**` spans directories, `*` does not.
    """
    out, index = [], 0
    while index < len(pattern):
        if pattern.startswith("**/", index):
            out.append("(?:[^/]+/)*")
            index += 3
        elif pattern.startswith("**", index):
            out.append(".*")
            index += 2
        elif pattern[index] == "*":
            out.append("[^/]*")
            index += 1
        elif pattern[index] == "?":
            out.append("[^/]")
            index += 1
        else:
            out.append(re.escape(pattern[index]))
            index += 1
    return re.compile("".join(out) + r"\Z")


def carrier():
    """True where this repository is the source that holds every pack."""
    try:
        with open(REPO / ".agents/config.json.example", encoding="utf-8") as source:
            settings = json.load(source)
    except (OSError, ValueError):
        return False
    block = settings.get("stack_packs")
    return isinstance(block, dict) and block.get("carrier") is True


def globs(path, key):
    """The entries under one list key of a frontmatter block, in order."""
    found, inside, listing = [], False, False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip() == "---":
            if inside:
                break
            inside = True
            continue
        if not inside:
            break                      # no frontmatter at all
        if line.startswith(f"{key}:"):
            listing = True
            continue
        if listing:
            stripped = line.strip()
            if stripped.startswith("- "):
                found.append(stripped[2:].strip().strip("'\""))
                continue
            listing = False
    return found


def tracked():
    result = subprocess.run(["git", "-C", str(REPO), "ls-files"],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit("check-stack-packs: needs a git work tree to list files")
    return result.stdout.splitlines()


def main():
    if carrier():
        print("check-stack-packs: carrier repository — every pack is held on purpose")
        return 0
    if not PACKS.is_dir():
        return 0

    files = tracked()
    stale = []
    packs = sorted(PACKS.glob("stack-*.md"))
    for pack in packs:
        rel = os.path.relpath(pack, REPO)
        if not globs(pack, "paths"):
            raise SystemExit(f"check-stack-packs: {rel} declares no scoping globs; "
                             "a rule with an empty `paths:` loads on every file")
        # `paths:` says when the rule loads and `detect:` says whether the stack
        # is here. They are different questions: Expo Router and the Next.js App
        # Router both own `app/**/*.tsx`, so loading breadth cannot decide
        # identity. Only a file one stack has and the other does not can.
        marks = globs(pack, "detect")
        if not marks:
            raise SystemExit(f"check-stack-packs: {rel} declares no marker globs; "
                             "without `detect:`, nothing can tell whether this "
                             "repository runs the stack")
        if not any(matcher(p).match(f) for p in marks for f in files):
            stale.append((rel, marks))

    for rel, marks in stale:
        print(f"check-stack-packs: {rel} finds none of its marker files", file=sys.stderr)
        print(f"  detect: {', '.join(marks)}", file=sys.stderr)
        print(f"  this repository does not run that stack — remove it: git rm {rel}",
              file=sys.stderr)
    if stale:
        return 1
    print(f"check-stack-packs: {len(packs)} pack(s), every stack present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
