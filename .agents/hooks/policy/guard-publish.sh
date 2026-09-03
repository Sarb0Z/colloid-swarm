#!/usr/bin/env bash
# Claude-scoped policy: force the permission prompt on outward mutations.
#
# Input  (stdin JSON): {"tool_name": "...", "tool_input": {...}}
# Output: exit 0 always. Stdout carries Claude's PreToolUse envelope with
# permissionDecision "ask" on a publish-shaped call, and also whenever the
# evaluator cannot run or decide (fail closed); silence otherwise.
#
# This enforces `AGENTS.md` §External actions. It asks rather than denies:
# a publish is legitimate exactly when the user approves it in this session,
# so the correct enforcement is the dialog, not exit 2. guard-destructive
# stays the deny path for irreversible commands.
#
# Scope: wired for Claude Code only. Kimi and Codex do not register this
# policy; their sessions rely on the instruction until either host exposes an
# ask-equivalent decision.
#
# The decision lives in ../lib/guard-publish.py. This half owns the engine
# contract: locate the repository, hand the payload over on stdin, and emit a
# static ask decision if the evaluator cannot complete.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
decide="$repo/.agents/hooks/lib/guard-publish.py"
payload=""

# An "ask" only fails closed where a human answers it. Only the modes the
# evaluator lists as prompting get one (its docstring records the evidence);
# a guard that cannot run denies everywhere else instead of letting the call
# through.
ask_failure() {
  local diagnostic="$1"
  local reason="$2"
  local decision="ask"
  if ! grep -Eq '"permission_mode": *"(default|acceptEdits|plan)"' <<<"$payload"; then
    decision="deny"
    reason="$reason This session's permission mode does not show approval prompts, so the call is denied; the user runs it themselves or switches the mode to default and answers the prompt."
  fi
  echo "guard-publish: $diagnostic" >&2
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s AGENTS.md §External actions: outward mutations need in-session user approval."}}\n' "$decision" "$reason"
  exit 0
}

if ! payload="$(cat)"; then
  ask_failure "input read failed; the guard cannot decide safely." \
    "The publish guard could not read the hook payload."
fi

if [[ ! -f "$decide" ]]; then
  ask_failure "$decide is missing; the guard cannot run." \
    "The publish guard decision library is missing."
fi

if output="$(python3 "$decide" "$repo" <<<"$payload")"; then
  if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
  fi
  exit 0
else
  status=$?
  ask_failure "evaluator exited $status; the guard cannot decide safely." \
    "The publish guard evaluator failed."
fi
