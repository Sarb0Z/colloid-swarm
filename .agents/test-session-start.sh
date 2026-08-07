#!/usr/bin/env bash
# Focused contract tests for the engine-neutral SessionStart policy.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

make_fixture() {
  local name="$1"
  local dir="$scratch/$name"
  mkdir -p \
    "$dir/.agents/hooks/policy" \
    "$dir/.agents/hooks/lib" \
    "$dir/.agents/playbooks" \
    "$dir/.agents/claude" \
    "$dir/.agents/codex" \
    "$dir/.codex/hooks"
  cp "$repo/.agents/hooks/policy/session-start.sh" "$dir/.agents/hooks/policy/"
  # The policy shells out to these, so the fixture is not a fixture without them.
  cp "$repo/.agents/hooks/lib/config.py" \
     "$repo/.agents/hooks/lib/payload.py" \
     "$repo/.agents/hooks/lib/emit-context.py" \
     "$repo/.agents/hooks/lib/mcp-off.py" "$dir/.agents/hooks/lib/"
  cp "$repo/.agents/toggles.py" "$dir/.agents/"
  cp "$repo/.agents/playbooks/learning-output-style.md" "$dir/.agents/playbooks/"
  cp "$repo/.agents/claude/adapter.sh" "$repo/.agents/claude/normalize-hook.py" "$dir/.agents/claude/"
  cp "$repo/.agents/codex/normalize-hook.py" "$dir/.agents/codex/"
  cp "$repo/.codex/hooks/adapter.sh" "$dir/.codex/hooks/"
  # Kimi is optional: only repositories that wire the engine carry .kimi/.
  if [[ -f "$repo/.kimi/hooks/adapter.sh" ]]; then
    mkdir -p "$dir/.kimi/hooks"
    cp "$repo/.kimi/hooks/adapter.sh" "$repo/.kimi/hooks/normalize-hook.py" "$dir/.kimi/hooks/"
  fi
  printf '%s\n' '- fixture breadcrumb' > "$dir/.agents/breadcrumbs.md"
  printf '%s\n' '{"mcpServers": {}}' > "$dir/.agents/mcp.json"
  printf '%s\n' '{"mcp": {"servers": {}}}' > "$dir/.agents/config.json.example"
  git -C "$dir" init -q
  printf '%s\n' "$dir"
}

write_config() {
  local dir="$1"
  local session_start="$2"
  local learning="$3"
  printf '{"hooks":{"session_start":{"enabled":%s},"learning_output_style":{"enabled":%s}}}\n' \
    "$session_start" "$learning" > "$dir/.agents/config.json"
}

run_policy() {
  local dir="$1"
  local source="${2:-startup}"
  printf '{"project_dir":"%s","source":"%s","session_id":"fixture-session","transcript_path":""}\n' \
    "$dir" "$source" | bash "$dir/.agents/hooks/policy/session-start.sh"
}

run_claude_adapter() {
  local dir="$1"
  local source="${2:-startup}"
  printf '{"hook_event_name":"SessionStart","cwd":"%s","source":"%s","session_id":"claude-fixture"}\n' \
    "$dir" "$source" |
    CLAUDE_PROJECT_DIR="$dir" bash "$dir/.agents/claude/adapter.sh" --agent main session-start.sh
}

run_codex_adapter() {
  local dir="$1"
  local source="${2:-startup}"
  printf '{"cwd":"%s","source":"%s","session_id":"codex-fixture"}\n' \
    "$dir" "$source" |
    bash "$dir/.codex/hooks/adapter.sh" session-start.sh
}

run_kimi_adapter() {
  local dir="$1"
  local source="${2:-startup}"
  local event="SessionStart"
  [[ "$source" == "compact" ]] && event="PostCompact"
  printf '{"hook_event_name":"%s","cwd":"%s","source":"%s","session_id":"kimi-fixture"}\n' \
    "$event" "$dir" "$source" |
    bash "$dir/.kimi/hooks/adapter.sh" session-start.sh
}

context_of() {
  local output="$1"
  OUTPUT="$output" python3 <<'PY'
import json
import os

payload = json.loads(os.environ["OUTPUT"])
assert payload["hookSpecificOutput"]["hookEventName"] == "SessionStart"
print(payload["hookSpecificOutput"]["additionalContext"])
PY
}

