#!/usr/bin/env bash
# Engine-agnostic policy: workloop messages reach their reader without being
# asked for.
#
# The controller's inbox is durable and pull-only: a worker learns of a peer
# finding only by running `inbox`, and a lead learns a lane stalled only by
# running `watch`. This policy turns the same state into push, on the
# events a host lets a hook add context to:
#   SubagentStart      — the cell's host agent id while a lane is claimable,
#                        so a lane's writer, told by its brief to claim,
#                        claims with the id the hook will later recognise;
#                        plus anything already addressed to a lane it holds.
#   PostToolBatch      — unread messages for the lanes this cell has claimed,
#                        between its tool calls, once each; and it stamps the
#                        lane or cell with the time and the batch's last tool
#                        call (tool_name and tool_input of the payload), at
#                        most once a minute (agent_activity.py); and, for a
#                        lane's writer whose edits sit uncommitted over 30
#                        minutes, a COMMIT: line (commit_nudge.py, toggle
#                        hooks.commit_nudge.enabled).
#   UserPromptSubmit   — for the lead: lanes awaiting review, carrying
#                        attention, stale, broken, or whose worker died; cells
#                        still out or whose agent died; messages awaiting
#                        acknowledgement; a run ready to integrate; and, run or
#                        no run, each dead agent of this checkout read from
#                        Claude Code's own records (agent_deaths.py).
#
# A hook cannot start a turn for an idle agent, so this reaches a cell only
# while it is working and a lead only when they next speak. Codex and Kimi
# expose no equivalent events; there the brief's manual `inbox` stands.
#
# Input (stdin JSON): {"project_dir", "event", "session_id", "agent_id", "transcript_path",
#                      "tool_name", "tool_input"}; the last two are a tool batch's last call.
# Output: additionalContext with the block, or nothing.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="$repo/.agents/hooks/lib"
cfg_path="$repo/.agents/config.json"

payload="$(cat)"

{ read -r proj; read -r event; read -r session; read -r agent_id; read -r transcript; } < <(
  printf '%s' "$payload" | python3 -c '
import json, re, sys
try:
    p = json.load(sys.stdin)
except ValueError:
    p = {}
if not isinstance(p, dict):
    p = {}
for k in ("project_dir", "event", "session_id", "agent_id", "transcript_path"):
    print(re.sub(r"[\r\n]", " ", str(p.get(k) or "")))')

[[ -n "$proj" && -n "$session" ]] || exit 0
state="$proj/.agents/.workloop-state.json"
# Without state, a subagent's event costs the payload parse above and nothing
# more. The lead's prompt goes on, run or no run: it hears this checkout's dead
# agents.
[[ -z "$agent_id" || -f "$state" ]] || exit 0
enabled="$(python3 "$lib/config.py" "$cfg_path" hooks.workloop_inbox.enabled=true 2>/dev/null || echo yes)"
[[ "$enabled" == "no" ]] && exit 0

# A subagent's tool batch stamps its lane or cell with the time and its last
# tool call from the payload, which is how a silent agent shows an age; the lead's prompt
# refreshes the readout of agents out (agent_activity.py).
if [[ ( -n "$agent_id" || "$event" == "UserPromptSubmit" ) && -f "$state" ]]; then
  printf '%s' "$payload" | python3 "$lib/agent_activity.py" "$state" "$proj/.agents" "$session" "$event" "$agent_id" "$transcript" \
    || echo "workloop-inbox: stamping $agent_id's activity failed" >&2
fi

block="$(python3 "$lib/workloop-inbox.py" "$state" "$proj/.agents" "$session" "$event" "$agent_id")"

# A lane's writer sitting on edits over 30 minutes old hears a COMMIT: line
# (commit_nudge.py, which reads the toggle itself); a cell with no lane, and the
# lead, hear nothing from it.
if [[ -n "$agent_id" && "$event" == "PostToolBatch" && -f "$state" ]]; then
  nudge="$(python3 "$lib/commit_nudge.py" "$state" "$proj/.agents" "$session" "$agent_id" "$transcript")" \
    || { echo "workloop-inbox: the commit reminder for $agent_id failed" >&2; nudge=""; }
  [[ -z "$nudge" ]] || block="${block:+$block$'\n'}$nudge"
fi
[[ -n "$block" ]] || exit 0
printf '%s' "$block" | python3 "$lib/emit-context.py" "$event"
exit 0
