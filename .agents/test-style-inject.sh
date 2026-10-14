#!/usr/bin/env bash
# Firing tests for the output style's reach: a spawned subagent is handed the
# style's body at SubagentStart (style-inject.sh), and a carrier session start
# reports an installed copy that says something else (session-start.sh through
# hooks/lib/output_style.py).
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

dir="$scratch/fixture"
mkdir -p "$dir/.agents/hooks/policy" "$dir/.agents/hooks/lib" "$dir/.agents/claude" "$dir/.claude/hooks"
cp "$repo/.agents/hooks/policy/style-inject.sh" "$repo/.agents/hooks/policy/session-start.sh" "$dir/.agents/hooks/policy/"
cp "$repo"/.agents/hooks/lib/{config,payload,emit-context,mcp-off,worklog,write_targets,output_style}.py "$dir/.agents/hooks/lib/"
cp "$repo/.agents/claude/adapter.sh" "$repo/.agents/claude/normalize-hook.py" "$dir/.agents/claude/"
ln -s ../../.agents/claude/adapter.sh "$dir/.claude/hooks/adapter.sh"
style="$dir/.agents/claude/output-style.md"
printf '%s\n' '---' 'name: colloid' 'keep-coding-instructions: true' '---' '' 'Counter-pressure fixture:' '' '- Fixture rule one.' > "$style"
printf '%s\n' '{"mcpServers": {}}' > "$dir/.agents/mcp.json"
printf '%s\n' '{"hooks": {}, "stack_packs": {"carrier": true}}' > "$dir/.agents/config.json.example"
git -C "$dir" init -q

inject() { printf '{"project_dir":"%s"}' "$dir" | bash "$dir/.agents/hooks/policy/style-inject.sh"; }
context() { python3 -c 'import json,sys; d=json.load(sys.stdin)["hookSpecificOutput"]; assert d["hookEventName"]==sys.argv[1], d; print(d["additionalContext"])' "$1"; }

# 1. A subagent start carries the style's body and none of its frontmatter.
got="$(inject | context SubagentStart)"
[[ "$got" == *"main session only"* && "$got" == *"- Fixture rule one."* ]] || fail "row 1: the body did not reach the subagent: $got"
[[ "$got" != *"keep-coding-instructions"* ]] || fail "row 1: the frontmatter leaked into the context"
ok "a subagent start carries the style's body without its frontmatter"

# 2. Through the Claude adapter, with the payload the host sends.
got="$(printf '{"hook_event_name":"SubagentStart","session_id":"s1","agent_id":"a1","agent_type":"general-purpose","cwd":"%s"}' "$dir" \
  | CLAUDE_PROJECT_DIR="$dir" bash "$dir/.claude/hooks/adapter.sh" style-inject.sh | context SubagentStart)"
[[ "$got" == *"- Fixture rule one."* ]] || fail "row 2: the adapter path dropped the body: $got"
ok "the Claude adapter delivers the same context"

# 3. Switched off, nothing is said.
printf '{"hooks":{"style_inject":{"enabled":false}}}\n' > "$dir/.agents/config.json"
[[ -z "$(inject)" ]] || fail "row 3: a disabled hook still injected"
rm "$dir/.agents/config.json"
ok "hooks.style_inject.enabled=false silences it"

# 4. A missing style is reported on stderr, never blocks, and injects nothing.
mv "$style" "$scratch/style.bak"
out="$(inject 2>"$scratch/err")"; rc=$?
[[ "$rc" -eq 0 && -z "$out" && "$(cat "$scratch/err")" == *"is missing"* ]] || fail "row 4: rc=$rc out=$out err=$(cat "$scratch/err")"
mv "$scratch/style.bak" "$style"
ok "a missing style is reported and the subagent starts anyway"

