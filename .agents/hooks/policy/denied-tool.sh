#!/usr/bin/env bash
# Claude policy: refuse a tool that `permissions.deny` names, with the reason and
# what to use instead, read from ../lib/denied-tools.json.
#
# Input  (stdin JSON): {"tool_name": "<tool>", "project_dir": "<repo>"}
# Output: exit 2 + stderr remedy on a listed tool; exit 0 otherwise.
#
# The deny rule enforces the refusal and removes the tool from the main thread's
# list. A subagent whose `tools` names the server still sees the tool, and the
# host's bare denial gives it nothing to do next. This hook guards against that
# dead end with a remedy; the deny rule stays the floor.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
table="$repo/.agents/hooks/lib/denied-tools.json"

[[ "$(python3 "$repo/.agents/hooks/lib/config.py" "$repo/.agents/config.json" hooks.denied_tool.enabled=true)" == yes ]] || exit 0

if [[ ! -f "$table" ]]; then
  echo "denied-tool: $table is missing; the remedy cannot be read." >&2
  exit 0
fi

# The heredoc below is python's stdin, so the payload travels as an argument.
payload="$(cat)"

exec python3 - "$table" "$payload" <<'PY'
import json
import sys

tool = json.loads(sys.argv[2] or "{}").get("tool_name") or ""
entry = json.load(open(sys.argv[1])).get(tool)
if entry is None:
    sys.exit(0)
print(f"{tool} is denied in this repository: {entry['why']}. Instead, {entry['instead']}.", file=sys.stderr)
sys.exit(2)
PY
