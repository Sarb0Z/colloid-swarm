"""What a dead agent left in this checkout, and the line that says so.

An agent belongs to this checkout when its session's folder or a path it
edited lies in one of the checkout's worktrees, or in a worktree the sweep
removed after saving it to a `saved/<name>` branch (worktree_removal.py names
the worktree in that commit's subject), or when it holds a lane or a cell of
a run here. What it left: edited files still uncommitted, counted per
worktree; a `saved/` branch holding any of them; its lane or cell; or, for an
agent of the reading session, its failure itself.

A Git call that gives no answer leaves the question open rather than answered
"no": `belongs` then answers None, and `edits_left` gives a clause saying the
uncommitted count is unknown, so the agent is never cached as having left
nothing and the next read asks again.
"""

from __future__ import annotations

import os
import time
from functools import cached_property
from pathlib import Path

from agent_records import mtime_ns
from readout import CONTROL
from workloop_size import status_paths

SAVED_SUBJECT = "Save unsaved work from worktree "


def _real(path: str) -> Path:
    return Path(os.path.realpath(path))


def _git_key(repo: Path) -> list[int] | None:
    """Times that change when a worktree or a `saved/` branch comes or goes, or None in a linked
    worktree, whose `.git` is a file: there Git is asked every time."""
    common = repo / ".git"
    if not common.is_dir():
        return None
    return [mtime_ns(common / "worktrees"), mtime_ns(common / "refs" / "heads" / "saved"), mtime_ns(common / "packed-refs")]


class Places:
    """This checkout's worktrees, and the `saved/` branches of removed ones, by real path.
    Git is asked the first time either is needed, and not again while `_git_key` holds: the
    lists from the last read are passed in as `known`, and `known` is what to keep after.
    `unanswered` names each Git subcommand that gave no answer during this read."""

    def __init__(self, repo: Path, git, known: dict) -> None:
        self.repo, self.git, self.top, self.known = repo, git, _real(str(repo)), known
        self.unanswered: set[str] = set()

    def _ask(self, root: Path, *args: str) -> str | None:
        out = self.git(root, *args)
        if out is None:
            self.unanswered.add(" ".join(args[:2]) if args[0] == "worktree" else args[0])
        return out

    @cached_property
    def listed(self) -> dict:
        key = _git_key(self.repo)
        if key is not None and self.known.get("key") == key:
            return self.known
        listing = self._ask(self.repo, "worktree", "list", "--porcelain")
        refs = self._ask(self.repo, "for-each-ref", "--format=%(refname:short)%09%(objectname)%09%(subject)", "refs/heads/saved/")
        fresh = {"key": key, "live": [line[len("worktree "):] for line in (listing or "").splitlines() if line.startswith("worktree ")],
                 "saved": [[subject[len(SAVED_SUBJECT):], name, commit]
                           for name, commit, subject in (line.split("\t", 2) for line in (refs or "").splitlines() if line.count("\t") >= 2)
                           if subject.startswith(SAVED_SUBJECT)]}
        if key is not None and listing is not None and refs is not None:
            self.known = fresh
        return fresh

    @property
    def placed_all(self) -> bool:
        """Whether the worktree and `saved/` lists are whole: a path no root holds is then outside."""
        return not self.unanswered & {"worktree list", "for-each-ref"}

    @cached_property
    def live(self) -> set[Path]:
        return {path for path in map(_real, self.listed["live"]) if path.is_dir()} or {self.top}

    @cached_property
    def saved(self) -> list[tuple[Path, str, str]]:
        return [(_real(root), name, commit) for root, name, commit in self.listed["saved"]]

    @cached_property
    def roots(self) -> list[Path]:
        # Deepest first, so a nested worktree claims its own files before the checkout around it does.
        return sorted(self.live | {root for root, _, _ in self.saved}, key=lambda p: len(p.parts), reverse=True)

    def inside(self, path: str) -> bool:
        """Whether the path lies in this checkout, its worktrees or a saved one; the checkout
        itself is tested first, without Git."""
        return bool(path) and (_real(path).is_relative_to(self.top) or self.root_of(path) is not None)

    def root_of(self, path: str) -> Path | None:
        target = _real(path)
        return next((root for root in self.roots if target.is_relative_to(root)), None)

    def uncommitted(self, root: Path, names: set[str]) -> set[str] | None:
        """The names Git reports as changed or untracked in `root`; None when Git gave no answer."""
        out = self._ask(root, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--", *sorted(names))
        if out is None:
            return None
        return status_paths(out) & names

    def saved_with(self, root: Path, names: set[str]) -> tuple[str | None, bool]:
        """The `saved/` branch of the removed worktree `root` whose commit holds any of the names,
        and whether Git answered for every branch it had to look in."""
        answered = True
        for saved_root, name, commit in self.saved:
            if saved_root != root:
                continue
            changed = self._ask(self.repo, "diff-tree", "-r", "--root", "--name-only", "--no-commit-id", commit)
            if changed is None:
                answered = False
            elif names & set(changed.splitlines()):
                return name, True
        return None, answered


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


def belongs(agent_id: str, info: dict, places: Places, held: dict) -> bool | None:
    """Whether the agent is this checkout's; None when a Git list that could have placed it gave no answer."""
    if agent_id in held or any(places.inside(path) for path in [info["ends"]["cwd"], *info["edits"]]):
        return True
    return False if places.placed_all else None


def edits_left(info: dict, places: Places) -> list[str]:
    """A clause per worktree holding the agent's uncommitted edits, or per `saved/` branch holding
    them. Where Git gave no answer a clause says the count is unknown, so the list is empty only
    when Git answered that nothing is left."""
    if not info["edits"]:
        return []
    groups: dict[Path, set[str]] = {}
    unplaced = 0
    for path in info["edits"]:
        root = places.root_of(path)
        if root:
            groups.setdefault(root, set()).add(_real(path).relative_to(root).as_posix())
        else:
            unplaced += 1
    # Without the worktree list every edit falls to the checkout's own root, so no grouping holds.
    if "worktree list" in places.unanswered:
        return [f"{len(info['edits'])} edited files, uncommitted count unknown"]
    clauses = [] if places.placed_all or not unplaced else [f"{unplaced} edited files, uncommitted count unknown"]
    for root, names in sorted(groups.items()):
        if root in places.live:
            left = places.uncommitted(root, names)
            if left is None:
                clauses.append(f"{len(names)} edited files in {root}, uncommitted count unknown")
            elif left:
                clauses.append(f"{len(left)} of its {len(names)} edited files uncommitted in {root}")
            continue
        branch, answered = places.saved_with(root, names)
        if branch:
            clauses.append(f"its edits in {root} were saved on {branch}")
        elif not answered:
            clauses.append(f"{len(names)} edited files in {root}, uncommitted count unknown")
    return clauses


def leftovers(agent_id: str, info: dict, edits: list[str], held: dict, own: str) -> list[str]:
    """One clause per thing the agent left, its edits' clauses first; none when it left nothing."""
    clauses = edits + ([held[agent_id]] if agent_id in held else [])
    return clauses or (["it died in this session"] if info["session"] == own else [])


def _clean(text: str) -> str:
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
    return (f'{head}: "{_clean(meta["description"])}" ({_clean(meta["type"])}, {agent_id}) {verdict.cause} at {when}, '
            f"session {session} ({live}); {'; '.join(clauses)}; {remedy}; "
            f"dismiss: .agents/workloop.py dismiss {agent_id} --reason '<why>'")
