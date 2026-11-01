#!/usr/bin/env bash
# Policy: before a shell command that reads the macOS login keychain runs, name
# that command where the operator will see it.
#
# Input  (stdin JSON): {"project_dir": "<repo>", "cwd": "<shell dir>", "command": "<cmd>"}
# Output: a macOS notification and, inside tmux, a status-line message, each
#         naming the project folder, the reader and the command line that runs
#         it; the whole command appended to .agents/.keychain-notices.log.
#         Always exit 0: the notice never blocks.
#
# macOS's keychain dialog names only the program that asks ("supabase wants to
# access key ..."). With several sessions open, nothing else says which one ran
# it or why. hooks/lib/keychain-readers.py decides what counts as a reader.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="$repo/.agents/hooks/lib"

[[ "$(uname -s)" == Darwin ]] || exit 0
[[ "$(python3 "$lib/config.py" "$repo/.agents/config.json" hooks.keychain_notice.enabled=true)" == yes ]] || exit 0

# payload.py keeps newlines only in its last field, so the command goes last.
# An empty payload prints nothing, and the read's end-of-file is not a failure.
{ IFS= read -r cwd || true; command="$(cat)"; } < <(python3 "$lib/payload.py" cwd= command=)
[[ -n "$command" ]] || exit 0

status=0
found="$(printf '%s' "$command" | python3 "$lib/keychain-readers.py" "$repo/.agents/config.json")" || status=$?
[[ $status -ne 3 ]] || exit 0
if [[ $status -ne 0 ]]; then
  echo "keychain-notice: keychain-readers.py failed (exit $status), so this command gets no notice" >&2
  exit 0
fi
reader="${found%%$'\n'*}"
line="${found#*$'\n'}"
folder="${repo##*/}"

printf '%s  %s  reader: %s\n  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${cwd:-$repo}" "$reader" "$command" \
  >>"$repo/.agents/.keychain-notices.log" ||
  echo "keychain-notice: could not append to $repo/.agents/.keychain-notices.log" >&2

# A notifier that hangs, with no window server or a stuck notification daemon,
# must not hold the agent's command: each gets five seconds.
bounded() {  # <label> <command...>
  "${@:2}" >/dev/null &
  local pid=$! tries=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( ++tries > 50 )); then
      kill "$pid" 2>/dev/null || true
      echo "keychain-notice: $1 did not finish within 5 s and was stopped" >&2
      return 0
    fi
    sleep 0.1
  done
  wait "$pid" || echo "keychain-notice: $1 failed" >&2
}

bounded "osascript's notification" osascript \
  -e 'on run argv' \
  -e 'display notification (item 3 of argv) with title "Agent shell command: keychain read" subtitle ((item 1 of argv) & " · " & (item 2 of argv))' \
  -e 'end run' \
  "$folder" "$reader" "${line:0:240}"

# A Focus mode, or notifications switched off for Script Editor, hides the
# notification; inside tmux the status line carries the same notice. tmux reads
# `#` as the start of a format or a style, so each is doubled to show as typed.
if [[ -n "${TMUX:-}" ]]; then
  message="Keychain read by an agent shell command ($folder, $reader): ${line:0:160}"
  bounded "tmux's status-line notice" tmux display-message -d 15000 "${message//\#/##}"
fi
exit 0
