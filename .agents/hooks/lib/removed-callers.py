#!/usr/bin/env python3
"""List the removed Python definitions that other files still call or import.

Usage: removed-callers.py [--json] <project-dir>    # absolute .py paths on stdin, one per line

With --json it prints one line, `{"names": [...], "sites": n}`: every removed
name still in use and the number of call and import sites naming them, with no
cap. A failed git call then exits 1 with the reason on stderr, so a reader
never takes a failure for no callers.

For each edited, tracked file this compares the top-level `def`, `async def`
and `class` names at column 0 in the working tree with HEAD. A name the working
tree still binds at column 0 (an assignment, or a `from … import` or
`import … as` that names it) is a re-export, not a removal. Every tracked or
untracked .py file under the project folder is then searched once for the names
that disappeared. pyright runs on the edited files only, so a caller in an
unedited file would otherwise go unreported.

A hit counts when it is
  - an import line naming the removed name together with the module it left
    (a package's `__init__.py` is imported as its folder), which fails to
    import whether or not the name is defined elsewhere; or
  - a call `name(` with no word character or `.` before it, and no .py file
    defines the name at column 0. Otherwise the name moved or is another function.
Comment lines and definition lines never count. At most 8 names and 5 places
per name are printed, and a last line names the rest.

Limits: a name match, not resolution. A call through an attribute (`mod.name(`)
and a function passed without a call are missed; an import split across lines
matches only on the line holding the name; methods are not top-level; callers
outside the project folder are not searched. Deleted and moved files never reach
the hook, and the base is HEAD, so a removal that is already committed is not
shown. debt: colloid-shell-writes-skip-post-edit

Without --json, a failed or timed-out git call prints the reason on stderr and
prints nothing.
"""

import json
import os
import re
import subprocess
import sys

DEFINITION = re.compile(r"^(?:async\s+def|def|class)\s+(\w+)", re.M)
DEFINITION_LINE = re.compile(r"\s*(?:async\s+def|def|class)\s")
FROM_IMPORT = re.compile(r"\s*from\s+(\.*[\w.]*)\s+import\b(.*)")
BINDINGS = (
    re.compile(r"^(\w+)\s*(?::[^=\n]*)?=(?!=)", re.M),
    re.compile(r"^import\s+[\w.]+\s+as\s+(\w+)", re.M),
)
FROM_LINE = re.compile(r"^from\s+\S+\s+import\s+\(?([^)\n]*)", re.M)
NOT_IN_HEAD = ("does not exist in 'HEAD'", "exists on disk, but not in 'HEAD'")
MIN_NAME = 3
MAX_NAMES = 8
MAX_PLACES = 5
TIMEOUT = 5


def git(project, *args):
    return subprocess.run(["git", "-C", project, *args], capture_output=True,
                          encoding="utf-8", errors="replace", timeout=TIMEOUT)


def bound_names(source):
    """Names a module binds at column 0 without defining them."""
    names = set()
    for pattern in BINDINGS:
        names.update(pattern.findall(source))
    for imported in FROM_LINE.findall(source):
        for part in imported.split(","):
            words = part.split()
            if words:
                names.add(words[-1])            # `x` or the alias in `x as y`
    return names


def removed_names(project, path):
    """Top-level names HEAD defines in this file and the working tree no longer binds."""
    rel = os.path.relpath(path, project)
    head = git(project, "show", f"HEAD:./{rel}")
    if head.returncode != 0:
        if any(marker in head.stderr for marker in NOT_IN_HEAD):
            return set()                        # a new file has no base to lose names from
        raise subprocess.SubprocessError(f"git show HEAD:./{rel}: {head.stderr.strip()}")
    with open(path, encoding="utf-8", errors="replace") as handle:
        now = handle.read()
    kept = set(DEFINITION.findall(now)) | bound_names(now)
    return {n for n in set(DEFINITION.findall(head.stdout)) - kept if len(n) >= MIN_NAME}


def module_name(source):
    """The last part of the dotted name an importer writes for this file."""
    stem = os.path.splitext(os.path.basename(source))[0]
    return os.path.basename(os.path.dirname(source)) if stem == "__init__" else stem


def imports_from(line, name, module):
    found = FROM_IMPORT.match(line)
    if not found or not re.search(rf"\b{re.escape(name)}\b", found.group(2)):
        return False
    return found.group(1).lstrip(".").split(".")[-1] == module


def grep(project, names):
    """[(path, line number, text)] for every .py line naming any of `names`."""
    args = ["grep", "-n", "-z", "-w", "-I", "--untracked"]
    for name in names:
        args += ["-e", name]
    found = git(project, *args, "--", "*.py")
    if found.returncode not in (0, 1):
        raise subprocess.SubprocessError(found.stderr.strip() or f"git grep exited {found.returncode}")
    hits = []
    for row in found.stdout.splitlines():
        rel, number, text = row.split("\0", 2)
        hits.append((rel, int(number), text))
    return hits


def places(project, sources):
    """{name: [(path, line number, text)]} for every removed name still in use."""
    if not sources:
        return {}
    hits = grep(project, sorted(sources))
    result = {}
    for name in sorted(sources):
        word = re.compile(rf"\b{re.escape(name)}\b")
        source = sources[name]
        defined_elsewhere = any(
            re.match(rf"(?:async\s+def|def|class)\s+{re.escape(name)}\b", text)
            and os.path.join(project, rel) != source
            for rel, _, text in hits)
        module = module_name(source)
        kept = []
        for rel, number, text in hits:
            if os.path.join(project, rel) == source or not word.search(text):
                continue
            if text.lstrip().startswith("#") or DEFINITION_LINE.match(text):
                continue
            if imports_from(text, name, module) or (
                    not defined_elsewhere and re.search(rf"(?<![\w.]){re.escape(name)}\(", text)):
                kept.append((rel, number, text.strip()))
        if kept:
            result[name] = kept
    return result


def main():
    args = sys.argv[1:]
    as_json = args[:1] == ["--json"]
    if as_json:
        args = args[1:]
    if len(args) != 1:
        raise SystemExit("removed-callers.py: usage: removed-callers.py [--json] <project-dir>")
    project = args[0]
    files = [p for p in sys.stdin.read().splitlines()
             if p.strip().endswith(".py") and os.path.isfile(p)]
    try:
        sources = {}
        for path in files:
            for name in removed_names(project, path):
                sources.setdefault(name, path)
        result = places(project, sources)
    except (OSError, subprocess.SubprocessError) as error:
        if as_json:
            print(f"removed-callers: failed, {error}", file=sys.stderr)
            return 1
        print(f"removed-callers: skipped, {error}", file=sys.stderr)
        return 0
    if as_json:
        print(json.dumps({"names": list(result), "sites": sum(len(found) for found in result.values())}))
        return 0
    shown = list(result)[:MAX_NAMES]
    for name in shown:
        print(f"{name} (removed from {os.path.relpath(sources[name], project)}):")
        for rel, number, text in result[name][:MAX_PLACES]:
            print(f"  {rel}:{number}  {text[:100]}")
        if len(result[name]) > MAX_PLACES:
            print(f"  ({len(result[name]) - MAX_PLACES} more places)")
    rest = list(result)[MAX_NAMES:]
    if rest:
        print(f"({len(rest)} more removed names still in use: {', '.join(rest)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
