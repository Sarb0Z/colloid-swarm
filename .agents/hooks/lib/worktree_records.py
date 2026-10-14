#!/usr/bin/env python3
"""Record the worktrees a session makes, and remove them when it ends.

No worktree an agent makes outlives the session that made it (decision
`worktrees-end-with-their-session`). Three hooks share this module:

    teardown-gate.sh   PostToolUse and SubagentStart: `made()` reads an event
                       that created a worktree or a workloop run and
                       `record()` appends it to the session's record file.
    session-end.sh     `worktree_records.py end <project> <session> <workloop.py>`
                       removes what the ending session recorded.
    session-start.sh   `worktree_records.py sweep <project> <session> <workloop.py>`
                       treats the records of sessions no longer running the
                       same way, heals worktrees no record names that sat idle
                       24 hours, and prints the digest lines.

RECORD FILE. `<main checkout>/.agents/worktrees/.records/<session>.jsonl`,
gitignored with the lane worktrees beside it, one JSON object per line and
appended only, so concurrent hooks of one session never rewrite each other:

    {"type": "worktree", "path": <abs>, "by": <maker>, "host": [pid, start]}
    {"type": "run", "run": <name>, "state": <abs state file>, "host": [...]}
    {"type": "host", "host": [pid, start]}

`host` is the session's own process: the first ancestor of the hook that is
not a shell or an interpreter, with its `ps` start time so a reused pid does
not read as alive. The last line's host decides whether the session still
runs; a resumed session appends a fresh `host` line. A file with no host is
treated as ended once nothing has written it for 24 hours.

REMOVING ONE WORKTREE (`retire`), in this order, and any refusal leaves it in
place and names it:
  - it must be a linked worktree of its repository, never a main checkout;
  - a locked worktree is never touched: `git worktree lock` is how anyone
    keeps one;
  - a worktree that is some running process's working directory is skipped
    (read with lsof where the machine has it);
  - unsaved work — tracked changes and untracked files that are not ignored —
    is committed to `saved/<worktree name>` first, through a copy of the
    worktree's index so its branch and staging area stay as they were; a
    failed commit stops the removal;
  - ignored folders such as node_modules are renamed into a trash folder
    inside the git directory, then deleted by a detached `rm`, because
    deleting them in place takes seconds per worktree and a session-end hook
    has a budget;
  - `git worktree remove` runs without --force on a clean worktree, so git
    itself refuses anything that turned dirty or locked meanwhile;
  - its branch is deleted only when the main checkout's HEAD contains it.

A workloop run ends with the session that created it or added its lanes:
its worktrees are saved like any other, then `workloop.py abandon` closes it,
which keeps every branch HEAD does not contain. A run no record names is
never touched, only listed.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

IDLE_SECONDS = 24 * 3600
RECORDS = Path(".agents/worktrees/.records")
STATE = Path(".agents/.workloop-state.json")
TRASH = "colloid-trash"
# Ancestors that only carry the hook: the session's own process is the first
# one past them.
CARRIERS = {"sh", "bash", "zsh", "dash", "ksh", "fish", "env", "timeout", "nohup", "python", "python3"}
# A caller such as `git rebase -x` exports these, and with them set every git
# call below would act on that repository instead of the one it names.
GIT_ENV = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX", "GIT_COMMON_DIR")


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
    common = out(path, "rev-parse", "--path-format=absolute", "--git-common-dir")
    if not common:
        return None
    common_path = Path(common).resolve()
    return common_path.parent if common_path.name == ".git" else None


def worktrees(main: Path) -> list[dict]:
    """`git worktree list --porcelain`, one dict per entry; the first is the main checkout."""
    entries, current = [], None
    for line in out(main, "worktree", "list", "--porcelain").splitlines() + [""]:
        if line.startswith("worktree "):
            current = {"path": Path(line[len("worktree "):]).resolve(), "branch": None, "locked": None, "prunable": False}
        elif current is None:
            continue
        elif line.startswith("branch refs/heads/"):
            current["branch"] = line[len("branch refs/heads/"):]
        elif line == "locked" or line.startswith("locked "):
            current["locked"] = line[len("locked "):] if line.startswith("locked ") else "no reason given"
        elif line.startswith("prunable"):
            current["prunable"] = True
        elif line == "":
            entries.append(current)
            current = None
    return entries


# --- the session's own process ----------------------------------------------

def ps_row(pid: int) -> tuple[int, str, str] | None:
    """(parent pid, start time, command name) of a live process, or None."""
    result = subprocess.run(["ps", "-o", "ppid=", "-o", "lstart=", "-o", "comm=", "-p", str(pid)],
                            text=True, capture_output=True)
    words = result.stdout.split()
    if result.returncode != 0 or len(words) < 7:
        return None
    return int(words[0]), " ".join(words[1:6]), " ".join(words[6:])


def host() -> list | None:
    """[pid, start] of the process that runs this session's hooks.

    Claude Code names itself in CLAUDE_PID; it counts only when it is one of
    this process's ancestors, since a child inherits the variable. Elsewhere
    the first ancestor that is no shell or interpreter is the host.
    """
    named = os.environ.get("CLAUDE_PID", "")
    pid, first = os.getppid(), None
    for _ in range(10):
        row = ps_row(pid)
        if row is None:
            break
        parent, start, command = row
        if named == str(pid):
            return [pid, start]
        name = os.path.basename(command).lstrip("-")
        if first is None and name not in CARRIERS and not re.fullmatch(r"python[0-9.]*", name):
            first = [pid, start]
            if not named:
                break
        if parent <= 1:
            break
        pid = parent
    return first


def ancestors() -> set[int]:
    pids, pid = set(), os.getpid()
    for _ in range(12):
        pids.add(pid)
        row = ps_row(pid)
        if row is None or row[0] <= 1:
            break
        pid = row[0]
    return pids


def alive(recorded) -> bool:
    if not (isinstance(recorded, list) and len(recorded) == 2):
        return False
    row = ps_row(int(recorded[0]))
    return row is not None and row[1] == recorded[1]


def working_dirs() -> list[tuple[int, Path]] | None:
    """(pid, cwd) of every process this user can see; None where lsof is missing."""
    if not shutil.which("lsof"):
        return None
    result = subprocess.run(["lsof", "-n", "-P", "-w", "-d", "cwd", "-F", "pn"], text=True, capture_output=True)
    rows, pid = [], None
    for line in result.stdout.splitlines():
        if line.startswith("p"):
            pid = int(line[1:])
        elif line.startswith("n") and pid is not None:
            rows.append((pid, Path(line[1:])))
    return rows


def inside(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


# --- record files ----------------------------------------------------------

def session_key(session: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]", "", session)


def records_dir(project) -> Path:
    main = main_checkout(project)
    return (main or Path(project).resolve()) / RECORDS


def append(folder: Path, session: str, entries: list[dict]) -> None:
    if not entries:
        return
    folder.mkdir(parents=True, exist_ok=True)
    with open(folder / f"{session_key(session)}.jsonl", "a") as stream:
        stream.write("".join(json.dumps(entry, sort_keys=True) + "\n" for entry in entries))


def load(path: Path) -> list[dict]:
    entries = []
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            warn(f"{path}:{number} is not JSON; ignored")
            continue
        if isinstance(entry, dict):
            entries.append(entry)
    return entries


def last_host(entries: list[dict]):
    hosts = [entry.get("host") for entry in entries if entry.get("host")]
    return hosts[-1] if hosts else None


# --- what a tool call made -------------------------------------------------

def shell_parser(lib: Path):
    spec = importlib.util.spec_from_file_location("guard_destructive", lib / "guard-destructive.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


WORKTREE_ADD_VALUED = {"-b", "-B", "--reason"}


def added_path(args: list[str]) -> str | None:
    """The <path> operand of `git worktree add <options> <path> [<commit-ish>]`."""
    index = 0
    while index < len(args):
        word = args[index]
        if word == "--":
            return args[index + 1] if index + 1 < len(args) else None
        if word in WORKTREE_ADD_VALUED:
            index += 2
        elif word.startswith("-"):
            index += 1
        else:
            return word
    return None


def find_worktree(operand: str, base: Path, cwd: Path) -> Path | None:
    """The worktree `git worktree add <operand>` made, resolved against where it ran.

    The hook sees the shell's directory after the command, which a trailing
    `cd` may have moved, so a resolved path that is no worktree falls back to
    the one worktree whose path ends with the operand.
    """
    candidate = Path(os.path.normpath(base / os.path.expanduser(operand)))
    main = main_checkout(base) or main_checkout(cwd)
    if main is None:
        return None
    listed = [entry["path"] for entry in worktrees(main)[1:]]
    resolved = candidate.resolve() if candidate.exists() else candidate
    if resolved in listed:
        return resolved
    tail = [part for part in Path(operand).parts if part not in (".", "..")]
    if not tail:
        return None
    suffix = Path(*tail)
    matches = [path for path in listed if path.parts[-len(suffix.parts):] == suffix.parts]
    return matches[0] if len(matches) == 1 else None


def from_git(words: list[str], cwd: Path, shell) -> Path | None:
    base = cwd
    index = 1
    while index < len(words) and words[index].startswith("-"):
        if words[index] == "-C" and index + 1 < len(words):
            base = Path(os.path.normpath(base / os.path.expanduser(words[index + 1])))
        index += 2 if words[index] in shell.GIT_VALUED else 1
    verb, rest = shell.git_verb(words)
    if verb != "worktree" or not rest or rest[0] != "add":
        return None
    operand = added_path(rest[1:])
    return find_worktree(operand, base, cwd) if operand else None


def from_workloop(args: list[str], cwd: Path, script: Path) -> list[dict]:
    """A run this call created or added a lane to, and the lane's worktree."""
    state, positional, index = None, [], 0
    while index < len(args):
        word = args[index]
        if word in ("--state", "--event-id") and index + 1 < len(args):
            if word == "--state":
                state = args[index + 1]
            index += 2
            continue
        if word.startswith("--state="):
            state = word.split("=", 1)[1]
        elif not word.startswith("-"):
            positional.append(word)
        index += 1
    if len(positional) < 2 or positional[0] not in ("init", "add-lane"):
        return []
    state_path = (cwd / os.path.expanduser(state)).resolve() if state else (cwd / script).resolve().parent / ".workloop-state.json"
    try:
        run = json.loads(state_path.read_text())["runs"][positional[1]]
    except (OSError, ValueError, KeyError, TypeError):
        return []
    made = [{"type": "run", "run": positional[1], "state": str(state_path)}]
    if positional[0] == "add-lane" and len(positional) > 2:
        lane = run.get("lanes", {}).get(positional[2]) or {}
        workspace = Path(lane.get("workspace") or "/nonexistent")
        if workspace.is_dir():
            made.append({"type": "worktree", "path": str(workspace.resolve()), "by": "workloop.py add-lane", "run": positional[1]})
    return made