assert_contains() {
  local value="$1"
  local expected="$2"
  [[ "$value" == *"$expected"* ]] || fail "missing text: $expected"
}

assert_not_contains() {
  local value="$1"
  local rejected="$2"
  [[ "$value" != *"$rejected"* ]] || fail "unexpected text: $rejected"
}

assert_marker_once() {
  local value="$1"
  local count
  count="$(VALUE="$value" python3 <<'PY'
import os
print(os.environ["VALUE"].count("[learning-output-style:v1]"))
PY
)"
  [[ "$count" == "1" ]] || fail "learning marker count is $count, expected 1"
}

assert_no_wrap_state() {
  local dir="$1"
  local state
  state="$(find "$dir/.agents" -maxdepth 1 -name '.wrap-state-*' -print -quit)"
  [[ -z "$state" ]] || fail "session_start=false seeded wrap state"
}

assert_wrap_state() {
  local dir="$1"
  local state
  state="$(find "$dir/.agents" -maxdepth 1 -name '.wrap-state-*' -print -quit)"
  [[ -n "$state" ]] || fail "session_start=true did not seed wrap state"
}

# Both behaviors on: inject teaching and operational context.
tt="$(make_fixture both-on)"
write_config "$tt" true true
tt_output="$(run_policy "$tt")"
tt_context="$(context_of "$tt_output")"
assert_marker_once "$tt_context"
assert_contains "$tt_context" 'fixture breadcrumb'
assert_not_contains "$tt_context" 'TODO'
assert_wrap_state "$tt"

write_crumbs() {
  local dir="$1"
  local last="$2"
  local i
  : > "$dir/.agents/breadcrumbs.md"
  for i in $(seq -w 1 "$last"); do
    printf -- '- crumb-%s\n' "$i" >> "$dir/.agents/breadcrumbs.md"
  done
}

# Past the cap the hook shows the newest items. They are appended, so the tail
# is what recent sessions found and deferred; older items wait for a maintenance
# pass that reads the file directly.
cap="$(make_fixture breadcrumb-cap)"
write_config "$cap" true true
write_crumbs "$cap" 12
cap_context="$(context_of "$(run_policy "$cap")")"
assert_contains "$cap_context" '(10 most recent of 12 — prune the file)'
assert_contains "$cap_context" '- crumb-12'
assert_contains "$cap_context" '- crumb-03'
assert_not_contains "$cap_context" '- crumb-01'
assert_not_contains "$cap_context" '- crumb-02'

# At the cap exactly, every item shows and no truncation notice appears.
exact="$(make_fixture breadcrumb-exact)"
write_config "$exact" true true
write_crumbs "$exact" 10
exact_context="$(context_of "$(run_policy "$exact")")"
assert_contains "$exact_context" '- crumb-01'
assert_contains "$exact_context" '- crumb-10'
assert_not_contains "$exact_context" 'prune the file'

# Learning off: preserve operational context and side effects.
tf="$(make_fixture learning-off)"
write_config "$tf" true false
tf_output="$(run_policy "$tf")"
tf_context="$(context_of "$tf_output")"
assert_not_contains "$tf_context" '[learning-output-style:v1]'
assert_contains "$tf_context" 'fixture breadcrumb'
assert_wrap_state "$tf"

# Operational context off: inject teaching without operational state changes.
ft="$(make_fixture session-start-off)"
write_config "$ft" false true
printf '%s\n' manual > "$ft/.agents/.compaction-pending"
ft_output="$(run_policy "$ft")"
ft_context="$(context_of "$ft_output")"
assert_marker_once "$ft_context"
assert_not_contains "$ft_context" 'fixture breadcrumb'
[[ -f "$ft/.agents/.compaction-pending" ]] || fail 'session_start=false consumed compaction marker'
assert_no_wrap_state "$ft"
ft_compact_context="$(context_of "$(run_policy "$ft" compact)")"
assert_marker_once "$ft_compact_context"
assert_not_contains "$ft_compact_context" 'Context was just compacted'
[[ -f "$ft/.agents/.compaction-pending" ]] || fail 'disabled compact context consumed marker'

