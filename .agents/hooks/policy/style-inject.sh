#!/usr/bin/env bash
# Engine-agnostic policy: hand a spawned subagent the session's output style.
#
# Input  (stdin JSON): {"project_dir": "..."}
# Output (STDOUT): a JSON object carrying hookSpecificOutput.additionalContext,
#   or nothing. Always exit 0; never blocks.
#
# Claude Code sends the output style and an appended system prompt to the main
# session only. A cell dispatched with the Agent tool sees CLAUDE.md and the
# host's own defaults, among them "Commit or push only when the user asks. If
# on the default branch, branch first.", and none of the counter-pressure that
# answers them. SubagentStart context lands in the cell's transcript before its
# first prompt, so every cell carries the same rules as its lead.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="$repo/.agents/hooks/lib"
enabled="$(python3 "$lib/config.py" "$repo/.agents/config.json" hooks.style_inject.enabled=true)"
[[ "$enabled" == "no" ]] && exit 0

style="$repo/.agents/claude/output-style.md"
if [[ ! -f "$style" ]]; then
  echo "style-inject: $style is missing, so this subagent runs without the session's output style" >&2
  exit 0
fi
body="$(python3 "$lib/output_style.py" body "$style")" || { echo "style-inject: could not read $style; this subagent runs without it" >&2; exit 0; }
[[ -z "$body" ]] && exit 0

{
  echo "The session's output style, which Claude Code sends to the main session only; it binds this cell as it binds the lead. In a cell, \"the user\" is still the operator: approval comes only from their messages, and a question or a human gate returns to the lead in the final report. Commits in the lead's tree are the lead's; a cell commits only in its own workloop worktree."
  echo
  printf '%s\n' "$body"
} | python3 "$lib/emit-context.py" SubagentStart
exit 0
