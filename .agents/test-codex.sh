#!/usr/bin/env bash
# Verify Codex integration generation and normalized hook contracts.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$repo/.agents/sync-codex.sh"
"$repo/.agents/sync-codex.sh" --check

normalizer="$repo/.agents/codex/normalize-hook.py"
assert_json() {
  local payload="$1" policy="$2" expected="$3"
  actual="$(printf '%s' "$payload" | python3 "$normalizer" "$policy" "$repo")"
  ACTUAL="$actual" EXPECTED="$expected" python3 - <<'PY'
import json, os
if json.loads(os.environ["ACTUAL"]) != json.loads(os.environ["EXPECTED"]):
    raise SystemExit(f"expected {os.environ['EXPECTED']}, got {os.environ['ACTUAL']}")
PY
}

stamp="⊰ COLLOID GENOME · THE test"
missing='{"cwd":"'"$repo"'","tool_input":{"message":"review this","agent_type":"worker"}}'
stamped='{"cwd":"'"$repo"'","tool_input":{"message":"'"$stamp"'\nreview this","agent_type":"worker"}}'
duplicate='{"cwd":"'"$repo"'","tool_input":{"message":"'"$stamp"'\n'"$stamp"'\nreview this","agent_type":"worker"}}'
exempt='{"cwd":"'"$repo"'","tool_input":{"message":"review this","agent_type":"learning-reporter"}}'

for payload in "$missing" "$stamped" "$duplicate" "$exempt"; do
  set +e
  printf '%s' "$payload" | "$repo/.codex/hooks/adapter.sh" genome-guard.sh >/dev/null 2>&1
  rc=$?
  set -e
  case "$payload" in
    "$missing"|"$duplicate") [[ $rc -eq 2 ]] ;;
    *) [[ $rc -eq 0 ]] ;;
  esac
done

assert_json \
  '{"cwd":"/repo","tool_input":{"command":"*** Add File: plain.py\n*** Update File: \"dir/file name.ts\"\n*** Delete File: old.py\n*** Move to: moved.py"}}' \
  post-edit-check.sh \
  '{"project_dir":"/repo","files":["plain.py","dir/file name.ts","old.py","moved.py"],"warnings":[]}'
assert_json \
  '{"last_assistant_message":"I am unable to complete this.","stop_hook_active":false}' \
  stop-investigate.sh \
  '{"project_dir":"'"$repo"'","stop_hook_active":false,"transcript_path":"","last_assistant_message":"I am unable to complete this."}'

if printf '%s' '{"last_assistant_message":"Implemented work.\nI am unable to complete this.","stop_hook_active":false}' | "$repo/.codex/hooks/adapter.sh" stop-investigate.sh >/dev/null 2>&1; then
  echo "test-codex: stop-investigate must block a hedge" >&2
  exit 1
fi
printf '%s' '{"last_assistant_message":"Implemented and verified the change.","stop_hook_active":false}' | "$repo/.codex/hooks/adapter.sh" stop-investigate.sh >/dev/null
transcript="$(mktemp)"
printf '%s\n' '{"message":{"role":"assistant","content":"I am unable to complete this."}}' > "$transcript"
if printf '%s' '{"transcript_path":"'"$transcript"'","stop_hook_active":false}' | "$repo/.codex/hooks/adapter.sh" stop-investigate.sh >/dev/null 2>&1; then
  rm -f "$transcript"
  echo "test-codex: stop-investigate must fall back to transcript" >&2
  exit 1
fi
rm -f "$transcript"
if printf '%s' '{"last_assistant_message":"The lint errors are pre-existing.","stop_hook_active":false}' | "$repo/.codex/hooks/adapter.sh" stop-investigate.sh >/dev/null 2>&1; then
  echo "test-codex: stop-investigate must ratchet an unfiled defect" >&2
  exit 1
fi
(
  cd "$repo/.agents"
  printf '%s' "$stamped" | ../.codex/hooks/adapter.sh genome-guard.sh >/dev/null
)

echo "Codex integration checks passed."
