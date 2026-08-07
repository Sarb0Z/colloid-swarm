#!/usr/bin/env bash
# Engine-agnostic policy: refuse a subagent write to the standard that grades it.
#
# Input  (stdin JSON): {"files": ["<path>", ...]}
# Output: exit 2 + stderr reason on a governed path; exit 0 otherwise.
#
# Wired with the adapter's `--agent subagent` selector, so the main session —
# the operator's hands — never reaches this policy. Claude is the only engine
# wired: the Codex and Kimi adapters take no selector, and wiring them without
# one would lock the operator out of every gate instead of the subagents.
#
# The toggle is read here rather than in the decision module, so the scaffold
# keeps one config parser (../lib/config.py) instead of a second copy of it.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="$repo/.agents/hooks/lib"
decide="$lib/grader-lock.py"

if [[ ! -f "$decide" ]]; then
  echo "grader-lock: $decide is missing; the lock cannot run." >&2
  exit 0
fi

enabled="$(python3 "$lib/config.py" "$repo/.agents/config.json" \
  hooks.grader_lock.enabled=true 2>/dev/null || echo yes)"
[[ "$enabled" == "no" ]] && exit 0

exec python3 "$decide" "$repo"
