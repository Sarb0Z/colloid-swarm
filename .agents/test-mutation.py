#!/usr/bin/env python3
"""Prove that each gate's test goes red when the gate is removed.

A suite that passes tells you nothing about whether it would fail. A guard whose
removal turns nothing red is a green light wired to nothing, and the suite that
covers it reports success while measuring the absence of a check. This harness
is the other direction: it breaks one guard at a time, on a copy, and demands
the named suite notice.

Every row is one guard: the file, the exact text that implements it, the text
that neutralizes it, the suite that must then fail, and a fragment that suite
must print. Five outcomes, and only one of them is a pass:

  PROTECTED     the suite failed, and printed the fragment  -> the guard is covered
  UNPROTECTED   the suite passed with the guard removed     -> nothing tests it
  INCONCLUSIVE  the suite failed on something else          -> the row, or the
                harness, is broken; a failure for the wrong reason is not a catch
  VACUOUS       the fragment is already in the passing run  -> the row proves
                nothing: any non-zero exit would satisfy it
  TIMEOUT       the mutated suite never finished            -> removing a guard
                can unbound a loop; that is a result, not a hang to sit through

`expect` must name text the suite prints only when it FAILS. A fragment that
also appears on a green run — `ok    governed: …` and `FAIL  governed: …` share
a substring — reduces the row to "the suite exited non-zero", and then any
unrelated mutation certifies the guard. That is this file's own failure mode,
one level up, so the control output is checked for the fragment before any row
is believed.

The control run earns its cost twice over. Before any row is believed, the same
suite runs against an unmutated copy and must pass. Without it a suite that dies
on its own setup — a fixture built with `git ls-files`, run from a copy that is
not a repository — returns non-zero for every row, and every guard is certified
by a harness that never reached a mutation. Its output is then kept, because it
is also the only way to tell a real fragment from a vacuous one.

UNPROTECTED is a finding, never a licence to delete. It says no test covers the
guard, which is not the same as the guard being dead: dead means a firing test
cannot be written, and only an attempt to write one settles that.

Usage: test-mutation.py [--row <guard>] ...   # default: every row
"""

import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

# A control that has not finished by now is not slow, it is stuck.
CONTROL_LIMIT = 600.0

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent

