#!/usr/bin/env bash
# Claude Code → shared policy adapter.
#
# Normalizes Claude hook stdin into the shape the policy scripts expect,
# then runs the named policy. Exit code / stderr bubble up unchanged —
# Claude treats exit 2 + stderr as "block, feed reason to the model".
#
# Optional agent scoping:
#   adapter.sh [--agent <selector>] <policy.sh>
# Claude tags a spawned subagent's payload with agent_id and agent_type, a
# `claude --agent <name>` main session with agent_type alone, and a plain main
# session with neither. agent_id is therefore the only field that separates a
# subagent from the main agent. The selector gates whether the policy runs:
#   main      → only the main agent, `--agent` launch included (no agent_id)
#   subagent  → only spawned subagents (agent_id present)
#   <Type>    → only spawned subagents of the named type(s); '|'-separated,
#               e.g. Explore|Plan or a custom subagent name
# Flag absent → runs for every agent, main and subagents alike.
#
# normalize-hook.py owns both the gate and the payload mapping. The payload
# reaches it on stdin rather than in the environment, so a large edit cannot
# push the hook past ARG_MAX.

set -euo pipefail

agent_sel=""
if [[ "${1:-}" == "--agent" ]]; then
  agent_sel="${2:?--agent needs a selector}"; shift 2
fi

policy="$1"; shift || true
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

policy_path="$repo/.agents/hooks/policy/$(basename "$policy")"
normalizer="$repo/.agents/claude/normalize-hook.py"

raw="$(cat)"

if [[ ! -x "$policy_path" ]]; then
  echo "adapter: unknown or non-executable policy '$policy'" >&2
  # A missing PreToolUse policy is a missing gate. Exit 1 would let the tool
  # run; force the permission prompt instead so the loss is visible.
  if grep -Eq '"hook_event_name" *: *"PreToolUse"' <<<"$raw"; then
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"The %s policy is missing from this checkout, so its gate cannot run."}}\n' "$(basename "$policy")"
    exit 0
  fi
  exit 1
fi

# Exit 3 is the gate's deliberate "this policy does not run for this agent".
# Every other failure falls through to running the policy: a broken gate must
# never silently disable a safety policy.
gate=0
normalized="$(printf '%s' "$raw" |
  python3 "$normalizer" "$(basename "$policy")" "$repo" ${agent_sel:+--agent "$agent_sel"})" || gate=$?
[[ "$gate" -eq 3 ]] && exit 0

printf '%s' "$normalized" | exec "$policy_path"
