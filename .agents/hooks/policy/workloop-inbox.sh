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
#                        between its tool calls, once each; and it stamps the
#                        lane or cell with the time and its last tool call,
#                        at most once a minute (agent_activity.py).
#   UserPromptSubmit   — for the lead: lanes awaiting review, carrying
#                        attention, stale, or broken; cells still out;
#                        messages awaiting acknowledgement; a run ready to
#                        integrate; and, run or no run, a turn that dispatched
#                        two or more cells outside any run, read from the
#                        parallel-writers gate's .agents/.outside-runs-<session>
#                        (ruling 36).
#
# A hook cannot start a turn for an idle agent, so this reaches a cell only
# while it is working and a lead only when they next speak. Codex and Kimi
# expose no equivalent events; there the brief's manual `inbox` stands.
#
# Input (stdin JSON): {"project_dir", "event", "session_id", "agent_id", "transcript_path"}
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
# The gate names its ledger by the session id reduced to [A-Za-z0-9_-].
outside_runs="$proj/.agents/.outside-runs-$(printf '%s' "$session" | tr -cd 'A-Za-z0-9_-')"
# Without state, an event costs the payload parse above and nothing more,
# except a subagent's start or stop, which is recorded so a run begun
# mid-session knows which cells it can trust as its own. The ledger of
# dispatches outside any run lifts that exit at the lead's prompt alone, the
# one event that reads it.
if [[ ! -f "$state" ]] && ! [[ "$event" == "UserPromptSubmit" && -f "$outside_runs" ]]; then
  [[ -n "$agent_id" && ( "$event" == "SubagentStart" || "$event" == "SubagentStop" ) ]] || exit 0
fi
enabled="$(python3 "$lib/config.py" "$cfg_path" hooks.workloop_inbox.enabled=true 2>/dev/null || echo yes)"
[[ "$enabled" == "no" ]] && exit 0

# A subagent's tool batch stamps its lane or cell with the time and its last
# tool call, which is how a silent agent shows an age (agent_activity.py).
if [[ -n "$agent_id" && -f "$state" ]]; then
  python3 "$lib/agent_activity.py" "$state" "$proj/.agents" "$session" "$event" "$agent_id" "$transcript" \
    || echo "workloop-inbox: stamping $agent_id's activity failed" >&2
fi

block="$(python3 "$lib/workloop-inbox.py" "$state" "$proj/.agents" "$session" "$event" "$agent_id")"
[[ -n "$block" ]] || exit 0
printf '%s' "$block" | python3 "$lib/emit-context.py" "$event"
exit 0
