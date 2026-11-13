"""Fail when `check-all.sh` and `.github/workflows/ci.yml` run different checks.

Usage: python3 .agents/lint-suite.py [--script PATH] [--ci PATH] [--root DIR]

The suite script is the list a session runs (`suite.sh` runs it as
`owed.suite`); CI is the list that gates a merge. A check in one and not the
other means a session reads a green suite that CI rejects, or the reverse.

A check is a command line naming a script under `.agents/` or `demo/`, with
its arguments, read from the script's list and from the `run:` lines of the
workflow. Two named lists hold the differences that are meant:

  CI_ONLY    steps that are not suite checks: the step that gives the job
             the checks' environment, the clean-tree check and the showcase
             regeneration pair. A step that drops out of CI fails the lint.
  NOT_ON_CI  checks the runner cannot run, each with its reason.

An entry that no longer describes a difference is itself a failure. The first
check CI runs is ENVIRONMENT_STEP, which gives the job's later steps the
environment suite.sh gives each check; a check above it runs in the runner's
own.

The same list must also reach every test file. Every `test-*` file under
`.agents/` that git tracks or could track (ignored files, and folders named
node_modules, worktrees and mcp-servers, are not walked) must be a listed check
or be called by a file that is reached, however deep. A test nobody runs passes
nothing. A call is any non-comment line of a reached file that names the test's
file name: a string, an echo, or a call behind a condition counts, since the
match is on text and nothing runs. A call built from a variable is not seen.
The lint's own file is never read as a caller, since its UNLISTED_TESTS line
names tests. Two test files sharing a name are both reached when either is
named; none share a name today. UNLISTED_TESTS holds the tests that are meant
to be unreached, each with its reason; an entry whose test is reached or gone
fails.

The tree check runs on the real tree when `--script` is the default
`check-all.sh`, and otherwise only on the tree named by `--root`.
"""
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKIPPED_FOLDERS = {"node_modules", "worktrees", "mcp-servers"}

CI_ONLY = {
    ".agents/check-env.sh": "gives the job's later steps the environment suite.sh gives each check",
    ".agents/check-clean-tree.sh": "asserts the workflow's own earlier steps left the tree clean",
    "demo/embed-src.py": "regenerates the showcase panels so the clean-tree step can see drift",
}
NOT_ON_CI = {}
UNLISTED_TESTS = {}
ENVIRONMENT_STEP = ".agents/check-env.sh"

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
    found, block, indent = [], False, 0
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
    if in_ci and script_path(in_ci[0]) != ENVIRONMENT_STEP:
        errors.append(f"{in_ci[0]}: runs before {ENVIRONMENT_STEP} in {Path(ci).name}, in the runner's own environment")
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


def test_files(root):
    """Relative paths of the test-* files under .agents/ that git sees and the walk keeps."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    listing = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", ".agents"],
        env=env, capture_output=True, text=True, check=False,
    )
    if listing.returncode != 0:
        raise SystemExit(f"lint-suite: {root}: {listing.stderr.strip()}")
    found = set()
    for rel in filter(None, listing.stdout.split("\0")):
        parts = Path(rel).parts
        if (
            parts[-1].startswith("test-")
            and not SKIPPED_FOLDERS.intersection(parts[:-1])
            and (Path(root) / rel).is_file()
        ):
            found.add(rel)
    return found


def active_lines(path):
    return [line for line in path.read_text(encoding="utf-8", errors="replace").splitlines()
            if line.strip() and not line.lstrip().startswith("#")]


def reached_tests(root, listed, tests):
    """The test files the listed checks run, directly or through a file they call."""
    by_name = {}
    for rel in tests:
        by_name.setdefault(Path(rel).name, []).append(rel)
    patterns = {name: re.compile(r"(?<![\w.-])" + re.escape(name) + r"(?![\w-])") for name in by_name}
    reached = {script_path(check) for check in listed} & tests
    queue = [script_path(check) for check in listed]
    seen = set()
    while queue:
        rel = queue.pop()
        if rel in seen or not (Path(root) / rel).is_file():
            continue
        seen.add(rel)
        if Path(rel).name == Path(__file__).name:
            continue
        text = "\n".join(active_lines(Path(root) / rel))
        for name, pattern in patterns.items():
            if pattern.search(text):
                for hit in by_name[name]:
                    reached.add(hit)
                    queue.append(hit)
    return reached


def test_problems(root, script):
    tests = test_files(root)
    reached = reached_tests(root, script_checks(script), tests)
    errors = []
    for rel in sorted(tests - reached - set(UNLISTED_TESTS)):
        errors.append(f"{rel}: test file is neither listed in {Path(script).name} nor called by a listed check")
    for rel in UNLISTED_TESTS:
        if rel in reached or rel not in tests:
            errors.append(f"UNLISTED_TESTS entry {rel} no longer describes an unlisted test")
    return errors, len(tests & reached)


def main(argv):
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    default_script = ROOT / ".agents" / "check-all.sh"
    parser.add_argument("--script", default=str(default_script))
    parser.add_argument("--ci", default=str(ROOT / ".github" / "workflows" / "ci.yml"))
    parser.add_argument("--root", default=None, help="tree whose test files must be reached (default: this one, when --script is the default)")
    args = parser.parse_args(argv)
    script = args.script
    uses_default = Path(script).resolve() == default_script.resolve()
    root = args.root or (str(ROOT) if uses_default else None)
    errors, count = problems(script, args.ci)
    tests_reached = None
    if root:
        more, tests_reached = test_problems(root, script)
        errors += more
    for error in errors:
        print(f"FAIL: {error}", file=sys.stderr)
    if errors:
        return 1
    suffix = f"; {tests_reached} test files reached" if tests_reached is not None else ""
    print(f"suite lint: {count} checks, script and CI agree{suffix}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
