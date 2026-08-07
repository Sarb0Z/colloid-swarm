#!/usr/bin/env bash
# Engine-agnostic policy: block destructive shell commands.
#
# Input  (stdin JSON): {"command": "<shell command>"}
# Output: exit 2 + stderr reason on block; exit 0 otherwise.
#
# Claude Code, Kimi CLI, and Codex all treat exit 2 + stderr as "block, feed
# reason to the model", so no per-engine output adapter is needed. Every other
# non-zero exit is a hook failure on all three, and the action proceeds — so a
# policy that cannot run must exit 0 deliberately rather than error.
#
# The decision itself needs a shell-aware parse, which lives in
# ../lib/guard-destructive.py. This half owns the engine contract: locate the
# repository, hand the payload over on stdin, and let the exit code through.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
decide="$repo/.agents/hooks/lib/guard-destructive.py"

if [[ ! -f "$decide" ]]; then
  echo "guard-destructive: $decide is missing; the guard cannot run." >&2
  exit 0
fi

exec python3 "$decide" "$repo"
