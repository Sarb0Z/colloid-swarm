#!/usr/bin/env python3
"""Fail when `check-all.sh` and `.github/workflows/ci.yml` run different checks.

Usage: lint-suite.py [--script PATH] [--ci PATH]

The suite script is the list a session runs (`suite.sh` runs it as
`owed.suite`); CI is the list that gates a merge. A check in one and not the
other means a session reads a green suite that CI rejects, or the reverse.

A check is a command line naming a script under `.agents/` or `demo/`, with
its arguments, read from the script's list and from the `run:` lines of the
workflow. Two named lists hold the differences that are meant:

  CI_ONLY    steps that exist to gate the merge and are not suite checks:
             the clean-tree check and the showcase regeneration pair.
  NOT_ON_CI  checks the runner cannot run, each with its reason.

An entry that no longer describes a difference is itself a failure.
"""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

CI_ONLY = {
    ".agents/check-clean-tree.sh": "asserts the workflow's own earlier steps left the tree clean",
    "demo/embed-src.py": "regenerates the showcase panels so the clean-tree step can see drift",
    "demo/check-inventory.py": "gates the showcase inventory, which only the carrier ships",
}
NOT_ON_CI = {}

CHECK = re.compile(r"^(?:python3\s+)?((?:\.agents|demo)/\S+(?:\s+[A-Za-z][\w-]*)?)\s*(?:$|\|)")


def normalize(line):
    """The check a command line names, or None for a line that runs no check."""
    match = CHECK.match(line.strip())
    if not match:
        return None
    command = match.group(1).strip()
    # `port-public.py check` keeps its argument; a script path alone stays alone.
    return command


def script_checks(path):
    inside, found = False, []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if line.strip() == "cat <<'LIST'":
            inside = True
        elif line.strip() == "LIST":
            inside = False
        elif inside and line.strip() and not line.startswith("#"):
            check = normalize(line)
            if check is None:
                raise SystemExit(f"lint-suite: {path}: {line!r} is not a check line")
            found.append(check)
    return found


def ci_checks(path):
    found, block = [], False
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if block:
            if stripped and len(line) - len(line.lstrip()) <= indent:
                block = False
            else:
                check = normalize(stripped)
                if check:
                    found.append(check)
                continue
        match = re.match(r"^(\s*)(?:- )?run:\s*(.*)$", line)
        if not match:
            continue
        if match.group(2) in ("|", ">", "|-", ">-"):
            block, indent = True, len(match.group(1))
        else:
            check = normalize(match.group(2))
            if check:
                found.append(check)
    return found


def script_path(check):
    return check.split()[0]


def problems(script, ci):
    in_script, in_ci = script_checks(script), ci_checks(ci)
    errors = []
    for check in in_script:
        if check not in in_ci and script_path(check) not in NOT_ON_CI:
            errors.append(f"{check}: in {Path(script).name} but not run by {Path(ci).name}")
    for check in in_ci:
        if check not in in_script and script_path(check) not in CI_ONLY:
            errors.append(f"{check}: run by {Path(ci).name} but not in {Path(script).name}")
    for name in CI_ONLY:
        if not any(script_path(c) == name for c in in_ci) or any(script_path(c) == name for c in in_script):
            errors.append(f"CI_ONLY entry {name} no longer describes a CI-only check")
    for name in NOT_ON_CI:
        if any(script_path(c) == name for c in in_ci) or not any(script_path(c) == name for c in in_script):
            errors.append(f"NOT_ON_CI entry {name} no longer describes a check missing from CI")
    return errors, len(in_script)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--script", default=str(ROOT / ".agents" / "check-all.sh"))
    parser.add_argument("--ci", default=str(ROOT / ".github" / "workflows" / "ci.yml"))
    args = parser.parse_args(argv)
    errors, count = problems(args.script, args.ci)
    for error in errors:
        print(f"FAIL: {error}", file=sys.stderr)
    if errors:
        return 1
    print(f"suite lint: {count} checks, script and CI agree")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
