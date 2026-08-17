#!/usr/bin/env bash
# Claude-scoped policy: force the permission prompt on outward mutations.
#
# Input  (stdin JSON): {"tool_name": "...", "tool_input": {...}}
# Output: exit 0 always. On a publish-shaped call, stdout carries Claude's
# PreToolUse envelope with permissionDecision "ask", which shows the user the
# permission dialog even where the tool would otherwise run silently.
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
# contract: locate the repository, hand the payload over on stdin, and let
# stdout and the exit code through.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
decide="$repo/.agents/hooks/lib/guard-publish.py"

if [[ ! -f "$decide" ]]; then
  echo "guard-publish: $decide is missing; the guard cannot run." >&2
  exit 0
fi

exec python3 "$decide" "$repo"
