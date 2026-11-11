#!/usr/bin/env python3
"""Group edited JS/TS files by the nearest node_modules/.bin holding a tool.

Usage: js-groups.py <project-dir> <tool> [--missing]   # file list on stdin, one per line

Prints one tab-delimited row per group: `<binary>\t<cwd>\t<file>...`. With
`--missing` it prints instead the files no group claims, one per line.

bun and npm both install a workspace's own devDependencies inside that
workspace, so a monorepo holds one eslint per app and a root that holds none.
Resolving from the root alone gives a gate that reports success having run
nothing. A file with no binary above it forms no group; `--missing` lists it, and
post-edit-check.sh reports it when a configuration of that tool covers the file,
since a configured check that does not run is a finding. ESLint with no
configuration in reach of the file does not run, so such a file is in neither
list.

The directory holding the binary must be inside the project, or inside the main
checkout of the repository the project is a worktree of: a lane worktree links
its node_modules to the main tree rather than installing its own. A holder
anywhere else is refused.

The run directory is the binary's own workspace, except for eslint: ESLint 9
looks for its flat config from the working directory, and a monorepo that
hoists eslint to the root keeps each app's eslint.config.* in the app. Run
from the root, it finds no config and lints nothing. So eslint runs from the
nearest folder above the file that holds an ESLint configuration.
"""

import json
import os
import sys

import checkers

ESLINT_CONFIGS = tuple(f"eslint.config.{ext}" for ext in ("js", "mjs", "cjs", "ts", "mts", "cts")) + (
    ".eslintrc", ".eslintrc.js", ".eslintrc.cjs", ".eslintrc.json", ".eslintrc.yaml", ".eslintrc.yml")


def has_eslint_config(directory):
    if any(os.path.isfile(os.path.join(directory, name)) for name in ESLINT_CONFIGS):
        return True
    try:
        with open(os.path.join(directory, "package.json"), encoding="utf-8") as handle:
            return "eslintConfig" in json.load(handle)
    except (OSError, ValueError, TypeError):
        return False                          # no package.json, or not an object: no config here


def flat_config_dir(path, stop):
    """The nearest folder from the file up to `stop` holding an ESLint config."""
    directory = os.path.dirname(path)
    while True:
        if has_eslint_config(directory):
            return directory
        if directory == stop or directory == os.path.dirname(directory):
            return None
        directory = os.path.dirname(directory)


def main():
    args = [arg for arg in sys.argv[1:] if arg != "--missing"]
    list_missing = len(args) != len(sys.argv) - 1
    if len(args) != 2:
        raise SystemExit("js-groups.py: usage: js-groups.py <project-dir> <tool> [--missing]")
    project, tool = args
    roots = {os.path.realpath(project), checkers.main_checkout(project)}

    groups = {}
    unclaimed = []
    for path in sys.stdin.read().splitlines():
        if not path:
            continue                          # already absolute and already in scope
        directory = os.path.dirname(path)
        while True:
            candidate = os.path.join(directory, "node_modules", ".bin", tool)
            # The same rule the shell's in_repo applies: judge the directory
            # holding the binary, never the binary's own link target. A .bin entry
            # is a symlink by construction and pnpm's can point into a store
            # outside the project, so following it would disarm the gate for every
            # pnpm repository. What must stay inside the repository is the
            # directory, because that is what a symlinked workspace can move.
            holder = os.path.realpath(os.path.dirname(candidate))
            if os.access(candidate, os.X_OK) and any(
                    holder == root or holder.startswith(root + os.sep) for root in roots):
                workspace = os.path.dirname(os.path.dirname(os.path.dirname(candidate)))
                cwd = workspace
                if tool == "eslint":
                    # ESLint with no configuration in reach does not run: it exits 2
                    # on every file, which would block each JS or TS edit.
                    cwd = flat_config_dir(path, project)
                    if cwd is None:
                        break
                groups.setdefault((candidate, cwd), []).append(path)
                break
            if directory == project or directory == os.path.dirname(directory):
                unclaimed.append(path)        # no install anywhere above
                break
            directory = os.path.dirname(directory)

    if list_missing:
        print("\n".join(unclaimed))
        return 0
    for (binary, cwd), files in groups.items():
        print("\t".join([binary, cwd] + files))
    return 0


if __name__ == "__main__":
    sys.exit(main())
