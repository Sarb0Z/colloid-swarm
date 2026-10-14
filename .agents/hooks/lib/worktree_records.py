#!/usr/bin/env python3
"""Record the worktrees and workloop runs a session's tool calls create.

Decision `worktrees-end-with-their-session`. This module holds the git and
process helpers and the record files; teardown-gate.sh calls `snapshot` and
`made`. worktree_removal.py removes what a session recorded, and
worktree_sweep.py is the session-start sweep.

RECORD FILE: `<main checkout>/.agents/worktrees/.records/<session>.jsonl`,
gitignored, appended only, one object per line: `worktree` (path, by, run?),
`run` (run, state) or `host`. Each carries `host`, the session's [pid, ps
start time]; the last one decides whether the session still runs.

ONLY WHAT THE CALL CREATED: PreToolUse stores what the command asks for and
the worktrees and runs that exist, under the call's tool_use_id; PostToolUse
records only what is new since and matches the command, so a failed `git
worktree add` or `workloop.py init` adopts nothing. Without a snapshot
nothing is recorded.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

RECORDS = Path(".agents/worktrees/.records")
# Ancestors that only carry the hook: the session's own process is the first
# one past them.
CARRIERS = {"sh", "bash", "zsh", "dash", "ksh", "fish", "env", "timeout", "nohup", "python", "python3"}
# A caller such as `git rebase -x` exports these, and with them set every git
# call would act on that repository instead of the one it names.
GIT_ENV = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX", "GIT_COMMON_DIR")
SNAPSHOT_SECONDS = 86400
PORCELAIN = {"HEAD ": "head", "branch refs/heads/": "branch", "locked": "locked", "prunable": "prunable"}


def warn(message: str) -> None:
    print(f"worktree-records: {message}", file=sys.stderr)


def clean_env(extra: dict | None = None) -> dict:
    env = {key: value for key, value in os.environ.items() if key not in GIT_ENV}
    env.update(extra or {})
    return env


def git(cwd, *args, env: dict | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(cwd), *args], text=True, capture_output=True, env=clean_env(env))


def out(cwd, *args) -> str:
    result = git(cwd, *args)
    return result.stdout.strip() if result.returncode == 0 else ""


def main_checkout(path) -> Path | None:
    """The main checkout of the repository `path` lies in; None outside one or for a bare one."""
    common = out(path, "rev-parse", "--path-format=absolute", "--git-common-dir") if Path(path).is_dir() else ""
    common_path = Path(common).resolve() if common else None
    return common_path.parent if common_path and common_path.name == ".git" else None


def worktrees(main: Path) -> list[dict]:
    """`git worktree list --porcelain` entries, main checkout first; `locked` is the reason."""
    entries = []
    for block in out(main, "worktree", "list", "--porcelain").split("\n\n"):
        lines = block.splitlines()
        if not lines or not lines[0].startswith("worktree "):
            continue
        entry = {"path": Path(lines[0][len("worktree "):]).resolve(), "head": None, "branch": None,
                 "locked": None, "prunable": None}
        for line in lines[1:]:
            for prefix, key in PORCELAIN.items():
                if line.startswith(prefix):
                    entry[key] = line[len(prefix):].strip() or ("no reason given" if key == "locked" else True)
        entries.append(entry)
    return entries


def ps_row(pid: int) -> tuple[int, str, str] | None:
    """(parent pid, start time, command name) of a live process, or None."""
    result = subprocess.run(["ps", "-o", "ppid=", "-o", "lstart=", "-o", "comm=", "-p", str(pid)],
                            text=True, capture_output=True)
    words = result.stdout.split()
    return (int(words[0]), " ".join(words[1:6]), " ".join(words[6:])) if not result.returncode and len(words) > 6 else None


def chain() -> list[tuple[int, str, str]]:
    """(pid, start, command) of this process and its ancestors."""
    rows, pid = [], os.getpid()
    while len(rows) < 12 and pid > 1:
        row = ps_row(pid)
        if row is None:
            break
        rows.append((pid, row[1], row[2]))
        pid = row[0]
    return rows


def host() -> list | None:
    """[pid, start] of the session's process: CLAUDE_PID when it is an ancestor
    (a child inherits the variable), else the first ancestor no shell carries."""
    rows = chain()[1:]
    for pid, start, _ in rows:
        if os.environ.get("CLAUDE_PID") == str(pid):
            return [pid, start]
    for pid, start, command in rows:
        name = os.path.basename(command).lstrip("-")
        if name not in CARRIERS and not re.fullmatch(r"python[0-9.]*", name):
            return [pid, start]
    return None


def alive(recorded) -> bool:
    row = ps_row(int(recorded[0])) if isinstance(recorded, list) and len(recorded) == 2 else None
    return row is not None and row[1] == recorded[1]


def session_key(session: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]", "", session)


def records_dir(project) -> Path:
    return (main_checkout(project) or Path(project).resolve()) / RECORDS


def append(folder: Path, session: str, entries: list[dict]) -> None:
    if entries:
        folder.mkdir(parents=True, exist_ok=True)
        with open(folder / f"{session_key(session)}.jsonl", "a") as stream:
            stream.write("".join(json.dumps(entry, sort_keys=True) + "\n" for entry in entries))


def load(path: Path) -> list[dict]:
    entries = []
    for number, line in enumerate(path.read_text().splitlines(), 1):
        try:
            entry = json.loads(line) if line.strip() else None
        except ValueError:
            warn(f"{path}:{number} is not JSON; ignored")
            continue
        if isinstance(entry, dict):
            entries.append(entry)
    return entries


def last_host(entries: list[dict]):
    hosts = [entry.get("host") for entry in entries if entry.get("host")]
    return hosts[-1] if hosts else None


def record(project, session: str, entries: list[dict]) -> None:
    stamp, now = host(), int(time.time())
    append(records_dir(project), session, [dict(entry, host=stamp, at=now) for entry in entries])


def runs_in(state: str) -> dict:
    try:
        runs = json.loads(Path(state).read_text()).get("runs", {})
    except (OSError, ValueError):
        return {}
    return runs if isinstance(runs, dict) else {}


def named(command: str, cwd: Path, lib: Path) -> dict:
    """What the command asks for: `git worktree add` operands with the folder
    git runs in, and workloop init/add-lane calls with their state file."""
    found = {"adds": [], "runs": []}
    if not command or not re.search(r"\bworktree\b|workloop\.py", command):
        return found
    spec = importlib.util.spec_from_file_location("guard_destructive", lib / "guard-destructive.py")
    shell = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(shell)
    for parsed in shell.normalize(command):
        words = shell.lead(parsed.words)
        while words and words[0] in shell.CONTROL_KEYWORDS:
            words = shell.lead(words[1:])
        if words and shell.base(words[0]) == "git":
            found["adds"] += [add for add in [git_add(words, cwd, shell)] if add]
            continue
        script = next((index for index, word in enumerate(words) if shell.base(word) == "workloop.py"), None)
        if script is not None:
            found["runs"] += [call for call in [workloop_call(words[script + 1:], cwd, Path(words[script]))] if call]
    return found


def git_add(words: list[str], cwd: Path, shell) -> list | None:
    """[folder git runs in, path operand] of `git [-C d] worktree add ... <path>`."""
    base, index = cwd, 1
    while index < len(words) and words[index].startswith("-"):
        if words[index] == "-C" and index + 1 < len(words):
            base = Path(os.path.normpath(base / os.path.expanduser(words[index + 1])))
        index += 2 if words[index] in shell.GIT_VALUED else 1
    verb, rest = shell.git_verb(words)
    args, index = (rest[1:], 0) if verb == "worktree" and rest[:1] == ["add"] else ([], 0)
    while index < len(args):
        if args[index] == "--":
            return [str(base), args[index + 1]] if index + 1 < len(args) else None
        if not args[index].startswith("-"):
            return [str(base), args[index]]
        index += 2 if args[index] in ("-b", "-B", "--reason") else 1
    return None


def workloop_call(args: list[str], cwd: Path, script: Path) -> dict | None:
    state, positional, index = None, [], 0
    while index < len(args):
        word = args[index]
        if word in ("--state", "--event-id") and index + 1 < len(args):
            state, index = (args[index + 1] if word == "--state" else state), index + 2
            continue
        if word.startswith("--state="):
            state = word.split("=", 1)[1]
        elif not word.startswith("-"):
            positional.append(word)
        index += 1
    if len(positional) < 2 or positional[0] not in ("init", "add-lane"):
        return None
    path = (cwd / os.path.expanduser(state)) if state else (cwd / script).parent / ".workloop-state.json"
    return {"verb": positional[0], "run": positional[1], "state": str(path.resolve())}


def matches(path: Path, base: str, operand: str) -> bool:
    """The new worktree is the operand resolved from where git ran, or, after a
    `cd` in the command, the worktree whose path ends with it."""
    if Path(os.path.normpath(Path(base) / os.path.expanduser(operand))).resolve() == path:
        return True
    tail = [part for part in Path(operand).parts if part not in (".", "..")]
    return bool(tail) and path.parts[-len(tail):] == tuple(tail)


def snapshot_file(project, tool_use_id: str) -> Path:
    return records_dir(project) / f".snap-{session_key(tool_use_id)}.json"


def snapshot(project, tool: str, command: str, cwd: Path, tool_use_id: str, lib: Path) -> None:
    """PreToolUse: store what a call asks for and what exists before it runs."""
    asked = named(command, cwd, lib)
    if not tool_use_id or not (tool == "EnterWorktree" or asked["adds"] or asked["runs"]):
        return
    repos = {main_checkout(cwd)} | {main_checkout(base) for base, _ in asked["adds"]}
    for call in asked["runs"]:
        repos |= {main_checkout(run.get("repo") or cwd) for run in runs_in(call["state"]).values()}
    state = dict(asked, worktrees={str(repo): [str(e["path"]) for e in worktrees(repo)] for repo in repos if repo},
                 before={call["state"]: sorted(runs_in(call["state"])) for call in asked["runs"]})
    folder = snapshot_file(project, tool_use_id).parent
    folder.mkdir(parents=True, exist_ok=True)
    for old in folder.glob(".snap-*.json"):
        if time.time() - old.stat().st_mtime > SNAPSHOT_SECONDS:
            old.unlink()
    snapshot_file(project, tool_use_id).write_text(json.dumps(state))


def claude_worktree(cwd: Path, prefix: str) -> Path | None:
    """`cwd` when it is a worktree Claude Code made: `<main>/.claude/worktrees/<prefix>*`."""
    cwd = cwd.resolve()
    main = main_checkout(cwd)
    if main is None or cwd.parent != main / ".claude" / "worktrees" or not cwd.name.startswith(prefix):
        return None
    return cwd if cwd in [entry["path"] for entry in worktrees(main)[1:]] else None


def made(project, event: str, tool: str, cwd: Path, tool_use_id: str) -> list[dict]:
    """Records for what the call created. `cwd` is the session's folder after it:
    the new worktree after EnterWorktree, an isolated cell's own `agent-<id>`
    worktree at its SubagentStart."""
    if event == "SubagentStart":
        path = claude_worktree(cwd, "agent-")
        return [{"type": "worktree", "path": str(path), "by": "Agent isolation"}] if path else []
    snap = snapshot_file(project, tool_use_id) if tool_use_id else None
    if snap is None or not snap.is_file():
        return []
    before = json.loads(snap.read_text())
    snap.unlink()
    new = [entry["path"] for repo, paths in before["worktrees"].items()
           for entry in worktrees(Path(repo))[1:] if str(entry["path"]) not in paths]
    if tool == "EnterWorktree":
        path = claude_worktree(cwd, "")
        return [{"type": "worktree", "path": str(path), "by": "EnterWorktree"}] if path in new else []
    found = [{"type": "worktree", "path": str(path), "by": "git worktree add"}
             for base, operand in before["adds"] for path in new if matches(path, base, operand)]
    for call in before["runs"]:
        run = runs_in(call["state"]).get(call["run"]) or {}
        lead = {"type": "run", "run": call["run"], "state": call["state"]}
        if call["verb"] == "init" and run and call["run"] not in before["before"].get(call["state"], []):
            found.append(lead)
        spaces = [Path(lane["workspace"]).resolve() for lane in (run.get("lanes") or {}).values() if lane.get("workspace")]
        for space in [space for space in spaces if call["verb"] == "add-lane" and space in new]:
            found += [lead, {"type": "worktree", "path": str(space), "by": "workloop.py add-lane", "run": call["run"]}]
    return found
