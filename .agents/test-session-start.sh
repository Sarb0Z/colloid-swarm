#!/usr/bin/env bash
# Focused contract tests for the engine-neutral SessionStart policy.

set -euo pipefail
# A caller such as `git rebase -x` exports these; the git calls below must
# reach only their own temporary repositories.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR
# The heal begins no removal past its time budget, and judging this file's ~60
# worktrees outlasts the default 20 s on a slower machine, so every removal row
# would read as kept. Only the removal-budget row sets a budget of its own.
export WORKTREE_HEAL_SECONDS=inf

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
     "$repo/.agents/hooks/lib/mcp-off.py" "$repo/.agents/hooks/lib/workloop-inbox.py" \
     "$repo/.agents/hooks/lib/worklog.py" "$repo/.agents/hooks/lib/write_targets.py" \
     "$repo/.agents/hooks/lib/worktree_records.py" "$repo/.agents/hooks/lib/worktree_removal.py" \
     "$repo/.agents/hooks/lib/worktree_sweep.py" "$repo/.agents/hooks/lib/worktree_runs.py" \
     "$repo/.agents/hooks/lib/worktree_heal.py" "$dir/.agents/hooks/lib/"
  cp "$repo/.agents/workloop_docker.py" "$dir/.agents/"
  cp "$repo/.agents/playbooks/learning-output-style.md" "$repo/.agents/playbooks/worklog.md" "$dir/.agents/playbooks/"
  cp "$repo/.agents/claude/adapter.sh" "$repo/.agents/claude/normalize-hook.py" "$dir/.agents/claude/"
  cp "$repo/.agents/codex/normalize-hook.py" "$dir/.agents/codex/"
  cp "$repo/.codex/hooks/adapter.sh" "$dir/.codex/hooks/"
  # Kimi is optional: only repositories that wire the engine carry .kimi/.
  if [[ -f "$repo/.kimi/hooks/adapter.sh" ]]; then
    mkdir -p "$dir/.kimi/hooks"
    cp "$repo/.kimi/hooks/adapter.sh" "$repo/.kimi/hooks/normalize-hook.py" "$dir/.kimi/hooks/"
  fi
  printf '%s\n' '- fixture breadcrumb' > "$dir/.agents/breadcrumbs.md"
  printf '%s\n' '# Decisions' '' '### fixture-decision' '' '- **Decision** — fixture decision body' \
    > "$dir/.agents/decisions.md"
  mkdir -p "$dir/.agents/knowledge"
  printf '%s\n' '# Knowledge index' '' \
    '- 2026-01-02 · research · Fixture subject — fixture summary that stays in the file' \
    > "$dir/.agents/knowledge/index.md"
  printf '%s\n' '{"mcpServers": {}}' > "$dir/.agents/mcp.json"
  printf '%s\n' '{"hooks": {}}' > "$dir/.agents/config.json.example"
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
# Decisions surface as headings only; the knowledge index as date · kind ·
# subject, with the summary after the em dash left in the file.
assert_contains "$tt_context" '- fixture-decision'
assert_not_contains "$tt_context" 'fixture decision body'
assert_contains "$tt_context" '- 2026-01-02 · research · Fixture subject'
assert_not_contains "$tt_context" 'fixture summary'
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

# A sectioned file: every bullet under "## Open decisions" surfaces regardless
# of the cap, and only the other bullets are counted and capped.
sectioned="$(make_fixture breadcrumb-sections)"
write_config "$sectioned" true true
{
  printf '%s\n' '# Breadcrumbs' '' '## Open decisions' ''
  for i in 1 2 3; do printf -- '- open-%s\n' "$i"; done
  printf '%s\n' '' '## Work' ''
  for i in $(seq -w 1 12); do printf -- '- crumb-%s\n' "$i"; done
} > "$sectioned/.agents/breadcrumbs.md"
sectioned_context="$(context_of "$(run_policy "$sectioned")")"
assert_contains "$sectioned_context" 'Open decisions in .agents/breadcrumbs.md'
assert_contains "$sectioned_context" '- open-1'
assert_contains "$sectioned_context" '- open-3'
assert_contains "$sectioned_context" '(10 most recent of 12 — prune the file)'
assert_contains "$sectioned_context" '- crumb-12'
assert_not_contains "$sectioned_context" '- crumb-01'

# The knowledge index caps at the twelve newest lines, newest last.
kcap="$(make_fixture knowledge-cap)"
write_config "$kcap" true true
{
  printf '%s\n' '# Knowledge index' ''
  for i in $(seq -w 1 14); do printf -- '- 2026-01-%s · research · Subject %s — summary %s\n' "$i" "$i" "$i"; done
} > "$kcap/.agents/knowledge/index.md"
kcap_context="$(context_of "$(run_policy "$kcap")")"
assert_contains "$kcap_context" '(12 most recent of 14 — read the index)'
assert_contains "$kcap_context" '- 2026-01-14 · research · Subject 14'
assert_contains "$kcap_context" '- 2026-01-03 · research · Subject 03'
assert_not_contains "$kcap_context" 'Subject 02'
assert_not_contains "$kcap_context" 'summary 14'

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
assert_not_contains "$ft_context" 'fixture-decision'
assert_not_contains "$ft_context" 'Fixture subject'
[[ -f "$ft/.agents/.compaction-pending" ]] || fail 'session_start=false consumed compaction marker'
assert_no_wrap_state "$ft"
ft_compact_context="$(context_of "$(run_policy "$ft" compact)")"
assert_marker_once "$ft_compact_context"
assert_not_contains "$ft_compact_context" 'Context was just compacted'
[[ -f "$ft/.agents/.compaction-pending" ]] || fail 'disabled compact context consumed marker'

# The restated policy defers commit timing to the repository and sizes the
# trivial exception without a clock, because it ships to every satellite.
tt_compact_context="$(context_of "$(run_policy "$tt" compact)")"
assert_contains "$tt_compact_context" 'Context was just compacted'
assert_contains "$tt_compact_context" "the repository's commit rule decides when commits land"
assert_not_contains "$tt_compact_context" 'only when the user asks'
assert_not_contains "$tt_compact_context" 'minutes'

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

