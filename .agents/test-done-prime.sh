#!/usr/bin/env bash
# Firing tests for the done-prime UserPromptSubmit policy, direct and through
# each host adapter.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

dir="$scratch/fixture"
mkdir -p "$dir/.agents/hooks/policy" "$dir/.agents/hooks/lib" "$dir/.agents/claude" "$dir/.agents/codex" "$dir/.codex/hooks"
cp "$repo/.agents/hooks/policy/done-prime.sh" "$dir/.agents/hooks/policy/"
cp "$repo/.agents/hooks/lib/config.py" "$repo/.agents/hooks/lib/payload.py" "$repo/.agents/hooks/lib/emit-context.py" "$dir/.agents/hooks/lib/"
cp "$repo/.agents/claude/adapter.sh" "$repo/.agents/claude/normalize-hook.py" "$dir/.agents/claude/"
cp "$repo/.agents/codex/normalize-hook.py" "$dir/.agents/codex/"
cp "$repo/.codex/hooks/adapter.sh" "$dir/.codex/hooks/"
if [[ -f "$repo/.kimi/hooks/adapter.sh" ]]; then
  mkdir -p "$dir/.kimi/hooks"
  cp "$repo/.kimi/hooks/adapter.sh" "$repo/.kimi/hooks/normalize-hook.py" "$dir/.kimi/hooks/"
fi

policy() {  # <prompt>
  printf '{"project_dir":"%s","prompt":%s}' "$dir" "$(printf '%s' "$1" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')" \
    | bash "$dir/.agents/hooks/policy/done-prime.sh"
}
context_of() {
  OUTPUT="$1" python3 -c 'import json,os
p=json.loads(os.environ["OUTPUT"])["hookSpecificOutput"]
assert p["hookEventName"]=="UserPromptSubmit"; print(p["additionalContext"])'
}

for prompt in "let's implement xp feature" "add a settings page for admins" "can you wire up the payments endpoint" "Fix the login form validation" "revamp the dashboard"; do
  out="$(policy "$prompt")"
  [[ -n "$out" ]] || fail "silent on: $prompt"
  [[ "$(context_of "$out")" == *"user-facing surface"* ]] || fail "wrong body on: $prompt"
done
ok "fires on implementation-shaped prompts"

for prompt in "what does this function do?" "continue please" "why did the build fail" "summarize the session" "is the fix correct?"; do
  [[ -z "$(policy "$prompt")" ]] || fail "fired on: $prompt"
done
ok "silent on questions and continuations"

[[ -z "$(printf '{"project_dir":"%s"}' "$dir" | bash "$dir/.agents/hooks/policy/done-prime.sh")" ]] || fail "fired with no prompt"
ok "silent with no prompt"

printf '{"hooks":{"done_prime":{"enabled":false}}}\n' > "$dir/.agents/config.json"
[[ -z "$(policy "implement the thing")" ]] || fail "fired while disabled"
rm "$dir/.agents/config.json"
ok "the config toggle turns the policy off"

claude="$(printf '{"hook_event_name":"UserPromptSubmit","cwd":"%s","session_id":"c","prompt":"add a checkout flow"}' "$dir" \
  | CLAUDE_PROJECT_DIR="$dir" bash "$dir/.agents/claude/adapter.sh" --agent main done-prime.sh)"
[[ "$(context_of "$claude")" == *"user-facing surface"* ]] || fail "claude adapter path"
ok "fires through the Claude adapter"
[[ -z "$(printf '{"hook_event_name":"UserPromptSubmit","cwd":"%s","agent_id":"a1","agent_type":"Explore","prompt":"add a checkout flow"}' "$dir" \
  | CLAUDE_PROJECT_DIR="$dir" bash "$dir/.agents/claude/adapter.sh" --agent main done-prime.sh)" ]] || fail "ran inside a subagent"
ok "the main-agent gate skips subagents"

codex="$(printf '{"cwd":"%s","session_id":"x","prompt":"refactor the billing module"}' "$dir" | bash "$dir/.codex/hooks/adapter.sh" done-prime.sh)"
[[ "$(context_of "$codex")" == *"user-facing surface"* ]] || fail "codex adapter path"
ok "fires through the Codex adapter"

if [[ -f "$dir/.kimi/hooks/adapter.sh" ]]; then
  kimi="$(printf '{"hook_event_name":"UserPromptSubmit","cwd":"%s","session_id":"k","prompt":[{"type":"text","text":"build out the reports screen"}]}' "$dir" \
    | bash "$dir/.kimi/hooks/adapter.sh" done-prime.sh)"
  [[ "$kimi" == *"user-facing surface"* && "$kimi" != *"hookSpecificOutput"* ]] || fail "kimi adapter should unwrap to plain text"
  ok "fires through the Kimi adapter as plain text"
fi

printf 'PASS: done-prime policy\n'
