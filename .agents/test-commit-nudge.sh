#!/usr/bin/env bash
# Firing tests for the commit nudge: a lane's writer whose edits have sat
# uncommitted over 30 minutes hears one COMMIT: line at its next tool batch
# (commit_nudge.py, run by workloop-inbox.sh); a cell with no lane and the lead
# never do. Edits are dated by fixture transcript records, so nothing waits.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

dir="$scratch/fixture"
mkdir -p "$dir/.agents/hooks/policy" "$dir/.agents/hooks/lib" "$scratch/home" "$scratch/project/s1/subagents"
cp "$repo/.agents/hooks/policy/workloop-inbox.sh" "$dir/.agents/hooks/policy/"
cp "$repo/.agents/hooks/lib/config.py" "$repo/.agents/hooks/lib/emit-context.py" "$repo/.agents/hooks/lib/workloop-inbox.py" "$repo/.agents/hooks/lib/commit_nudge.py" "$repo/.agents/hooks/lib/agent_activity.py" "$repo/.agents/hooks/lib/agent_silence.py" "$repo/.agents/hooks/lib/readout.py" "$repo/.agents/hooks/lib/workloop_size.py" "$repo/.agents/hooks/lib/worktree_records.py" "$repo"/.agents/hooks/lib/agent_{deaths,effects,records,sessions,verdicts,leftovers,dismissals,waits}.py "$dir/.agents/hooks/lib/"
cp "$repo/.agents/workloop_docker.py" "$dir/.agents/"
export HOME="$scratch/home"
unset CLAUDE_CONFIG_DIR
git -C "$dir" init -q
git -C "$dir" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
printf '.agents/\n' > "$dir/.gitignore"
mkdir -p "$dir/src"
policy="$dir/.agents/hooks/policy/workloop-inbox.sh"
state="$dir/.agents/.workloop-state.json"
config="$dir/.agents/config.json"
transcript_path="$scratch/project/s1.jsonl"
printf '{"hooks":{"workloop_inbox":{"enabled":true},"commit_nudge":{"enabled":true}}}\n' > "$config"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$state" <<EOF
{"version":1,"runs":{"r1":{"objective":"o","repo":"$dir","lanes":{
  "w1":{"state":"active","claimed_by":"w1","claimed_at":"$now","heartbeat_at":"$now","attention":null,"env":"ready","place":"main"},
  "w2":{"state":"active","claimed_by":"w2","claimed_at":"$now","heartbeat_at":"$now","attention":null,"env":"ready","place":"main"}},
 "messages":[],"integration":null}}}
EOF

# edit <agent> <file> <minutes ago> [tool]: the agent's transcript gains an edit call dated so long ago.
edit() {
  python3 - "$scratch/project/s1/subagents/agent-$1.jsonl" "$2" "$3" "${4:-Edit}" <<'PY'
import json, sys, time
path, target, minutes, tool = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() - minutes * 60)) + ".000Z"
record = {"type": "assistant", "timestamp": stamp, "cwd": "/",
          "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "t", "name": tool, "input": {"file_path": target}}]}}
open(path, "a").write(json.dumps(record, separators=(",", ":")) + "\n")
PY
}
fire() {  # <agent id or empty> -> the nudge's context, or nothing; stderr goes to $scratch/err
  local out
  out="$(printf '{"project_dir":"%s","event":"PostToolBatch","session_id":"s1","agent_id":"%s","transcript_path":"%s"}' "$dir" "$1" "$transcript_path" | bash "$policy" 2>"$scratch/err")"
  [[ -z "$out" ]] || python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' <<<"$out"
}
# rewind <agent>: the last nudge happened 31 minutes ago.
rewind() {
  python3 - "$dir/.agents/.readout/.commit-nudge-$1" <<'PY'
import json, sys, time
p = sys.argv[1]; s = json.load(open(p)); s["last_nudge"] = time.time() - 31 * 60; json.dump(s, open(p, "w"))
PY
}
expect_none() { [[ -z "$1" ]] || fail "$2: heard $1"; [[ ! -s "$scratch/err" ]] || fail "$2: stderr: $(cat "$scratch/err")"; }

