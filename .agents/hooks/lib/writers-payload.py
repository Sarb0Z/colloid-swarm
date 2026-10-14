#!/usr/bin/env python3
"""Read the parallel-writers gate's payload into the lines the gate reads.

Usage: writers-payload.py   # the gate's payload on stdin

Prints fourteen lines, in order: project_dir, event, session_id, prompt_id,
agent_id, agent_type, tool_name, the dispatch's subagent_type, the dispatch's
kind, whether every write target lies outside the checkout (yes|no),
tool_use_id, transcript_path, why a declared workspace was refused (empty
when none was declared or it was accepted), and the task a TaskStop call
names, which for a background cell is its agent id. Ids that name state files keep only
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

BRIEF = re.compile(r"WORKLOOP (?:WORKER|REVIEWER|QA) BRIEF[^\w\n]+([\w.-]+)/([\w.-]+)")
WORKSPACE = re.compile(r"^[ \t]*WORKSPACE:[ \t]*(\S.*?)[ \t]*$", re.MULTILINE)


def line(value):
    return re.sub(r"[\r\n]", " ", str(value or ""))


def ident(value):
    return re.sub(r"[^A-Za-z0-9_-]", "", str(value or ""))


def real_lane(root, prompt):
    """A header is only text anyone can type; it exempts the dispatch when the
    controller really holds that lane with a worktree outside this checkout."""
    header = BRIEF.search(prompt)
    if not header:
        return False
    try:
        with open(os.path.join(root, ".agents", ".workloop-state.json"), encoding="utf-8") as source:
            lane = json.load(source)["runs"][header.group(1)]["lanes"][header.group(2)]
        workspace = os.path.realpath(lane["workspace"])
    except (OSError, ValueError, KeyError, TypeError):
        return False
    return not write_targets.in_checkout(workspace, root)


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
    if real_lane(root, prompt):
        return "brief"
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
