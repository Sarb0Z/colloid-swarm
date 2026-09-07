#!/usr/bin/env python3
"""Git, provisioning, and composition steps behind workloop.py.

workloop.py owns the state file and its transitions; everything that shells
out lives here, so a reader of the controller sees decisions and a reader of
this file sees every command the controller can run.
"""

from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHA = re.compile(r"[0-9a-f]{40}")
VERIFY_TIMEOUT = 1800
TAIL_LINES = 40


def fail(message: str) -> None:
    raise SystemExit(f"workloop: {message}")


def git(repo: Path | str, *args: str, check: bool = True, strip: bool = True) -> str:
    result = subprocess.run(["git", "-C", str(repo), *args], text=True, capture_output=True)
    if check and result.returncode != 0:
        fail(f"git {' '.join(args)} failed in {repo}: {(result.stderr or result.stdout).strip()}")
    return result.stdout.strip() if strip else result.stdout


def toplevel(path: Path | str) -> Path:
    return Path(git(path, "rev-parse", "--show-toplevel")).resolve()


def is_linked_worktree(path: Path | str) -> bool:
    # Both paths come back absolute, so the comparison is between canonical
    # locations rather than between the `.git` and `../.git` spellings git
    # prints from a subdirectory.
    out = git(path, "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir", check=False)
    lines = out.splitlines()
    return len(lines) == 2 and Path(lines[0]).resolve() != Path(lines[1]).resolve()


def same_repository(path: Path | str, repo: Path | str) -> bool:
    mine = git(path, "rev-parse", "--path-format=absolute", "--git-common-dir", check=False)
    theirs = git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir", check=False)
    return bool(mine) and Path(mine).resolve() == Path(theirs).resolve()


def resolve_commit(repo: Path | str, rev: str) -> str:
    sha = git(repo, "rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}", check=False)
    if not SHA.fullmatch(sha):
        fail(f"base {rev!r} does not name a commit in {repo}")
    return sha


def branch_of(workspace: Path | str) -> str:
    name = git(workspace, "symbolic-ref", "--quiet", "--short", "HEAD", check=False)
    if not name:
        fail(f"lane workspace must be on a branch, not detached: {workspace}")
    return name


def branch_tip(repo: Path | str, branch: str) -> str | None:
    sha = git(repo, "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}^{{commit}}", check=False)
    return sha if SHA.fullmatch(sha) else None


def is_ancestor(repo: Path | str, ancestor: str, descendant: str) -> bool:
    return subprocess.run(
        ["git", "-C", str(repo), "merge-base", "--is-ancestor", ancestor, descendant],
        capture_output=True,
    ).returncode == 0


def head_of(path: Path | str) -> str:
    return git(path, "rev-parse", "HEAD")


def worktree_root(workspace: Path) -> Path:
    if not workspace.is_dir():
        fail(f"lane workspace is missing: {workspace}")
    top = git(workspace, "rev-parse", "--show-toplevel", check=False)
    if not top:
        fail(f"lane workspace is not a Git worktree: {workspace}")
    if Path(top).resolve() != workspace.resolve():
        fail(f"lane workspace must be the worktree root: {workspace}")
    return workspace


def dirty_paths(workspace: Path | str) -> list[str]:
    # Porcelain lines are "XY path"; a modified file's X is a space, so the
    # output must not be stripped before the slice.
    lines = git(workspace, "status", "--porcelain", "--untracked-files=all", strip=False).splitlines()
    return sorted(line[3:] for line in lines if len(line) > 3)


def changed_files(workspace: Path, base: str) -> list[str]:
    seen: set[str] = set(line for line in git(workspace, "diff", "--name-only", base).splitlines() if line)
    root = workspace.resolve()
    for line in git(workspace, "ls-files", "--others", "--exclude-standard").splitlines():
        if not line:
            continue
        # A `node_modules/` ignore pattern matches directories only, so the
        # link provisioning leaves behind is listed as untracked. A link that
        # points out of the worktree is environment, never the lane's work.
        candidate = workspace / line
        if candidate.is_symlink():
            try:
                candidate.resolve().relative_to(root)
            except ValueError:
                continue
        seen.add(line)
    return sorted(seen)


