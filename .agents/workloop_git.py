#!/usr/bin/env python3
"""Git, provisioning, and composition steps behind workloop.py.

workloop.py owns the state file and its transitions; everything that shells
out lives here, so a reader of the controller sees decisions and a reader of
this file sees every command the controller can run.
"""

from __future__ import annotations

import fnmatch
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


def merge_base(repo: Path | str, left: str, right: str) -> str | None:
    return git(repo, "merge-base", left, right, check=False) or None


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


def committed_files(repo: Path | str, since: str, until: str) -> list[str]:
    return sorted(line for line in git(repo, "diff", "--name-only", f"{since}..{until}").splitlines() if line)


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


# Folders provisioning never enters; a lockfile or manifest inside one belongs
# to a dependency, not to the project (kept in step with provision.sh nested()).
PRUNED_FOLDERS = frozenset({"node_modules", ".git", "vendor", ".venv", "target"})
LOCKFILES = ("pnpm-lock.yaml", "bun.lock", "bun.lockb", "yarn.lock", "package-lock.json",
             "uv.lock", "poetry.lock", "Cargo.lock", "go.sum", "requirements*.txt")


def base_tree(repo: Path, base: str) -> list[str]:
    """Every tracked path at the base outside the pruned folders."""
    out = git(repo, "ls-tree", "-r", "-z", "--name-only", base, strip=False)
    return [p for p in out.split("\0") if p and not PRUNED_FOLDERS.intersection(p.split("/"))]


def _patch_folders(manifest: dict) -> list[str]:
    """Folders holding a patch file named by patchedDependencies (the pnpm and the bun key)."""
    pnpm = manifest.get("pnpm")
    patched: dict = {}
    for source in (pnpm.get("patchedDependencies") if isinstance(pnpm, dict) else None, manifest.get("patchedDependencies")):
        if isinstance(source, dict):
            patched.update(source)
    folders = set()
    for patch in patched.values():
        if not isinstance(patch, str):
            fail(f"package.json patchedDependencies holds {patch!r}, which is not a patch file path")
        parent = os.path.normpath(patch).rpartition("/")[0]
        if parent:
            folders.add(parent)
    return sorted(folders)


def _pnpm_packages(text: str) -> list[str]:
    """The block list under `packages:` in pnpm-workspace.yaml; any other shape is refused."""
    patterns: list[str] | None = None
    for raw in text.splitlines():
        line = raw.split(" #")[0].rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if patterns is None:
            if re.fullmatch(r"packages\s*:", line):
                patterns = []
            elif re.match(r"packages\s*:", line):
                fail(f"pnpm-workspace.yaml has `{line}`; only a block list under `packages:` is readable here, so give the lane the whole tree (drop --sparse)")
            continue
        if not (line[0].isspace() or line.startswith("-")):
            break
        item = re.fullmatch(r"\s*-\s+(['\"]?)(.+?)\1", line)
        if not item:
            fail(f"pnpm-workspace.yaml has `{line.strip()}` under packages:; only plain list items are readable here, so give the lane the whole tree (drop --sparse)")
        patterns.append(item.group(2))
    if not patterns:
        fail("pnpm-workspace.yaml has no readable `packages:` list; give the lane the whole tree (drop --sparse)")
    return patterns


def _glob_regex(pattern: str) -> re.Pattern[str]:
    out, i = "", 0
    pattern = pattern.removeprefix("./").rstrip("/")
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out += "(?:.*/)?"
            i += 3
        elif pattern.startswith("**", i):
            out += ".*"
            i += 2
        elif pattern[i] == "*":
            out += "[^/]*"
            i += 1
        else:
            out += re.escape(pattern[i])
            i += 1
    return re.compile(out)


def _members(patterns: list[str], tree: list[str]) -> list[str]:
    """Folders holding a package.json that a positive glob matches and no negated one does."""
    folders = {str(Path(p).parent) for p in tree if Path(p).name == "package.json"} - {"."}
    chosen: set[str] = set()
    for pattern in patterns:
        if not pattern.startswith("!"):
            rx = _glob_regex(pattern)
            chosen |= {f for f in folders if rx.fullmatch(f)}
    for pattern in patterns:
        if pattern.startswith("!"):
            rx = _glob_regex(pattern[1:])
            chosen -= {f for f in chosen if rx.fullmatch(f)}
    return sorted(chosen)


def _on_disk(folder: str, cone: list[str]) -> bool:
    """A cone checks out its folders, everything under them, and the files directly in their ancestors."""
    return folder == "." or any(
        folder == c or folder.startswith(c + "/") or c.startswith(folder + "/") for c in cone
    )


def cone_for(repo: Path, base: str, paths: list[str], extra: list[str]) -> tuple[list[str], list[str]]:
    """Directories a sparse lane needs on disk, and one note per group the install pulled in.

    The cone is each owned path's directory, the extras, and what the base
    commit's install needs: the folders holding patchedDependencies patches
    and every workspace member. Cone mode takes directories only, so an owned
    file contributes its parent. A path absent at the base is a directory the
    lane will create — a new module, or the review directory — and belongs in
    the cone too, or git refuses to stage what lands there. Root-level files
    are always present in a cone. A lockfile the cone would still drop is
    refused, because the install for its folder would silently not run.
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
    tree = base_tree(repo, base)
    gained: list[tuple[str, list[str]]] = []
    if "package.json" in tree:
        try:
            manifest = json.loads(git(repo, "show", f"{base}:package.json", strip=False))
        except json.JSONDecodeError as exc:
            fail(f"package.json at the base is not valid JSON ({exc}); give the lane the whole tree (drop --sparse)")
        if isinstance(manifest, dict):
            gained.append(("patchedDependencies", _patch_folders(manifest)))
            workspaces = manifest.get("workspaces")
            if isinstance(workspaces, dict):
                workspaces = workspaces.get("packages")
            if isinstance(workspaces, list):
                gained.append(("workspaces", _members([w for w in workspaces if isinstance(w, str)], tree)))
    if "pnpm-workspace.yaml" in tree:
        gained.append(("pnpm-workspace.yaml", _members(_pnpm_packages(git(repo, "show", f"{base}:pnpm-workspace.yaml", strip=False)), tree)))
    notes: list[str] = []
    for reason, folders in gained:
        added = sorted(set(folders) - dirs)
        if added:
            notes.append(f"cone + {', '.join(added)} ({reason})")
            dirs.update(added)
    cone = sorted(dirs)
    dropped = sorted(
        p for p in tree
        if any(fnmatch.fnmatchcase(Path(p).name, pattern) for pattern in LOCKFILES) and not _on_disk(str(Path(p).parent), cone)
    )
    if dropped:
        lines = "\n".join(f"  {p} (add --also {Path(p).parent})" for p in dropped)
        fail(f"the sparse cone drops {len(dropped)} lockfile(s) whose install would silently not run:\n{lines}\nname them with --also, or give the lane the whole tree (drop --sparse)")
    return cone, notes


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
