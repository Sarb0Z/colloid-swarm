#!/usr/bin/env python3
"""Reduce an eslint or pyright JSON report to one error line per finding.

Usage: tool-errors.py <eslint|pyright> <project-dir>    # report on stdin

Prints `<relative-file>:<line>[:<column>]: <message>`. Errors only: a warning
the repository has chosen to tolerate is not this gate's business. An
unreadable report prints nothing, because the caller already distinguishes
"the tool could not run" from "the tool found nothing".
"""

import json
import os
import sys


def eslint(report, project):
    for result in report if isinstance(report, list) else []:
        path = result.get("filePath", "")
        if path.startswith(project + os.sep):
            path = path[len(project) + 1:]
        for message in result.get("messages", []):
            if message.get("severity") != 2:
                continue
            rule = message.get("ruleId") or "parse-error"
            yield (f"{path}:{message.get('line', 0)}:{message.get('column', 0)}: "
                   f"{message.get('message', '')} [{rule}]")


def pyright(report, project):
    diagnostics = report.get("generalDiagnostics", []) if isinstance(report, dict) else []
    for diagnostic in diagnostics:
        if diagnostic.get("severity") != "error":
            continue
        path = diagnostic.get("file", "")
        if path.startswith(project + os.sep):
            path = path[len(project) + 1:]
        line = diagnostic.get("range", {}).get("start", {}).get("line", 0) + 1
        message = (diagnostic.get("message", "") or "").splitlines()[0]
        yield f"{path}:{line}: {message}"


READERS = {"eslint": eslint, "pyright": pyright}


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in READERS:
        raise SystemExit("tool-errors.py: usage: tool-errors.py <eslint|pyright> <project-dir>")
    try:
        report = json.loads(sys.stdin.read() or "null")
    except ValueError:
        return 0
    if report is None:
        return 0
    for line in READERS[sys.argv[1]](report, sys.argv[2]):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