def cone_for(repo: Path, base: str, paths: list[str], extra: list[str]) -> list[str]:
    """Directories a sparse lane needs on disk: each owned path's directory, plus extras.

    Cone mode takes directories only, so an owned file contributes its
    parent. A path absent at the base is a directory the lane will create —
    a new module, or the review directory — and belongs in the cone too, or
    git refuses to stage what lands there. Root-level files are always
    present in a cone.
    """
    dirs: set[str] = set()
    for path in list(paths) + list(extra):
        kind = git(repo, "cat-file", "-t", f"{base}:{path}", check=False)
        if kind == "blob":
            parent = str(Path(path).parent)
            if parent != ".":
                dirs.add(parent)
        else:
            dirs.add(path)
    return sorted(dirs)


def worktree_add(repo: Path, workspace: Path, branch: str, base: str, cone: list[str] | None = None) -> None:
    """Create the lane worktree; with a cone, populate only those directories."""
    if not cone:
        git(repo, "worktree", "add", "-q", "-b", branch, str(workspace), base)
        return
    git(repo, "worktree", "add", "-q", "--no-checkout", "-b", branch, str(workspace), base)
    git(workspace, "sparse-checkout", "set", "--cone", *cone)
    git(workspace, "read-tree", "-mu", "HEAD")


# --- provisioning ------------------------------------------------------------

def provision_script() -> Path:
    return ROOT / ".agents/provision.sh"


def provision(path: Path | str, share_from: Path | str | None = None) -> tuple[bool, str]:
    env = dict(os.environ)
    if share_from:
        env["PROVISION_SHARE_FROM"] = str(share_from)
    result = subprocess.run([str(provision_script()), str(path)], text=True, capture_output=True, env=env)
    text = (result.stdout + result.stderr).strip()
    return result.returncode == 0, text


def lock_hash(path: Path | str) -> str:
    result = subprocess.run([str(provision_script()), "--hash", str(path)], text=True, capture_output=True)
    if result.returncode != 0:
        fail(f"cannot hash lockfiles in {path}: {(result.stderr or result.stdout).strip()}")
    return result.stdout.strip()


# --- composition -------------------------------------------------------------

def topo_order(lanes: dict) -> list[str]:
    """Dependencies first, alphabetical among peers, so merge order is stable."""
    order: list[str] = []
    seen: set[str] = set()

    def visit(name: str, trail: list[str]) -> None:
        if name in seen:
            return
        if name in trail:
            fail("dependency cycle: " + " -> ".join(trail + [name]))
        for dependency in sorted(lanes[name]["depends_on"]):
            visit(dependency, trail + [name])
        seen.add(name)
        order.append(name)

    for name in sorted(lanes):
        visit(name, [])
    return order


def prepare_integration(repo: Path, workspace: Path, branch: str, base: str) -> None:
    """Leave `workspace` checked out on `branch` at exactly `base`.

    Ignored files survive the reset, so a previous integration's installed
    dependencies are reused and only the lockfile hash decides whether the
    next provision does anything.
    """
    if workspace.exists():
        # Only a linked worktree of this repository may be reset and cleaned;
        # the main checkout holds the operator's uncommitted work.
        if (not same_repository(workspace, repo) or toplevel(workspace) != workspace.resolve()
                or not is_linked_worktree(workspace)):
            fail(f"integration workspace is not a linked worktree root of {repo}: {workspace}")
        git(workspace, "merge", "--abort", check=False)
        if branch_tip(repo, branch) is None:
            git(workspace, "checkout", "-q", "-b", branch, base)
        else:
            git(workspace, "checkout", "-q", branch)
        git(workspace, "reset", "-q", "--hard", base)
        git(workspace, "clean", "-q", "-fd")
        return
    if branch_tip(repo, branch) is None:
        git(repo, "worktree", "add", "-q", "-b", branch, str(workspace), base)
    else:
        git(repo, "worktree", "add", "-q", str(workspace), branch)
        git(workspace, "reset", "-q", "--hard", base)
        git(workspace, "clean", "-q", "-fd")


