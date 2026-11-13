"""Lane-size warnings for the workloop digest, read from state and Git.

A lane past any limit is warned about, never refused: one behaviour per lane
keeps review and merge small. Every figure is best effort. All Git calls of
one digest share one deadline, so a slow repository costs the prompt at most
GIT_BUDGET seconds in total; a figure Git could not give reads "size unknown"
in the digest and is explained on stderr.

This module imports nothing from the workloop controller, so a trimmed export
that ships only the hooks still gets the digest.
"""

from __future__ import annotations

import calendar
import os
import subprocess
import sys
import time
from pathlib import Path

MAX_CHANGED_LINES = 800
MAX_LANE_PATHS = 15
WIDEN_LIMIT = 2
OPEN_RUN_SECONDS = 24 * 3600
GIT_BUDGET = 5
SPLIT_REMEDY = "split what remains into a new lane after this one is reviewed"


def stamp(value: str | None) -> float | None:
    if not value:
        return None
    try:
        return float(calendar.timegm(time.strptime(value, "%Y-%m-%dT%H:%M:%SZ")))
    except ValueError:
        return None


class GitBudget:
    """Runs Git against one shared deadline and counts the calls it had to drop."""

    def __init__(self) -> None:
        self.deadline = time.monotonic() + GIT_BUDGET
        self.dropped = 0

    def out(self, repo: Path, *args: str) -> str | None:
        """Git's stdout, or None with a note on stderr: a missing figure is dropped, not fatal."""
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            return self._drop(args, repo, "the digest's Git time is spent")
        # Git's location variables (GIT_DIR, GIT_WORK_TREE, ...), inherited from a
        # git hook or a bare-repository dotfiles setup, would point every call at
        # one repository.
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        try:
            # Every caller only reads; without --no-optional-locks a status takes
            # .git/index.lock to refresh the index and fails a concurrent `git add`
            # or `git commit` of another session in the same checkout.
            result = subprocess.run(["git", "--no-optional-locks", "-C", str(repo), *args],
                                    text=True, capture_output=True, timeout=remaining, env=env)
        except (OSError, subprocess.TimeoutExpired) as error:
            return self._drop(args, repo, str(error))
        if result.returncode != 0:
            return self._drop(args, repo, result.stderr.strip())
        return result.stdout

    def _drop(self, args: tuple[str, ...], repo: Path, reason: str) -> None:
        self.dropped += 1
        print(f"workloop-inbox: git {args[0]} in {repo} dropped: {reason}", file=sys.stderr)
        return None


def status_paths(out: str) -> set[str]:
    """The paths in the stdout of `git status --porcelain -z`, a rename's or copy's from-path included."""
    found, entries = set(), iter(out.split("\0"))
    for entry in entries:
        if len(entry) > 3:
            found.add(entry[3:])
            if entry[0] in "RC":
                found.add(next(entries, ""))
    return found


def changed_lines(git: GitBudget, lane: dict, run: dict) -> int | None:
    workspace = Path(lane.get("workspace") or "")
    origin = lane.get("start") if lane.get("place") == "main" else run.get("base")
    if not origin or not workspace.is_dir():
        return None
    paths = [*lane.get("paths", []), *run.get("shared", [])]
    # diff-index, unlike diff, never refreshes the checkout's index, which a
    # cell's `git add` may be writing at the same moment.
    out = git.out(workspace, "diff-index", "--numstat", origin, "--", *paths)
    if out is None:
        return None
    # Binary files report "-" and count as no lines.
    return sum(int(count) for row in out.splitlines() for count in row.split("\t")[:2] if count.isdigit())


def commits_behind(git: GitBudget, run: dict) -> tuple[int, str] | None:
    """Commits on the default branch past the run base, with that branch's name."""
    repo = Path(run.get("repo") or "")
    if not repo.is_dir() or not run.get("base"):
        return None
    # for-each-ref exits 0 with no output for a ref that is absent, so a repository
    # without origin/HEAD, main or master falls through quietly.
    for pattern, field in (("refs/remotes/origin/HEAD", "symref"), ("refs/heads/main", "refname"), ("refs/heads/master", "refname")):
        found = git.out(repo, "for-each-ref", f"--format=%({field}:short)", pattern)
        if found is None:
            return None
        branch = found.strip().splitlines()[0] if found.strip() else ""
        if branch:
            out = git.out(repo, "rev-list", "--count", f"{run['base']}..{branch}")
            return (int(out), branch) if out and out.strip().isdigit() else None
    return None


def size_notes(git: GitBudget, run: dict, now: float) -> list[str]:
    """Warnings for a lane not yet reviewed whose size says it holds more than one behaviour."""
    widens: dict[str, int] = {}
    opened = None
    for event in run.get("events", []):
        if event.get("action") == "widen":
            widens[event.get("lane")] = widens.get(event.get("lane"), 0) + 1
        elif event.get("action") == "init":
            opened = stamp(event.get("at"))
    unreviewed_worktree = any(lane.get("state") != "reviewed" and lane.get("place") != "main" for lane in run["lanes"].values())
    old_run = opened is not None and now - opened > OPEN_RUN_SECONDS
    behind = commits_behind(git, run) if old_run and unreviewed_worktree else None
    notes: list[str] = []
    for lane_name, lane in sorted(run["lanes"].items()):
        if lane.get("state") == "reviewed":
            continue
        before = git.dropped
        lines = changed_lines(git, lane, run)
        if git.dropped > before:
            notes.append(f"size unknown for {lane_name}")
        elif lines is not None and lines > MAX_CHANGED_LINES:
            notes.append(f"{lane_name} has {lines:,} changed lines (over {MAX_CHANGED_LINES}): {SPLIT_REMEDY}")
        owned = len(lane.get("paths", []))
        if owned > MAX_LANE_PATHS:
            notes.append(f"{lane_name} owns {owned} paths (over {MAX_LANE_PATHS}): {SPLIT_REMEDY}")
        if widens.get(lane_name, 0) >= WIDEN_LIMIT:
            notes.append(f"{lane_name} was widened {widens[lane_name]} times (the second widen is the limit): {SPLIT_REMEDY}")
        if behind and behind[0] and lane.get("place") != "main":
            notes.append(f"{lane_name}'s run has been open over a day and {behind[1]} has {behind[0]} commit(s) past its base: {SPLIT_REMEDY}")
    return notes
