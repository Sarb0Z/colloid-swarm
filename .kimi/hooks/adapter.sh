#!/usr/bin/env bash
# Kimi CLI → shared policy adapter.
#
# Normalizes Kimi hook stdin into the shape the policy scripts expect,
# then runs the named policy. For blockable events (PreToolUse,
# UserPromptSubmit, Stop) the exit code / stderr bubble up unchanged —
# Kimi treats exit 2 + stderr as "block, feed reason to the model".
#
# Per-engine seams this adapter owns (verified against Kimi 0.29):
# - PostToolUse is pure observation: exit 2 AND stdout are both discarded,
#   so post-edit-check findings buffer in a per-session state file and
#   relay through the next Stop — which IS blockable — so the model sees
#   them at end of turn. sources-capture is unaffected (it only logs).
# - Context-injecting policies (session-start, research-prime) emit
#   Claude's {"hookSpecificOutput":{"additionalContext":...}} envelope;
#   Kimi appends raw stdout to context instead, so the adapter unwraps
#   the envelope and prints the plain text.
# - Kimi has no transcript_path; session_id (present on every payload)
#   is the session identity session-wrap keys its throttle state on.
# - UserPromptSubmit's prompt is an array of content parts, not a string.
# - PostCompact maps to session-start.sh with source=compact: Kimi
#   compacts in-session, so the post-compaction re-prime rides the
#   PostCompact event rather than a SessionStart(source=compact).
# colloid-only
# - SubagentStart is observation-only and discards output, so genome context
#   must stay in the Agent/AgentSwarm dispatch prompt.
# /colloid-only
# - A policy absent from this repo's .agents/hooks/policy/ exits 0
#   silently — the global ~/.kimi-code/config.toml registers the full
#   fleet of hooks, and repos vendor only the policies they carry.

set -euo pipefail

policy="$1"; shift || true
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
policy_path="$repo/.agents/hooks/policy/$(basename "$policy")"
[[ -x "$policy_path" ]] || exit 0

normalizer="$repo/.kimi/hooks/normalize-hook.py"
parsed="$(python3 "$normalizer" "$policy" "$repo")"
sid="$(printf '%s\n' "$parsed" | sed -n '1p')"
normalized="$(printf '%s\n' "$parsed" | tail -n +2)"
pending="$repo/.agents/.kimi-pending-findings-$sid"

run() { printf '%s' "$normalized" | "$policy_path"; }

# Unwrap Claude's additionalContext envelope into plain stdout for Kimi.
unwrap() {
  OUT="$1" python3 -c '
import json, os
raw = os.environ["OUT"]
try:
    ctx = json.loads(raw)["hookSpecificOutput"]["additionalContext"]
    print(ctx)
except Exception:
    if raw.strip():
        print(raw)
'
}

case "$(basename "$policy")" in
post-edit-check.sh)
  set +e
  findings="$(run 2>&1)"
  rc=$?
  set -e
  # Both channels are buffered. The gate exits 2 with plain stderr; the fixer
  # exits 0 and emits an additionalContext envelope, and dropping that would
  # lose every tombstone, null-safety and reformatted notice on this engine.
  if [[ -n "$findings" ]]; then
    if [[ $rc -eq 2 ]]; then
      printf '%s\n' "$findings" >> "$pending"
    else
      unwrap "$findings" >> "$pending"
    fi
  fi
  exit 0
  ;;
session-wrap.sh)
  # Orphans from sessions that died between edit and stop; reap quietly.
  find "$repo/.agents" -maxdepth 1 -name '.kimi-pending-findings-*' -mtime +1 -delete 2>/dev/null || true
  if [[ -s "$pending" ]]; then
    findings="$(cat "$pending")"
    rm -f "$pending"
    printf '%s\n' "$findings" >&2
    exit 2
  fi
  run
  ;;
session-start.sh|research-prime.sh)
  set +e
  out="$(run)"
  rc=$?
  set -e
  [[ -n "$out" ]] && unwrap "$out"
  exit $rc
  ;;
*)
  run
  ;;
esac
