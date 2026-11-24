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
#
# Where the policy is:
#   - here and executable: it runs.
#   - here without its executable bit: it runs through bash, with a stderr
#     warning naming the chmod. A registration saved before `chmod +x` must
#     not lock every tool its matcher covers.
#   - absent here, present in COLLOID_HOOK_LAUNCH: the registered command maps
#     a session launched in a lane worktree to the main checkout and exports
#     the folder it was launched in; a policy only the lane has (the lane adds
#     it) runs from the lane's own adapter.
#   - absent everywhere: a PreToolUse Write or Edit whose target is that
#     policy's own path passes, so the session can write the missing script;
#     every other PreToolUse call is asked about or denied (below), and other
#     events exit 1.

set -euo pipefail

agent_sel=""
if [[ "${1:-}" == "--agent" ]]; then
  agent_sel="${2:?--agent needs a selector}"; shift 2
fi

policy="$1"; shift || true
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

name="$(basename "$policy")"
policy_path="$repo/.agents/hooks/policy/$name"
normalizer="$repo/.agents/claude/normalize-hook.py"

raw="$(cat)"

launch="${COLLOID_HOOK_LAUNCH:-}"
if [[ ! -e "$policy_path" && -n "$launch" && "$launch" != "$repo" && -e "$launch/.agents/hooks/policy/$name" && -f "$launch/.agents/claude/adapter.sh" ]]; then
  echo "adapter: $repo has no $name; running the copy in $launch" >&2
  CLAUDE_PROJECT_DIR="$launch" COLLOID_HOOK_LAUNCH="" \
    exec bash "$launch/.agents/claude/adapter.sh" ${agent_sel:+--agent "$agent_sel"} "$name" <<<"$raw"
fi

if [[ ! -e "$policy_path" ]]; then
  echo "adapter: no policy '$policy' in $repo" >&2
  # A missing PreToolUse policy is a missing gate. Exit 1 would let the tool
  # run; force the permission prompt instead so the loss is visible. Where the
  # mode is not one known to show a prompt, deny: an unseen prompt hides the
  # loss instead of showing it.
  if grep -Eq '"hook_event_name" *: *"PreToolUse"' <<<"$raw"; then
    # Writing the missing policy itself is how the loss is repaired.
    if printf '%s' "$raw" | python3 -c '
import json, os, sys
try:
    payload = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
tool_input = payload.get("tool_input") if isinstance(payload, dict) else None
target = tool_input.get("file_path") if isinstance(tool_input, dict) else None
own = os.path.join(".agents", "hooks", "policy", sys.argv[1])
ok = payload.get("tool_name") in ("Write", "Edit", "MultiEdit") and isinstance(target, str) and (os.sep + os.path.normpath(target)).endswith(os.sep + own)
sys.exit(0 if ok else 1)' "$name"; then
      exit 0
    fi
    decision="deny"
    grep -Eq '"permission_mode" *: *"(default|acceptEdits|plan)"' <<<"$raw" && decision="ask"
    reason="The $name policy is missing from this checkout, so its gate cannot run."
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$decision" "$reason"
    exit 0
  fi
  exit 1
fi

run=(exec "$policy_path")
if [[ ! -x "$policy_path" ]]; then
  echo "adapter: the $name policy is present but not executable; running it through bash. Run: chmod +x .agents/hooks/policy/$name" >&2
  run=(exec bash "$policy_path")
fi

# Exit 3 is the gate's deliberate "this policy does not run for this agent".
# Every other failure falls through to running the policy: a broken gate must
# never silently disable a safety policy.
gate=0
normalized="$(printf '%s' "$raw" |
  python3 "$normalizer" "$(basename "$policy")" "$repo" ${agent_sel:+--agent "$agent_sel"})" || gate=$?
[[ "$gate" -eq 3 ]] && exit 0

printf '%s' "$normalized" | "${run[@]}"
