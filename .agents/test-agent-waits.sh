#!/usr/bin/env bash
# Firing tests for the agents that wait on the operator (hooks/lib/agent_waits.py):
# the PermissionRequest hook fired through the adapter command settings.json
# registers, with a payload shaped as Claude Code 2.1.322 sends it, and the
# WAITING ON YOU lines the lead's prompt and session start then print, from a
# fixture store under a scratch home. They miss a change in Claude Code's real
# payload or job records; the plan's live run catches that.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR
unset CLAUDE_CONFIG_DIR CLAUDE_PROJECT_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }
export HOME="$scratch/home"

# The fixture checkout: a Git repository whose hooks and adapter are this
# repository's own, reached by links, so the hook's record lands in the fixture.
fx="$scratch/checkout"
mkdir -p "$fx/.agents" "$fx/.claude/hooks"
git -C "$fx" init -q -b main
ln -s "$repo/.agents/hooks" "$fx/.agents/hooks"
ln -s "$repo/.agents/claude" "$fx/.agents/claude"
ln -s ../../.agents/claude/adapter.sh "$fx/.claude/hooks/adapter.sh"
waits="$fx/.agents/.readout/.agent-waits"

# A Claude Code store under the home: the session registry names two live
# sessions, this shell's own process as `own` and as `other`.
project="$HOME/.claude/projects/-fixture"
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/jobs" "$project"
register() {  # <session id> <pid>
  python3 - "$HOME/.claude/sessions/$2-$1.json" "$1" "$2" "$(LC_ALL=C TZ=UTC ps -o lstart= -p "$2" | awk '{$1=$1};1')" <<'PY'
import json, sys, time
path, session, pid, start = sys.argv[1:]
json.dump({"pid": int(pid), "sessionId": session, "cwd": "/", "procStart": start,
           "startedAt": int((time.time() - 3600) * 1000), "kind": "interactive"}, open(path, "w"))
PY
}
register own $$
register other $$

# An agent of session `other` whose transcript ends on the Bash call that asked for permission.
agent() {  # <session> <agent id> <description>
  mkdir -p "$project/$1/subagents"
  python3 - "$project/$1/subagents" "$2" "$3" <<'PY'
import json, sys, time
folder, aid, description = sys.argv[1:]
stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() - 5)) + ".000Z"
call = {"type": "assistant", "timestamp": stamp, "cwd": "/", "agentId": aid,
        "message": {"role": "assistant", "stop_reason": "tool_use",
                    "content": [{"type": "tool_use", "id": "toolu_1", "name": "Bash", "input": {"command": "touch prompted.txt"}}]}}
open(f"{folder}/agent-{aid}.jsonl", "w").write(json.dumps(call, separators=(",", ":")) + "\n")
json.dump({"agentType": "general-purpose", "description": description, "requestShape": "background"},
          open(f"{folder}/agent-{aid}.meta.json", "w"))
PY
}
# The agent's next record: the tool's result once the operator answered.
answered() {  # <session> <agent id>
  python3 - "$project/$1/subagents/agent-$2.jsonl" <<'PY'
import json, sys, time
stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() + 1)) + ".000Z"
record = {"type": "user", "timestamp": stamp, "cwd": "/",
          "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_1", "content": ""}]}}
open(sys.argv[1], "a").write(json.dumps(record, separators=(",", ":")) + "\n")
PY
}

# The PermissionRequest command exactly as settings.json registers it, fed S8's payload shape.
hook_command="$(jq -r '.hooks.PermissionRequest[0].hooks[0].command' "$repo/.agents/claude/settings.json")"
[[ "$hook_command" == *"adapter.sh\" --agent subagent agent-waits.sh" ]] || fail "settings.json registers no PermissionRequest hook running agent-waits.sh: $hook_command"
payload() {  # <session> <agent id or empty> <command>
  python3 - "$@" "$project" "$fx" <<'PY'
import json, sys
session, aid, command, project, cwd = sys.argv[1:]
body = {"agent_id": aid, "agent_type": "general-purpose", "hook_event_name": "PermissionRequest", "tool_name": "Bash",
        "tool_input": {"command": command, "description": "Create prompted.txt"},
        "permission_suggestions": [{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "touch:*"}],
                                    "behavior": "allow", "destination": "localSettings"}],
        "permission_mode": "default", "session_id": session, "transcript_path": f"{project}/{session}.jsonl", "cwd": cwd}
if not aid:
    del body["agent_id"], body["agent_type"]
print(json.dumps(body))
PY
}
fire() {  # <payload> -> the hook's stdout; its stderr goes to $scratch/hook.err
  (cd "$fx" && CLAUDE_PROJECT_DIR="$fx" bash -c "$hook_command" <<<"$1" 2>"$scratch/hook.err")
}
prompt_block() { python3 "$repo/.agents/hooks/lib/workloop-inbox.py" "$fx/.agents/.workloop-state.json" "$fx/.agents" own UserPromptSubmit "" 2>/dev/null; }
start_block() { python3 "$repo/.agents/hooks/lib/workloop-inbox.py" "$fx/.agents/.workloop-state.json" "$fx/.agents" own SessionStart "" startup claude 2>/dev/null; }

