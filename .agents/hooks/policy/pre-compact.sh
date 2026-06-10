#!/usr/bin/env bash
# Engine-agnostic policy: record that a compaction is imminent.
#
# Input  (stdin JSON): {"project_dir": "...", "trigger": "auto"|"manual"}
# Output: none on stdout. Writes the trigger word to
#   .agents/.compaction-pending and always exits 0.
#
# PreCompact is control-only: its stdout is discarded by the host and it
# cannot inject context (Claude Code docs; not in the stdout-as-context
# exception list, no additionalContext support). So this hook does the one
# useful pre-compaction thing — leave a marker the post-compaction context
# policy (session-start.sh, source=compact) consumes to re-state the
# Discovered Subprojects policy and tailor the nudge to the trigger.
#
# A checkpoint marker, never a gate — it does not block compaction.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cfg_path="$repo/.agents/config.json"
enabled="$(CFG_PATH="$cfg_path" python3 <<'PY'
import json, os
cfg = {}
try:
    with open(os.environ["CFG_PATH"], encoding="utf-8") as f: cfg = json.load(f)
except Exception: pass
print("yes" if cfg.get("hooks", {}).get("pre_compact", {}).get("enabled", True) else "no")
PY
)"
[[ "$enabled" == "no" ]] && exit 0

input="$(cat)"

parsed="$(HOOK_INPUT="$input" python3 <<'PY'
import json, os
d = json.loads(os.environ["HOOK_INPUT"] or "{}")
print(d.get("project_dir", ""))
print(d.get("trigger", ""))
PY
)"
proj="$(printf '%s\n' "$parsed" | sed -n '1p')"
trigger="$(printf '%s\n' "$parsed" | sed -n '2p')"
[[ -z "$proj" ]] && proj="$PWD"
[[ -z "$trigger" ]] && trigger="auto"

mkdir -p "$proj/.agents"
printf '%s\n' "$trigger" > "$proj/.agents/.compaction-pending"
exit 0