# A broken file drops the exceptions it states, so the reader reports it; an
# absent file states none, so the reader stays quiet.
config_stderr() {  # <fixture> -> what config.py writes to stderr
  python3 "$1/.agents/hooks/lib/config.py" "$1/.agents/config.json" hooks.session_start.enabled=true 2>&1 >/dev/null
}
[[ -z "$(config_stderr "$missing")" ]] || fail 'config.py reported an absent policy or config'
printf '%s\n' '{"hooks": {"teardown_gate": {"enabled": false},}}' > "$malformed/.agents/policy.json"
broken_err="$(config_stderr "$malformed")"
[[ "$broken_err" == *"$malformed/.agents/policy.json is unreadable"* ]] || fail "malformed policy.json not reported: $broken_err"
[[ "$broken_err" == *"$malformed/.agents/config.json is unreadable"* ]] || fail "malformed config.json not reported: $broken_err"
printf '%s\n' '[]' > "$malformed/.agents/policy.json"
[[ "$(config_stderr "$malformed")" == *"policy.json holds [], not a JSON object"* ]] || fail 'non-object policy.json not reported'
rm "$malformed/.agents/policy.json"

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


# A fresh start or a resume clears the parallel-writers gate's live record for
# the session; a compaction continues the process and leaves it alone.
writers="$(make_fixture writers)"
write_config "$writers" true false
printf 'dead-cell\timplementer\n' > "$writers/.agents/.writers-live-fixture-session"
printf 'p\t1' > "$writers/.agents/.writers-turn-fixture-session"
printf 'p\t implementer' > "$writers/.agents/.writers-kinds-fixture-session"
printf 'toolu_1\tREAD-ONLY\n' > "$writers/.agents/.cell-markers-fixture-session"
run_policy "$writers" compact >/dev/null
[[ -f "$writers/.agents/.writers-live-fixture-session" && -f "$writers/.agents/.cell-markers-fixture-session" ]] || fail "compact cleared the live-writers record"
run_policy "$writers" startup >/dev/null
[[ ! -e "$writers/.agents/.writers-live-fixture-session" && ! -e "$writers/.agents/.writers-turn-fixture-session" && ! -e "$writers/.agents/.writers-kinds-fixture-session" && ! -e "$writers/.agents/.cell-markers-fixture-session" ]] || fail "startup left a stale live-writers record"
printf 'dead-cell\timplementer\n' > "$writers/.agents/.writers-live-fixture-session"
run_policy "$writers" resume >/dev/null
[[ ! -e "$writers/.agents/.writers-live-fixture-session" ]] || fail "resume left a stale live-writers record"
printf 'ok: startup and resume clear the live-writers record; compact keeps it\n'


# A run in flight is surfaced at session start; a torn-down one is not.
inflight="$(make_fixture inflight)"
write_config "$inflight" true false
printf '{"version":1,"runs":{"r1":{"objective":"o","lanes":{"api":{"state":"review","claimed_by":"a","attention":null}},"messages":[],"integration":null},"old":{"objective":"o","torn_down":{"at":"x"},"lanes":{"z":{"state":"review"}},"messages":[]}}}' > "$inflight/.agents/.workloop-state.json"
inflight_context="$(context_of "$(run_policy "$inflight" startup)")"
[[ "$inflight_context" == *"Workloop runs in flight"* && "$inflight_context" == *"WORKLOOP r1: api awaits review"* ]] || fail "session start did not surface the run in flight"
[[ "$inflight_context" != *"WORKLOOP old"* ]] || fail "session start surfaced a torn-down run"
printf 'ok: a run in flight is surfaced at session start\n'

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

# The work log. Off by default: nothing about it is injected and no folder
# outside the tree is consulted, even one the config names.
wl_off="$(make_fixture worklog-off)"
printf '{"hooks":{"worklog":{"enabled":false,"dir":"../nowhere"}}}\n' > "$wl_off/.agents/config.json"
wl_off_context="$(context_of "$(run_policy "$wl_off")")"
assert_not_contains "$wl_off_context" 'work log'
assert_not_contains "$wl_off_context" 'Work log'
assert_not_contains "$wl_off_context" 'nowhere'

# A policy.json cannot switch it on: the folder is one operator's choice.
printf '{"hooks":{"worklog":{"enabled":true}}}\n' > "$wl_off/.agents/policy.json"
rm "$wl_off/.agents/config.json"
assert_not_contains "$(context_of "$(run_policy "$wl_off")")" 'Work log'
rm "$wl_off/.agents/policy.json"

# Every folder case shares one parent, so siblings are under the test's control.
wl="$(make_fixture worklog-parent/repo)"
parent="$(cd "$wl/.." && pwd -P)"
mkdir -p "$parent/.claude" "$parent/sibling-repo" "$parent/other-repo/inner" "$parent/holder/child" "$parent/worklog" \
  "$parent/deep/x/y"
git -C "$parent/sibling-repo" init -q
git -C "$parent/other-repo" init -q
git -C "$parent/holder/child" init -q
git -C "$parent/deep/x/y" init -q
worklog_config() {  # <dir value>
  printf '{"hooks":{"worklog":{"enabled":true,"dir":"%s"}}}\n' "$1" > "$wl/.agents/config.json"
}
refused() {  # <dir value> <expected reason fragment>
  local context
  worklog_config "$1"
  context="$(context_of "$(run_policy "$wl")")"
  assert_contains "$context" 'Work log refused:'
  assert_contains "$context" "$2"
  assert_contains "$context" 'hooks.worklog.dir in .agents/config.json'
  assert_not_contains "$context" 'additionalDirectories'
  assert_not_contains "$context" '# Work log'
}
refused '../.claude' 'lies in a hidden folder (.claude)'
refused '../deep' 'holds a Git repository (x/y)'
refused '../sibling-repo' 'is a Git repository'
refused '../other-repo/inner' 'is inside a Git work tree'
refused '../holder' 'holds a Git repository (child)'
refused '..' 'is the folder that holds this repository'
refused '.' 'is this repository or inside it'
mkdir -p "$wl/docs"
refused 'docs' 'is this repository or inside it'
refused '../missing' 'does not exist. Create it yourself'
refused '/' "is outside $parent"
[[ ! -e "$parent/missing" ]] || fail 'the work-log check created a folder'
# A hidden folder anywhere in the resolved path refuses, not only in the setting.
dotted="$(make_fixture .hidden-parent/repo)"
mkdir -p "$dotted/../worklog"
printf '{"hooks":{"worklog":{"enabled":true,"dir":"../worklog"}}}\n' > "$dotted/.agents/config.json"
dotted_context="$(context_of "$(run_policy "$dotted")")"
assert_contains "$dotted_context" 'lies in a hidden folder (.hidden-parent)'
assert_not_contains "$dotted_context" 'additionalDirectories'
printf 'ok: unsafe work-log folders are refused with the reason and the fix\n'

