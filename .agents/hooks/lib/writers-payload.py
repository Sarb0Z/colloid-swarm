#!/usr/bin/env python3
"""Read the parallel-writers gate's payload into the lines the gate reads.

Usage: writers-payload.py   # the gate's payload on stdin

Prints fifteen lines, in order: project_dir, event, session_id, prompt_id,
agent_id, agent_type, tool_name, the dispatch's subagent_type, the dispatch's
kind, whether every write target lies outside the checkout (yes|no),
tool_use_id, transcript_path, why a declared workspace was refused (empty
when none was declared or it was accepted), the task a TaskStop call
names, which for a background cell is its agent id, and whether the prompt
carries a `WORKLOOP (WORKER|REVIEWER|QA|CELL) BRIEF` header (yes|no), the
mark of a dispatch a run records. Ids that name state files keep only
[A-Za-z0-9_-]; every other field is flattened to one line. A payload that is
not a JSON object reads as empty, which the gate ignores.

The kind is, tested in this order, `read-only` or `notes-only` for a prompt
that opens with that marker, `brief` for a workloop brief naming a lane the
controller holds outside the checkout, `workspace` for a prompt with one
`WORKSPACE: <absolute path>` line naming an existing directory that neither
contains nor lies in the checkout and is no worktree or clone of this
repository, and `plain` otherwise. A copy made without Git (`cp -R`, an
archive) cannot be told from an unrelated directory.

"In the checkout" is write_targets.in_checkout: the nearest Git working tree
decides, so a lane worktree nested at `.agents/worktrees/<run>/<lane>` lies
outside it, and is still refused as a WORKSPACE, being a worktree of this
repository.
"""

import json
import os
import re
import subprocess
import sys

import write_targets

BRIEF = re.compile(r"WORKLOOP (WORKER|REVIEWER|QA|CELL) BRIEF[^\w\n]+([\w.-]+)/([\w.-]+)")
BRIEF_PATH = re.compile(r"Read the full brief at (/\S+?\.md)\b")
BRIEF_STATE = re.compile(r"workloop\.py --state (/\S+)")
WORKSPACE = re.compile(r"^[ \t]*WORKSPACE:[ \t]*(\S.*?)[ \t]*$", re.MULTILINE)
# A run's cells of these roles return text and write nothing (workloop_cells.py).
READING_ROLES = ("research", "review", "qa")


def line(value):
    return re.sub(r"[\r\n]", " ", str(value or ""))


def ident(value):
    return re.sub(r"[^A-Za-z0-9_-]", "", str(value or ""))


def main_checkout(directory):
    """The main working tree of the repository holding `directory`, or None."""
    common = git_words(directory, "rev-parse", "--path-format=absolute", "--git-common-dir")
    path = next(iter(common), "") if len(common) == 1 else ""
    return os.path.dirname(path) if path.endswith(os.sep + ".git") else None


def state_file(root, prompt):
    """The workloop state file that records the brief's run. The brief file the
    dispatch names (`Read the full brief at <path>`) carries it on its State,
    Claim and handoff lines (`--state <path>`), wherever the run's state lives;
    a brief file without one lies in a lane worktree or the run's folder, so
    Git places it in its repository, whose state is the default. With neither,
    the run is this checkout's."""
    found = BRIEF_PATH.search(prompt)
    if found:
        try:
            with open(found.group(1), encoding="utf-8") as source:
                named = BRIEF_STATE.search(source.read())
        except OSError:
            named = None
        if named:
            return named.group(1)
        there = main_checkout(os.path.dirname(found.group(1))) if os.path.isdir(os.path.dirname(found.group(1))) else None
        if there:
            return os.path.join(there, ".agents", ".workloop-state.json")
    return os.path.join(main_checkout(root) or root, ".agents", ".workloop-state.json")


def elsewhere(root, run):
    """True when the run's repository is another than this checkout's."""
    repo = run.get("repo") if isinstance(run, dict) else None
    if not isinstance(repo, str) or not os.path.isdir(repo):
        return False
    there, here = main_checkout(repo), main_checkout(root) or root
    return bool(there) and os.path.realpath(there) != os.path.realpath(here)


