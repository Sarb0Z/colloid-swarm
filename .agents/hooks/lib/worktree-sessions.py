#!/usr/bin/env python3
"""Keep Claude Code sessions that enter a worktree listed under their repository.

A session that enters `<repo>/.claude/worktrees/<name>` (EnterWorktree, or
`claude --worktree`) has its transcript filed under the worktree's folder in
`<config dir>/projects/`, so `/resume` at the repository root stops listing
it. This makes each worktree's folder a symlink to the root's, so the move
lands back in the root folder.

    worktree-sessions.py hook [--default true|false]
        Normalized payload on stdin: {event, tool_name, tool_input, cwd}. Runs
        when the session repository's `hooks.worktree_sessions.enabled` says
        so; `--default` answers when policy.json and config.json are silent.
        Never exits 2, so never blocks.
    worktree-sessions.py sweep [--dry-run]
        Fold every existing worktree folder into its repository's folder.

Folding a real folder is safe while a session writes to it: every file is
hard-linked into the root, then the folder and a prepared symlink swap names in
one atomic call, so an append by either path reaches the same inode and the
name is never missing. A same-named file that differs stays in
`<folder>.unmerged-<time>`, reaches the person as a systemMessage, is listed by
every sweep, and is never deleted.
"""

import ctypes
import ctypes.util
import fcntl
import importlib.util
import json
import os
import pathlib
import re
import subprocess
import sys
import time


def projects():
    """Resolved per call: one process may serve a second config directory."""
    return pathlib.Path(os.environ.get("CLAUDE_CONFIG_DIR", "~/.claude")).expanduser() / "projects"


MARKER = "--claude-worktrees-"
SWITCH = "hooks.worktree_sessions.enabled"
# Claude Code's documented folder rule: every non-alphanumeric character of the
# working directory becomes "-". Past 200 characters it truncates and appends a
# hash this script cannot reproduce, so such paths are reported and left alone.
SLUG_LIMIT = 200
LOCK_TRIES = 50
LOCK_WAIT = 0.1
AT_FDCWD = -100
RENAME_SWAP = 0x2  # macOS <stdio.h>
RENAME_EXCHANGE = 0x2  # Linux <linux/fs.h>


def warn(message):
    print(f"worktree-sessions: {message}", file=sys.stderr)


def slug(path):
    name = re.sub(r"[^A-Za-z0-9]", "-", str(path))
    if len(name) > SLUG_LIMIT:
        raise ValueError(f"{path} encodes past {SLUG_LIMIT} characters; its folder name is hashed")
    return name


def main_checkout(cwd):
    """The repository's main checkout, from any directory in it or its worktrees."""
    out = subprocess.run(
        ["git", "-C", str(cwd), "rev-parse", "--path-format=absolute", "--git-common-dir"],
        check=False, capture_output=True, text=True,
    )
    if out.returncode != 0:
        return None
    common = pathlib.Path(out.stdout.strip())
    return common.parent if common.name == ".git" else None


def same_file(a, b):
    return a.exists() and b.exists() and os.stat(a).st_ino == os.stat(b).st_ino


def link_tree(source, target, unmerged):
    """Hard-link every file under `source` into `target`; collect what clashes."""
    if source.is_symlink():
        raise RuntimeError(f"refusing to link from {source}: it is a symlink")
    target.mkdir(parents=True, exist_ok=True)
    for entry in source.iterdir():
        destination = target / entry.name
        if entry.is_dir() and not entry.is_symlink():
            if destination.exists() and not destination.is_dir():
                unmerged.append(entry)
                continue
            link_tree(entry, destination, unmerged)
        elif not destination.exists():
            os.link(entry, destination)
        elif not same_file(entry, destination):
            unmerged.append(entry)


def remove_linked(source, target):
    """Delete from `source` the files that now also live in `target`. Through a
    symlink to `target`, every entry would match itself and the root would empty."""
    if source.is_symlink():
        raise RuntimeError(f"refusing to clean {source}: it is a symlink")
    for entry in source.iterdir():
        destination = target / entry.name
        if entry.is_dir() and not entry.is_symlink():
            remove_linked(entry, destination)
            if not any(entry.iterdir()):
                entry.rmdir()
        elif same_file(entry, destination):
            entry.unlink()


def already_linked(folder, root):
    if not folder.is_symlink():
        return False
    if folder.resolve() != root.resolve():
        warn(f"{folder.name} already links to {os.readlink(folder)}, not {root.name}; left alone")
    return True


def fold(folder, root, dry_run=False):
    """Make `folder` a symlink to `root`, its contents moved there; return a clash or None."""
    if already_linked(folder, root):
        return None
    if dry_run:
        print(f"would fold {folder.name} -> {root.name}" if folder.exists() else f"would link {folder.name} -> {root.name}")
        return None
    root.mkdir(parents=True, exist_ok=True)
    # Hooks for one event run in parallel. One fold at a time, rechecking for the
    # symlink under the lock, keeps a second run from parking the first's link.
    with open(root.parent / ".worktree-sessions.lock", "w") as lock:
        take_lock(lock)
        return fold_locked(folder, root)


def take_lock(lock):
    """Wait briefly for another fold, then give up: the next start or sweep retries,
    while an unbounded wait would stall every session start behind one stuck fold."""
    for _ in range(LOCK_TRIES):
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            time.sleep(LOCK_WAIT)
    raise RuntimeError("another fold holds the session-store lock; skipped, the next start retries")


