#!/usr/bin/env python3
"""Group edited TypeScript files by the workspace that typechecks them.

Usage: ts-workspaces.py <project-dir>    # file list on stdin, one per line

Prints one tab-delimited row per group: `<workspace>\t<tsconfig>\t<relative-file>...`.
The workspace is the nearest ancestor holding a tsconfig.json, so a monorepo
gets one tsc run per package rather than one hardcoded run for the tree.
"""

import json
import os
import re
import sys


def read_config(path):
    """tsconfig permits comments and trailing commas; json does not."""
    try:
        with open(path, encoding="utf-8") as handle:
            raw = handle.read()
    except OSError:
        return {}
    raw = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)
    raw = re.sub(r"(^|\s)//[^\n]*", r"\1", raw)
    raw = re.sub(r",(\s*[}\]])", r"\1", raw)
    try:
        value = json.loads(raw)
    except ValueError:
        return {}
    return value if isinstance(value, dict) else {}


def literal_prefix(pattern):
    """The leading path of an include pattern, up to its first wildcard."""
    return re.split(r"[*?]", pattern, maxsplit=1)[0].rstrip("/")


def covers(config_dir, config, target_file):
    """Length of the longest include prefix that claims the file, else None."""
    rel = os.path.relpath(target_file, config_dir)
    if rel.startswith(os.pardir):
        return None
    for entry in config.get("files") or []:
        if os.path.normpath(entry) == os.path.normpath(rel):
            return len(rel)
    for pattern in config.get("exclude") or []:
        prefix = literal_prefix(pattern)
        if prefix and (rel == prefix or rel.startswith(prefix + os.sep)):
            return None
    best = None
    for pattern in config.get("include") or ["**/*"]:
        prefix = literal_prefix(pattern)
        if not prefix or rel == prefix or rel.startswith(prefix + os.sep):
            best = max(best or 0, len(prefix))
    return best


def project_for(workspace, target_file):
    """Pick the tsconfig that actually typechecks this file.

    A Vite or React workspace usually keeps `tsconfig.json` as a solution file
    -- `{"files": [], "references": [...]}`. tsc run against it reads no source,
    so the gate would report success having checked nothing. Where the nearest
    config declares no inputs of its own, follow its references and take the
    project whose include prefix claims the file most specifically.
    """
    config = read_config(os.path.join(workspace, "tsconfig.json"))
    references = config.get("references") or []
    if not references:
        return "tsconfig.json"
    if (config.get("files") or config.get("include")) and \
            covers(workspace, config, target_file) is not None:
        return "tsconfig.json"
    best, best_score = None, -1
    for reference in references:
        path = reference.get("path") if isinstance(reference, dict) else None
        if not isinstance(path, str):
            continue
        candidate = os.path.normpath(os.path.join(workspace, path))
        if os.path.isdir(candidate):
            candidate = os.path.join(candidate, "tsconfig.json")
        if not os.path.isfile(candidate):
            continue
        score = covers(os.path.dirname(candidate), read_config(candidate), target_file)
        if score is not None and score > best_score:
            best, best_score = os.path.relpath(candidate, workspace), score
    return best or "tsconfig.json"


def main():
    project = os.path.realpath(sys.argv[1] if len(sys.argv) > 1 else os.getcwd())
    groups = {}
    for path in sys.stdin.read().splitlines():
        if not path:
            continue                          # already absolute and already in scope
        directory = os.path.dirname(path)
        while True:
            if os.path.isfile(os.path.join(directory, "tsconfig.json")):
                key = (directory, project_for(directory, path))
                groups.setdefault(key, []).append(os.path.relpath(path, directory))
                break
            if directory == project or directory == os.path.dirname(directory):
                break                         # no tsconfig anywhere above: skip
            directory = os.path.dirname(directory)

    for (workspace, config), rels in groups.items():
        print("\t".join([workspace, config] + rels))
    return 0


if __name__ == "__main__":
    sys.exit(main())
