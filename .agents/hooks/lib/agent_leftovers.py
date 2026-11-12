"""What a dead agent left in this checkout, and the line that says so.

An agent belongs to this checkout when its session's folder or a path it
edited lies in one of the checkout's worktrees, or in a worktree the sweep
removed after saving it to a `saved/<name>` branch (worktree_removal.py names
the worktree in that commit's subject), or when it holds a lane or a cell of
a run here. What it left: edited files still uncommitted, counted per
worktree; a `saved/` branch holding any of them; its lane or cell; or, for an
agent of the reading session, its failure itself.
"""

from __future__ import annotations

import os
import re
import time
from functools import cached_property
from pathlib import Path

SAVED_SUBJECT = "Save unsaved work from worktree "
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")


def real(path: str) -> Path:
    return Path(os.path.realpath(path))


def git_key(repo: Path) -> list[int] | None:
    """Times that change when a worktree or a `saved/` branch comes or goes, or None in a linked
    worktree, whose `.git` is a file: there Git is asked every time."""
    common = repo / ".git"
    if not common.is_dir():
        return None
    return [mtime_ns(common / "worktrees"), mtime_ns(common / "refs" / "heads" / "saved"), mtime_ns(common / "packed-refs")]


def mtime_ns(path: Path) -> int:
    try:
        return os.stat(path).st_mtime_ns
    except FileNotFoundError:
        return 0