# Both behaviors off: emit nothing and do not change operational state.
ff="$(make_fixture both-off)"
write_config "$ff" false false
printf '%s\n' manual > "$ff/.agents/.compaction-pending"
ff_output="$(run_policy "$ff")"
[[ -z "$ff_output" ]] || fail 'both disabled emitted context'
[[ -f "$ff/.agents/.compaction-pending" ]] || fail 'both disabled consumed compaction marker'
assert_no_wrap_state "$ff"

# Missing and malformed config use the default-on behavior.
missing="$(make_fixture missing-config)"
missing_output="$(run_policy "$missing")"
missing_context="$(context_of "$missing_output")"
assert_marker_once "$missing_context"
assert_contains "$missing_context" 'fixture breadcrumb'

malformed="$(make_fixture malformed-config)"
printf '%s\n' '{not-json' > "$malformed/.agents/config.json"
malformed_output="$(run_policy "$malformed")"
malformed_context="$(context_of "$malformed_output")"
assert_marker_once "$malformed_context"
assert_contains "$malformed_context" 'fixture breadcrumb'

# Valid JSON with a non-object root also uses the default-on behavior.
index=0
for root_value in 'null' '[]' '"text"' '42'; do
  index=$((index + 1))
  non_object="$(make_fixture "non-object-$index")"
  printf '%s\n' "$root_value" > "$non_object/.agents/config.json"
  non_object_context="$(context_of "$(run_policy "$non_object")")"
  assert_marker_once "$non_object_context"
  assert_contains "$non_object_context" 'fixture breadcrumb'
done

# Startup, resume, and compact starts each inject one teaching contract.
resume="$(make_fixture resume)"
write_config "$resume" true true
resume_context="$(context_of "$(run_policy "$resume" resume)")"
assert_marker_once "$resume_context"

compact="$(make_fixture compact)"
write_config "$compact" true true
printf '%s\n' manual > "$compact/.agents/.compaction-pending"
compact_context="$(context_of "$(run_policy "$compact" compact)")"
assert_marker_once "$compact_context"
assert_contains "$compact_context" 'Context was just compacted (trigger: manual).'
[[ ! -e "$compact/.agents/.compaction-pending" ]] || fail 'compact start did not consume marker'

# Each engine adapter must preserve one canonical marker on startup and compact.
adapters="$(make_fixture adapters)"
write_config "$adapters" true true
for engine in claude codex; do
  adapter="run_${engine}_adapter"
  assert_marker_once "$(context_of "$("$adapter" "$adapters")")"
  assert_marker_once "$(context_of "$("$adapter" "$adapters" compact)")"
done
if [[ -f "$adapters/.kimi/hooks/adapter.sh" ]]; then
  assert_marker_once "$(run_kimi_adapter "$adapters")"
  assert_marker_once "$(run_kimi_adapter "$adapters" compact)"
fi

# Disabled learning must remain absent through each real adapter path.
write_config "$adapters" true false
for engine in claude codex; do
  adapter="run_${engine}_adapter"
  assert_not_contains "$(context_of "$("$adapter" "$adapters")")" '[learning-output-style:v1]'
done
if [[ -f "$adapters/.kimi/hooks/adapter.sh" ]]; then
  assert_not_contains "$(run_kimi_adapter "$adapters")" '[learning-output-style:v1]'
fi

# The --agent gate keys on agent_id, the one field a spawned subagent carries
# and a `claude --agent <name>` main session does not. Keying on agent_type
# would let a launch flag disable every main-gated policy for a whole session.
gate() {
  local dir="$1"
  local tags="$2"
  printf '{"hook_event_name":"SessionStart","cwd":"%s","source":"startup","session_id":"gate-fixture"%s}\n' \
    "$dir" "$tags" |
    CLAUDE_PROJECT_DIR="$dir" bash "$dir/.agents/claude/adapter.sh" --agent main session-start.sh
}
write_config "$adapters" true true
[[ -n "$(gate "$adapters" '')" ]] || fail 'the main agent must run a --agent main policy'
[[ -n "$(gate "$adapters" ',"agent_type":"code-reviewer"')" ]] ||
  fail 'a --agent launch is still the main agent, so the policy must run'
[[ -z "$(gate "$adapters" ',"agent_type":"Explore","agent_id":"agent_1"')" ]] ||
  fail 'a spawned subagent must not run a --agent main policy'

printf 'PASS: session-start policy\n'