# ── 1. the hook fires through the adapter, decides nothing, and the wait shows ──
agent other a7d21c0abf1f8d03b "Create the prompted file"
out="$(fire "$(payload other a7d21c0abf1f8d03b 'touch prompted.txt')")" || fail "the hook exited non-zero"
[[ -z "$out" ]] || fail "the hook printed to stdout, which Claude Code would read as a decision: $out"
[[ -f "$waits" ]] || fail "the hook recorded no wait: $(cat "$scratch/hook.err")"
expected='WAITING ON YOU: "Create the prompted file" (a7d21c0abf1f8d03b) Bash: touch prompted.txt'
[[ "$(prompt_block)" == *"$expected"* ]] || fail "the lead's prompt did not name the waiting agent: $(prompt_block)"
[[ "$(start_block)" == *"$expected"* ]] || fail "a session start did not name the waiting agent: $(start_block)"
ok "the PermissionRequest hook, fired through the adapter, prints nothing and the agent shows waiting at a prompt and a start"

# ── 2. a newer record of the agent's closes the wait ──
answered other a7d21c0abf1f8d03b
[[ "$(prompt_block)" != *"WAITING ON YOU"* ]] || fail "an answered prompt still shows: $(prompt_block)"
[[ "$(jq -r 'keys | length' "$waits")" == 0 ]] || fail "the closed wait was left in the record: $(cat "$waits")"
ok "a record the agent wrote after the request closes its wait and drops it"

# ── 3. the session's end closes the wait ──
agent other a2 "Second task"
fire "$(payload other a2 'rm -rf build')" >/dev/null
[[ "$(prompt_block)" == *'WAITING ON YOU: "Second task" (a2) Bash: rm -rf build'* ]] || fail "the second agent does not show waiting: $(prompt_block)"
rm "$HOME/.claude/sessions/$$-other.json"
[[ "$(prompt_block)" != *"WAITING ON YOU"* ]] || fail "a wait of an ended session still shows: $(prompt_block)"
register other $$
ok "a wait closes when its session ends"

# ── 4. the lead's own prompt is not kept ──
: > "$scratch/hook.err"
rm -f "$waits"
(cd "$fx" && payload own "" 'touch lead.txt' | CLAUDE_PROJECT_DIR="$fx" bash "$repo/.agents/hooks/policy/agent-waits.sh" 2>"$scratch/hook.err")
[[ ! -s "$waits" ]] || fail "a payload with no agent id was recorded: $(cat "$waits")"
[[ ! -s "$scratch/hook.err" ]] || fail "a payload with no agent id was taken for a failure: $(cat "$scratch/hook.err")"
ok "a payload with no agent id is passed over quietly, not recorded"

# ── 5. a failure is reported on stderr, never as a decision ──
err="$( (cd "$fx" && printf '{"agent_id":"a3","tool_name":"Bash"}' | bash "$repo/.agents/hooks/policy/agent-waits.sh") 2>&1 >/dev/null)" || fail "the hook exited non-zero on a payload with no session"
[[ "$err" == *"recording the agent waiting on this permission prompt failed"* ]] || fail "the failure was not named on stderr: $err"
ok "a payload the hook cannot record exits 0 and names the failure on stderr"

# ── 6. a blocked background session shows with its needs and claude attach ──
# 2.1.322 holds a session on a permission prompt at state working, tempo blocked, with
# its needs (observed live); earlier versions wrote state blocked.
job() {  # <job id> <state> <tempo> <session> <cwd> [needs]
  mkdir -p "$HOME/.claude/jobs/$1"
  python3 - "$HOME/.claude/jobs/$1/state.json" "$@" <<'PY'
import json, sys
path, job, state, tempo, session, cwd, *needs = sys.argv[1:]
data = {"state": state, "detail": "asked", "tempo": tempo, "name": f"Job {job}", "sessionId": session,
        "resumeSessionId": session, "daemonShort": job, "cwd": cwd, "worktreePath": None, "template": "bg"}
if needs:
    data["needs"] = needs[0]
json.dump(data, open(path, "w"))
PY
}
job bb000001 working blocked other "$fx/sub" "approve Bash: touch bg.txt && ls -l bg.txt"
job bb000005 blocked idle other "$fx" "which one?"
job bb000002 blocked blocked gone-session "$fx" "approve Bash: ls"
job bb000003 working blocked other "$scratch/elsewhere" "not this checkout"
job bb000004 working active other "$fx"
block="$(prompt_block)"
[[ "$block" == *'WAITING ON YOU: "Job bb000001" (bb000001) approve Bash: touch bg.txt && ls -l bg.txt; claude attach bb000001'* ]] \
  || fail "the background session held on a prompt in this checkout was not named with its needs and attach command: $block"
[[ "$block" == *'WAITING ON YOU: "Job bb000005" (bb000005) which one?; claude attach bb000005'* ]] \
  || fail "a job that reads state blocked was not named: $block"
[[ "$block" != *bb000002* ]] || fail "a blocked job whose session no longer runs was shown: $block"
[[ "$block" != *bb000003* ]] || fail "a blocked job of another checkout was shown: $block"
[[ "$block" != *bb000004* ]] || fail "a working job was shown: $block"
job bb000001 working active other "$fx/sub"
[[ "$(prompt_block)" != *bb000001* ]] || fail "an answered background session still shows: $(prompt_block)"
ok "a blocked background session of this checkout shows its needs and claude attach, and goes once answered"