# 1. 31 minutes old and uncommitted: one COMMIT: line.
printf 'a\n' > "$dir/src/a.txt"; printf 'b\n' > "$dir/src/b.txt"
edit w1 "$dir/src/a.txt" 31
edit w1 "$dir/src/b.txt" 5
got="$(fire w1)"
since="$(python3 -c 'import time; print(time.strftime("%H:%M", time.localtime(time.time() - 31 * 60)))')"
[[ "$got" == "COMMIT: 2 of your edited files have been uncommitted since $since (31 min). Commit each piece whose acceptance passes, staging by path." ]] \
  || fail "1: the nudge read '$got' (stderr: $(cat "$scratch/err"))"
ok "a lane writer whose oldest uncommitted edit is 31 minutes old hears one COMMIT: line"

# 2. Not again within 30 minutes.
expect_none "$(fire w1)" "2: a repeat within 30 minutes"
ok "no second COMMIT: line within 30 minutes"

# 3. After 30 minutes it is due again while the files stay uncommitted.
rewind w1
[[ "$(fire w1)" == "COMMIT: 2 of your edited files"* ]] || fail "3: no nudge 31 minutes after the last"
ok "the line comes again once 30 minutes have passed"

# 4. Committed files drop out.
git -C "$dir" add -- src/a.txt src/b.txt
git -C "$dir" -c user.name=t -c user.email=t@t commit -q -m pieces
rewind w1
expect_none "$(fire w1)" "4: after the files were committed"
ok "none once those files are committed"

# 5. An edit younger than 30 minutes, and one outside the lane's tree, are not nudged.
printf 'c\n' > "$dir/src/c.txt"; printf 'x\n' > "$scratch/outside.txt"
edit w1 "$dir/src/c.txt" 20
edit w1 "$scratch/outside.txt" 90
expect_none "$(fire w1)" "5: a 20-minute edit or a file outside the tree"
ok "an edit under 30 minutes old and a file outside the lane's tree draw none"

# 6. Toggle off: the same stale edit is quiet; on again, it speaks.
printf 'd\n' > "$dir/src/d.txt"
edit w2 "$dir/src/d.txt" 40
printf '{"hooks":{"workloop_inbox":{"enabled":true},"commit_nudge":{"enabled":false}}}\n' > "$config"
expect_none "$(fire w2)" "6: with hooks.commit_nudge.enabled false"
printf '{"hooks":{"workloop_inbox":{"enabled":true},"commit_nudge":{"enabled":true}}}\n' > "$config"
[[ "$(fire w2)" == "COMMIT: 1 of your edited files"*"(40 min)."* ]] || fail "6: the toggle on again did not nudge: $(fire w2)"
ok "hooks.commit_nudge.enabled false silences it, and on it speaks"

# 7. A cell with no lane, and the lead.
edit w9 "$dir/src/d.txt" 90
expect_none "$(fire w9)" "7: a cell with no lane"
expect_none "$(fire '')" "7: the lead"
ok "a cell with no lane and the lead hear none"

# 8. An api-request-blob record copies an earlier request, edit call included, with no timestamp: it is no edit and no failure.
printf 'f\n' > "$dir/src/f.txt"
printf '%s\n' '{"type":"api-request-blob","hash":"h","message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"Edit","input":{"file_path":"'"$dir"'/src/f.txt"}}]}}' >> "$scratch/project/s1/subagents/agent-w1.jsonl"
rewind w1
expect_none "$(fire w1)" "8: an api-request-blob record without a timestamp"
ok "a timestamp-less api-request-blob record is neither an edit nor a failure"

# 9. A failure in the nudge goes to stderr and the hook's other output stays.
printf 'e\n' > "$dir/src/e.txt"
edit w1 "$dir/src/e.txt" 60
rewind w1
printf 'not json\n' > "$dir/.agents/.readout/.commit-nudge-w1"
out="$(printf '{"project_dir":"%s","event":"PostToolBatch","session_id":"s1","agent_id":"w1","transcript_path":"%s"}' "$dir" "$transcript_path" | bash "$policy" 2>"$scratch/err")" \
  || fail "8: the hook exited non-zero"
[[ -z "$out" && "$(cat "$scratch/err")" == *"commit_nudge: w1 gets no commit reminder"* ]] || fail "8: out='$out' err='$(cat "$scratch/err")'"
ok "a failing nudge reports on stderr and the hook exits 0"