# One row per guard. `find` must appear exactly once in `file` — a row that no
# longer matches is reported as STALE rather than quietly skipped, because a
# silently skipped row is the same green-light-wired-to-nothing this file exists
# to catch, one level up.
ROWS = [
    {
        "guard": "guard-destructive/rm-rules",
        "file": ".agents/hooks/lib/guard-destructive.py",
        "find": "RULES = (rule_rm, rule_git, rule_ssh, rule_sql, rule_cloud)",
        "replace": "RULES = (rule_git, rule_ssh, rule_sql, rule_cloud)",
        "test": ["python3", ".agents/test-guard-destructive.py"],
        "expect": "FAIL  block: 'rm -rf /'",
    },
    {
        "guard": "grader-lock/hooks-tree-governed",
        "file": ".agents/hooks/lib/grader-lock.py",
        "find": '    ".agents/hooks/",\n',
        "replace": "",
        "test": ["python3", ".agents/test-grader-lock.py"],
        "expect": "FAIL  governed: .agents/hooks/",
    },
    {
        "guard": "grader-lock/skills-stay-writable",
        "file": ".agents/hooks/lib/grader-lock.py",
        "find": "    if rel.startswith(SKILLS):\n        return None\n",
        "replace": "",
        "test": ["python3", ".agents/test-grader-lock.py"],
        "expect": "FAIL  writable: .agents/skills/",
    },
    {
        "guard": "sync-claude/check-needs-a-work-tree",
        "file": ".agents/sync-claude-agents.sh",
        "find": "    if known is None:\n",
        "replace": "    if False:\n",
        "test": ["bash", ".agents/test-sync-claude.sh"],
        "expect": "work tree",
    },
    {
        "guard": "sync-claude/generated-not-tracked",
        "file": ".agents/sync-claude-agents.sh",
        "find": ("        for rel in sorted(set(plan) - known):\n"
                 '            drift.append(f"{rel} (generated, not tracked — commit it)")\n'),
        "replace": "",
        "test": ["bash", ".agents/test-sync-claude.sh"],
        "expect": "--check passed with generated links the tree does not track",
    },
    {
        "guard": "sync-claude/directory-at-a-generated-name",
        "file": ".agents/sync-claude-agents.sh",
        "find": ('        if os.path.isdir(path) and not os.path.islink(path):\n'),
        "replace": "        if False:\n",
        "test": ["bash", ".agents/test-sync-claude.sh"],
        # Without the guard the generator still fails — os.replace onto a
        # non-empty directory raises — but it crashes instead of naming the path.
        # The guard's product is the clean refusal, so that is what to require.
        "expect": "the generator did not name the directory that blocked it",
    },
    {
        "guard": "sync-claude/unknown-subagent-field",
        "file": ".agents/sync-claude-agents.sh",
        "find": "    unknown = sorted(set(settings) - set(CONFIGURED_FIELDS))\n",
        "replace": "    unknown = []\n",
        "test": ["bash", ".agents/test-sync-claude.sh"],
        "expect": "a subagent field the script cannot emit must stop the run",
    },
    {
        "guard": "sync-claude/undefined-tier",
        "file": ".agents/sync-claude-agents.sh",
        "find": "    if not isinstance(tiers, dict) or tier not in tiers:\n",
        "replace": "    if False:\n",
        "test": ["bash", ".agents/test-sync-claude.sh"],
        # An unguarded lookup raises KeyError, which also stops the run. The
        # guard's product is the clean refusal, so that is what to require.
        "expect": "the undefined-tier refusal must name the bad tier and the defined set",
    },
    {
        "guard": "sync-claude/dead-models-block",
        "file": ".agents/sync-claude-agents.sh",
        "find": 'if "models" in local:\n',
        "replace": "if False:\n",
        "test": ["bash", ".agents/test-sync-claude.sh"],
        "expect": "a dead config.json models block must warn",
    },
    {
        "guard": "stack-packs/detect-required",
        "file": ".agents/check-stack-packs.py",
        "find": "        if not marks:\n",
        "replace": "        if False:\n",
        "test": ["bash", ".agents/test-stack-packs.sh"],
        "expect": "a missing detect: must be refused, not reported as a stale pack",
    },
    {
        "guard": "stack-packs/paths-required",
        "file": ".agents/check-stack-packs.py",
        "find": '        if not globs(pack, "paths"):\n',
        "replace": "        if False:\n",
        "test": ["bash", ".agents/test-stack-packs.sh"],
        "expect": "a missing paths: must be refused, not reported as a stale pack",
    },
    {
        "guard": "stack-packs/carrier-exemption",
        "file": ".agents/check-stack-packs.py",
        "find": "    if carrier():\n",
        "replace": "    if False:\n",
        "test": ["bash", ".agents/test-stack-packs.sh"],
        "expect": "the carrier must pass with every pack and no matching file",
    },
    {
        "guard": "stack-packs/detect-decides-presence",
        "file": ".agents/check-stack-packs.py",
        # Read `paths:` instead of `detect:` and the gate passes stack-expo in a
        # Next.js repository: both own `app/**/*.tsx`. This is the row that says
        # the two keys answer different questions.
        "find": '        marks = globs(pack, "detect")\n',
        "replace": '        marks = globs(pack, "paths")\n',
        "test": ["bash", ".agents/test-stack-packs.sh"],
        "expect": "the report must name stack-expo.md",
    },
]


def tracked_copy(destination):
    """The working tree, as a committable git repository.

    Tracked files plus untracked ones git would add — a gate under development
    is not committed yet, and a copy that omitted it would report every row on
    that gate as a control failure. Ignored paths stay behind, which is what
    keeps the 250 MB of node_modules under mcp-servers out of every row.

    The copy is committed because a suite that builds its fixture from
    `git ls-files` reads an empty manifest in a directory that is not a
    repository, and dies before it reaches any mutation.
    """
    os.makedirs(destination, exist_ok=True)
    listing = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=REPO, capture_output=True, check=True)
    archive = subprocess.run(["tar", "-cf", "-", "--null", "-T", "-"],
                             cwd=REPO, input=listing.stdout, capture_output=True, check=True)
    subprocess.run(["tar", "-xf", "-"], cwd=destination, input=archive.stdout, check=True)
    quiet = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
             "-c", "user.name=mutation", "-c", "user.email=mutation@invalid"]
    subprocess.run(["git", "init", "-q"], cwd=destination, check=True)
    subprocess.run(["git"] + quiet + ["add", "-A"], cwd=destination, check=True)
    subprocess.run(["git"] + quiet + ["commit", "-qm", "baseline"], cwd=destination, check=True)


