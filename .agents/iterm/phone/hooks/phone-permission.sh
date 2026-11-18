#!/usr/bin/env bash
# PermissionRequest hook of the phone link. `.agents/iterm/install.sh` links it
# into ~/.local/bin and registers it in each Claude account's user settings,
# for every tool except AskUserQuestion and ExitPlanMode, with timeout 3600.
#
# Claude Code's payload comes on stdin. client.py does the work beside this
# file's real place: it exits 0 at once, silently, unless the session's folder
# carries the harness (.agents/AGENTS.md at or above its cwd), and prints a
# decision only when the phone gave one.
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
exec python3 "$here/../client.py" permission
