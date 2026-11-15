#!/usr/bin/env bash
# Policy: show in iTerm2's Session Status sidebar what waits on the operator in
# this tab at the end of a turn: an open gate (`waiting`, `decide: <gate>`), a
# background agent of this session whose death was found in that turn
# (`error`, `agent died: ...`), or what the session owes (`done`, `owed: ...`).
#
# Events: Stop and Notification idle_prompt, async, main agent only;
#         hooks/lib/iterm_attention.py holds the rules.
# Input  (stdin JSON): {"project_dir", "event", "notification_type",
#                       "session_id", "transcript_path",
#                       "last_assistant_message"}
# Output: nothing on stdout. With something to show, it watches this tab with
#         `it2 session get-status` for 6 s at most and runs `it2 session
#         set-status` once the turn's end shows, and again each time iTerm2 or
#         Claude Code covers the status; it stops when a new turn starts.
#         Always exits 0; a failure goes to stderr and to one line of
#         .agents/.readout/.iterm-attention.log.
#
# Most runs are not a tab's own Claude, so the checks that need no Python run
# here and end those runs before an interpreter starts. ITERM_ATTENTION_IT2
# names another it2 for tests; the tab records are claude-tab-state's.

set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
it2="${ITERM_ATTENTION_IT2:-$HOME/.config/iterm2/it2}"

[[ -n "${ITERM_SESSION_ID:-}" && -x "$it2" ]] || exit 0

python3 "$repo/.agents/hooks/lib/iterm_attention.py" "$repo" "$it2"
status=$?
if (( status )); then
  # An async hook's stderr reaches no one, so the log is where a crash shows.
  message="iterm_attention.py exited $status, so the tab keeps iTerm2's own status"
  echo "iterm-attention: $message" >&2
  log="$repo/.agents/.readout/.iterm-attention.log"
  { mkdir -p "${log%/*}" && printf '%s ?: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$message" >>"$log"; } \
    || echo "iterm-attention: could not append to $log" >&2
fi
exit 0
