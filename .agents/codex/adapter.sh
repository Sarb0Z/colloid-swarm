#!/usr/bin/env bash
# Codex hook adapter for the engine-neutral policy scripts.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  echo "hooks: bash $BASH_VERSION is too old (need >= 4); policies are disabled." >&2
  exit 0
fi

policy="${1:?usage: adapter.sh <policy.sh>}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
policy_path="$repo/.agents/hooks/policy/$(basename "$policy")"
normalizer="$repo/.agents/codex/normalize-hook.py"

if [[ ! -x "$policy_path" || ! -x "$normalizer" ]]; then
  echo "adapter: missing executable policy or normalizer for $policy" >&2
  exit 1
fi

normalized="$(python3 "$normalizer" "$policy" "$repo")"
if [[ "$policy" == "post-edit-check.sh" ]]; then
  warning="$(HOOK_INPUT="$normalized" python3 - <<'PY'
import json, os
for item in json.loads(os.environ["HOOK_INPUT"]).get("warnings", []):
    print(item)
PY
)"
  [[ -z "$warning" ]] || echo "adapter: $warning" >&2
fi
printf '%s' "$normalized" | exec "$policy_path"
