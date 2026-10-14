"""The files a write tool's input names, and where they land, read one way by
every hook.

Edit, Write and NotebookEdit name one file under `file_path`, `path` or
`notebook_path`; MultiEdit names one per entry of `edits`. The Claude hook
normalizer, the parallel-writers gate and the product-folder grant all import
`named`, so a new key is learned in one place. The gate resolves each name with
`resolved` and asks `in_checkout` whether it belongs to the checkout, so every
one of its checks means the same thing by "inside".
"""

import os
import subprocess

KEYS = ("file_path", "path", "notebook_path")


def named(tool_input):
    """Every non-empty file name `tool_input` carries, in the order it names them."""
    if not isinstance(tool_input, dict):
        return []
    names = [tool_input.get(key) for key in KEYS]
    edits = tool_input.get("edits")
    if isinstance(edits, list):
        names += [edit.get("file_path") for edit in edits if isinstance(edit, dict)]
    return [name for name in names if isinstance(name, str) and name]


def resolved(root, tool_input):
    """The real path of every file `tool_input` names; a relative name is read from `root`."""
    return [os.path.realpath(os.path.join(root, os.path.expanduser(name))) for name in named(tool_input)]


def under(path, root):
    """True when the real path `path` is `root` or lies beneath it."""
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def in_checkout(path, root):
    """True when the real path `path` belongs to the checkout at real path `root`.

    A path under a worktree of this repository nested in the checkout, a
    workloop lane at `.agents/worktrees/<run>/<lane>`, belongs to that worktree;
    every other nested tree stays the checkout's (see `_tree_belongs`). A path
    that does not exist yet is read from its nearest existing folder.
    """
    if not under(path, root):
        return False
    folder = path
    while not os.path.isdir(folder):
        folder = os.path.dirname(folder)
    # Git finds a working tree by the nearest `.git` above a folder. With none
    # between the folder and the checkout's root, Git would stop at that root,
    # so the answer needs no Git process: the common case costs a few stats.
    probe = folder
    while probe != root and under(probe, root):
        if os.path.lexists(os.path.join(probe, ".git")):
            return _tree_belongs(folder, root)
        probe = os.path.dirname(probe)
    return True


_TREES = {}
_COMMON = {}


def _git_lines(folder, *args):
    """Git's output lines, or None when Git fails there."""
    # Git's location variables (GIT_DIR, GIT_WORK_TREE, ...), inherited from a
    # git hook, would point the call at one fixed repository.
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    try:
        done = subprocess.run(["git", "-C", folder, *args], capture_output=True, text=True, timeout=5, env=env)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return done.stdout.splitlines() if done.returncode == 0 else None


def _common_dir(root):
    if root not in _COMMON:
        dot_git = os.path.join(root, ".git")
        if os.path.isdir(dot_git):
            _COMMON[root] = os.path.realpath(dot_git)
        else:
            lines = _git_lines(root, "rev-parse", "--path-format=absolute", "--git-common-dir")
            _COMMON[root] = os.path.realpath(lines[0]) if lines else ""
    return _COMMON[root]


def _tree_belongs(folder, root):
    """Whether the working tree holding `folder` is the checkout's.

    Asked once per folder per process: the gate is one process per tool call.
    Only a worktree of this repository nested in the checkout, a workloop lane
    or a `.claude/worktrees` session, is its own: it shares the checkout's Git
    directory, so a lane is told apart in one Git call. Any other nested tree
    stays the checkout's: a submodule, which a writer in the checkout edits,
    and a repository someone ran `git init` in, which may cover files the
    checkout tracks and would otherwise let a second writer through. Whatever
    Git cannot answer is the checkout's too, so the gate fails closed.
    """
    if folder in _TREES:
        return _TREES[folder]
    belongs = True
    lines = _git_lines(folder, "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir")
    if lines and len(lines) == 2:
        top = os.path.realpath(lines[0])
        if top != root and under(top, root) and os.path.realpath(lines[1]) == _common_dir(root):
            belongs = False
    _TREES[folder] = belongs
    return belongs
