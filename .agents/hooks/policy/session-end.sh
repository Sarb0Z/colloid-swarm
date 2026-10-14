#!/usr/bin/env bash
# Engine-agnostic policy: when a session ends, remove the worktrees it made.
#
# teardown-gate.sh records every worktree an agent tool call makes, and every
# workloop run it creates or adds lanes to, in the session's record file.
# This removes what is still on disk: a clean worktree at once, its branch
# deleted when the main checkout's HEAD contains it; one holding unsaved work
# after committing it to `saved/<worktree name>`; a workloop run's worktrees
# the same way, then the run closed with `workloop.py abandon`. A locked
# worktree, or one a running process works in, stays and is named.
# hooks/lib/worktree_records.py owns all of it; its header has the order of
# the checks and the record format.
#
# What a session that never reaches this hook leaves (a killed process, a host
# without the event) is swept by session-start.sh at the next start.
#
# Claude Code fires SessionEnd on /exit, Ctrl-D, /clear, an interactive
# /resume, a closed terminal, and when `claude -p` finishes; a SIGKILL fires
# nothing. The event cannot block, and its 1.5 s default budget is raised by
# the registration's `timeout`.
#
# The session is the payload's session_id, or CLAUDE_CODE_SESSION_ID, which
# Claude Code sets to the same value in every hook's environment; its adapter
# passes this policy only project_dir.
#
# Input (stdin JSON): {"project_dir", "session_id"?}.
# Output: one line per worktree removed or kept, on stderr. Always exit 0.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="$repo/.agents/hooks/lib"
enabled="$(python3 "$lib/config.py" "$repo/.agents/config.json" hooks.teardown_gate.enabled=true)"
[[ "$enabled" == "no" ]] && exit 0

parsed="$(python3 "$lib/payload.py" project_dir session_id)"
proj="$(printf '%s\n' "$parsed" | sed -n '1p')"
session="$(printf '%s\n' "$parsed" | sed -n '2p')"
[[ -z "$proj" ]] && proj="$repo"
session="${session:-${CLAUDE_CODE_SESSION_ID:-}}"
if [[ -z "$session" ]]; then
  echo "session-end: no session id in the payload or CLAUDE_CODE_SESSION_ID; the next session start sweeps this session's worktrees" >&2
  exit 0
fi

report="$(python3 "$lib/worktree_records.py" end "$proj" "$session" "$repo/.agents/workloop.py")" \
  || { echo "session-end: removing this session's worktrees failed; the next session start sweeps them" >&2; exit 0; }
[[ -n "$report" ]] && printf '%s\n' "$report" | sed 's/^/session-end: /' >&2
exit 0