worklog_config '../worklog'
wl_context="$(context_of "$(run_policy "$wl")")"
assert_contains "$wl_context" '# Work log'
assert_contains "$wl_context" "Today's work log: $parent/worklog/$(date +%Y-%m-%d).md"
assert_contains "$wl_context" "\"permissions\": {\"additionalDirectories\": [\"$parent/worklog\"]} in .claude/settings.local.json"
assert_contains "$wl_context" "sandbox_workspace_write.writable_roots = [\"$parent/worklog\"]"
assert_not_contains "$wl_context" 'Work log refused'
# Compaction restates it.
assert_contains "$(context_of "$(run_policy "$wl" compact)")" "Today's work log: $parent/worklog/"
printf 'ok: a safe folder beside the repository yields the one grant to add\n'

worklog_config ''
wl_tree="$(context_of "$(run_policy "$wl")")"
assert_contains "$wl_tree" "Today's work log: $(cd "$wl" && pwd -P)/.agents/worklog/$(date +%Y-%m-%d).md"
assert_not_contains "$wl_tree" 'additionalDirectories'
printf 'ok: an empty folder setting keeps the log in .agents/worklog/\n'

# Both other contexts off still leaves the work log on its own toggle.
printf '{"hooks":{"session_start":{"enabled":false},"learning_output_style":{"enabled":false},"worklog":{"enabled":true,"dir":""}}}\n' \
  > "$wl/.agents/config.json"
assert_contains "$(context_of "$(run_policy "$wl")")" "Today's work log:"

# ── the worktree sweep ───────────────────────────────────────────────────────
# Sessions that ended without session-end.sh are swept as their end would
# have; worktrees no record names that sat idle 24 hours go only when nothing
# in them would be lost, and every other one is named with its work.
sw="$(make_fixture sweep)"
sw="$(cd "$sw" && pwd -P)"
cp "$repo"/.agents/workloop*.py "$repo/.agents/provision.sh" "$sw/.agents/"
git -C "$sw" config user.name fixture
git -C "$sw" config user.email fixture@example.invalid
printf '.agents/\nnode_modules/\n.env\n' > "$sw/.gitignore"
mkdir -p "$sw/src" && printf 'one\n' > "$sw/src/app.txt"
export GIT_COMMITTER_DATE=2026-01-01T00:00:00 GIT_AUTHOR_DATE=2026-01-01T00:00:00
git -C "$sw" add .gitignore src
git -C "$sw" commit -qm init
git -C "$sw" branch -M main
remote="$scratch/sweep-remote.git"
git init -q --bare "$remote"
git -C "$sw" remote add origin "$remote"
git -C "$sw" push -q origin HEAD:refs/heads/main 2>/dev/null
git -C "$sw" fetch -q origin && git -C "$sw" remote set-head origin main >/dev/null
wt() { git -C "$sw" worktree add -q "$scratch/sweep-$1" -b "$1"; }
age() {  # <worktree name>: no commit, checkout or file change for 24 hours
  find "$scratch/sweep-$1" "$sw/.git/worktrees/sweep-$1" -exec touch -h -t 202601010000 {} +
}
commit_in() {  # <worktree name> <file> <text>
  printf '%s\n' "$3" > "$scratch/sweep-$1/$2"
  git -C "$scratch/sweep-$1" add "$2" && git -C "$scratch/sweep-$1" commit -qm "$1: add $2"
}
wt merged; age merged
wt squash; commit_in squash squashed.txt same
printf 'same\n' > "$sw/squashed.txt" && git -C "$sw" add squashed.txt && git -C "$sw" commit -qm "squash of squash"
age squash
wt stable; commit_in stable stable.txt pushed
git -C "$scratch/sweep-stable" push -q -u origin stable 2>/dev/null; age stable
wt deps; mkdir -p "$scratch/sweep-deps/node_modules/pkg" && printf 'x\n' > "$scratch/sweep-deps/node_modules/pkg/i.js"; age deps
wt envfile; printf 'SECRET=1\n' > "$scratch/sweep-envfile/.env"; age envfile
wt dirty; printf 'draft\n' > "$scratch/sweep-dirty/src/draft.txt"; age dirty
wt unmerged; commit_in unmerged local.txt mine; age unmerged
wt nested; git init -q "$scratch/sweep-nested/node_modules/vendored"; age nested
wt skipflag; git -C "$scratch/sweep-skipflag" update-index --skip-worktree src/app.txt
printf 'hidden\n' > "$scratch/sweep-skipflag/src/app.txt"; age skipflag
wt bisecting; git -C "$scratch/sweep-bisecting" bisect start >/dev/null 2>&1; age bisecting
find "$sw/.git/worktrees/sweep-bisecting" -exec touch -h -t 202601010000 {} +
git -C "$sw" worktree add -q "$sw/.agents/worktrees/old-run/lane" -b old-lane
find "$sw/.agents/worktrees/old-run/lane" "$sw/.git/worktrees/lane" -exec touch -h -t 202601010000 {} +
# The heal's rows: what may go, and every way something could be lost.
printf '%s\n' build/ '.env.*' .DS_Store out/ logs/ '*.pem' '*.tfstate' '*.sqlite3-wal' credentials.json >> "$sw/.git/info/exclude"
wt build-env; mkdir -p "$scratch/sweep-build-env/build" && printf 'SECRET=1\n' > "$scratch/sweep-build-env/build/.env.production"; age build-env
wt build-db; mkdir -p "$scratch/sweep-build-db/build" && printf 'rows\n' > "$scratch/sweep-build-db/build/local.db"; age build-db
wt dist-env; mkdir -p "$scratch/sweep-dist-env/dist" && printf 'SECRET=1\n' > "$scratch/sweep-dist-env/dist/.env.production"; age dist-env
wt build-only; mkdir -p "$scratch/sweep-build-only/build/static" && printf 'x\n' > "$scratch/sweep-build-only/build/static/app.js"
printf 'x' > "$scratch/sweep-build-only/.DS_Store"; age build-only
wt build-repo; git init -q "$scratch/sweep-build-repo/build/vendored"
git -C "$scratch/sweep-build-repo/build/vendored" -c user.name=f -c user.email=f@x commit -q --allow-empty -m "unpushed"
age build-repo
wt out-csv; mkdir -p "$scratch/sweep-out-csv/out" && printf 'a,b\n' > "$scratch/sweep-out-csv/out/results.csv"; age out-csv
# A tracked tools/build/ folder whose ignored secret git lists on its own.
wt tools-build; mkdir -p "$scratch/sweep-tools-build/tools/build" && printf 'how\n' > "$scratch/sweep-tools-build/tools/build/README.md"
git -C "$scratch/sweep-tools-build" add -f tools/build/README.md && git -C "$scratch/sweep-tools-build" commit -qm "tools"
git -C "$scratch/sweep-tools-build" push -q -u origin tools-build 2>/dev/null
printf '{"token": 1}\n' > "$scratch/sweep-tools-build/tools/build/credentials.json"; age tools-build
for key in .env.local secrets.pem terraform.tfstate app.sqlite3-wal; do
  wt "key$key"; printf 'secret\n' > "$scratch/sweep-key$key/$key"; age "key$key"
