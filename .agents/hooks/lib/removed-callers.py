#!/usr/bin/env python3
"""List the removed Python definitions that other files still call or import.

Usage: removed-callers.py <project-dir>    # absolute .py paths on stdin, one per line

For each edited, tracked file this compares the top-level `def`, `async def`
and `class` names at column 0 in the working tree with HEAD, then searches every
tracked or untracked .py file once for the names that disappeared. pyright runs
on the edited files only, so a caller in an unedited file would otherwise go
unreported.

A hit counts when it is
  - an import line naming the removed name together with the module it left,
    which fails to import whether or not the name is defined elsewhere; or
  - a call `name(` with no word character or `.` before it, and no .py file
    defines the name at column 0. Otherwise the name moved or is another function.
Comment lines and definition lines never count.

Limits: a name match, not resolution. A call through an attribute (`mod.name(`)
and a function passed without a call are missed; an import split across lines
matches only on the line holding the name; methods are not top-level. Deleted
and moved files never reach the hook, and the base is HEAD, so a removal that is
already committed is not shown. debt: colloid-shell-writes-skip-post-edit

A failed or timed-out git call prints the reason on stderr and prints nothing.
"""

import os
import re
import subprocess
import sys

DEFINITION = re.compile(r"^(?:async\s+def|def|class)\s+(\w+)", re.M)
DEFINITION_LINE = re.compile(r"\s*(?:async\s+def|def|class)\s")
FROM_IMPORT = re.compile(r"\s*from\s+(\.*[\w.]*)\s+import\b(.*)")
MIN_NAME = 3
MAX_NAMES = 8
MAX_PLACES = 5
TIMEOUT = 5


def git(project, *args):
    return subprocess.run(["git", "-C", project, *args], capture_output=True,
                          text=True, timeout=TIMEOUT)


def removed_names(project, path):
    """Top-level names HEAD defines in this file and the working tree does not."""
    rel = os.path.relpath(path, project)
    head = git(project, "show", f"HEAD:{rel}")
    if head.returncode != 0:                # not in HEAD, so it has no base to lose names from
        return set()
    with open(path, encoding="utf-8", errors="replace") as handle:
        now = set(DEFINITION.findall(handle.read()))
    return {n for n in set(DEFINITION.findall(head.stdout)) - now if len(n) >= MIN_NAME}


def imports_from(line, name, stem):
    found = FROM_IMPORT.match(line)
    if not found or not re.search(rf"\b{re.escape(name)}\b", found.group(2)):
        return False
    return found.group(1).lstrip(".").split(".")[-1] == stem


def places(project, sources):
    """{name: [(path, line number, text)]} for the removed names still in use."""
    names = sorted(sources)
    dropped = names[MAX_NAMES:]
    names = names[:MAX_NAMES]
    if not names:
        return {}, dropped
    args = ["grep", "-n", "-w", "-I", "--untracked"]
    for name in names:
        args += ["-e", name]
    found = git(project, *args, "--", "*.py")
    if found.returncode not in (0, 1):
        raise subprocess.SubprocessError(found.stderr.strip() or f"git grep exited {found.returncode}")
    hits = []
    for row in found.stdout.splitlines():
        rel, number, text = row.split(":", 2)
        hits.append((rel, int(number), text))
    result = {}
    for name in names:
        word = re.compile(rf"\b{re.escape(name)}\b")
        source = sources[name]
        defined_elsewhere = any(
            re.match(rf"(?:async\s+def|def|class)\s+{re.escape(name)}\b", text)
            and os.path.join(project, rel) != source
            for rel, _, text in hits)
        stem = os.path.splitext(os.path.basename(source))[0]
        kept = []
        for rel, number, text in hits:
            if os.path.join(project, rel) == source or not word.search(text):
                continue
            if text.lstrip().startswith("#") or DEFINITION_LINE.match(text):
                continue
            if imports_from(text, name, stem) or (
                    not defined_elsewhere and re.search(rf"(?<![\w.]){re.escape(name)}\(", text)):
                kept.append((rel, number, text.strip()))
        if kept:
            result[name] = kept[:MAX_PLACES]
    return result, dropped


def main():
    if len(sys.argv) != 2:
        raise SystemExit("removed-callers.py: usage: removed-callers.py <project-dir>")
    project = sys.argv[1]
    files = [p for p in sys.stdin.read().splitlines()
             if p.strip().endswith(".py") and os.path.isfile(p)]
    try:
        sources = {}
        for path in files:
            for name in removed_names(project, path):
                sources.setdefault(name, path)
        result, dropped = places(project, sources)
    except (OSError, subprocess.SubprocessError) as error:
        print(f"removed-callers: skipped, {error}", file=sys.stderr)
        return 0
    for name, kept in result.items():
        print(f"{name} (removed from {os.path.relpath(sources[name], project)}):")
        for rel, number, text in kept:
            print(f"  {rel}:{number}  {text[:100]}")
    if dropped and result:
        print(f"({len(dropped)} more removed names were not searched: {', '.join(dropped)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
