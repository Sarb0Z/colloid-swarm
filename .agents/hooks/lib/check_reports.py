"""Read a tsc or pyright run into findings for the post-edit hook.

Both functions return the report text, or "" when the run found nothing the
hook should say. checkers.py owns configuration, the ledger and the files the
baseline lives in; this module only reads what a tool printed.
"""

import json
import os
import re

TSC_FINDING = re.compile(r"error TS\d+")
# A diagnostic about a configuration rather than a source file: it carries no
# path (`error TS5083`), or its path is a .json file, which covers a tsconfig the
# edited file's own tsconfig extends or references.
TSC_CONFIG_FINDING = re.compile(r"^(error TS\d+|[^()\s][^()]*\.json\(\d+,\d+\): error TS\d+)")
FIRST_LINES = 3


def first_lines(text):
    lines = [line.strip() for line in text.splitlines() if line.strip()][:FIRST_LINES]
    return " | ".join(lines) if lines else "(no output)"


def tsc(project, workspace, config, status, rels, raw, swap_baseline):
    """Findings from one `tsc --noEmit` run in `workspace`.

    Reported: errors in the edited files (`rels`), a configuration that tsc
    could not read, a non-zero exit with no error line, and errors in files the
    edit did not touch that the session's last run in this workspace did not
    have. `swap_baseline(lines)` stores this run's error lines and returns the
    previous run's, or None on the first run, which only sets the baseline.
    """
    label = config if workspace == project else f"{os.path.relpath(workspace, project)}/{config}"
    lines = raw.splitlines()
    errors = [line for line in lines if TSC_FINDING.search(line)]
    if status != 0 and not errors:
        return f"[tsc] {label} exited {status} with no parsable output: {first_lines(raw)}"
    scoped = [line for line in lines if any(rel in line for rel in rels)]
    broken = [line for line in lines if TSC_CONFIG_FINDING.match(line)]
    previous = swap_baseline(errors)
    outside = [line for line in errors if line not in scoped and line not in broken]
    fresh = [] if previous is None else [line for line in outside if line not in set(previous)]
    blocks = []
    if broken:
        blocks.append(f"[tsc] {label} could not be read as a project:\n" + "\n".join(broken))
    if scoped:
        blocks.append(f"[tsc --noEmit] {label} (scoped to edited files)\n" + "\n".join(scoped))
    if fresh:
        blocks.append("[tsc] new errors outside the edited files (an edit may have broken a caller):\n"
                      + "\n".join(fresh))
    return "\n".join(blocks)


def pyright(project, workspace, status, stderr, raw, scoped):
    """A finding when pyright's run cannot be trusted: it exited 2 or more, left
    no JSON report, or wrote to stderr and yet reported nothing in the edited
    files. A pyrightconfig.json it cannot parse exits 3 with an empty report and
    the reason on stderr, so a clean-looking report is not enough."""
    try:
        report = json.loads(raw or "null")
    except ValueError:
        report = None
    readable = isinstance(report, dict) and "generalDiagnostics" in report
    if readable and status < 2 and not (stderr.strip() and not scoped):
        return ""
    label = os.path.relpath(workspace, project)
    if not readable:
        return f"[pyright] {label} exited {status} with no parsable output: {first_lines(stderr or raw)}"
    return f"[pyright] {label} exited {status} with stderr: {first_lines(stderr)}"