done
wt nm-env; mkdir -p "$scratch/sweep-nm-env/node_modules/pkg" && printf 'X=1\n' > "$scratch/sweep-nm-env/node_modules/pkg/.env"; age nm-env
# Git lists a folder that holds only ignored files together with its contents.
wt dsonly; mkdir -p "$scratch/sweep-dsonly/assets/icons" && printf 'x' > "$scratch/sweep-dsonly/assets/icons/.DS_Store"; age dsonly
# The lane brief as `workloop.py brief` writes it: a folder that ignores itself.
wt brief; mkdir -p "$scratch/sweep-brief/.workloop" && printf '*\n' > "$scratch/sweep-brief/.workloop/.gitignore"
printf 'brief\n' > "$scratch/sweep-brief/.workloop/brief.md"; age brief
for name in expiry expiry-fresh; do
  wt "$name"; mkdir -p "$scratch/sweep-$name/logs" && printf 'log\n' > "$scratch/sweep-$name/logs/run.log"; age "$name"
done
wt wtref; keep_commit="$(git -C "$scratch/sweep-wtref" commit-tree -p HEAD -m "only refs/worktree holds this" "HEAD^{tree}")"
git -C "$scratch/sweep-wtref" update-ref refs/worktree/keep "$keep_commit"; age wtref
# Git records a worktree's path in the case it was given when the folder did not
# yet exist, or after `git worktree repair` with a mis-cased path; miscase() records it so.
miscase() { printf '%s/.git\n' "$2" > "$sw/.git/worktrees/$1/gitdir"; }  # <admin name> <path as recorded>
wt mcase; wt busy-mc
if [[ -d "$scratch/SWEEP-MCASE" ]]; then
  git -C "$sw" worktree add -q "$scratch/sweep-mcase/node_modules/inner-mc" -b inner-mc
  miscase inner-mc "$scratch/SWEEP-MCASE/node_modules/inner-mc"
  printf 'inner work\n' > "$scratch/sweep-mcase/node_modules/inner-mc/work.txt"
  age mcase; find "$sw/.git/worktrees/inner-mc" -exec touch -h -t 202601010000 {} +
  miscase sweep-busy-mc "$scratch/SWEEP-BUSY-MC"; age busy-mc
else
  printf 'note: this file system tells case apart; the mis-cased rows are skipped\n'
  rm -rf "$scratch/sweep-mcase" "$scratch/sweep-busy-mc"; git -C "$sw" worktree prune
fi
wt assume; git -C "$scratch/sweep-assume" update-index --assume-unchanged src/app.txt
printf 'hidden\n' > "$scratch/sweep-assume/src/app.txt"; age assume
git -C "$sw" worktree add -q --detach "$scratch/sweep-detached-main" main; age detached-main
wt later; commit_in later one.txt one; git -C "$sw" merge -q --no-ff later -m "merge later"
commit_in later two.txt two; age later
wt upgone; commit_in upgone gone.txt gone; git -C "$scratch/sweep-upgone" push -q -u origin upgone 2>/dev/null
git -C "$remote" branch -q -D upgone; git -C "$sw" update-ref -d refs/remotes/origin/upgone; age upgone
# A detached HEAD whose only other holder is the stale copy of a branch the remote deleted (S3).
orphan="$(git -C "$sw" commit-tree -p main -m "gone feature" "main^{tree}")"
git -C "$sw" push -q origin "$orphan:refs/heads/gone-feature" 2>/dev/null && git -C "$sw" fetch -q origin
git -C "$remote" branch -q -D gone-feature
git -C "$sw" worktree add -q --detach "$scratch/sweep-detached-gone" "$orphan"; age detached-gone
# Commits only the HEAD log reaches, left a moment ago by a switch away from a detached HEAD.
wt reflog
(cd "$scratch/sweep-reflog" && unset GIT_COMMITTER_DATE GIT_AUTHOR_DATE && git checkout -q --detach \
  && git commit -q --allow-empty -m "abandoned" && git checkout -q reflog 2>/dev/null); age reflog
wt holder; git -C "$sw" worktree add -q "$scratch/sweep-holder/.agents/worktrees/r/l" -b holder-lane
age holder; find "$sw/.git/worktrees/l" -exec touch -h -t 202601010000 {} +
wt holder-build; git -C "$sw" worktree add -q "$scratch/sweep-holder-build/build/inner" -b holder-inner
printf 'inner work\n' > "$scratch/sweep-holder-build/build/inner/work.txt"
age holder-build; find "$sw/.git/worktrees/inner" -exec touch -h -t 202601010000 {} +
git -C "$sw" config extensions.worktreeConfig true
wt hidden; git -C "$scratch/sweep-hidden" config --worktree status.showUntrackedFiles no
printf 'notes\n' > "$scratch/sweep-hidden/notes.txt"; age hidden
wt corrupt; printf 'garbage' > "$sw/.git/worktrees/sweep-corrupt/index"; age corrupt
# A run whose state lives in another checkout of the repository names a lane outside .agents/worktrees/.
wt keeper; git -C "$sw" worktree add -q "$scratch/sweep-far-lane" -b far-lane
mkdir -p "$scratch/sweep-keeper/.agents"
printf '{"version": 1, "runs": {"far": {"repo": "%s", "base": "%s", "lanes": {"l": {"workspace": "%s"}}, "messages": [], "events": [], "integration": null}}}\n' \
  "$scratch/sweep-keeper" "$(git -C "$sw" rev-parse main)" "$scratch/sweep-far-lane" > "$scratch/sweep-keeper/.agents/.workloop-state.json"