class Places:
    """This checkout's worktrees, and the `saved/` branches of removed ones, by real path.
    Git is asked the first time either is needed, and not again while `git_key` holds: the
    lists from the last read are passed in as `known`, and `known` is what to keep after."""

    def __init__(self, repo: Path, git, known: dict) -> None:
        self.repo, self.git, self.top, self.known = repo, git, real(str(repo)), known

    @cached_property
    def listed(self) -> dict:
        key = git_key(self.repo)
        if key is not None and self.known.get("key") == key:
            return self.known
        listing = self.git(self.repo, "worktree", "list", "--porcelain")
        refs = self.git(self.repo, "for-each-ref", "--format=%(refname:short)%09%(objectname)%09%(subject)", "refs/heads/saved/")
        fresh = {"key": key, "live": [line[len("worktree "):] for line in (listing or "").splitlines() if line.startswith("worktree ")],
                 "saved": [[subject[len(SAVED_SUBJECT):], name, commit]
                           for name, commit, subject in (line.split("\t", 2) for line in (refs or "").splitlines() if line.count("\t") >= 2)
                           if subject.startswith(SAVED_SUBJECT)]}
        if key is not None and listing is not None and refs is not None:
            self.known = fresh
        return fresh

    @cached_property
    def live(self) -> set[Path]:
        return {path for path in map(real, self.listed["live"]) if path.is_dir()} or {self.top}

    @cached_property
    def saved(self) -> list[tuple[Path, str, str]]:
        return [(real(root), name, commit) for root, name, commit in self.listed["saved"]]

    @cached_property
    def roots(self) -> list[Path]:
        # Deepest first, so a nested worktree claims its own files before the checkout around it does.
        return sorted(self.live | {root for root, _, _ in self.saved}, key=lambda p: len(p.parts), reverse=True)

    def inside(self, path: str) -> bool:
        """Whether the path lies in this checkout, its worktrees or a saved one; the checkout
        itself is tested first, without Git."""
        return bool(path) and (real(path).is_relative_to(self.top) or self.root_of(path) is not None)

    def root_of(self, path: str) -> Path | None:
        target = real(path)
        return next((root for root in self.roots if target.is_relative_to(root)), None)

    def uncommitted(self, root: Path, names: set[str]) -> set[str] | None:
        """The names Git reports as changed or untracked in `root`; None when Git gave no answer."""
        out = self.git(root, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--", *sorted(names))
        if out is None:
            return None
        found, entries = set(), iter(out.split("\0"))
        for entry in entries:
            if len(entry) > 3:
                found.add(entry[3:])
                if entry[0] in "RC":
                    found.add(next(entries, ""))
        return found & names

    def saved_with(self, root: Path, names: set[str]) -> str | None:
        """The `saved/` branch of the removed worktree `root` whose commit holds any of the names."""
        for saved_root, name, commit in self.saved:
            if saved_root != root:
                continue
            changed = self.git(self.repo, "diff-tree", "-r", "--root", "--name-only", "--no-commit-id", commit)
            if changed and names & set(changed.splitlines()):
                return name
        return None


def run_agents(runs: dict) -> dict[str, str]:
    """Agents holding a lane or a cell of a live run, with the clause that says which."""
    held = {}
    for run_name, run in runs.items():
        for lane_name, lane in run.get("lanes", {}).items():
            if lane.get("state") == "active" and lane.get("claimed_by"):
                held[lane["claimed_by"]] = f"it holds lane {run_name}/{lane_name}"
        for cell_name, cell in (run.get("cells") or {}).items():
            if cell.get("state") == "out" and cell.get("agent_id"):
                held[cell["agent_id"]] = f"it is cell {run_name}/{cell_name}, still out"
    return held


def belongs(agent_id: str, info: dict, places: Places, held: dict) -> bool:
    return agent_id in held or any(places.inside(path) for path in [info["ends"]["cwd"], *info["edits"]])


def edits_left(info: dict, places: Places) -> list[str]:
    """A clause per worktree holding the agent's uncommitted edits, or per `saved/` branch holding them."""
    groups: dict[Path, set[str]] = {}
    for path in info["edits"]:
        root = places.root_of(path)
        if root:
            groups.setdefault(root, set()).add(real(path).relative_to(root).as_posix())
    clauses = []
    for root, names in sorted(groups.items()):
        if root in places.live:
            left = places.uncommitted(root, names)
            if left is None:
                clauses.append(f"{len(names)} edited files in {root}, uncommitted count unknown")
            elif left:
                clauses.append(f"{len(left)} of its {len(names)} edited files uncommitted in {root}")
        elif branch := places.saved_with(root, names):
            clauses.append(f"its edits in {root} were saved on {branch}")
    return clauses


def leftovers(agent_id: str, info: dict, edits: list[str], held: dict, own: str) -> list[str]:
    """One clause per thing the agent left, its edits' clauses first; none when it left nothing."""
    clauses = edits + ([held[agent_id]] if agent_id in held else [])
    return clauses or (["it died in this session"] if info["session"] == own else [])


def clean(text: str) -> str:
    return CONTROL.sub(" ", text).replace('"', "'")


def line(agent_id: str, info: dict, verdict, clauses: list[str], own: str, live: str) -> str:
    """The AGENT DIED line, AGENT PARKED for a parked agent: who, how and when, its session, what
    it left, and the remedy. `live` is the session's state as the reader could tell it: live,
    ended or unknown."""
    session = info["session"]
    when = time.strftime("%Y-%m-%d %H:%M", time.localtime(verdict.at)) if verdict.at else "an unknown time"
    head = "AGENT PARKED" if verdict.state == "parked" else "AGENT DIED"
    if verdict.state == "parked":
        remedy = f"restart its background session and agents: `claude respawn {verdict.job}`"
    elif session == own:
        remedy = f"resume it: SendMessage to {agent_id}"
    else:
        where = "its open terminal" if live == "live" else f"`claude --resume {session}`"
        remedy = (f"resume session {session} ({where}) and message agent {agent_id}; "
                  "to send the work again instead, dismiss this first")
    meta = info["meta"]
    return (f'{head}: "{clean(meta["description"])}" ({clean(meta["type"])}, {agent_id}) {verdict.cause} at {when}, '
            f"session {session} ({live}); {'; '.join(clauses)}; {remedy}; "
            f"dismiss: .agents/workloop.py dismiss {agent_id} --reason '<why>'")
