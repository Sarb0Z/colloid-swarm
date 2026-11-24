#!/usr/bin/env bash
# Engine-agnostic policy: when a session ends, mark its record ended.
#
# teardown-gate.sh records every worktree an agent tool call makes, and every
# workloop run it creates or adds lanes to, in the session's record file.
# This appends an `end` entry to that file and removes nothing: the hourly
# check (hooks/lib/worktree_sweep.py `hourly`, run from session-start.sh and
# the lead's per-prompt digest) removes a dead session's worktree once its
# work is merged into its source branch, and flags every other one to the lead
# with the operator's three answers (ruling R1). A resume of the same session
# stamps the record again, so a resumed session is never dead.
#
# What a session that never reaches this hook leaves (a killed process, a host
# without the event) reads dead once its process is gone.
#
# Claude Code fires SessionEnd on /exit and Ctrl-D (reason prompt_input_exit,
# after its keep-or-remove prompt for a dirty EnterWorktree worktree), /clear
# (clear), an in-session /resume (resume), a closed terminal and a finished
# `claude -p` (other); a SIGKILL fires nothing. The event cannot block.
#
# Input (stdin JSON): {"project_dir", "session_id", "reason", "cwd"}. A payload
# without session_id falls back to CLAUDE_CODE_SESSION_ID, which Claude Code
# sets to the ending session's id in every hook's environment.
# Output: nothing, or why the end could not be marked, on stderr. Always exit 0.
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
  echo "session-end: no session id in the payload or CLAUDE_CODE_SESSION_ID; this session's worktrees read dead once its process is gone" >&2
  exit 0
fi

python3 "$lib/worktree_sweep.py" end "$proj" "$session" "$reason" \
  || echo "session-end: marking this session's end failed; its worktrees read dead once its process is gone" >&2
exit 0