age keeper; age far-lane
unset GIT_COMMITTER_DATE GIT_AUTHOR_DATE
sleepers=()
trap 'for pid in "${sleepers[@]+"${sleepers[@]}"}"; do kill "$pid" 2>/dev/null || true; done; rm -rf "$scratch"' EXIT
host_of() { printf '[%s, "%s"]' "$1" "$(ps -o lstart= -p "$1" | awk '{$1=$1};1')"; }
# Backgrounded with their output closed, so no command substitution waits on them.
sleep 300 >/dev/null 2>&1 & sleepers+=($!)
live="$(host_of "${sleepers[0]}")"
sleep 300 >/dev/null 2>&1 & gone=$!
dead="$(host_of "$gone")"
kill "$gone"; wait "$gone" 2>/dev/null || true
records="$sw/.agents/worktrees/.records"
mkdir -p "$records"
note() { printf '{"type": "worktree", "path": "%s", "by": "git worktree add", "host": %s}\n' "$scratch/sweep-$1" "$2"; }

real="$(cd "$scratch" && pwd -P)"
wt claude-stale; age claude-stale
git -C "$sw" worktree lock "$scratch/sweep-claude-stale" --reason "claude session claude-stale (pid $gone start $(date -u '+%a %b %d %H:%M:%S %Y'))"
wt dead; printf 'unsaved\n' > "$scratch/sweep-dead/src/new.txt"
note dead "$dead" > "$records/ended-session.jsonl"
wt live; note live "$live" > "$records/running-session.jsonl"
wt mine; note mine "$dead" > "$records/fixture-session.jsonl"
# A claim a killed end left, and folders a killed removal parked.
wt ghost
printf '{"type": "worktree", "path": "%s", "by": "git worktree add", "host": %s}\n' "$real/sweep-ghost" "$dead" \
  > "$records/.ghost.jsonl.ending-$gone"
wt parked; mkdir -p "$sw/.git/colloid-trash/1-1/0" && printf 'dep\n' > "$sw/.git/colloid-trash/1-1/0/i.js"
printf '{"worktree": "%s", "moves": [["%s", "%s"]]}' "$real/sweep-parked" "$real/sweep-parked/node_modules" \
  "$sw/.git/colloid-trash/1-1/0" > "$sw/.git/colloid-trash/1-1/manifest.json"
touch -t 202601010000 "$sw/.git/colloid-trash/1-1"
wt today
wt locked; age locked; git -C "$sw" worktree lock "$scratch/sweep-locked"
wt busy; age busy
(cd "$scratch/sweep-busy" && exec sleep 120) >/dev/null 2>&1 & sleepers+=($!)
busy_mc=""
if [[ -d "$scratch/sweep-busy-mc" ]]; then
  (cd "$scratch/sweep-busy-mc" && exec sleep 120) >/dev/null 2>&1 & busy_mc=$!; sleepers+=("$busy_mc")
fi
wt lane; age lane
wt away; mv "$scratch/sweep-away" "$scratch/moved-away"
python3 - "$sw" "$scratch" <<'PY' > "$sw/.agents/.workloop-state.json"
import json, sys
sw, scratch = sys.argv[1], sys.argv[2]
def run(repo, lanes):
    return {"repo": repo, "base": "0" * 40, "lanes": {f"l{i}": {"workspace": w} for i, w in enumerate(lanes)},
            "messages": [], "events": [], "integration": None}
print(json.dumps({"version": 1, "runs": {
    "lq-ui": run(sw, [f"{scratch}/sweep-lane"]),                  # workspace listed: named
    "fold": run(sw, [f"{scratch}/sweep-gone-lane"]),              # git lists none: closed
    "empty": run(sw, []),                                         # no lanes: named
    "unmounted": run(sw, [f"{scratch}/sweep-away"]),              # listed, not on disk: named
    "moved-repo": run(f"{scratch}/no-such-checkout", [f"{scratch}/x"]),  # no repository: named
}}, indent=2, sort_keys=True))
PY
other="$scratch/sweep-other-repo"
git init -q "$other" && git -C "$other" -c user.name=f -c user.email=f@x commit -q --allow-empty -m init
git -C "$other" worktree add -q "$scratch/sweep-foreign" -b foreign
find "$scratch/sweep-foreign" "$other/.git/worktrees" -exec touch -h -t 202601010000 {} +
for pid in "${sleepers[1]}" ${busy_mc:+"$busy_mc"}; do
  for _ in $(seq 50); do lsof -a -p "$pid" -d cwd >/dev/null 2>&1 && break; sleep 0.1; done
done

sweep_context="$(context_of "$(run_policy "$sw" resume)")"
[[ -n "${SWEEP_TEST_VERBOSE:-}" ]] && printf '%s\n' "$sweep_context"
[[ ! -e "$scratch/sweep-dead" && "$(git -C "$sw" show saved/sweep-dead:src/new.txt)" == unsaved ]] || fail "an ended session's worktree must be saved and swept"
[[ ! -e "$records/ended-session.jsonl" ]] || fail "a swept session's records must go"
printf 'ok: a session that ended without its hook is swept at the next start, unsaved work saved\n'
[[ -d "$scratch/sweep-live" && -f "$records/running-session.jsonl" && -d "$scratch/sweep-mine" ]] || fail "running and resumed sessions keep their worktrees"
grep -q '"type": "host"' "$records/fixture-session.jsonl" || fail "a resumed session must record its new process"
printf 'ok: a running session and the resumed session keep their worktrees\n'
[[ ! -e "$scratch/sweep-ghost" && -z "$(ls -A "$records" | grep '^\.ghost')" ]] || fail "a killed end's claim must be reclaimed and swept"
[[ -f "$scratch/sweep-parked/node_modules/i.js" && ! -e "$sw/.git/colloid-trash/1-1" ]] || fail "folders a killed removal parked must go back"
printf 'ok: a killed end'"'"'s claim is reclaimed, and folders a killed removal parked go back\n'
# Each row names whether the heal must remove the worktree or keep it, with
# the file a kept row must still hold. Rows report before any check fails, so
# one run shows the whole table.
heal_failures=0
row() {  # <removed|kept> <worktree name> <context> <what the row covers> [file that must survive]
  local got=removed
  [[ -e "$scratch/sweep-$2" ]] && got=kept
  [[ "$got" == removed && "$3" != *"removed idle $real/sweep-$2 "* ]] && got="gone, unreported"
  [[ "$got" == kept && -n "${5:-}" && ! -e "$scratch/sweep-$2/$5" ]] && got="kept without $5"
  if [[ "$got" == "$1" ]]; then
    printf 'row ok    %-7s %s\n' "$1" "$4"
  else
    printf 'row FAIL  %-7s %s (got: %s)\n' "$1" "$4" "$got"
    heal_failures=$((heal_failures + 1))
  fi
}
row removed merged "$sweep_context" "a branch merged into the default branch"
row removed squash "$sweep_context" "a squash-merged branch"
row removed stable "$sweep_context" "a branch whose upstream holds every commit"
row removed deps "$sweep_context" "only node_modules ignored"
row removed nested "$sweep_context" "a repository inside node_modules"
row removed nm-env "$sweep_context" "a .env inside node_modules, which the walk skips"
row removed dsonly "$sweep_context" "only .DS_Store, in folders holding nothing else"
row removed brief "$sweep_context" "only the lane brief, in a .workloop/ that ignores itself"
row removed detached-main "$sweep_context" "a detached HEAD the default branch contains"
row removed claude-stale "$sweep_context" "Claude Code's lock of a session that has ended"
row kept envfile "$sweep_context" "a .env file" .env
for key in .env.local secrets.pem terraform.tfstate app.sqlite3-wal; do
  row kept "key$key" "$sweep_context" "an ignored $key" "$key"
