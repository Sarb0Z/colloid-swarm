"""Which paths and worktrees a lane may touch: names, ownership, and where lanes live."""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path, PurePosixPath

import workloop_git as wg
from workloop_state import fail, require_workspace, shared_of

# Lane and integration worktrees nest in the checkout they belong to, under a
# gitignored folder (decision lane-worktrees-nest-in-the-checkout).
WORKTREES = ".agents/worktrees"
# Folders the system clears on its own, which once took a run's lanes with them.
TEMPORARY_ROOTS = tuple({Path("/tmp"), Path("/private/tmp"), Path(tempfile.gettempdir()).resolve()})


def normalize_path(value: str) -> str:
    path = PurePosixPath(value)
    if not value or path.is_absolute() or ".." in path.parts or str(path) == ".":
        fail(f"path must be a repository-relative file or directory: {value!r}")
    return str(path).rstrip("/")


def owned(path: str, declared: list[str]) -> bool:
    return any(path == root or path.startswith(root + "/") for root in declared)


def overlaps(left: list[str], right: list[str]) -> bool:
    return any(owned(path, right) for path in left) or any(owned(path, left) for path in right)


def canonical_reference(value: str, roots: list[Path]) -> str:
    """Validate a review reference as a file in the first of `roots` that has it.

    A report kept in the main checkout is reachable from every lane; one the
    lane committed in its own worktree resolves there.
    """
    file_name, separator, anchor = value.partition("#")
    normalized = normalize_path(file_name)
    for root in roots:
        candidate = (root / normalized).resolve()
        try:
            candidate.relative_to(root.resolve())
        except ValueError:
            fail(f"review reference escapes the repository: {value!r}")
        if candidate.is_file():
            return normalized + ("#" + anchor if separator else "")
    fail(f"review reference must name an existing file in the main checkout or the lane worktree: {value!r}")


def reference_roots(run: dict, lane: dict) -> list[Path]:
    return [Path(run["repo"]), require_workspace(lane)]


def temporary(path: Path) -> bool:
    return any(path == root or root in path.parents for root in TEMPORARY_ROOTS)


def workspace_for(value: str | None, repo: Path, run_name: str, leaf: str, label: str) -> Path:
    """The worktree path a lane or an integration uses.

    Without --workspace it is <checkout>/.agents/worktrees/<run>/<leaf>. A
    --workspace under /tmp is refused unless the checkout lies there too: the
    system clears that folder, and the run would outlive its worktrees.
    """
    default = repo / WORKTREES / run_name / leaf
    if value is None:
        # Unignored, the worktree shows as untracked in the checkout, and a
        # `git add -A` there would commit it as an embedded repository.
        if not wg.ignored(repo, default):
            print(f"workloop: WARNING: {repo} does not ignore {WORKTREES}/; add `{WORKTREES}/` to its .gitignore "
                  "before committing there, or the worktree shows as untracked work", file=sys.stderr)
        return default
    workspace = Path(value).resolve()
    if temporary(workspace) and not temporary(repo.resolve()):
        fail(f"{label} workspace {value} lies in a temporary folder, which the system clears; omit --workspace to use the default {default}")
    return workspace


def lane_allows(run: dict, lane: dict, path: str) -> bool:
    review_paths = {item["reference"].partition("#")[0] for item in lane["review_refs"]}
    return owned(path, lane["paths"]) or owned(path, shared_of(run)) or path in review_paths


def start_point(run: dict, lane_name: str, head: str) -> str:
    """The commit this lane's own work starts from.

    A lane rebased onto a sibling's branch carries the sibling's files; they
    are the sibling's work, not this lane's. A sibling branch that shares
    history with `head` beyond the run base marks such a rebase, and the newest
    of those merge-bases is where this lane's own commits begin. A merge-base
    counts only when the sibling is in review or reviewed and everything it
    adds past the base lies inside its own paths: otherwise the rebase would
    launder a change the sibling was never allowed to make.
    """
    repo, base = Path(run["repo"]), run["base"]
    candidates: set[str] = set()
    for name, other in run["lanes"].items():
        tip = wg.branch_tip(repo, other["branch"]) if name != lane_name and other.get("branch") else None
        point = wg.merge_base(repo, head, tip) if tip else None
        # A sibling built on top of this lane merges at this lane's head; that
        # says nothing about where this lane's own work began.
        if (
            point and point not in (base, head) and wg.is_ancestor(repo, base, point)
            and other["state"] in ("review", "reviewed")
            and all(lane_allows(run, other, path) for path in map(normalize_path, wg.committed_files(repo, base, point)))
        ):
            candidates.add(point)
    newest = [point for point in candidates if all(wg.is_ancestor(repo, other, point) for other in candidates)]
    return newest[0] if newest else base


def undeclared_paths(run: dict, lane: dict, actual: list[str]) -> list[str]:
    return [path for path in actual if not lane_allows(run, lane, path)]


def review_start(run: dict, lane_name: str, lane: dict) -> str | None:
    repo = Path(run["repo"])
    tip = wg.branch_tip(repo, lane["branch"]) if lane.get("branch") else None
    return start_point(run, lane_name, tip) if tip else None


def changed_paths(lane: dict, since: str) -> list[str]:
    return [normalize_path(path) for path in wg.changed_files(require_workspace(lane), since)]


def uncommitted_owned(run: dict, lane: dict, workspace: Path) -> list[str]:
    """Dirty paths the lane owns, shares, or has a review reference for.

    An unignored install directory or a scratch file elsewhere in the
    worktree is not the lane's work and must not block its handoff.
    """
    review_paths = {item["reference"].partition("#")[0] for item in lane["review_refs"]}
    return [path for path in wg.dirty_paths(workspace) if owned(path, lane["paths"]) or owned(path, shared_of(run)) or path in review_paths]
