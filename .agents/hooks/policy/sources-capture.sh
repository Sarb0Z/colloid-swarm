#!/usr/bin/env bash
# Engine-agnostic policy: log every web lookup to the sources evidence trail.
#
# A PostToolUse capture hook — it observes search/fetch/browse calls (the main
# agent's and any researcher cell's, since subagents inherit hooks) and appends
# one row to .agents/.sources-ledger. It is a *trail*, never a gate: it always
# exits 0 and never blocks a tool.
#
# Input  (stdin JSON): {"project_dir": "...", "agent": "...", "kind": "search|fetch|browse", "value": "<query-or-url>"}
# Output: none; side effect is the appended ledger row `ts \t agent \t kind \t value`.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="$repo/.agents/hooks/lib"
enabled="$(python3 "$lib/config.py" "$repo/.agents/config.json" hooks.sources_capture.enabled=true)"
[[ "$enabled" == "no" ]] && exit 0

python3 "$lib/sources-ledger.py"
exit 0