done
row kept build-env "$sweep_context" "build/.env.production inside an ignored build/" build/.env.production
row kept build-db "$sweep_context" "build/local.db inside an ignored build/" build/local.db
row kept build-only "$sweep_context" "only build output in an ignored build/" build/static/app.js
row kept build-repo "$sweep_context" "a repository with an unpushed commit inside build/" build/vendored/.git
row kept out-csv "$sweep_context" "out/results.csv" out/results.csv
row kept tools-build "$sweep_context" "an ignored secret under a tracked tools/build/" tools/build/credentials.json
row kept dist-env "$sweep_context" "dist/.env.production with only .env.* ignored" dist/.env.production
row kept dirty "$sweep_context" "an untracked file" src/draft.txt
row kept hidden "$sweep_context" "an untracked file status.showUntrackedFiles=no hides" notes.txt
row kept skipflag "$sweep_context" "a skip-worktree secret" src/app.txt
row kept assume "$sweep_context" "an assume-unchanged edit" src/app.txt
row kept bisecting "$sweep_context" "a bisect in progress"
row kept corrupt "$sweep_context" "an index git cannot read"
row kept unmerged "$sweep_context" "a branch with unmerged commits"
row kept later "$sweep_context" "a merged branch with later commits" two.txt
row kept upgone "$sweep_context" "a branch whose upstream is gone"
row kept detached-gone "$sweep_context" "a detached HEAD on a branch the remote deleted"
row kept reflog "$sweep_context" "commits only its HEAD log reaches"
row kept wtref "$sweep_context" "a commit only its refs/worktree/ ref reaches"
row kept holder "$sweep_context" "a worktree holding a nested lane"
row kept holder/.agents/worktrees/r/l "$sweep_context" "the nested lane itself"
row kept holder-build "$sweep_context" "a worktree holding another inside build/" build/inner/work.txt
if [[ -n "$busy_mc" ]]; then
  row kept mcase "$sweep_context" "a worktree holding another git records in another case" node_modules/inner-mc/work.txt
  row kept busy-mc "$sweep_context" "a process inside a worktree git records in another case"
fi
row kept far-lane "$sweep_context" "a lane of a run whose state lives in another checkout"
row kept locked "$sweep_context" "a locked worktree"
row kept busy "$sweep_context" "a worktree a process works in"
# The second start: a kept verdict stands while its key does, and falls when it
# changes or ages past a week.
rm "$scratch/sweep-envfile/.env"  # then idle again, at another old time than the cached one
find "$scratch/sweep-envfile" "$sw/.git/worktrees/sweep-envfile" -exec touch -h -t 202601020000 {} +
rm "$scratch/sweep-expiry/logs/run.log" "$scratch/sweep-expiry-fresh/logs/run.log"
python3 - "$sw/.git/colloid-heal-cache.json" "$real/sweep-expiry" <<'PY'
import json, sys, time
cache = json.load(open(sys.argv[1]))
cache[sys.argv[2]]["at"] = time.time() - 8 * 86400
json.dump(cache, open(sys.argv[1], "w"))
PY
git -C "$sw" merge -q --no-ff unmerged -m "merge unmerged"
again="$(context_of "$(run_policy "$sw")")"
[[ -n "${SWEEP_TEST_VERBOSE:-}" ]] && printf '%s\n' "$again"
row removed unmerged "$again" "unmerged at the first start, merged before the second"
row removed envfile "$again" "its .env deleted from the top folder before the second start"
row removed expiry "$again" "its log deleted inside logs/, its cached verdict a week old"
row kept expiry-fresh "$again" "its log deleted inside logs/: the fresh cached verdict stands"
row kept later "$again" "the default branch moved; still unmerged" two.txt

# The scaffold's own ignored files, as its .gitignore fragment lists them.
mini() {  # <name>: a fixture repository with one commit on main, whose .gitignore is <stdin>
  local dir
  dir="$(make_fixture "$1")"; dir="$(cd "$dir" && pwd -P)"
  cat > "$dir/.gitignore"
  mkdir -p "$dir/src" && printf 'one\n' > "$dir/src/app.txt"
  git -C "$dir" add .gitignore src && git -C "$dir" -c user.name=f -c user.email=f@x commit -qm init
  git -C "$dir" branch -M main
  printf '%s\n' "$dir"
}
mwt() {  # <repo> <name>: an idle worktree of <repo> at $scratch/sweep-<name>
  git -C "$1" worktree add -q "$scratch/sweep-$2" -b "$2"
  mkdir -p "$scratch/sweep-$2/.agents"
}
mage() { find "$scratch/sweep-$2" "$1/.git/worktrees/sweep-$2" -exec touch -h -t 202601010000 {} +; }
export GIT_COMMITTER_DATE=2026-01-01T00:00:00 GIT_AUTHOR_DATE=2026-01-01T00:00:00
# The carrier keeps the scaffold's ignore rules in the export fragment; a
# satellite carries them in its own .gitignore.
fragment="$repo/.agents/export/gitignore-fragment"
[[ -f "$fragment" ]] || fragment="$repo/.gitignore"
sc="$({ cat "$fragment"; printf '%s\n' .DS_Store next-env.d.ts; } | mini scaffolded)"
mwt "$sc" sc-ledgers
for ledger in .wrap-state-s1 .teardown-pending-s1 .compaction-pending .workloop-state.json.lock; do
  printf 'x\n' > "$scratch/sweep-sc-ledgers/.agents/$ledger"
