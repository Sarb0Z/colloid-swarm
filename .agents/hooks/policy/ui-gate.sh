#!/usr/bin/env bash
# Engine-agnostic policy: a UI change must be looked at before the turn ends.
#
# Two events share one policy because they share one state file:
#   PostToolUse  — an edit to a client-rendered UI file records the path in
#                  .agents/.ui-pending-<session>; the first such edit in a batch
#                  also injects a reminder. A screenshot tool call clears the
#                  file: every recorded edit happened before it.
#   Stop         — a non-empty pending file blocks the stop once (exit 2) with
#                  the file list, then marks itself so later stops pass until a
#                  screenshot clears the file.
#                  A one-shot is accepted deliberately: the host caps repeated
#                  blocks anyway, and a second block teaches nothing new.
#
# Scope: client-rendered UI (tsx, jsx, vue, svelte, css, scss, html). Server
# templates are not covered. A screenshot of the wrong page still clears the
# gate — no host ties a screenshot to a route — so the gate guarantees a look,
# not the right look. Subagent edits record under the parent session on hosts
# that share the id, which is unverified. debt: colloid-ui-gate-subagent-session-id
# Kimi is not wired: its PostToolUse output is discarded.
#
# Input (stdin JSON): {"project_dir", "event": "PostToolUse"|"Stop", "session_id",
#   "files": [...], "tool_name": "...", "stop_hook_active": bool}
# Output: PostToolUse — an additionalContext object on the first pending edit,
#   exit 0. Stop — exit 2 + stderr reason on a block, exit 0 otherwise.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="$repo/.agents/hooks/lib"
enabled="$(python3 "$lib/config.py" "$repo/.agents/config.json" hooks.ui_gate.enabled=true)"
[[ "$enabled" == "no" ]] && exit 0

# One interpreter for every field plus the UI-file filter: this runs on every
# edit, so each extra process is paid thousands of times a session.
read -r -d '' parse <<'PY' || true
import json, re, sys
try:
    p = json.loads(sys.stdin.read() or "{}")
except ValueError:
    p = {}
p = p if isinstance(p, dict) else {}
s = lambda k: v if isinstance((v := p.get(k)), str) else ""
ui = re.compile(r"\.(tsx|jsx|vue|svelte|css|scss|html)$")
skip = re.compile(r"(\.test\.|\.spec\.|\.stories\.|/__tests__/|/node_modules/|/dist/|/build/)")
hits = [f for f in (p.get("files") or []) if isinstance(f, str) and ui.search(f) and not skip.search(f)]
print(s("project_dir")); print(s("event")); print(re.sub(r"[^A-Za-z0-9_-]", "", s("session_id")))
print(s("tool_name")); print("yes" if p.get("stop_hook_active") else "no"); print("\n".join(hits))
PY
parsed="$(python3 -c "$parse")"
proj="$(printf '%s\n' "$parsed" | sed -n '1p')"
event="$(printf '%s\n' "$parsed" | sed -n '2p')"
session="$(printf '%s\n' "$parsed" | sed -n '3p')"
tool="$(printf '%s\n' "$parsed" | sed -n '4p')"
stop_active="$(printf '%s\n' "$parsed" | sed -n '5p')"
hits="$(printf '%s\n' "$parsed" | tail -n +6 | grep . || true)"
[[ -z "$proj" ]] && proj="$repo"

# No session identity means no state to key on; do nothing rather than share
# one file across every session.
[[ -z "$session" ]] && exit 0
pending="$proj/.agents/.ui-pending-$session"

screenshot='^(mcp__playwright__browser_take_screenshot|mcp__plugin_playwright_playwright__browser_take_screenshot|mcp__playwright-reader__browser_take_screenshot|mcp__claude-in-chrome__.*screenshot.*)$'

case "$event" in
PostToolUse)
  if [[ -n "$tool" ]] && printf '%s' "$tool" | grep -Eq "$screenshot"; then
    rm -f "$pending"
    exit 0
  fi
  [[ -z "$hits" ]] && exit 0
  first="no"
  [[ -s "$pending" ]] || first="yes"
  mkdir -p "$proj/.agents"
  printf '%s\n' "$hits" >> "$pending"
  [[ "$first" == "no" ]] && exit 0
  printf '%s' "UI changed: $(printf '%s' "$hits" | head -n1). Before you report it done, render the route and take a screenshot (a browser_take_screenshot call clears this gate); fix what you see." \
    | python3 "$lib/emit-context.py" PostToolUse
  exit 0
  ;;
Stop)
  find "$proj/.agents" -maxdepth 1 -name '.ui-pending-*' -mtime +7 -delete 2>/dev/null || true
  [[ -s "$pending" ]] || exit 0
  # A sibling Stop hook may have blocked; the host flag says so. Pass without
  # clearing, so the next stop still gets judged on the same edits.
  [[ "$stop_active" == "yes" ]] && exit 0
  if grep -qx '#blocked' "$pending"; then
    exit 0
  fi
  paths="$(grep -v '^#' "$pending" | awk '!seen[$0]++')"
  count="$(printf '%s\n' "$paths" | grep -c . || true)"
  printf '#blocked\n' >> "$pending"
  {
    printf 'You changed %s UI file(s) this session and never looked at the rendered result:\n' "$count"
    printf '%s\n' "$paths" | sed 's/^/  - /'
    printf 'Render the route you changed and take a screenshot (browser_take_screenshot) before reporting it done; fix what you see. This gate blocks once per session, until a screenshot clears it.\n'
  } >&2
  exit 2
  ;;
*)
  exit 0
  ;;
esac