# 5. Drift: each kind of installed copy, read by output_style.py.
lib="$dir/.agents/hooks/lib/output_style.py"
device="$scratch/policy.json"
account="$scratch/account/output-styles/colloid.md"
mkdir -p "$(dirname "$account")"
[[ -z "$(python3 "$lib" drift "$style" "$device" "$account")" ]] || fail "row 5: absent copies were reported"
ln -s "$style" "$account"
python3 -c 'import json,sys; json.dump({"appendSystemPrompt": sys.argv[1]}, open(sys.argv[2], "w"))' "$(python3 "$lib" body "$style")" "$device"
[[ -z "$(python3 "$lib" drift "$style" "$device" "$account")" ]] || fail "row 5: a linked account copy and a current device policy were reported"
rm "$account"; cp "$style" "$account"
[[ -z "$(python3 "$lib" drift "$style" "$device" "$account")" ]] || fail "row 5: a byte-identical account copy was reported"
printf '%s\n' '- An older rule.' >> "$account"
python3 -c 'import json,sys; json.dump({"appendSystemPrompt": "Older text"}, open(sys.argv[1], "w"))' "$device"
got="$(python3 "$lib" drift "$style" "$device" "$account")"
[[ "$got" == *"$account differs"* && "$got" == *"$device appends text that differs"* ]] || fail "row 5: stale copies not named: $got"
rm "$account"; ln -s "$scratch/gone.md" "$account"
[[ "$(python3 "$lib" drift "$style" "$scratch/none.json" "$account")" == *"which does not exist"* ]] || fail "row 5: a broken link was not reported"
ok "drift names a stale account copy, a stale device policy and a broken link, and passes links, identical copies and absent ones"

# 5b. A copy that cannot be read is named and never hides another stale one.
rm "$account"; printf '%s\n' '- An older rule.' > "$account"
printf 'garbage' > "$device"
got="$(python3 "$lib" drift "$style" "$device" "$account")"
[[ "$got" == *"$account differs"* && "$got" == *"$device could not be read"* ]] || fail "row 5b: an unreadable device policy hid the stale account copy: $got"
printf '{"managedSettings":{}}' > "$device"
[[ "$(python3 "$lib" drift "$style" "$device" "$scratch/none.md")" == *"$device appends no output style"* ]] || fail "row 5b: a policy without appendSystemPrompt was misnamed"
python3 -c 'import json,sys; json.dump({"appendSystemPrompt": "Older text"}, open(sys.argv[1], "w"))' "$device"
ok "an unreadable copy is named on its own line and a policy that appends nothing is told apart"

# 6. A carrier session start tells the operator; a satellite's does not look.
start() { printf '{"project_dir":"%s","source":"startup","session_id":"s1","transcript_path":""}' "$dir" \
  | COLLOID_DEVICE_POLICY="$device" CLAUDE_CONFIG_DIR="$scratch/account" bash "$dir/.agents/hooks/policy/session-start.sh"; }
got="$(start | context SessionStart)"
[[ "$got" == *"output-style copies are stale"* && "$got" == *"$device appends text that differs"* && "$got" == *"ln -sf"* ]] \
  || fail "row 6: the carrier start did not report the stale device policy: $got"
printf '%s\n' '{"hooks": {}}' > "$dir/.agents/config.json.example"
out="$(start)"
[[ "$out" != *"output-style copies are stale"* ]] || fail "row 6: a satellite compared copies built from the carrier"
ok "the carrier's session start reports stale copies with the fix; a satellite's stays quiet"

# 6b. Started in a worktree, the suggested link names the main checkout's file,
# which outlives the worktree.
printf '%s\n' '{"hooks": {}, "stack_packs": {"carrier": true}}' > "$dir/.agents/config.json.example"
git -C "$dir" add -A && git -C "$dir" -c user.name=t -c user.email=t@t commit -qm fixture
git -C "$dir" worktree add -q "$scratch/wt" 2>/dev/null
got="$(printf '{"project_dir":"%s","source":"startup","session_id":"","transcript_path":""}' "$scratch/wt" \
  | COLLOID_DEVICE_POLICY="$device" CLAUDE_CONFIG_DIR="$scratch/account" bash "$scratch/wt/.agents/hooks/policy/session-start.sh" | context SessionStart)"
main_style="$(cd "$dir" && pwd -P)/.agents/claude/output-style.md"
[[ "$got" == *"ln -sf \"$main_style\""* ]] || fail "row 6b: the link does not name the main checkout's style: $got"
ok "a worktree's session start suggests a link to the main checkout's style"

# 7. The repository's settings run the hook at every subagent start.
python3 - "$repo/.agents/claude/settings.json" <<'PY' || fail "row 7: settings.json does not run style-inject.sh once at SubagentStart"
import json, sys
groups = json.load(open(sys.argv[1], encoding="utf-8"))["hooks"]["SubagentStart"]
commands = [h["command"] for g in groups if not g.get("matcher") for h in g["hooks"]]
runs = [c for c in commands if c.endswith('adapter.sh" style-inject.sh')]
# Registering it must not run any other SubagentStart hook a second time.
raise SystemExit(0 if len(runs) == 1 and len(commands) == len(set(commands)) else 1)
PY
ok "settings.json runs style-inject.sh once, at every subagent start, and no hook there twice"

echo "ALL PASS"
