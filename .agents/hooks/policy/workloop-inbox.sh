#!/usr/bin/env bash
# Engine-agnostic policy: workloop messages reach their reader without being
# asked for.
#
# The controller's inbox is durable and pull-only: a worker learns of a peer
# finding only by running `inbox`, and a lead learns a lane stalled only by
# running `watch`. This policy turns the same state into push, on the
# events a host lets a hook add context to:
#   SubagentStart      — the cell's host agent id, so it claims its lane with
#                        the id the hook will later recognise; plus anything
#                        already addressed to a lane it holds.
#   PostToolBatch      — unread messages for the lanes this cell has claimed,
#                        between its tool calls, once each.
#   UserPromptSubmit   — for the lead: lanes awaiting review, carrying
#                        attention, stale, or broken; messages awaiting
#                        acknowledgement; a run ready to integrate.
#
# A hook cannot start a turn for an idle agent, so this reaches a cell only
# while it is working and a lead only when they next speak. Codex and Kimi
# expose no equivalent events; there the brief's manual `inbox` stands.
#
# Input (stdin JSON): {"project_dir", "event", "session_id", "agent_id"}
# Output: additionalContext with the block, or nothing.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="$repo/.agents/hooks/lib"
cfg_path="$repo/.agents/config.json"

payload="$(cat)"

{ read -r proj; read -r event; read -r session; read -r agent_id; } < <(
  printf '%s' "$payload" | python3 -c '
import json, re, sys
try:
    p = json.load(sys.stdin)
except ValueError:
    p = {}
if not isinstance(p, dict):
    p = {}
for k in ("project_dir", "event", "session_id", "agent_id"):
    print(re.sub(r"[\r\n]", " ", str(p.get(k) or "")))')

[[ -n "$proj" && -n "$session" ]] || exit 0
state="$proj/.agents/.workloop-state.json"
# A repository that never runs a workloop pays one interpreter start per
# event and nothing more: the toggle is read only once there is state.
[[ -f "$state" ]] || exit 0
enabled="$(python3 "$lib/config.py" "$cfg_path" hooks.workloop_inbox.enabled=true 2>/dev/null || echo yes)"
[[ "$enabled" == "no" ]] && exit 0

block="$(python3 "$lib/workloop-inbox.py" "$state" "$proj/.agents" "$session" "$event" "$agent_id")"
[[ -n "$block" ]] || exit 0
printf '%s' "$block" | python3 "$lib/emit-context.py" "$event"
exit 0