def fold_locked(folder, root):
    if not folder.exists() and not folder.is_symlink():
        try:
            folder.symlink_to(root.name)
            return None
        except FileExistsError:
            pass  # Claude Code created it between the check and the link; fold it below.
    if already_linked(folder, root):
        return None
    # Claude Code appends by path and recreates a missing folder. An atomic swap
    # with a prepared symlink leaves no instant in which the name is missing.
    link_tree(folder, root, [])
    parked = folder.with_name(f"{folder.name}.unmerged-{time.time_ns()}-{os.getpid()}")
    parked.symlink_to(root.name)
    exchange(parked, folder)
    # Files created in the old folder after the first pass are not in the root yet.
    unmerged = []
    link_tree(parked, root, unmerged)
    remove_linked(parked, root)
    if not any(parked.iterdir()):
        parked.rmdir()
        print(f"worktree-sessions: folded {folder.name} -> {root.name}", file=sys.stderr)
        return None
    names = sorted(str(p.relative_to(parked)) for p in unmerged)
    return f"kept {parked} beside the session store: {names} differ from the copies in {root.name}; merge them by hand"


def exchange(a, b):
    """Swap two directory entries atomically (macOS renamex_np, Linux renameat2)."""
    libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    if sys.platform == "darwin":
        result = libc.renamex_np(os.fsencode(a), os.fsencode(b), RENAME_SWAP)
    else:
        result = libc.renameat2(AT_FDCWD, os.fsencode(a), AT_FDCWD, os.fsencode(b), RENAME_EXCHANGE)
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, f"cannot swap {a.name} with {b.name}: {os.strerror(error)}")


def load_config():
    """config.py, imported by path: it owns the policy.json/config.json layering."""
    spec = importlib.util.spec_from_file_location("colloid_config", pathlib.Path(__file__).with_name("config.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def enabled(root, default):
    """The session repository decides, not the checkout this script runs from.

    A policy or config file that does not parse may be the one that says false,
    so it turns the hook off rather than falling back to the default.
    """
    config = load_config()
    path = str(root / ".agents" / "config.json")
    broken = config.unparsed(path)
    if broken:
        warn(f"not running: {broken} unreadable, and it may switch this hook off")
        return False
    return config.read(config.load(path), SWITCH, default)


def hook_targets(payload, worktrees):
    """The worktree directories this event concerns, possibly not created yet."""
    cwd = pathlib.Path(payload.get("cwd") or os.getcwd())
    event = payload.get("event")
    tool_input = payload.get("tool_input") or {}
    targets = []
    if event in ("PreToolUse", "PostToolUse") and payload.get("tool_name") == "EnterWorktree":
        if tool_input.get("path"):
            targets.append(pathlib.Path(tool_input["path"]))
        elif tool_input.get("name"):
            targets.append(worktrees / tool_input["name"])
        # An unnamed worktree gets a generated name; once the tool has run, the
        # session's cwd is inside it.
        if event == "PostToolUse":
            targets.append(cwd)
    elif event == "SessionStart":
        targets.append(cwd)
    names = []
    for target in targets:
        try:
            relative = target.resolve().relative_to(worktrees.resolve())
        except ValueError:
            continue
        if relative.parts:
            names.append(relative.parts[0])
    return names


def handle_hook(payload, default):
    """Fold this event's worktree folders; return the clashes the user must see."""
    root = main_checkout(payload.get("cwd") or os.getcwd())
    if root is None or not enabled(root, default):
        return []
    worktrees = root / ".claude" / "worktrees"
    clashes = []
    for name in hook_targets(payload, worktrees):
        clash = fold(projects() / slug(worktrees / name), projects() / slug(root))
        if clash:
            clashes.append(clash)
    return clashes


def sweep(dry_run):
    for folder in sorted(projects().iterdir()):
        if MARKER not in folder.name or ".unmerged-" in folder.name or folder.is_symlink():
            continue
        clash = fold(folder, projects() / folder.name.split(MARKER, 1)[0], dry_run)
        if clash:
            warn(clash)
    for parked in sorted(projects().glob(f"*{MARKER}*.unmerged-*")):
        warn(f"{parked.name} still holds entries that differ from its repository's copies; merge them by hand")


def parse_default(argv):
    value = argv[argv.index("--default") + 1] if "--default" in argv[:-1] else "false"
    if value not in ("true", "false"):
        warn(f"--default {value!r} is neither true nor false; treated as false")
    return value == "true"


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    if mode == "hook":
        # A hook that must not block: an expected failure (the store, the
        # payload, a refused fold) goes to stderr with exit 0. Anything else is
        # a defect and leaves with Python's traceback and exit 1, which Claude
        # Code reports without blocking; only exit 2 blocks.
        try:
            clashes = handle_hook(json.load(sys.stdin), parse_default(argv))
        except (OSError, ValueError, RuntimeError) as error:
            warn(f"hook failed: {error!r}")
            return 0
        # stderr from a hook that exits 0 reaches only the debug log; a kept
        # transcript fragment must reach the person.
        if clashes:
            print(json.dumps({"systemMessage": "worktree-sessions: " + "; ".join(clashes)}))
        return 0
    if mode == "sweep":
        sweep("--dry-run" in argv[2:])
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