def claude_worktree(cwd: Path, prefix: str) -> Path | None:
    """`cwd` when it is a worktree Claude Code made: `<main>/.claude/worktrees/<prefix>*`."""
    cwd = cwd.resolve()
    main = main_checkout(cwd)
    if main is None or cwd.parent != main / ".claude" / "worktrees" or not cwd.name.startswith(prefix):
        return None
    return cwd if cwd in [entry["path"] for entry in worktrees(main)[1:]] else None


def made(event: str, tool: str, tool_input: dict, command: str, cwd: Path, lib: Path) -> list[dict]:
    """Records for whatever worktree or workloop run this hook event shows was created.

    `cwd` is the directory Claude Code ran the hook in, which is the session's
    after the call: inside the new worktree after EnterWorktree, and the
    cell's own worktree at the SubagentStart of an isolated cell (Claude names
    those `agent-<id>` and removes one the cell left unchanged).
    """
    found: list[dict] = []
    if event == "SubagentStart":
        path = claude_worktree(cwd, "agent-")
        if path:
            found.append({"type": "worktree", "path": str(path), "by": "Agent isolation"})
    elif tool == "EnterWorktree":
        # With a path the tool enters a worktree that already exists.
        path = None if tool_input.get("path") else claude_worktree(cwd, "")
        if path:
            found.append({"type": "worktree", "path": str(path), "by": "EnterWorktree"})
    elif command and re.search(r"\bworktree\b|workloop\.py", command):
        shell = shell_parser(lib)
        for parsed in shell.normalize(command):
            words = shell.lead(parsed.words)
            while words and words[0] in shell.CONTROL_KEYWORDS:
                words = shell.lead(words[1:])
            if not words:
                continue
            if shell.base(words[0]) == "git":
                path = from_git(words, cwd, shell)
                if path:
                    found.append({"type": "worktree", "path": str(path), "by": "git worktree add"})
                continue
            for index, word in enumerate(words):
                if shell.base(word) == "workloop.py":
                    found.extend(from_workloop(words[index + 1:], cwd, Path(word)))
                    break
    return found


