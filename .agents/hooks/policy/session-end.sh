#!/usr/bin/env bash
# Engine-agnostic policy: when a session ends, remove the worktrees it made.
#
# teardown-gate.sh records every worktree an agent tool call makes, and every
# workloop run it creates or adds lanes to, in the session's record file.
# This removes what is still on disk, in this repository or another: a clean
# worktree at once, its branch deleted when the main checkout's HEAD contains
# it; one holding unsaved work after committing it to `saved/<worktree name>`;
# a workloop run's worktrees the same way, then the run closed with
# `workloop.py abandon`. A worktree locked by anything but Claude Code's own
# lock of this session, one a running process works in, one holding a nested
# repository, and an EnterWorktree worktree kept at Claude Code's exit prompt
# all stay and are named; so does a run whose lane's writer cell is still
# live. hooks/lib/worktree_removal.py owns the order of the checks, and
# hooks/lib/worktree_sweep.py `end` the session's record file.
#
# What a session that never reaches this hook leaves (a killed process, a host
# without the event) is swept by session-start.sh at the next start.
#
# Claude Code fires SessionEnd on /exit and Ctrl-D (reason prompt_input_exit,
# after its keep-or-remove prompt for a dirty EnterWorktree worktree), /clear
# (clear), /resume, a closed terminal and a finished `claude -p` (other); a
# SIGKILL fires nothing. The event cannot block, and its 1.5 s default budget
# is raised by the registration's `timeout`.
#
# Input (stdin JSON): {"project_dir", "session_id", "reason", "cwd"}. A payload
# without session_id falls back to CLAUDE_CODE_SESSION_ID, which Claude Code
# sets to the ending session's id in every hook's environment.
# Output: one line per worktree removed or kept, on stderr. Always exit 0.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="$repo/.agents/hooks/lib"
enabled="$(python3 "$lib/config.py" "$repo/.agents/config.json" hooks.teardown_gate.enabled=true)"
[[ "$enabled" == "no" ]] && exit 0

parsed="$(python3 "$lib/payload.py" project_dir session_id reason)"
proj="$(printf '%s\n' "$parsed" | sed -n '1p')"
session="$(printf '%s\n' "$parsed" | sed -n '2p')"
reason="$(printf '%s\n' "$parsed" | sed -n '3p')"
[[ -z "$proj" ]] && proj="$repo"
session="${session:-${CLAUDE_CODE_SESSION_ID:-}}"
if [[ -z "$session" ]]; then
  echo "session-end: no session id in the payload or CLAUDE_CODE_SESSION_ID; the next session start sweeps this session's worktrees" >&2
  exit 0
fi

report="$(python3 "$lib/worktree_sweep.py" end "$proj" "$session" "$reason" "$repo/.agents/workloop.py")" \
  || { echo "session-end: removing this session's worktrees failed; the next session start sweeps them" >&2; exit 0; }
[[ -n "$report" ]] && printf '%s\n' "$report" | sed 's/^/session-end: /' >&2
exit 0
