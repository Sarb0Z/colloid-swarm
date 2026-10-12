#!/usr/bin/env python3
"""The product folder: the one folder outside a checkout whose notes agents may edit.

Usage: product_folder.py root <checkout>
         Prints the product folder and exits 0, or exits 1: silently when the
         switch is off, with one stderr line saying why when it is refused.
       product_folder.py grant <checkout>
         Reads a PreToolUse payload on stdin ({"tool_input", "cwd",
         "permission_mode"}); prints an "allow" decision when the payload names
         at least one file, the product folder holds every one, and the
         session is not in plan mode.

A product folder is the directory that holds one product's repositories side
by side with that product's notes. It is the checkout's parent directory minus
every git checkout inside it, and it is open only where the operator set
`hooks.product_folder.enabled` in the ignored config.json. The switch is read
from that file alone, never from the tracked policy.json: a tracked switch
would travel to clones whose parent folder can be anything. An agent that may
edit config.json can turn it on (debt: colloid-product-folder-switch-agent-writable).

The grant is hard-coded around what it must never open: a checkout (its own
guards govern it), a hidden folder or file (tool and account state), the
instruction files a session in a sibling repository loads from this folder,
and the risky parts of a notes folder: a folder named for tools, backups or
installed packages, and a file that runs. That last rule is a deny-list, so a
new risky folder name is open until it is added to RISKY_NAMES.

`worklog.py` keeps a second, stricter folder rule on purpose: it vets the one
folder the work log names, while this grant covers the whole parent folder.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # noqa: E402
import write_targets  # noqa: E402

# Compared case-folded: on a case-insensitive volume `agents.md` is AGENTS.md.
INSTRUCTION_FILES = {"agents.md", "claude.md", "claude.local.md"}
RISKY_NAMES = {"tools", "backups", "node_modules", "__pycache__"}
RISKY_SUFFIXES = {".py", ".sh", ".js", ".mjs"}


def _refuse(reason):
    print(f"product_folder.py: {reason}", file=sys.stderr)
    return None


def root(checkout):
    """The product folder of `checkout`, or None (one stderr line when refused)."""
    settings = config.read_json(os.path.join(checkout, ".agents", "config.json"))
    if not config.read(settings, "hooks.product_folder.enabled", False):
        return None
    checkout = os.path.realpath(checkout)
    if os.path.isfile(os.path.join(checkout, ".git")):
        return _refuse(f"{checkout} is a linked worktree, whose parent folder is not a product folder.")
    if not os.path.isdir(os.path.join(checkout, ".git")):
        return _refuse(f"{checkout} has no .git directory, so it is not the root of a checkout.")
    parent = os.path.dirname(checkout)
    home = os.environ.get("HOME")
    if not home:
        return _refuse("HOME is unset, so no folder is known to lie under it.")
    home = os.path.realpath(home)
    if not parent.startswith(home + os.sep):
        return _refuse(f"{parent} does not lie under {home}; a product folder must.")
    folder = parent
    while True:
        if os.path.exists(os.path.join(folder, ".git")):
            return _refuse(f"{parent} is inside the git checkout {folder}, so it is not a product folder.")
        up = os.path.dirname(folder)
        if up == folder:
            return parent
        folder = up


def holds(folder, path):
    """True when `path` lies in `folder` outside every checkout, hidden name, instruction file and risky part."""
    real = os.path.realpath(path)
    if not real.startswith(folder + os.sep):
        return False
    names = real[len(folder) + 1:].split(os.sep)
    if any(name.startswith(".") or name.casefold() in INSTRUCTION_FILES | RISKY_NAMES for name in names):
        return False
    if os.path.splitext(names[-1])[1].casefold() in RISKY_SUFFIXES:
        return False
    here = os.path.dirname(real)
    while here != folder:
        if os.path.exists(os.path.join(here, ".git")):
            return False
        here = os.path.dirname(here)
    return True


def targets(payload):
    """Every path the payload's write tool names, resolved against its working folder."""
    base = payload.get("cwd") or ""
    if not isinstance(base, str):
        base = ""
    return [os.path.join(base, os.path.expanduser(name)) for name in write_targets.named(payload.get("tool_input"))]


def payload_holds(checkout, payload):
    folder = root(checkout)
    paths = targets(payload)
    return bool(folder and paths and all(os.path.isabs(p) and holds(folder, p) for p in paths))


def main(argv):
    if len(argv) != 3 or argv[1] not in ("root", "grant"):
        raise SystemExit("product_folder.py: usage: product_folder.py root|grant <checkout>")
    command, checkout = argv[1], argv[2]
    if command == "root":
        folder = root(checkout)
        if folder:
            print(folder)
        return 0 if folder else 1
    try:
        payload = json.load(sys.stdin)
    except ValueError as error:
        print(f"product_folder.py: the payload is not JSON ({error}); nothing is granted.", file=sys.stderr)
        return 1
    if not isinstance(payload, dict):
        print("product_folder.py: the payload is not a JSON object; nothing is granted.", file=sys.stderr)
        return 1
    if payload_holds(checkout, payload) and payload.get("permission_mode") != "plan":
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": "The target lies in the product folder, which hooks.product_folder.enabled opens.",
        }}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