def record(project, session: str, entries: list[dict]) -> None:
    stamp = host()
    now = int(time.time())
    append(records_dir(project), session, [dict(entry, host=stamp, at=now) for entry in entries])


# --- removing what a session left -----------------------------------------

class Remover:
    """Retires worktrees; collects one report line per outcome."""

    def __init__(self, session_label: str, exclude_pids: set[int]):
        self.label = session_label
        self.lines: list[str] = []
        self._procs = None
        self._loaded = False
        self.exclude = exclude_pids

    def procs(self):
        if not self._loaded:
            self._procs, self._loaded = working_dirs(), True
        return self._procs

    def occupant(self, path: Path) -> str | None:
        rows = self.procs()
        if rows is None:
            return None
        for pid, cwd in rows:
            if pid not in self.exclude and inside(cwd, path):
                return f"process {pid} is working in it"
        return None

    def blocked(self, path: Path) -> tuple[str, str] | None:
        """(kind, reason) when `path` must stay, None when it may go.

        Kind "locked" is someone's decision to keep it; every other kind may
        clear by the next sweep.
        """
        main = main_checkout(path)
        if main is None:
            return "other", "it is not in a git repository"
        if path == main:
            return "other", "it is the main checkout"
        entry = next((item for item in worktrees(main) if item["path"] == path), None)
        if entry is None:
            return "other", "git does not list it as a worktree"
        if entry["locked"]:
            return "locked", f"it is locked ({entry['locked']})"
        occupied = self.occupant(path)
        return ("busy", occupied) if occupied else None

    def retire(self, path: Path) -> str:
        """Remove one worktree; return "removed", "gone", "locked" or "kept"."""
        path = path.resolve() if path.exists() else path
        if not path.is_dir():
            return "gone"
        refusal = self.blocked(path)
        if refusal:
            self.lines.append(f"kept {path}: {refusal[1]}")
            return "locked" if refusal[0] == "locked" else "kept"
        main = main_checkout(path)
        entry = next(item for item in worktrees(main) if item["path"] == path)
        saved = None
        if dirty(path):
            saved, error = save(path, self.label)
            if error:
                self.lines.append(f"kept {path}: its unsaved work could not be committed ({error})")
                return "kept"
        # A worktree's own process directory goes with it; leave it first.
        os.chdir(main)
        moved = park_ignored(path, main)
        args = ["worktree", "remove"] + (["--force"] if saved else []) + [str(path)]
        result = git(main, *args)
        if result.returncode != 0:
            restore(moved)
            self.lines.append(f"kept {path}: git refused to remove it ({(result.stderr or result.stdout).strip()})")
            return "kept"
        purge(moved)
        branch_note = drop_branch(main, entry["branch"])
        line = f"removed {path}"
        if saved:
            line += f"; its unsaved work is on branch {saved}"
        self.lines.append(line + branch_note)
        return "removed"


