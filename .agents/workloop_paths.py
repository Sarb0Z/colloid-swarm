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
# Where `brief` leaves each role's full brief: inside a worktree lane, or under
# the run's folder for a main lane, so nothing lands in the checkout's tree.
BRIEF_FOLDER = ".workloop"
# How a writing or QA cell tests, waits and edits; a worker's and a QA brief carry it.
WORKING_PRACTICE = Path(__file__).resolve().parent / "skills/workloop/working-practice.md"
# Folders the system clears on its own, which once took a run's lanes with them.
TEMPORARY_ROOTS = tuple({Path("/tmp"), Path("/private/tmp"), Path(tempfile.gettempdir()).resolve()})


def scratch_line(run: dict, run_name: str, cell: str) -> str:
    """Create a writing or QA cell's own kept-scratch folder under the run and return the brief's line naming it.

    It lives under `.agents/worktrees/<run>/scratch/`, which the checkout
    ignores and the run's closed record keeps, so nothing the lead may read
    later sits in a `$TMPDIR` the system clears or a sibling cell shares.
    """
    root = Path(run["repo"]) / WORKTREES / run_name / "scratch"
    folder = root / cell
    folder.mkdir(parents=True, exist_ok=True)
    (root / ".gitignore").write_text("*\n")
    return (f"Scratch: {folder} — yours alone: keep there anything the lead may read later, and make throwaway "
            f"folders with mktemp -d {folder}/tmp.XXXXXX, never under $TMPDIR.")


def normalize_path(value: str) -> str:
    path = PurePosixPath(value)
    if not value or path.is_absolute() or ".." in path.parts or str(path) == ".":
        fail(f"path must be a repository-relative file or directory: {value!r}")
    return str(path).rstrip("/")


def owned(path: str, declared: list[str]) -> bool:
    return wg.within(path, declared)


def overlaps(left: list[str], right: list[str]) -> bool:
    return any(owned(path, right) for path in left) or any(owned(path, left) for path in right)


def owning_lane(paths: list[str], lanes: dict, exclude: str | None = None) -> str | None:
    """The lane, other than `exclude`, whose owned paths overlap `paths`; None when none does.

    One check for every command that gives a path an owner or a sharer:
    add-lane and widen refuse the overlap because writing lanes own their
    paths exclusively, share because a shared path has no owner.
    """
    return next((name for name, other in lanes.items() if name != exclude and overlaps(paths, other["paths"])), None)


def canonical_reference(value: str, roots: list[Path]) -> str:
    """Validate a review reference as a file in the first of `roots` that has it.

    A report kept in the main checkout is reachable from every lane; one the
    lane committed in its own worktree resolves there. An absolute path names
    any existing file, such as a report written in another project.
    """
    file_name, separator, anchor = value.partition("#")
    if PurePosixPath(file_name).is_absolute():
        target = Path(file_name).resolve()
        if not target.is_file():
            fail(f"review reference must name an existing file: {value!r}")
        suffix = "#" + anchor if separator else ""
        # Inside a root it is the repository's own file, which the lane's
        # diff and dirty checks match by repository-relative path.
        for root in roots:
            try:
                return str(target.relative_to(root.resolve())) + suffix
            except ValueError:
                continue
        return str(target) + suffix
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


def source_branch(run: dict) -> str | None:
    """The branch the run was cut from (ruling R11); None for a run started from a detached commit.

    A run recorded before the field existed takes the branch checked out in
    its checkout at its first use, and keeps it: a command holding the state
    lock writes it back with the run.
    """
    if "source" not in run:
        run["source"] = wg.current_branch(Path(run["repo"]))
    return run["source"]


def source_tip(run: dict) -> str:
    """The source branch's commit now; the run's recorded base when it has no source branch."""
    branch = source_branch(run)
    tip = wg.branch_tip(Path(run["repo"]), branch) if branch else None
    if branch and tip is None:
        fail(f"the run's source branch {branch} no longer exists in {run['repo']}")
    return tip or run["base"]


def lane_base(run: dict, head: str) -> str:
    """Where a worktree lane's history leaves its source branch: the merge-base of its tip
    with that branch's tip now, so a lane that merged or rebased onto the branch is measured
    from there, not from the commit recorded at init (ruling R2)."""
    return wg.merge_base(Path(run["repo"]), head, source_tip(run)) or run["base"]


def start_point(run: dict, lane_name: str, head: str) -> str:
    """The commit this lane's own work starts from.

    A lane rebased onto a sibling's branch carries the sibling's files; they
    are the sibling's work, not this lane's. A sibling branch that shares
    history with `head` beyond the lane's base marks such a rebase, and the
    newest of those merge-bases is where this lane's own commits begin. A
    merge-base counts only when the sibling is in review or reviewed and
    everything it adds past the base lies inside its own paths: otherwise the
    rebase would launder a change the sibling was never allowed to make.
    """
    repo, base = Path(run["repo"]), lane_base(run, head)
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


def foreign_paths(run: dict, lane_name: str, lane: dict, actual: list[str]) -> tuple[list[str], list[str]]:
    """(paths another lane of the run owns, any other path outside this lane's).

    The first refuse a handoff: two writers would edit one file. The second
    are listed for the reviewer as outside the lane, never refused: a fix to
    an unowned file, or a file the writer created beside its work, is the
    reviewer's call.
    """
    outside = undeclared_paths(run, lane, actual)
    owned_elsewhere = [path for path in outside if owning_lane([path], run["lanes"], lane_name)]
    return owned_elsewhere, [path for path in outside if path not in owned_elsewhere]


def review_start(run: dict, lane_name: str, lane: dict) -> str | None:
    """The start the reviewer reads from: the one submit recorded, or, before a submit, the live one."""
    if lane.get("start") and lane.get("tip"):
        return lane["start"]
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
