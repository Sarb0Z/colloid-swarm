#!/usr/bin/env python3
"""Resolve the work log's day file, or say why its folder is refused.

Usage: worklog.py <repo>

Prints three lines: off | ok | refused; then today's file or the refusal
reason; then the folder an operator must grant, empty when it is in the tree.
`session-start.sh` injects the procedure from it and `session-wrap.sh` checks
the day file's age, so the folder rules live here alone.

The setting is read from the untracked config.json only: the folder is one
operator's machine, and a tracked policy.json naming a path outside the
repository would point every clone at a folder its operator never chose. Off
reads no path outside the tree. The folder is never created.

`product_folder.py` keeps a second, looser folder rule on purpose: it grants
the whole parent folder, while this vets the one folder the log names.
"""

import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # noqa: E402


def emit(status, detail="", grant=""):
    print(status)
    print(detail)
    print(grant)
    sys.exit(0)


def main(repo):
    settings = config.read_json(os.path.join(repo, ".agents", "config.json"))
    if not config.read(settings, "hooks.worklog.enabled", False):
        emit("off")
    day = time.strftime("%Y-%m-%d") + ".md"
    root = os.path.realpath(repo)
    raw = config.read(settings, "hooks.worklog.dir", "")
    if raw is None:
        raw = ""
    if not isinstance(raw, str):
        emit("refused", "hooks.worklog.dir must be a folder path as a string.")
    raw = raw.strip()
    if not raw:
        emit("ok", os.path.join(root, ".agents", "worklog", day))

    target = os.path.realpath(os.path.join(root, os.path.expanduser(raw)))
    hidden = [part for part in target.split(os.sep) if part.startswith(".")]
    if hidden:
        emit("refused", f"{target} lies in a hidden folder ({hidden[0]}); hidden folders hold tool and account state.")
    parent = os.path.dirname(root)
    if not os.path.exists(target):
        emit("refused", f"{target} does not exist. Create it yourself; the hook never creates it.")
    if not os.path.isdir(target):
        emit("refused", f"{target} is not a folder.")
    if target == root or target.startswith(root + os.sep):
        emit("refused", f"{target} is this repository or inside it. Leave hooks.worklog.dir empty "
                        "to keep the log in .agents/worklog/, which Git ignores.")
    if target == parent:
        emit("refused", f"{target} is the folder that holds this repository. Use a subfolder of it, "
                        f"such as {os.path.join(parent, 'worklog')}.")
    if not target.startswith(parent + os.sep):
        emit("refused", f"{target} is outside {parent}, the folder that holds this repository.")
    if os.path.exists(os.path.join(target, ".git")):
        emit("refused", f"{target} is a Git repository.")
    # A bounded walk: a repository up to four levels down is refused; deeper ones
    # are not looked for, so a large folder costs at most four levels of listing.
    level = [target]
    for _ in range(4):
        below = []
        for folder in level:
            try:
                entries = sorted(os.scandir(folder), key=lambda entry: entry.name)
            except OSError as error:
                emit("refused", f"{folder} cannot be listed ({error.strerror}).")
            for entry in entries:
                if entry.is_dir(follow_symlinks=False):
                    if os.path.exists(os.path.join(entry.path, ".git")):
                        emit("refused", f"{target} holds a Git repository ({os.path.relpath(entry.path, target)}).")
                    below.append(entry.path)
        level = below
    env = {name: value for name, value in os.environ.items() if not name.startswith("GIT_")}
    inside = subprocess.run(["git", "-C", target, "rev-parse", "--is-inside-work-tree"],
                            capture_output=True, text=True, env=env)
    if inside.returncode == 0:
        emit("refused", f"{target} is inside a Git work tree.")
    emit("ok", os.path.join(target, day), target)


if __name__ == "__main__":
    main(sys.argv[1])