def dirty(path: Path) -> bool:
    return bool(out(path, "--no-optional-locks", "status", "--porcelain"))


def admin_dir(path: Path) -> Path:
    return Path(out(path, "rev-parse", "--path-format=absolute", "--git-dir"))


def save(path: Path, session_label: str) -> tuple[str | None, str | None]:
    """Commit the worktree's unsaved work to a new `saved/<name>` branch.

    The commit is built in a copy of the worktree's index, so its own index,
    branch and HEAD stay exactly as they were. Returns (branch, error).
    """
    admin = admin_dir(path)
    handle, scratch = tempfile.mkstemp(prefix="saved-index.", dir=str(admin))
    os.close(handle)
    try:
        index = admin / "index"
        if index.exists():
            shutil.copyfile(index, scratch)
        else:
            os.unlink(scratch)
        env = {"GIT_INDEX_FILE": scratch}
        head = out(path, "rev-parse", "-q", "--verify", "HEAD^{commit}")
        if not index.exists():
            seeded = git(path, "read-tree", head, env=env) if head else git(path, "read-tree", "--empty", env=env)
            if seeded.returncode != 0:
                return None, seeded.stderr.strip()
        added = git(path, "add", "-A", env=env)
        if added.returncode != 0:
            return None, added.stderr.strip()
        tree = git(path, "write-tree", env=env)
        if tree.returncode != 0:
            return None, tree.stderr.strip()
        message = (f"Save unsaved work from worktree {path}\n\n"
                   f"Committed when {session_label} ended, before the worktree was removed. "
                   "Untracked files are included; ignored files are not.")
        parents = ["-p", head] if head else []
        commit = git(path, "commit-tree", tree.stdout.strip(), *parents, "-m", message)
        if commit.returncode != 0:
            return None, commit.stderr.strip()
        name = re.sub(r"[^A-Za-z0-9._-]", "-", admin.name).strip(".-") or "worktree"
        for candidate in [f"saved/{name}"] + [f"saved/{name}-{time.strftime('%Y%m%d-%H%M%S')}-{n}" for n in range(1, 10)]:
            created = git(path, "update-ref", f"refs/heads/{candidate}", commit.stdout.strip(), "")
            if created.returncode == 0:
                return candidate, None
        return None, f"no free branch name under saved/{name}"
    finally:
        if os.path.exists(scratch):
            os.unlink(scratch)