def run_suite(row, cwd, limit=None):
    """Exit code and combined output, or (None, "") when the suite ran out of time.

    Removing a guard is exactly the class of change that unbounds a loop or makes
    a check retry forever, and the report prints only after every row finishes —
    so an untimed row is a CI job that hangs with nothing to show for it.
    """
    try:
        result = subprocess.run(row["test"], cwd=cwd, capture_output=True,
                                text=True, timeout=limit)
    except subprocess.TimeoutExpired:
        return None, ""
    return result.returncode, (result.stdout or "") + (result.stderr or "")


def main():
    wanted = [sys.argv[i + 1] for i, a in enumerate(sys.argv) if a == "--row"]
    rows = [r for r in ROWS if not wanted or r["guard"] in wanted]
    if not rows:
        print(f"no row matches {wanted}", file=sys.stderr)
        return 1

    verdicts, controlled = [], {}
    with tempfile.TemporaryDirectory() as scratch:
        pristine = os.path.join(scratch, "pristine")
        tracked_copy(pristine)

        for row in rows:
            key = " ".join(row["test"])

            # One control per distinct suite: it must pass unmutated, or nothing
            # this suite reports about any guard can be believed.
            if key not in controlled:
                started = time.monotonic()
                code, output = run_suite(row, pristine, limit=CONTROL_LIMIT)
                elapsed = time.monotonic() - started
                controlled[key] = (code == 0, output, elapsed)
                print(f"control  {'pass' if code == 0 else 'FAIL'}  {elapsed:5.1f}s  {key}")
            ok, control_output, elapsed = controlled[key]
            if not ok:
                verdicts.append(("CONTROL-FAILED", row["guard"],
                                 f"{key} does not pass unmutated:\n"
                                 + control_output.strip()[-400:]))
                continue

            # The fragment must be text the suite prints only on failure. One that
            # also appears on this green run turns the row into "exited non-zero",
            # and then a mutation nowhere near this guard certifies it.
            if row["expect"] in control_output:
                verdicts.append(("VACUOUS", row["guard"],
                                 f"{row['expect']!r} is already in the passing output of {key}; "
                                 "any non-zero exit would satisfy this row"))
                continue

            target = os.path.join(pristine, row["file"])
            with open(target, encoding="utf-8") as handle:
                source = handle.read()
            hits = source.count(row["find"])
            if hits != 1:
                verdicts.append(("STALE", row["guard"],
                                 f"{row['file']} holds the guard text {hits} times, expected 1"))
                continue

            work = os.path.join(scratch, "row")
            shutil.rmtree(work, ignore_errors=True)
            shutil.copytree(pristine, work, symlinks=True)
            with open(os.path.join(work, row["file"]), "w", encoding="utf-8") as handle:
                handle.write(source.replace(row["find"], row["replace"]))

            # A mutated suite gets several times the control's own duration. Well
            # past ordinary variance, short enough that a hang is a verdict.
            code, output = run_suite(row, work, limit=max(60.0, elapsed * 5))
            if code is None:
                verdicts.append(("TIMEOUT", row["guard"],
                                 f"{key} did not finish within {max(60.0, elapsed * 5):.0f}s "
                                 f"(control took {elapsed:.1f}s)"))
            elif code == 0:
                verdicts.append(("UNPROTECTED", row["guard"],
                                 f"{key} still passes with the guard removed"))
            elif row["expect"] in output:
                verdicts.append(("PROTECTED", row["guard"], ""))
            else:
                verdicts.append(("INCONCLUSIVE", row["guard"],
                                 f"{key} failed without printing {row['expect']!r}:\n"
                                 + output.strip()[-400:]))

    print()
    width = max(len(v[0]) for v in verdicts)
    for verdict, guard, detail in verdicts:
        print(f"{verdict.ljust(width)}  {guard}")
        if detail:
            for line in detail.splitlines():
                print(f"{' ' * width}    {line}")

    tally = {}
    for verdict, _, _ in verdicts:
        tally[verdict] = tally.get(verdict, 0) + 1
    print("\n" + "  ".join(f"{name}={count}" for name, count in sorted(tally.items())))

    # Every verdict but PROTECTED fails the build. `.agents/AGENTS.md` states the
    # rule as "a guard ships with a test that goes red when the guard is removed"
    # and names this file as its enforceable statement, so UNPROTECTED has to
    # block: a green check beside an uncovered guard is the same green light
    # wired to nothing, one level up. A new guard's row is written with the guard,
    # or the guard is deleted.
    return 0 if set(tally) <= {"PROTECTED"} else 1


if __name__ == "__main__":
    sys.exit(main())