def merge_lane(workspace: Path, lane: str, branch: str, merged: list[str]) -> None:
    result = subprocess.run(
        ["git", "-C", str(workspace), "merge", "--no-ff", "--no-edit", "-m", f"integrate {lane}", branch],
        text=True, capture_output=True,
    )
    if result.returncode != 0:
        git(workspace, "merge", "--abort", check=False)
        against = ", ".join(merged) if merged else "the base"
        fail(f"lane {lane!r} conflicts with {against}: {(result.stdout + result.stderr).strip()}")


def guard_command(command: str, repo: Path) -> None:
    """Refuse a verify command the destructive and publish rules would refuse.

    The controller runs the command outside any tool call, so no PreToolUse
    hook sees it. Both guards are asked with --force: the config toggles
    govern the hooks, where a denial costs the operator one tool call they
    can rephrase, and a command running unattended in the integration
    worktree has no such escape. The run's repository is passed so the
    guards read that repository's policy, not the one this file lives in.
    """
    lib = ROOT / ".agents/hooks/lib"
    destructive = subprocess.run(
        [sys.executable, str(lib / "guard-destructive.py"), str(repo), "--force"],
        input=json.dumps({"command": command}), text=True, capture_output=True,
    )
    if destructive.returncode == 2:
        fail(f"verify command refused by guard-destructive: {destructive.stderr.strip()}")
    if destructive.returncode != 0:
        fail(f"guard-destructive could not evaluate the verify command (exit {destructive.returncode}): {destructive.stderr.strip()}")
    publish = subprocess.run(
        [sys.executable, str(lib / "guard-publish.py"), str(repo), "--force"],
        input=json.dumps({"tool_name": "Bash", "tool_input": {"command": command}, "permission_mode": "default"}),
        text=True, capture_output=True,
    )
    if publish.returncode != 0:
        fail(f"guard-publish could not evaluate the verify command (exit {publish.returncode}): {publish.stderr.strip()}")
    if publish.stdout.strip():
        try:
            reason = json.loads(publish.stdout)["hookSpecificOutput"].get("permissionDecisionReason", "")
        except (ValueError, KeyError, TypeError):
            reason = publish.stdout.strip()
        fail(f"verify command refused by guard-publish: {reason}")


def run_verify(command: str, cwd: Path, timeout: int = VERIFY_TIMEOUT) -> tuple[bool, str]:
    # A new session puts the shell and everything it spawns in one process
    # group, so a timeout kills a test runner's server or watcher too, not
    # just the shell in front of it.
    process = subprocess.Popen(
        command, shell=True, cwd=str(cwd), text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True,
    )
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        return False, f"verify did not finish within {timeout}s"
    return process.returncode == 0, "\n".join((output or "").splitlines()[-TAIL_LINES:])


def remove_worktree(repo: Path, path: Path) -> bool:
    """Remove a linked worktree of `repo`; a main checkout is left alone."""
    if not path.exists() or not is_linked_worktree(path):
        return False
    if not same_repository(path, repo):
        fail(f"refusing to remove a worktree that does not belong to {repo}: {path}")
    git(repo, "worktree", "remove", "--force", str(path))
    return True


def delete_branch(repo: Path, branch: str) -> str | None:
    """Delete a branch; return git's reason when it refuses instead of raising."""
    result = subprocess.run(["git", "-C", str(repo), "branch", "-q", "-D", branch], text=True, capture_output=True)
    return None if result.returncode == 0 else (result.stderr or result.stdout).strip()