done
mkdir -p "$scratch/sweep-sc-ledgers/.agents/.writers-lock-s1" && printf 'x\n' > "$scratch/sweep-sc-ledgers/.agents/.writers-lock-s1/held"
mwt "$sc" sc-no-run; printf '{"version": 1, "runs": {}}\n' > "$scratch/sweep-sc-no-run/.agents/.workloop-state.json"
mwt "$sc" sc-run; printf '{"version": 1, "runs": {"r": {"lanes": {}}}}\n' > "$scratch/sweep-sc-run/.agents/.workloop-state.json"
mwt "$sc" sc-worklog; mkdir -p "$scratch/sweep-sc-worklog/.agents/worklog" && printf 'did\n' > "$scratch/sweep-sc-worklog/.agents/worklog/day.md"
mwt "$sc" sc-config; printf '{}\n' > "$scratch/sweep-sc-config/.agents/config.json"
mwt "$sc" sc-local; printf 'mine\n' > "$scratch/sweep-sc-local/CLAUDE.local.md"
mwt "$sc" sc-next-env; printf '/// x\n' > "$scratch/sweep-sc-next-env/next-env.d.ts"
mwt "$sc" sc-pycache; mkdir -p "$scratch/sweep-sc-pycache/src/__pycache__" && printf 'x' > "$scratch/sweep-sc-pycache/src/__pycache__/m.pyc"
for name in sc-ledgers sc-no-run sc-run sc-worklog sc-config sc-local sc-next-env sc-pycache; do mage "$sc" "$name"; done
# One worktree each for the removal budget and compaction, and for a write between verdict and removal.
pace="$(printf '.env*\n' | mini pace)"; mwt "$pace" pace; mage "$pace" pace
late="$(printf '.env*\n' | mini late)"; mwt "$late" late; mage "$late" late
unset GIT_COMMITTER_DATE GIT_AUTHOR_DATE
sc_context="$(context_of "$(run_policy "$sc")")"
[[ -n "${SWEEP_TEST_VERBOSE:-}" ]] && printf '%s\n' "$sc_context"
row removed sc-ledgers "$sc_context" "only session-keyed scaffold ledgers in .agents/"
row removed sc-no-run "$sc_context" "a workloop state file holding no run"
row removed sc-next-env "$sc_context" "only next-env.d.ts"
row kept sc-run "$sc_context" "a workloop state file holding a run" .agents/.workloop-state.json
row kept sc-worklog "$sc_context" "a work log" .agents/worklog/day.md
row kept sc-config "$sc_context" "the operator's .agents/config.json" .agents/config.json
row kept sc-local "$sc_context" "CLAUDE.local.md" CLAUDE.local.md
row removed sc-pycache "$sc_context" "only a __pycache__ folder, a cache Python rebuilds"
pace_first="$(context_of "$(WORKTREE_HEAL_SECONDS=0 run_policy "$pace")")"
row kept pace "$pace_first" "past the removal budget: named, left for the next start"
pace_compact="$(run_policy "$pace" compact)"
row kept pace "$pace_compact" "a compaction start removes nothing"
pace_next="$(context_of "$(run_policy "$pace")")"
row removed pace "$pace_next" "the next start, within the budget"
# lsof's second call, which only the removal makes, writes an ignored file into the worktree.
mkdir -p "$scratch/shim"
printf '#!/bin/bash\nn=$(cat %q 2>/dev/null || echo 0); echo $((n + 1)) > %q\n(( n >= 1 )) && printf "LATE=1\\n" > %q\nexec %q "$@"\n' \
  "$scratch/lsof-calls" "$scratch/lsof-calls" "$scratch/sweep-late/.env.late" "$(command -v lsof)" > "$scratch/shim/lsof"
