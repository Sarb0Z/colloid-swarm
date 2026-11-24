#!/usr/bin/env bash
# Firing tests for the fan-out record (spec Unit 2.4, ruling R4, acceptance
# row 12): the lead's read-only cells record themselves in the run
# fanout-<session> through the parallel-writers gate's PostToolUse Agent and
# SubagentStop events, with no controller command from the lead.
# Seam: the gate and the real controller in a scratch repository, fed Claude
# Code's normalized payloads; it catches a cell not recorded, one recorded that
# should not be, one never marked returned, and a failure that blocks, and
# misses the order in which a live Claude Code fires the two events.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(cd "$(mktemp -d)" && pwd -P)"
trap 'chmod -R u+w "$scratch" 2>/dev/null; rm -rf "$scratch"' EXIT
fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
ok() { printf 'ok    %s\n' "$*"; }

fx="$scratch/fx"
mkdir -p "$fx/.agents/hooks/policy" "$fx/.agents/hooks/lib" "$fx/.agents/skills/workloop"
git init -q "$fx"; git -C "$fx" -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
cp "$repo/.agents/hooks/policy/parallel-writers-gate.sh" "$fx/.agents/hooks/policy/"
cp "$repo"/.agents/hooks/lib/*.py "$fx/.agents/hooks/lib/"
cp "$repo"/.agents/workloop*.py "$fx/.agents/"
cp "$repo/.agents/skills/workloop/working-practice.md" "$fx/.agents/skills/workloop/"
printf '{"hooks":{"parallel_writers":{"enabled":true}}}\n' > "$fx/.agents/config.json"
gate="$fx/.agents/hooks/policy/parallel-writers-gate.sh"
transcripts="$scratch/transcripts"
state="$fx/.agents/.workloop-state.json"

fire() {  # key=value ... -> stdout; stderr lands in $scratch/err
  local args=(--arg project_dir "$fx" --arg session_id s1 --arg transcript_path "$transcripts/s1.jsonl") pair
  for pair in "$@"; do args+=(--arg "${pair%%=*}" "${pair#*=}"); done
  jq -nc "${args[@]}" '$ARGS.named
    | .tool_input = ({subagent_type, prompt} | with_entries(select(.value != null)))
    | del(.subagent_type, .prompt)' | bash "$gate" 2>"$scratch/err"
}
dispatched() {  # <tool_use_id> <subagent_type> <prompt> <agent_status>
  fire event=PostToolUse tool_name=Agent tool_use_id="$1" subagent_type="$2" prompt="$3" agent_status="$4"
}
stopped() {  # <agent_id> <tool_use_id>: Claude Code's metadata names the dispatch
  mkdir -p "$transcripts/s1/subagents"
  printf '{"agentType":"general-purpose","description":"d","toolUseId":"%s"}\n' "$2" > "$transcripts/s1/subagents/agent-$1.meta.json"
  fire event=SubagentStop agent_id="$1" agent_type=general-purpose
}
cells() {  # <state> -> how many cells of fanout-s1 are in it
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sum(1 for c in d["runs"].get("fanout-s1",{}).get("cells",{}).values() if c["state"]==sys.argv[2]))' "$state" "$1"
}

for n in 1 2 3; do
  [[ -z "$(dispatched "toolu_0$n" general-purpose "READ-ONLY: read part $n" async_launched)" ]] || fail "a READ-ONLY dispatch's record printed output"
done
status_out="$(python3 "$fx/.agents/workloop.py" --state "$state" status fanout-s1 2>&1)" || fail "status fanout-s1 failed: $status_out"
[[ "$(cells out)" -eq 3 && "$(grep -c 'cell out' <<<"$status_out")" -eq 3 ]] || fail "row 12: status fanout-s1 does not list 3 cells out: $status_out"
for n in 1 2 3; do stopped "a$n" "toolu_0$n" >/dev/null; done
[[ "$(cells returned)" -eq 3 && "$(cells out)" -eq 0 ]] || fail "row 12: the 3 cells are not all returned after SubagentStop: $(cat "$state")"
ok "row 12: three READ-ONLY cells and no controller command: status fanout-s1 lists 3 cells, all returned once they stop"

before=$fails
dispatched toolu_04 Explore "find the config loader" completed >/dev/null
dispatched toolu_05 reviewer "review the diff" async_launched >/dev/null
dispatched toolu_06 researcher "NOTES-ONLY: inventory vendors" async_launched >/dev/null
python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["runs"]["fanout-s1"]["cells"]
assert c["toolu_04"]["state"] == "returned", c["toolu_04"]
assert c["toolu_05"]["role"] == "review" and c["toolu_05"]["state"] == "out", c["toolu_05"]
assert c["toolu_06"]["role"] == "research", c["toolu_06"]' "$state" || fail "a reading persona's or NOTES-ONLY cell was recorded wrongly"
[[ "$fails" -eq "$before" ]] && ok "a foreground reading persona is recorded returned at once; a reviewer is a review cell, a NOTES-ONLY one research"

before=$fails
dispatched toolu_07 implementer "change the module" completed >/dev/null
dispatched toolu_08 general-purpose "READ-ONLY — this cell reads the checkout and writes nothing; its result is its reply.
WORKLOOP CELL BRIEF — r/scout
Read the full brief at $fx/.agents/worktrees/r/.workloop/cells/scout.md" async_launched >/dev/null
fire event=PostToolUse tool_name=Agent tool_use_id=toolu_09 agent_id=a7 subagent_type=explorer prompt=look agent_status=completed >/dev/null
python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["runs"]["fanout-s1"]["cells"]
assert not {"toolu_07", "toolu_08", "toolu_09"} & set(c), sorted(c)' "$state" || fail "a writer, a briefed cell or a cell's own dispatch was recorded in the fan-out"
stopped a7 toolu_07 >/dev/null
[[ -z "$(<"$scratch/err")" ]] || fail "a writer's SubagentStop reported: $(<"$scratch/err")"
[[ "$fails" -eq "$before" ]] && ok "a writer, a dispatch carrying a WORKLOOP brief, and a cell's own dispatch are not recorded"

before=$fails
chmod a-w "$fx/.agents"
out="$(dispatched toolu_10 explorer "look" async_launched)" && rc=0 || rc=$?
chmod u+w "$fx/.agents"
[[ "$rc" -eq 0 && -z "$out" && "$(<"$scratch/err")" == *"fan-out record was not updated"* ]] \
  || fail "a failed record write blocked or went silent: exit $rc, '$out', '$(<"$scratch/err")'"
[[ "$fails" -eq "$before" ]] && ok "a record that cannot be written is reported on stderr and blocks nothing"

[[ "$fails" -eq 0 ]] || { printf '%s fan-out record rows failed\n' "$fails" >&2; exit 1; }
printf '\nall fan-out record tests passed\n'
