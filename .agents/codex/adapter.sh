#!/usr/bin/env bash
# Codex hook adapter for the engine-neutral policy scripts.
set -euo pipefail

policy="$(basename "${1:?usage: adapter.sh <policy.sh>}")"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
policy_path="$repo/.agents/hooks/policy/$policy"
normalizer="$repo/.agents/codex/normalize-hook.py"

if [[ ! -x "$policy_path" || ! -x "$normalizer" ]]; then
  echo "adapter: missing executable policy or normalizer for $policy" >&2
  exit 1
fi

normalized="$(python3 "$normalizer" "$policy" "$repo")"
if [[ "$policy" == "post-edit-check.sh" ]]; then
  warning="$(printf '%s' "$normalized" | python3 -c 'import json, sys
for item in json.load(sys.stdin).get("warnings", []):
    print(item)')"
  [[ -z "$warning" ]] || echo "adapter: $warning" >&2
fi
printf '%s' "$normalized" | exec "$policy_path"
