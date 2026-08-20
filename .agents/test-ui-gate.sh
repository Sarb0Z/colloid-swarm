#!/usr/bin/env bash
# Firing tests for the ui-gate policy: record, remind, clear, block once.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

dir="$scratch/fixture"
mkdir -p "$dir/.agents/hooks/policy" "$dir/.agents/hooks/lib" "$dir/.agents/claude" "$dir/.agents/codex" "$dir/.codex/hooks"
cp "$repo/.agents/hooks/policy/ui-gate.sh" "$dir/.agents/hooks/policy/"
cp "$repo/.agents/hooks/lib/config.py" "$repo/.agents/hooks/lib/payload.py" "$repo/.agents/hooks/lib/emit-context.py" "$dir/.agents/hooks/lib/"
cp "$repo/.agents/claude/adapter.sh" "$repo/.agents/claude/normalize-hook.py" "$dir/.agents/claude/"
cp "$repo/.agents/codex/normalize-hook.py" "$dir/.agents/codex/"
cp "$repo/.codex/hooks/adapter.sh" "$dir/.codex/hooks/"
pending="$dir/.agents/.ui-pending-s1"

edit() {  # <path> -> stdout
  printf '{"project_dir":"%s","event":"PostToolUse","session_id":"s1","tool_name":"Edit","files":["%s"]}' "$dir" "$1" | bash "$dir/.agents/hooks/policy/ui-gate.sh"
}
tool() {  # <tool_name>
  printf '{"project_dir":"%s","event":"PostToolUse","session_id":"s1","tool_name":"%s","files":[]}' "$dir" "$1" | bash "$dir/.agents/hooks/policy/ui-gate.sh"
}
stop() {  # [stop_hook_active] -> sets rc, err
  set +e
  err="$(printf '{"project_dir":"%s","event":"Stop","session_id":"s1","stop_hook_active":%s}' "$dir" "${1:-false}" | bash "$dir/.agents/hooks/policy/ui-gate.sh" 2>&1 >/dev/null)"
  rc=$?
  set -e
}

[[ -z "$(edit "$dir/src/lib/math.py")" && ! -e "$pending" ]] || fail "a .py edit must not record"
[[ -z "$(edit "$dir/src/__tests__/Button.tsx")" && ! -e "$pending" ]] || fail "a test file must not record"
[[ -z "$(edit "$dir/src/Button.stories.tsx")" && ! -e "$pending" ]] || fail "a story must not record"
ok "non-UI and test files are ignored"

stop; [[ $rc -eq 0 ]] || fail "stop with nothing pending must pass"
ok "a clean session stops freely"

out="$(edit "$dir/src/app/page.tsx")"
[[ "$out" == *"UI changed"* ]] || fail "first UI edit must inject a reminder"
grep -q 'src/app/page.tsx' "$pending" || fail "first UI edit must record"
[[ -z "$(edit "$dir/src/app/layout.css")" ]] || fail "a second UI edit must stay quiet"
grep -q 'layout.css' "$pending" || fail "second UI edit must record"
ok "UI edits record; only the first reminds"

stop; [[ $rc -eq 2 && "$err" == *"2 UI file(s)"* && "$err" == *"page.tsx"* && "$err" == *"layout.css"* ]] || fail "stop must block with both files (rc=$rc): $err"
ok "the first stop blocks with the file list"
stop true; [[ $rc -eq 0 ]] || fail "stop_hook_active must pass"
grep -q 'page.tsx' "$pending" || fail "a pass on the host flag must not clear the pending set"
ok "a sibling block passes without clearing"
stop; [[ $rc -eq 0 ]] || fail "a second judged stop must pass (one-shot)"
ok "the gate blocks once per batch"

tool "mcp__playwright__browser_snapshot"
[[ -e "$pending" ]] || fail "a snapshot must not clear the gate"
tool "mcp__playwright__browser_take_screenshot"
[[ ! -e "$pending" ]] || fail "a screenshot must clear the gate"
ok "only a screenshot clears"

