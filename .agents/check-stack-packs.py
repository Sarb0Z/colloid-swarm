#!/usr/bin/env python3
"""Fail when a stack pack is installed in a repository that does not run it.

Usage: .agents/check-stack-packs.py

Colloid carries every pack and chooses between none of them: the export is
uniform, and the agent running the transplant reads the target and deletes what
it does not run. That leaves one failure mode, the inverse of the old one — a
pack nobody deleted, firing framework rules at a repository with no such
framework. A pack whose markers match nothing in the repository is that pack.

A pack declares its markers two ways. `detect:` lists globs, and the pack is
present when one matches a tracked file. `detect-deps:` lists dependency names
for a stack that leaves no signature file — MongoDB, an ORM, a client SDK — and
the pack is present when a tracked manifest outside `.agents/` names one. A
name may carry an ecosystem prefix (`npm:`, `pypi:`, `gem:`); an unprefixed
name matches in any ecosystem, and a prefixed one only in its own, so npm's
`motor` does not stand for the Python driver. `detect:` stays required:
`detect-deps:` is never the only key declared. Manifests read:
`package.json` (dependencies, devDependencies, peerDependencies,
optionalDependencies), `pyproject.toml` (PEP 621 dependencies and
optional-dependencies, `[dependency-groups]`, Poetry dependency and group
tables, uv dev-dependencies), `requirements*.txt` and `Gemfile`. Python names
are compared after PEP 503 normalisation, with extras and version specifiers
stripped.

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
import tomllib

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


ECOSYSTEMS = ("npm", "pypi", "gem")
NPM_SECTIONS = ("dependencies", "devDependencies", "peerDependencies",
                "optionalDependencies")
PEP508_NAME = re.compile(r"\s*([A-Za-z0-9][A-Za-z0-9._-]*)")
GEM_LINE = re.compile(r"""^\s*gem\s*\(?\s*['"]([^'"]+)['"]""")


def pypi_name(spec):
    """The PEP 503 normalised project name of a requirement specifier."""
    found = PEP508_NAME.match(spec)
    return re.sub(r"[-_.]+", "-", found.group(1)).lower() if found else None


def poetry_names(table):
    return [name for name in table if name.lower() != "python"]


def npm_deps(text, rel):
    try:
        document = json.loads(text)
    except ValueError as error:
        raise SystemExit(f"check-stack-packs: {rel} is not valid JSON: {error}")
    names = set()
    for section in NPM_SECTIONS:
        block = document.get(section) if isinstance(document, dict) else None
        if isinstance(block, dict):
            names.update(block)
    return {("npm", name) for name in names}


def pyproject_deps(text, rel):
    try:
        document = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        raise SystemExit(f"check-stack-packs: {rel} is not valid TOML: {error}")
    specs = []

    def collect(listing):
        if isinstance(listing, list):
            specs.extend(item for item in listing if isinstance(item, str))

    project = document.get("project", {})
    collect(project.get("dependencies"))
    for listing in (project.get("optional-dependencies") or {}).values():
        collect(listing)
    for listing in (document.get("dependency-groups") or {}).values():
        collect(listing)
    tool = document.get("tool", {})
    collect((tool.get("uv") or {}).get("dev-dependencies"))
    poetry = tool.get("poetry") or {}
    names = []
    for key in ("dependencies", "dev-dependencies"):
        names += poetry_names(poetry.get(key) or {})
    for group in (poetry.get("group") or {}).values():
        names += poetry_names(group.get("dependencies") or {})
    found = {("pypi", pypi_name(spec)) for spec in specs}
    found |= {("pypi", pypi_name(name)) for name in names}
    found.discard(("pypi", None))
    return found


def requirements_deps(text):
    found = set()
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if line and not line.startswith("-"):
            name = pypi_name(line)
            if name:
                found.add(("pypi", name))
    return found


def gem_deps(text):
    return {("gem", found.group(1)) for found in map(GEM_LINE.match, text.splitlines()) if found}


def manifest_deps(files):
    """Every (ecosystem, name) the tracked manifests outside `.agents/` declare."""
    found = set()
    for rel in files:
        base = pathlib.PurePosixPath(rel).name
        if base == "package.json":
            reader = lambda text: npm_deps(text, rel)
        elif base == "pyproject.toml":
            reader = lambda text: pyproject_deps(text, rel)
        elif matcher("requirements*.txt").match(base):
            reader = requirements_deps
        elif base == "Gemfile":
            reader = gem_deps
        else:
            continue
        try:
            text = (REPO / rel).read_text(encoding="utf-8")
        except OSError as error:
            raise SystemExit(f"check-stack-packs: cannot read {rel}: {error}")
        found |= reader(text)
    return found


def has_dep(markers, deps):
    """True when a `detect-deps:` entry names a declared dependency.

    A prefixed entry is compared inside its own ecosystem only. An unprefixed
    one matches in any, folding the name by PEP 503 where the manifest is
    Python's.
    """
    for entry in markers:
        prefix, _, rest = entry.partition(":")
        eco, name = (prefix, rest) if rest and prefix in ECOSYSTEMS else (None, entry)
        for have_eco, have in deps:
            if eco not in (None, have_eco):
                continue
            wanted = pypi_name(name) if have_eco == "pypi" else name
            if have == wanted:
                return True
    return False


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

    # The scaffold ships its own sources under .agents/ (the MCP servers carry a
    # tsconfig.json), so a file there says nothing about the repository's stack.
    files = [f for f in tracked() if not f.startswith(".agents/")]
    stale = []
    deps = None                        # manifests are read once, and only if a pack needs them
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
        if any(matcher(p).match(f) for p in marks for f in files):
            continue
        dep_marks = globs(pack, "detect-deps")
        if dep_marks:
            if deps is None:
                deps = manifest_deps(files)
            if has_dep(dep_marks, deps):
                continue
        stale.append((rel, marks, dep_marks))

    for rel, marks, dep_marks in stale:
        print(f"check-stack-packs: {rel} finds none of its markers", file=sys.stderr)
        print(f"  detect: {', '.join(marks)}", file=sys.stderr)
        if dep_marks:
            print(f"  detect-deps: {', '.join(dep_marks)}", file=sys.stderr)
        print(f"  this repository does not run that stack — remove it: git rm {rel}",
              file=sys.stderr)
    if stale:
        return 1
    print(f"check-stack-packs: {len(packs)} pack(s), every stack present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