chmod +x "$scratch/shim/lsof"
late_context="$(context_of "$(PATH="$scratch/shim:$PATH" run_policy "$late")")"
row kept late "$late_context" "an ignored file written between the verdict and the removal" .env.late
(( heal_failures == 0 )) || fail "$heal_failures heal row(s) failed"
printf 'ok: the heal removes what would lose nothing and keeps the rest\n'
assert_contains "$sweep_context" "removed idle $real/sweep-merged [merged] last commit 2026-01-01"
assert_contains "$sweep_context" "0 commit(s) not in the default branch, 0 uncommitted file(s): could go: merged into main; branch merged deleted, HEAD contains it"
assert_contains "$sweep_context" "removed idle $real/sweep-squash [squash] last commit 2026-01-01 squash: add squashed.txt; 1 commit(s) not in the default branch, 0 uncommitted file(s): could go: its changes are already in main; branch squash kept, HEAD does not contain it"
assert_contains "$sweep_context" ": could go: every commit is on origin/stable; branch stable kept, it is the trunk or tracks a remote"
assert_contains "$sweep_context" "removed idle $real/sweep-detached-main [detached]"
git -C "$sw" rev-parse -q --verify refs/heads/squash >/dev/null || fail "a squash-merged branch HEAD does not contain must stay"
assert_contains "$sweep_context" "idle $real/sweep-envfile [envfile] last commit"
assert_contains "$sweep_context" "stays: it holds ignored files that do not rebuild: .env"
assert_contains "$sweep_context" "sweep-build-env [build-env]"
assert_contains "$sweep_context" "stays: it holds ignored files that do not rebuild: build/; see \`git -C $real/sweep-build-env status --ignored\`"
assert_contains "$sweep_context" "stays: it holds ignored files that do not rebuild: dist/.env.production"
assert_contains "$sweep_context" "stays: it holds ignored files that do not rebuild: out/"
assert_contains "$sweep_context" "stays: it holds ignored files that do not rebuild: tools/build/credentials.json"
assert_contains "$sweep_context" "stays: it holds a nested repository at $real/sweep-build-repo/build/vendored; see \`git -C $real/sweep-build-repo/build/vendored status\`"
assert_contains "$sweep_context" "idle $real/sweep-dirty [dirty]"
assert_contains "$sweep_context" "1 uncommitted file(s): stays: it holds uncommitted work; see \`git -C $real/sweep-dirty status\`"
assert_contains "$sweep_context" "idle $real/sweep-hidden [hidden] last commit 2026-01-01 merge later; 0 commit(s) not in the default branch, 1 uncommitted file(s): stays: it holds uncommitted work"
assert_contains "$sweep_context" "idle $real/sweep-unmerged [unmerged] last commit 2026-01-01 unmerged: add local.txt; 1 commit(s) not in the default branch, 0 uncommitted file(s): stays: its commits are not in main and it has no upstream; see \`git -C $real/sweep-unmerged log main..HEAD\`"
assert_not_contains "$sweep_context" "removed idle $real/sweep-unmerged"
assert_contains "$again" "removed idle $real/sweep-unmerged [unmerged]"
assert_contains "$sweep_context" "idle $real/sweep-skipflag [skipflag]"
assert_contains "$sweep_context" "stays: it holds skip-worktree or assume-unchanged files git status does not show: src/app.txt"
assert_contains "$sweep_context" "stays: a BISECT_LOG operation is in progress"
assert_contains "$sweep_context" "sweep-corrupt [corrupt] last commit 2026-01-01 merge later; 0 commit(s) not in the default branch, status unreadable: stays: git could not read its index"
assert_contains "$sweep_context" "sweep-detached-gone [detached]"
assert_contains "$sweep_context" "stays: its detached HEAD is not in main"
assert_contains "$sweep_context" "stays: its commits are not in main and its upstream origin/upgone is gone"
assert_contains "$sweep_context" "sweep-reflog [reflog]"
assert_contains "$sweep_context" "stays: 1 commit(s) only its HEAD log or refs/worktree/ refs reach, which git keeps until $(date -v+30d +%Y-%m-%d 2>/dev/null || date -d '+30 days' +%Y-%m-%d)"
assert_contains "$sweep_context" "sweep-wtref [wtref]"
assert_contains "$sweep_context" "stays: 1 commit(s) only its HEAD log or refs/worktree/ refs reach; see"
assert_contains "$sweep_context" "stays: another worktree lies inside it: $real/sweep-holder/.agents/worktrees/r/l"
assert_contains "$sweep_context" "lane folder $real/sweep-holder/.agents/worktrees/r/l [holder-lane]"
assert_contains "$sweep_context" "stays: another worktree lies inside it: $real/sweep-holder-build/build/inner"
assert_contains "$sweep_context" "stays: it is locked (no reason given); \`git worktree unlock $real/sweep-locked\` lets the next start judge it"
assert_contains "$sweep_context" "removed idle $real/sweep-claude-stale [claude-stale]"
assert_not_contains "$sweep_context" "sweep-far-lane"
git -C "$sw" rev-parse -q --verify refs/heads/saved/sweep-dirty >/dev/null && fail "the heal must save nothing"
[[ -f "$sw/.git/colloid-heal-cache.json" ]] || fail "the heal must cache its kept verdicts"
printf 'ok: each idle unrecorded worktree is named with its work, why it went or stays, and the command to look\n'
# After the first start a kept verdict is counted, not repeated; the listing command prints it, dated.
assert_not_contains "$again" "idle $real/sweep-dirty "
assert_contains "$again" "other idle worktree(s) stay as judged at an earlier start; list them with \`python3 "
listed="$(python3 "$sw/.agents/hooks/lib/worktree_sweep.py" list "$sw")"
assert_contains "$listed" "idle $real/sweep-dirty [dirty]"
assert_contains "$listed" "(judged $(date +%Y-%m-%d))"
printf 'ok: later starts count the standing verdicts and name the command that lists them, dated\n'
assert_contains "$sc_context" "stays: it holds ignored files that do not rebuild: .agents/config.json"
assert_contains "$sc_context" "stays: it holds ignored files that do not rebuild: .agents/worklog/"
assert_contains "$pace_first" "could go: merged into main; this start begins no removal after 0 s, so the next start removes it"
assert_contains "$late_context" "stays: it holds ignored files that do not rebuild: .env.late"
printf 'ok: scaffold ledgers rebuild and its operator files keep; the budget and compaction defer; a late write keeps\n'
[[ -d "$sw/.agents/worktrees/old-run/lane" ]] || fail "a lane folder must never be removed by the sweep"
assert_contains "$sweep_context" "lane folder $sw/.agents/worktrees/old-run/lane [old-lane]"
assert_contains "$sweep_context" ": belongs to no workloop run"
printf 'ok: a lane folder under .agents/worktrees/ that belongs to no run is named\n'
[[ -d "$scratch/sweep-today" && -d "$scratch/sweep-locked" && -d "$scratch/sweep-busy" && -d "$scratch/sweep-foreign" ]] \
  || fail "active, locked, occupied and foreign worktrees must stay"
assert_contains "$sweep_context" "idle $real/sweep-busy [busy]"
assert_contains "$sweep_context" "stays: process ${sleepers[1]} is working in it"
assert_not_contains "$sweep_context" "sweep-today"
assert_not_contains "$sweep_context" "sweep-foreign"
printf 'ok: active, locked, occupied and foreign worktrees stay\n'
[[ -d "$scratch/sweep-lane" ]] || fail "a run with no recorded lead must keep its worktrees"
assert_contains "$sweep_context" "closed workloop run fold: git lists none of its worktrees"
assert_contains "$sweep_context" "Workloop runs no session recorded as their lead, left alone with their worktrees: empty, lq-ui, moved-repo, unmounted"
python3 - "$sw/.agents/.workloop-state.json" <<'PY' || fail "only fold may be closed, by dropping its entry"
import json, sys
runs = json.load(open(sys.argv[1]))["runs"]
sys.exit(sorted(runs) != ["empty", "lq-ui", "moved-repo", "unmounted"])
PY
[[ -n "$(git -C "$sw" worktree list --porcelain | grep "$real/sweep-away")" ]] || fail "closing a run must not prune another lane's worktree entry"
printf 'ok: an unowned run closes only when it has lanes, its repository exists and git lists none of its worktrees; no prune\n'
assert_contains "$sweep_context" "removed $real/sweep-dead; its unsaved work is on branch saved/sweep-dead"
assert_contains "$again" "  saved/sweep-dead "
assert_not_contains "$again" "removed $real/sweep-dead"
printf 'ok: the digest names each saved branch until it is deleted\n'

python3 -c 'import fcntl,sys,time; f=open(sys.argv[1],"w"); fcntl.flock(f,fcntl.LOCK_EX); print("held",flush=True); time.sleep(60)' \
  "$sw/.git/colloid-sweep.lock" > "$scratch/held" 2>&1 & sleepers+=($!)
for _ in $(seq 50); do grep -q held "$scratch/held" && break; sleep 0.1; done
assert_contains "$(context_of "$(run_policy "$sw")")" "Another session start is sweeping this repository's worktrees; this one skipped it."
printf 'ok: one sweep per repository at a time\n'

printf 'PASS: session-start policy\n'