edit "$dir/src/Card.vue" >/dev/null
stop; [[ $rc -eq 2 && "$err" == *"1 UI file(s)"* ]] || fail "a new batch must block again"
tool "mcp__claude-in-chrome__take_screenshot"
[[ ! -e "$pending" ]] || fail "chrome screenshot must clear"
ok "a new batch after a look is judged afresh"

[[ -z "$(printf '{"project_dir":"%s","event":"PostToolUse","session_id":"","tool_name":"Edit","files":["%s/a.tsx"]}' "$dir" "$dir" | bash "$dir/.agents/hooks/policy/ui-gate.sh")" ]] || fail "no session id must do nothing"
[[ -z "$(find "$dir/.agents" -maxdepth 1 -name '.ui-pending-*')" ]] || fail "no session id must write no state"
ok "no session identity means no state"

printf '{"hooks":{"ui_gate":{"enabled":false}}}\n' > "$dir/.agents/config.json"
[[ -z "$(edit "$dir/src/X.tsx")" && ! -e "$pending" ]] || fail "disabled policy recorded"
rm "$dir/.agents/config.json"
ok "the config toggle turns the gate off"

# Claude adapter end to end: Edit payload, screenshot payload, Stop payload.
c_edit() { printf '{"hook_event_name":"PostToolUse","cwd":"%s","session_id":"c9","tool_name":"Edit","tool_input":{"file_path":"%s/src/Home.tsx","old_string":"a","new_string":"b"}}' "$dir" "$dir" | CLAUDE_PROJECT_DIR="$dir" bash "$dir/.agents/claude/adapter.sh" ui-gate.sh; }
[[ "$(c_edit)" == *"UI changed"* ]] || fail "claude adapter edit path"
set +e
err="$(printf '{"hook_event_name":"Stop","cwd":"%s","session_id":"c9","stop_hook_active":false}' "$dir" | CLAUDE_PROJECT_DIR="$dir" bash "$dir/.agents/claude/adapter.sh" --agent main ui-gate.sh 2>&1 >/dev/null)"; rc=$?
set -e
[[ $rc -eq 2 && "$err" == *"Home.tsx"* ]] || fail "claude adapter stop path (rc=$rc)"
printf '{"hook_event_name":"PostToolUse","cwd":"%s","session_id":"c9","tool_name":"mcp__playwright__browser_take_screenshot","tool_input":{"type":"png"}}' "$dir" | CLAUDE_PROJECT_DIR="$dir" bash "$dir/.agents/claude/adapter.sh" ui-gate.sh
[[ ! -e "$dir/.agents/.ui-pending-c9" ]] || fail "claude adapter screenshot path"
ok "records, blocks and clears through the Claude adapter"

# Codex adapter: apply_patch carries the paths inside the patch text.
patch='*** Begin Patch\n*** Update File: src/Nav.tsx\n@@\n-a\n+b\n*** End Patch'
printf '{"cwd":"%s","session_id":"x7","hook_event_name":"PostToolUse","tool_name":"apply_patch","tool_input":{"command":"%s"}}' "$dir" "$patch" | bash "$dir/.codex/hooks/adapter.sh" ui-gate.sh >/dev/null
grep -q 'src/Nav.tsx' "$dir/.agents/.ui-pending-x7" || fail "codex apply_patch path must record"
set +e
err="$(printf '{"cwd":"%s","session_id":"x7","hook_event_name":"Stop","stop_hook_active":false}' "$dir" | bash "$dir/.codex/hooks/adapter.sh" ui-gate.sh 2>&1 >/dev/null)"; rc=$?
set -e
[[ $rc -eq 2 && "$err" == *"Nav.tsx"* ]] || fail "codex adapter stop path (rc=$rc)"
ok "records and blocks through the Codex adapter"
set +e
printf '{"cwd":"%s","session_id":"x7","tool_name":"apply_patch","tool_input":{"command":"%s"}}' "$dir" "$patch" | bash "$dir/.codex/hooks/adapter.sh" ui-gate.sh >/dev/null 2>&1; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "an unlabeled tool payload must not be judged a Stop (rc=$rc)"
ok "an unlabeled Codex tool payload never blocks"

printf 'PASS: ui-gate policy\n'
