#!/usr/bin/env bash
# Firing tests for workloop-authority.sh: a cell (a payload with agent_id) may
# not run workloop.py review … --ruling, widen or share; the lead may, and a
# cell's other controller commands pass (spec Unit 2.5, acceptance row 19).
# Seam: Claude Code's payload through the real adapter, normalizer and policy,
# as settings.json registers it (`--agent subagent`); it catches a selector
# that skips cells, a normalizer that drops the command or agent_id, and a
# parse that misses a spelling, and misses a controller run from a script.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
ok() { printf 'ok    %s\n' "$*"; }

fx="$scratch/fx"
mkdir -p "$fx/.agents/claude" "$fx/.agents/hooks/policy" "$fx/.agents/hooks/lib"
cp "$repo/.agents/claude/adapter.sh" "$repo/.agents/claude/normalize-hook.py" "$fx/.agents/claude/"
cp "$repo/.agents/hooks/policy/workloop-authority.sh" "$fx/.agents/hooks/policy/"
cp "$repo/.agents/hooks/lib/guard-destructive.py" "$repo/.agents/hooks/lib/write_targets.py" "$fx/.agents/hooks/lib/"

# The registration's selector, read from settings.json so the test runs what ships.
selector="$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | select(contains("workloop-authority.sh"))' \
  "$repo/.agents/claude/settings.json" | sed -E 's/.*adapter\.sh" (.*)workloop-authority\.sh$/\1/')"
[[ "$selector" == "--agent subagent " ]] || fail "settings.json registers workloop-authority.sh on Bash with '$selector', not '--agent subagent'"

fire() {  # <agent_id or -> <command> -> exit code; stderr in $scratch/err
  local payload
  payload="$(jq -nc --arg c "$2" --arg a "$1" '{hook_event_name:"PreToolUse",session_id:"s1",tool_name:"Bash",tool_input:{command:$c}}
    + (if $a == "-" then {} else {agent_id:$a, agent_type:"implementer"} end)')"
  bash "$fx/.agents/claude/adapter.sh" --agent subagent workloop-authority.sh <<<"$payload" >/dev/null 2>"$scratch/err" && return 0 || return $?
}

refused=(
  ".agents/workloop.py review run lane --reference r.md#1 --result accept --tip abc --ruling x"
  "python3 .agents/workloop.py --state /x/.agents/.workloop-state.json review run lane --ruling='past the cap'"
  ".agents/workloop.py widen run lane --also src/new"
  "cd /x && python3 -u /x/.agents/workloop.py --state /x/s.json share run docs/shared.md"
  "COLLOID_RUN=r .agents/workloop.py widen run lane --also y"
  "bash -c '.agents/workloop.py share run a.md'"
)
for command in "${refused[@]}"; do
  rc=0; fire a1b2 "$command" || rc=$?
  [[ "$rc" -eq 2 && "$(<"$scratch/err")" == *"the lead's"* ]] || fail "a cell's '$command' was not refused (exit $rc, '$(<"$scratch/err")')"
  rc=0; fire - "$command" || rc=$?
  [[ "$rc" -eq 0 ]] || fail "the lead's '$command' was refused (exit $rc, '$(<"$scratch/err")')"
done
[[ "$fails" -eq 0 ]] && ok "row 19: a cell's review --ruling, widen and share are refused in every spelling; the lead's same commands run"

before=$fails
for command in ".agents/workloop.py review run lane --reference r.md#1 --result accept --tip abc" \
               ".agents/workloop.py --state /x/s.json submit run lane --evidence 'tests pass'" \
               ".agents/workloop.py claim run lane --agent a1b2" \
               "echo widen share --ruling" "git log --grep=widen"; do
  rc=0; fire a1b2 "$command" || rc=$?
  [[ "$rc" -eq 0 ]] || fail "a cell's '$command' was refused (exit $rc, '$(<"$scratch/err")')"
done
[[ "$fails" -eq "$before" ]] && ok "a cell's other controller commands, and commands that only name the words, pass"

[[ "$fails" -eq 0 ]] || { printf '%s workloop-authority rows failed\n' "$fails" >&2; exit 1; }
printf '\nall workloop-authority tests passed\n'