def trash_dir(main: Path) -> Path:
    common = Path(out(main, "rev-parse", "--path-format=absolute", "--git-common-dir"))
    return common / TRASH


def park_ignored(path: Path, main: Path) -> list[tuple[Path, Path]]:
    """Rename the worktree's ignored entries into the trash; return (from, to) pairs."""
    listing = git(path, "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory")
    names = [name for name in listing.stdout.split("\0") if name] if listing.returncode == 0 else []
    if not names:
        return []
    bin_ = trash_dir(main) / f"{time.time_ns()}-{os.getpid()}"
    bin_.mkdir(parents=True, exist_ok=True)
    moved = []
    for number, name in enumerate(names):
        source = path / name.rstrip("/")
        target = bin_ / str(number)
        try:
            os.rename(source, target)
        except OSError:
            continue  # another filesystem: git deletes it in place instead
        moved.append((source, target))
    return moved


def restore(moved: list[tuple[Path, Path]]) -> None:
    for source, target in moved:
        try:
            os.rename(target, source)
        except OSError as error:
            warn(f"could not put {source} back from {target}: {error}")


def purge(moved: list[tuple[Path, Path]]) -> None:
    folders = sorted({str(target.parent) for _, target in moved})
    if folders:
        subprocess.Popen(["rm", "-rf", *folders], start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def drop_branch(main: Path, branch: str | None) -> str:
    """Delete a removed worktree's branch when the main checkout's HEAD contains it.

    A branch that tracks a remote, or is the repository's trunk, stays even
    then: it was never the worktree's alone.
    """
    if not branch:
        return ""
    trunk = out(main, "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD").split("/", 1)[-1]
    if branch in ("main", "master", trunk) or out(main, "rev-parse", "-q", "--abbrev-ref", f"{branch}@{{upstream}}"):
        return f"; branch {branch} kept, it is the trunk or tracks a remote"
    head = out(main, "rev-parse", "-q", "--verify", "HEAD")
    contained = head and git(main, "merge-base", "--is-ancestor", f"refs/heads/{branch}", head).returncode == 0
    if not contained:
        return f"; branch {branch} kept, HEAD does not contain it"
    result = git(main, "branch", "-D", branch)
    if result.returncode != 0:
        return f"; branch {branch} kept: {result.stderr.strip()}"
    return f"; branch {branch} deleted, HEAD contains it"


def close_run(remover: Remover, entry: dict, workloop: Path) -> bool:
    """Save a run's worktrees and close it with `abandon`; False when it must stay."""
    name, state = entry.get("run"), Path(entry.get("state") or "")
    try:
        runs = json.loads(state.read_text())["runs"]
    except (OSError, ValueError, KeyError, TypeError):
        return True  # the state or the run is gone: nothing left to close
    run = runs.get(name)
    if run is None:
        return True
    spaces = [lane.get("workspace") for lane in run.get("lanes", {}).values()]
    spaces.append((run.get("integration") or {}).get("workspace"))
    present = [Path(space).resolve() for space in spaces if space and Path(space).is_dir()]
    for path in present:
        refusal = remover.blocked(path)
        if refusal:
            remover.lines.append(f"kept workloop run {name}: {path}: {refusal[1]}")
            return False
    saved = []
    for path in present:
        if dirty(path):
            branch, error = save(path, remover.label)
            if error:
                remover.lines.append(f"kept workloop run {name}: {path}: its unsaved work could not be committed ({error})")
                return False
            saved.append(f"{path} -> {branch}")
    if not workloop.is_file():
        remover.lines.append(f"kept workloop run {name}: {workloop} is missing")
        return False
    main = main_checkout(present[0]) if present else None
    if main:
        os.chdir(main)
    moved = [pair for path in present for pair in park_ignored(path, main_checkout(path))]
    result = subprocess.run([sys.executable, str(workloop), "--state", str(state), "abandon", name],
                            text=True, capture_output=True, env=clean_env())
    if result.returncode != 0:
        restore([(source, target) for source, target in moved if source.parent.is_dir()])
        purge([(source, target) for source, target in moved if not source.parent.is_dir()])
        remover.lines.append(f"kept workloop run {name}: abandon failed: {(result.stderr or result.stdout).strip()}")
        return False
    purge(moved)
    line = f"closed workloop run {name}: {result.stdout.strip()}"
    if saved:
        line += "; unsaved work: " + ", ".join(saved)
    remover.lines.append(line)
    return True


def finish(entries: list[dict], remover: Remover, workloop: Path) -> list[dict]:
    """Close the runs, then remove the worktrees; return the entries still standing."""
    remaining, kept_runs = [], set()
    runs = {}
    for entry in entries:
        if entry.get("type") == "run":
            runs[(entry.get("run"), entry.get("state"))] = entry
    for key, entry in runs.items():
        if not close_run(remover, entry, workloop):
            kept_runs.add(key[0])
            remaining.append(entry)
    seen = set()
    for entry in entries:
        if entry.get("type") != "worktree" or entry.get("path") in seen:
            continue
        seen.add(entry.get("path"))
        # A run that stays keeps every lane, or its state would name worktrees
        # that are gone.
        if entry.get("run") in kept_runs:
            remaining.append(entry)
            continue
        # A locked worktree is someone's decision to keep it, so its record
        # goes; one kept for a passing reason is retried by the next sweep.
        if remover.retire(Path(entry["path"])) == "kept":
            remaining.append(entry)
    return remaining


def settle(path: Path, remaining: list[dict], stamp) -> None:
    """Write back what still stands, under the session's last host, for the next sweep."""
    if remaining:
        text = "".join(json.dumps(dict(entry, host=stamp), sort_keys=True) + "\n" for entry in remaining)
        with open(path, "a") as stream:
            stream.write(text)


def end(project: Path, session: str, workloop: Path) -> list[str]:
    """Remove what the ending session recorded.

    The session's own process and shells are ending, so their working
    directories do not hold a worktree.
    """
    path = records_dir(project) / f"{session_key(session)}.jsonl"
    if not session_key(session) or not path.is_file():
        return []
    claimed = path.with_name(f".{path.name}.ending-{os.getpid()}")
    try:
        os.rename(path, claimed)
    except OSError:
        return []
    entries = load(claimed)
    remover = Remover(f"session {session}", ancestors())
    remaining = finish(entries, remover, workloop)
    claimed.unlink()
    settle(path, remaining, last_host(entries))
    return remover.lines


def idle_since(path: Path) -> float:
    """The newest of the worktree's commit, checkout and file times."""
    admin = admin_dir(path)
    stamps = [os.stat(item).st_mtime for item in (admin / "HEAD", admin / "index", admin / "logs" / "HEAD", path) if item.exists()]
    committed = out(path, "log", "-1", "--format=%ct")
    if committed.isdigit():
        stamps.append(float(committed))
    newest = max(stamps) if stamps else 0.0
    if time.time() - newest < IDLE_SECONDS:
        return newest
    listing = git(path, "ls-files", "-z", "--cached", "--others", "--exclude-standard")
    for name in listing.stdout.split("\0"):
        if not name:
            continue
        try:
            newest = max(newest, os.lstat(path / name).st_mtime)
        except OSError:
            continue
        if time.time() - newest < IDLE_SECONDS:
            break
    return newest


def sweep(project: Path, session: str, workloop: Path) -> list[str]:
    """Digest lines: what the sweep removed or kept, saved branches, unowned runs."""
    main = main_checkout(project)
    if main is None:
        return []
    folder = main / RECORDS
    me = session_key(session)
    lines: list[str] = []
    remover = Remover("an earlier session", set())
    # A background delete that was killed leaves its folder behind. Only an
    # hour-old one is taken: a younger one may belong to a removal still in
    # flight, which moves its ignored files back if git refuses.
    trash = trash_dir(main)
    stale = [item for item in trash.iterdir() if time.time() - item.stat().st_mtime > 3600] if trash.is_dir() else []
    if stale:
        subprocess.Popen(["rm", "-rf", *map(str, stale)], start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if folder.is_dir():
        mine = folder / f"{me}.jsonl"
        if me and mine.is_file():
            # A resumed session continues its own records under its new process.
            append(folder, me, [{"type": "host", "host": host(), "at": int(time.time())}])
        for path in sorted(folder.glob("*.jsonl")):
            if path.name == f"{me}.jsonl":
                continue
            entries = load(path)
            stamp = last_host(entries)
            if stamp and alive(stamp):
                continue
            if not stamp and time.time() - path.stat().st_mtime < IDLE_SECONDS:
                continue
            claimed = path.with_name(f".{path.name}.sweep-{os.getpid()}")
            try:
                os.rename(path, claimed)
            except OSError:
                continue
            remover.label = f"session {path.stem}"
            remaining = finish(entries, remover, workloop)
            claimed.unlink()
            settle(path, remaining, stamp)
    recorded, leads = set(), set()
    for path in folder.glob("*.jsonl") if folder.is_dir() else []:
        for entry in load(path):
            if entry.get("type") == "worktree":
                recorded.add(str(Path(entry.get("path", "/")).resolve()))
            elif entry.get("type") == "run":
                leads.add(entry.get("run"))
    lanes, unowned = set(), []
    try:
        runs = json.loads((main / STATE).read_text()).get("runs", {})
    except (OSError, ValueError):
        runs = {}
    for name, run in runs.items():
        for lane in (run.get("lanes") or {}).values():
            if lane.get("workspace"):
                lanes.add(str(Path(lane["workspace"]).resolve()))
        if (run.get("integration") or {}).get("workspace"):
            lanes.add(str(Path(run["integration"]["workspace"]).resolve()))
        if name not in leads:
            unowned.append(name)
    remover.label = "an earlier session"
    remover.exclude = set()
    for entry in worktrees(main)[1:]:
        path = entry["path"]
        if entry["locked"] or entry["prunable"] or not path.is_dir():
            continue
        if str(path) in recorded or str(path) in lanes:
            continue
        if time.time() - idle_since(path) < IDLE_SECONDS:
            continue
        remover.retire(path)
    lines.extend(remover.lines)
    saved = out(main, "for-each-ref", "--format=%(refname:short) %(committerdate:short) %(subject)", "refs/heads/saved/")
    if saved:
        lines.append("Unsaved work from removed worktrees waits on these branches; merge what is wanted, then delete each branch:")
        lines.extend(f"  {line}" for line in saved.splitlines())
    if unowned:
        lines.append("Workloop runs no session recorded as their lead, left alone with their worktrees: " + ", ".join(sorted(unowned)))
    return lines


def main(argv: list[str]) -> int:
    if len(argv) == 5 and argv[1] == "end":
        for line in end(Path(argv[2]), argv[3], Path(argv[4])):
            print(line)
        return 0
    if len(argv) == 5 and argv[1] == "sweep":
        for line in sweep(Path(argv[2]), argv[3], Path(argv[4])):
            print(line)
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
