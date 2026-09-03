#!/usr/bin/env bash
# Claude-scoped policy: deny the next tool call after a provenance punt.
#
# Input  (stdin JSON): {"project_dir": "...", "transcript_path": "...", "session_id": "..."}
# Output: exit 0 always. Stdout carries Claude's PreToolUse envelope with
# permissionDecision "deny" the first time a claim appears in the turn;
# silence otherwise.
#
# The Stop gate judges the turn when it ends. This one judges it before each
# tool call, because the punt and the shipping are seconds apart: "all six fail
# identically without my changes, so they are pre-existing" was followed by the
# commit and the push in the same breath. No host event fires on assistant
# text, but every tool call carries the transcript, and when the host has
# written the text that precedes the call, the call that gets denied is the
# one the punt was about to make. The host does not always write it in time
# (breadcrumbs.md records a session where it stopped), so the Stop gate stays
# the layer that always sees the text; this one shortens the distance.
#
# A claim is reported once per turn. The model answers it — fixes, files, or
# says the regex misread it — and its next call goes through; the Stop gate
# still holds the turn if it did none of those. The ledger is one line per claim under
# .agents/.provenance-<session hash>, ignored runtime state.
#
# Scope: wired for Claude Code only, main agent. Codex and Kimi do not carry a
# transcript path into their PreToolUse payloads.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="$repo/.agents/hooks/lib"
enabled="$(python3 "$lib/config.py" "$repo/.agents/config.json" hooks.provenance_gate.enabled=true)"
[[ "$enabled" == "no" ]] && exit 0

parsed="$(python3 "$lib/payload.py" transcript_path session_id)"
transcript="$(printf '%s\n' "$parsed" | sed -n '1p')"
session_id="$(printf '%s\n' "$parsed" | sed -n '2p')"
[[ -n "$transcript" && -f "$transcript" ]] || exit 0

turn="$(python3 "$lib/turn-text.py" --turn-id "$transcript")"
turn_id="${turn%%$'\n'*}"
turn="${turn#*$'\n'}"
[[ -n "$turn" ]] || exit 0
claims="$(printf '%s' "$turn" | bash "$lib/ratchet-claim.sh")"
[[ -n "$claims" ]] || exit 0

# The first claim of the turn not yet reported. A turn can punt twice, and the
# second must not hide behind the first. The key is the turn plus the head of
# the span: the window is greedy, so as the turn grows the same claim can
# match a longer span, and its start is what stays put; the same sentence in a
# later turn is a new punt.
identity="${session_id:-$transcript}"
ledger="$repo/.agents/.provenance-$(printf '%s' "$identity" | shasum | cut -c1-12)"
claim=""
key=""
while IFS= read -r span; do
  [[ -n "$span" ]] || continue
  key="$(printf '%s %s' "$turn_id" "${span:0:60}" | shasum | cut -c1-40)"
  grep -qsF "$key" "$ledger" && continue
  claim="$span"
  break
done <<<"$claims"
[[ -n "$claim" ]] || exit 0

lead="Before this tool call runs: this turn tied a provenance claim to a defect it is not fixing:"
reason="$(bash "$lib/ratchet-reason.sh" "$claim" "$lead")" || reason="$lead $claim"
printf '%s' "$reason" | python3 -c 'import json, sys
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": sys.stdin.read().strip()}}))'
# Ledgered only once the deny is on stdout: a claim the model never heard
# about must be reported next time, not marked as answered.
printf '%s\n' "$key" >> "$ledger"
exit 0