def briefed(root, prompt):
    """What a WORKLOOP … BRIEF header makes the dispatch: `brief` for a lane the
    controller holds outside this checkout, `read-only` for a run's research,
    review or QA cell, None otherwise. A header is only text anyone can type, so
    each is read from the run's state."""
    header = BRIEF.search(prompt)
    if not header:
        return None
    role, run_name, name = header.groups()
    try:
        with open(state_file(root, prompt), encoding="utf-8") as source:
            run = json.load(source)["runs"][run_name]
        if role == "CELL":
            return "read-only" if run["cells"][name]["role"] in READING_ROLES else None
        lane = run["lanes"][name]
        workspace = os.path.realpath(lane["workspace"])
    except (OSError, ValueError, KeyError, TypeError):
        return None
    # A lane of another repository's run never writes in this checkout.
    if elsewhere(root, run):
        return "brief"
    # A main lane works in its run's checkout, which may be a worktree or a
    # clone of this one: wherever that is, its cell is a plain writer here.
    if isinstance(lane, dict) and lane.get("place") == "main":
        return None
    return None if write_targets.in_checkout(workspace, root) else "brief"


def git_words(directory, *args):
    # Git's location variables (GIT_DIR, GIT_WORK_TREE, ...), inherited from a
    # git hook or a bare-repository dotfiles setup, would point every call at
    # one repository, and every WORKSPACE would read as this one.
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    try:
        done = subprocess.run(["git", "-C", directory, *args], capture_output=True, text=True, timeout=5, env=env)
    except (OSError, subprocess.TimeoutExpired):
        return set()
    return set(done.stdout.split()) if done.returncode == 0 else set()


def same_repository(workspace, root):
    """A worktree shares the common Git directory; a clone shares a root commit."""
    common = ("rev-parse", "--path-format=absolute", "--git-common-dir")
    shared = git_words(workspace, *common)
    if shared and shared == git_words(root, *common):
        return True
    roots = ("rev-list", "--max-parents=0", "HEAD")
    return bool(git_words(workspace, *roots) & git_words(root, *roots))


def workspace_refusal(root, prompt):
    """Why the prompt's WORKSPACE line does not place the cell outside the
    checkout: empty when it does, or when the prompt declares none."""
    declared = WORKSPACE.findall(prompt)
    if not declared:
        return ""
    if len(declared) > 1:
        return "the prompt declares more than one WORKSPACE line"
    raw = declared[0]
    if not os.path.isabs(raw):
        return f"WORKSPACE {raw} is not an absolute path"
    if not os.path.isdir(raw):
        return f"WORKSPACE {raw} is not an existing directory"
    workspace = os.path.realpath(raw)
    if write_targets.in_checkout(workspace, root):
        return f"WORKSPACE {raw} lies inside this checkout"
    if write_targets.under(root, workspace):
        return f"WORKSPACE {raw} contains this checkout"
    if same_repository(workspace, root):
        return f"WORKSPACE {raw} is a worktree or clone of this repository, whose parallel work goes through a workloop run"
    return ""


def kind(root, prompt, refusal):
    # An explicit marker outranks a brief: a lane's reviewer opened READ-ONLY
    # writes nothing.
    if re.match(r"\s*READ-ONLY\b", prompt):
        return "read-only"
    if re.match(r"\s*NOTES-ONLY\b", prompt):
        return "notes-only"
    if found := briefed(root, prompt):
        return found
    if WORKSPACE.search(prompt) and not refusal:
        return "workspace"
    return "plain"


def outside(root, tool_input):
    """An edit whose every target lies outside the checkout, a nested lane
    worktree included, cannot collide with a cell working in it. A relative
    path is the checkout's."""
    paths = write_targets.resolved(root, tool_input)
    return "yes" if paths and not any(write_targets.in_checkout(path, root) for path in paths) else "no"


def fields(payload):
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = {}
    root = os.path.realpath(str(payload.get("project_dir") or "."))
    prompt = str(tool_input.get("prompt") or "")
    refusal = workspace_refusal(root, prompt)
    return [
        line(payload.get("project_dir")), line(payload.get("event")),
        ident(payload.get("session_id")), ident(payload.get("prompt_id")),
        ident(payload.get("agent_id")), line(payload.get("agent_type")), line(payload.get("tool_name")),
        line(tool_input.get("subagent_type") or "general-purpose"),
        kind(root, prompt, refusal), outside(root, tool_input),
        line(payload.get("tool_use_id")), line(payload.get("transcript_path")), line(refusal),
        ident(tool_input.get("task_id")),
        "yes" if BRIEF.search(prompt) else "no",
    ]


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        payload = {}
    print("\n".join(fields(payload if isinstance(payload, dict) else {})))
    return 0


if __name__ == "__main__":
    sys.exit(main())
