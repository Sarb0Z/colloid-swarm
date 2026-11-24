#!/usr/bin/env bash
# Firing tests for the workloop-inbox policy: a cell hears its host id at
# start and its lane's unread messages between tool calls, once each; the
# lead hears a digest of what needs them.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

dir="$scratch/fixture"
mkdir -p "$dir/.agents/hooks/policy" "$dir/.agents/hooks/lib"
cp "$repo/.agents/hooks/policy/workloop-inbox.sh" "$dir/.agents/hooks/policy/"
cp "$repo/.agents/hooks/lib/config.py" "$repo/.agents/hooks/lib/emit-context.py" "$repo/.agents/hooks/lib/workloop-inbox.py" "$repo/.agents/hooks/lib/commit_nudge.py" "$repo/.agents/hooks/lib/agent_activity.py" "$repo/.agents/hooks/lib/agent_silence.py" "$repo/.agents/hooks/lib/readout.py" "$repo/.agents/hooks/lib/workloop_size.py" "$repo/.agents/hooks/lib/worktree_records.py" "$repo/.agents/hooks/lib/process_start.py" "$repo"/.agents/hooks/lib/agent_{deaths,effects,records,sessions,verdicts,leftovers,dismissals,waits}.py "$dir/.agents/hooks/lib/"
cp "$repo/.agents/workloop_docker.py" "$dir/.agents/"
mkdir -p "$scratch/bin" "$scratch/home"
# The death reader reads Claude Code's store under the home and asks ps when a
# registered session started: a fixture home, and a ps that reports the starts
# listed in $PS_STARTS (`<pid>\t<start>`) and passes every other call through.
export HOME="$scratch/home" PS_STARTS="$scratch/ps-starts"
unset CLAUDE_CONFIG_DIR
: > "$PS_STARTS"
real_ps="$(command -v ps)"
cat > "$scratch/bin/ps" <<EOF
#!/usr/bin/env bash
if [[ "\$1 \$2 \$3" == "-o lstart= -p" ]]; then
  start="\$(awk -F '\t' -v pid="\$4" '\$1 == pid { print \$2 }' "\$PS_STARTS")"
  [[ -n "\$start" ]] && { printf '%s\n' "\$start"; exit 0; }
  exit 1
fi
exec "$real_ps" "\$@"
EOF
chmod +x "$scratch/bin/ps"
cat > "$scratch/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
case "$*" in
  "ps -aq --filter label=colloid.run=r1 --filter label=colloid.lane=db") printf 'dead1\n' ;;
  "ps --filter label=org.testcontainers=true --format "*) printf 'lonely_pg\tabc12345-0000\t20 minutes ago\n' ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$scratch/bin/docker"; export PATH="$scratch/bin:$PATH" DOCKER_LOG="$scratch/docker.log"
printf '{"hooks":{"workloop_inbox":{"enabled":true}}}\n' > "$dir/.agents/config.json"
policy="$dir/.agents/hooks/policy/workloop-inbox.sh"
state="$dir/.agents/.workloop-state.json"

fire() {  # <event> <agent_id> -> stdout
  printf '{"project_dir":"%s","event":"%s","session_id":"s1","agent_id":"%s"}' "$dir" "$1" "$2" | bash "$policy"
}
context() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["hookSpecificOutput"]["additionalContext"])' <<<"$1"; }

# no state file: silent everywhere
[[ -z "$(fire SubagentStart a1)" && -z "$(fire UserPromptSubmit '')" ]] || fail "spoke with no workloop state"
ok "silent without a workloop state file"

# with no run, dispatches outside any run are not counted at the lead's prompt:
# read-only cells record themselves in a fan-out run (fanout_record.py), so
# the digest has no "cells last turn outside any run" note (spec F9)
[[ -z "$(fire UserPromptSubmit '')" ]] || fail "the lead's prompt spoke with no run"
ok "the lead's prompt carries no note about dispatches outside any run"

# with no state, a subagent's tool batch parses its payload and stops
mkdir -p "$scratch/pybin"
printf '#!/usr/bin/env bash\nprintf "start\\n" >> "%s"\nexec "%s" "$@"\n' "$scratch/python3.log" "$(command -v python3)" > "$scratch/pybin/python3"
chmod +x "$scratch/pybin/python3"
out="$(printf '{"project_dir":"%s","event":"PostToolBatch","session_id":"s1","agent_id":"a9"}' "$dir" | PATH="$scratch/pybin:$PATH" bash "$policy")"
[[ -z "$out" ]] || fail "a subagent's tool batch spoke with no state: $out"
[[ "$(wc -l < "$scratch/python3.log" | tr -d ' ')" == 1 ]] || fail "a subagent's tool batch with no state started $(wc -l < "$scratch/python3.log" | tr -d ' ') interpreters, not one"
ok "a subagent's tool batch with no state prints nothing and starts one interpreter"

old="$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$state" <<EOF
{"version":1,"runs":{
 "r1":{"objective":"o","supervised":true,"lanes":{
   "api":{"state":"active","claimed_by":"a1","claimed_at":"$now","heartbeat_at":"$now","attention":null,"env":"ready"},
   "web":{"state":"review","claimed_by":"a2","claimed_at":"$old","heartbeat_at":"$old","attention":null,"env":"ready"},
   "db":{"state":"active","claimed_by":"a3","claimed_at":"$old","heartbeat_at":"$old","attention":{"severity":"P0","message":"stop"},"env":"broken"}},
  "messages":[
   {"id":"m1","from":"web","to":"api","agent":"a2","kind":"finding","message":"validate ids","reference":"docs/r.md#ids","requires_ack":true},
   {"id":"m2","from":"web","to":"api","agent":"a2","kind":"status","message":"progress","reference":"","requires_ack":false},
   {"id":"m3","from":"api","to":"web","agent":"a1","kind":"finding","message":"for web","reference":"","requires_ack":true,"acknowledged_at":"$now"}],
  "integration":null},
 "done":{"objective":"o","torn_down":{"at":"$now"},"lanes":{"x":{"state":"review","claimed_by":"a1"}},"messages":[]}
}}
EOF

# a cell hears its id at start, and its lane's unread messages
out="$(fire SubagentStart a1)"; ctx="$(context "$out")"
[[ "$ctx" == *"AGENT_ID: a1"* && "$ctx" == *"--agent a1"* ]] || fail "start did not name the host id: $ctx"
[[ "$ctx" == *"WORKLOOP MESSAGE r1/api from web [finding]: validate ids (docs/r.md#ids)"* && "$ctx" == *"ack-message r1 api m1 --agent a1"* ]] || fail "unread finding not delivered: $ctx"
[[ "$ctx" == *"[status]: progress"* ]] || fail "unread status not delivered"
[[ "$ctx" != *"for web"* ]] || fail "another lane's message leaked"
ok "a cell hears its host id and its lane's unread messages at start"

# once delivered, a message is not repeated; a new one is
[[ -z "$(fire PostToolBatch a1)" ]] || fail "delivered messages were repeated"
python3 - "$state" <<'EOF'
import json, sys
p = sys.argv[1]; s = json.load(open(p))
s["runs"]["r1"]["messages"].append({"id":"m4","from":"web","to":"api","agent":"a2","kind":"blocked","message":"need schema","reference":"","requires_ack":True})
json.dump(s, open(p, "w"))
EOF
ctx="$(context "$(fire PostToolBatch a1)")"
[[ "$ctx" == *"[blocked]: need schema"* && "$ctx" != *"validate ids"* ]] || fail "new message not delivered once: $ctx"
[[ -z "$(fire PostToolBatch a1)" ]] || fail "second delivery repeated"
ok "each message is delivered once, between tool calls"

# a cell with no lane to claim hears nothing; once a lane is ready it hears its id
[[ -z "$(fire SubagentStart zz)" ]] || fail "a cell with nothing to claim was told an id"
python3 - "$state" <<'EOF'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["runs"]["r1"]["lanes"]["spare"] = {"state":"ready","attention":None,"env":"ready"}; json.dump(s, open(p, "w"))
EOF
ctx="$(context "$(fire SubagentStart zz)")"
[[ "$ctx" == *"AGENT_ID: zz"* && "$ctx" != *"WORKLOOP MESSAGE"* ]] || fail "a cell with a lane to claim was not told its id: $ctx"
# Spec acceptance 13: a SubagentStart hook cannot see whether the cell is the
# lane's writer or a READ-ONLY one (probe P6), so no start context tells it to
# claim; the lane's brief, which only its writer receives, does.
[[ "$ctx" != *"claim your workloop lane"* && "$ctx" != *"claim"* ]] || fail "row 13: a cell's start context tells it to claim a lane: $ctx"
[[ -z "$(fire PostToolBatch zz)" ]] || fail "unclaimed cell heard something between tools"
ok "a cell hears its id only when a lane is claimable, and no messages until it claims"

# delivery is capped; the remainder follows next time
python3 - "$state" <<'EOF'
import json, sys
p = sys.argv[1]; s = json.load(open(p))
for i in range(10):
    s["runs"]["r1"]["messages"].append({"id":f"bulk{i}","from":"web","to":"api","agent":"a2","kind":"status","message":f"bulk {i}","reference":"","requires_ack":False})
json.dump(s, open(p, "w"))
EOF
ctx="$(context "$(fire PostToolBatch a1)")"
[[ "$(grep -c 'bulk ' <<<"$ctx")" -eq 8 && "$ctx" == *"more messages wait"* ]] || fail "delivery not capped at 8: $ctx"
ctx="$(context "$(fire PostToolBatch a1)")"
[[ "$(grep -c 'bulk ' <<<"$ctx")" -eq 2 ]] || fail "remainder not delivered next time: $ctx"
ok "at most eight messages per delivery; the rest follow"

# the lead hears a digest: review, attention, stale, broken, pending acks; not the torn-down run
ctx="$(context "$(fire UserPromptSubmit '')")"
[[ "$ctx" == *"WORKLOOP r1:"* ]] || fail "no digest: $ctx"
[[ "$ctx" == *"web awaits review"* && "$ctx" == *"db carries P0"* && "$ctx" == *"db stale "* && "$ctx" == *"db environment broken"* ]] || fail "digest missing items: $ctx"
[[ "$ctx" == *"2 message(s) await acknowledgement"* ]] || fail "pending ack count wrong: $ctx"
[[ "$ctx" != *"api stale"* ]] || fail "a fresh heartbeat was called stale"
[[ "$ctx" != *"WORKLOOP done"* ]] || fail "a torn-down run was reported"
ok "the lead hears review, attention, stale, broken, and pending acknowledgements"
python3 - "$state" <<'EOF'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["runs"]["r1"]["supervised"] = False; json.dump(s, open(p, "w"))
EOF
ctx="$(context "$(fire UserPromptSubmit '')")"
[[ "$ctx" == *"db active "* && "$ctx" != *"db stale"* ]] || fail "an ordinary lane was called stale: $ctx"
python3 - "$state" <<'EOF'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["runs"]["r1"]["supervised"] = True; json.dump(s, open(p, "w"))
EOF
ok "only a supervised run reports a lane stale; an ordinary one reports elapsed time"

# the hook's stamp is a sign of life beside the heartbeat: a supervised lane stamped a
# minute ago whose last heartbeat was 15 minutes ago is not stale at the prompt
stamp_db() {  # <seconds ago, or "none">
  python3 - "$state" "$1" <<'EOF'
import json, sys, time
p, ago = sys.argv[1:3]; s = json.load(open(p)); lane = s["runs"]["r1"]["lanes"]["db"]
if ago == "none":
    lane.pop("activity_at", None)
else:
    lane["activity_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - int(ago)))
json.dump(s, open(p, "w"))
EOF
}
stamp_db 60
ctx="$(context "$(fire UserPromptSubmit '')")"
[[ "$ctx" != *"db stale"* ]] || fail "a supervised lane stamped a minute ago was called stale: $ctx"
stamp_db none
ctx="$(context "$(fire UserPromptSubmit '')")"
[[ "$ctx" == *"db stale "* ]] || fail "the same lane without a stamp was not called stale: $ctx"
ok "a supervised lane stamped a minute ago with no heartbeat for 15 minutes is not stale at the prompt"


# How each claimant and cell agent ended comes from Claude Code's own records
# (agent_deaths.py): a fixture store under the fake home, the fixture made a
# Git checkout for this block, and the reader's own session s1 registered
# with the start the fake ps reports. A claimant that finished without
# submitting has its lane's docker resources reaped by label; one that died
# keeps them for the resume, as does one that ended its turn waiting on its
# own background command and whose session then ended (E6); a cell whose
# agent died is named; foreign orphans are only named.
git -C "$dir" init -q
python3 - "$HOME" "$dir" "$PS_STARTS" <<'EOF'
import json, os, sys, time
home, repo, starts = sys.argv[1:4]
now = time.time()
project = os.path.join(home, ".claude", "projects", "-fixture")
def iso(at): return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(at))
def line(record): return json.dumps(dict(record, cwd=repo), separators=(",", ":")) + "\n"
def msg(kind, at, content, **extra): return {"type": kind, "timestamp": iso(at), "message": {"role": kind, "content": content, **extra}}
def tool(at, name, use, **extra): return msg("assistant", at, [{"type": "tool_use", "id": use, "name": name, "input": {"command": "x", **extra}}], stop_reason="tool_use")
def result(at, use, **extra): return dict(msg("user", at, [{"type": "tool_result", "tool_use_id": use}]), **extra)
ends = {
    "gone": [tool(now - 2000, "SubagentHandback", "h"), result(now - 1990, "h")],
    "adied": [dict(msg("assistant", now - 2000, [{"type": "text", "text": "API Error"}]), isApiErrorMessage=True, error="server_error", apiError="computer_slept")],
    "await": [tool(now - 2000, "Bash", "b", run_in_background=True), result(now - 1990, "b", toolUseResult={"backgroundTaskId": "b1"}),
              msg("assistant", now - 1980, [{"type": "text", "text": "waiting on the suite"}], stop_reason="end_turn")],
    "acell": [dict(msg("assistant", now - 2000, [{"type": "text", "text": "API Error"}]), isApiErrorMessage=True, error="rate_limit", apiError="usage_limit_reached")],
}
os.makedirs(os.path.join(project, "s-old", "subagents"))
for aid, records in ends.items():
    base = os.path.join(project, "s-old", "subagents", f"agent-{aid}")
    open(base + ".meta.json", "w").write(json.dumps({"agentType": "implementer", "description": f"task of {aid}", "requestShape": "background", "toolUseId": f"t-{aid}", "finished": True}))
    open(base + ".jsonl", "w").write("".join(line(r) for r in [msg("user", now - 3000, "go")] + records))
parent = os.path.join(project, "s-old.jsonl")
open(parent, "w").write(line(msg("user", now - 3000, "lead")))
for path in [parent] + [os.path.join(project, "s-old", "subagents", f"agent-{aid}.jsonl") for aid in ends]:
    os.utime(path, (now - 1200, now - 1200))
os.makedirs(os.path.join(home, ".claude", "sessions"))
open(os.path.join(home, ".claude", "sessions", "4242.json"), "w").write(json.dumps(
    {"pid": 4242, "sessionId": "s1", "cwd": repo, "procStart": "Thu Jan  1 00:00:01 2026", "startedAt": int((now - 7200) * 1000)}))
open(starts, "a").write("4242\tThu Jan  1 00:00:01 2026\n")
EOF
python3 - "$state" <<'EOF'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); r = s["runs"]["r1"]
r["lanes"]["db"] = {"state":"active","claimed_by":"gone","claimed_at":"2026-01-01T00:00:00Z","heartbeat_at":"2026-01-01T00:00:00Z","attention":None,"env":"ready","progress":"seeding"}
r["lanes"]["lost"] = {"state":"active","claimed_by":"adied","worker":"implementer","claimed_at":"2026-01-01T00:00:00Z","attention":None,"env":"ready"}
r["lanes"]["e6"] = {"state":"active","claimed_by":"await","worker":"implementer","claimed_at":"2026-01-01T00:00:00Z","attention":None,"env":"ready"}
r["lanes"]["api"]["progress"] = "e2e 12/40"
r["cells"] = {"scout": {"role": "research", "model": "haiku", "state": "out", "out_since": "2026-01-01T00:00:00Z", "agent_id": "acell"}}
json.dump(s, open(p, "w"))
EOF
: > "$DOCKER_LOG"
ctx="$(context "$(fire UserPromptSubmit '')")"
[[ "$ctx" == *"db's worker gone has stopped without submitting; reaped 1 docker resource(s)"* ]] || fail "a claimant that finished without submitting was not reported and reaped: $ctx"
grep -q 'rm -f dead1' "$DOCKER_LOG" || fail "the finished claimant's container was not removed: $(cat "$DOCKER_LOG")"
[[ "$ctx" == *"lost's worker adied died (computer_slept) without submitting: resume it, or release-stale r1 lost"* ]] || fail "a claimant that died was not named with its cause: $ctx"
[[ "$ctx" == *"e6's worker await died (session ended) without submitting"* ]] || fail "a claimant that ended its turn waiting on its own command, then lost its session, did not read as died: $ctx"
[[ "$ctx" == *"cell scout's agent died (usage_limit_reached): resume it, or brief r1 scout --again"* ]] || fail "a cell whose agent died was not named: $ctx"
[[ "$ctx" == *'AGENT DIED: "task of adied" (implementer, adied) computer_slept at'*"it holds lane r1/lost"* ]] || fail "the dead claimant's AGENT DIED line is missing: $ctx"
[[ "$ctx" == *"api"*"e2e 12/40"* ]] || fail "progress not shown beside the live lane: $ctx"
[[ "$ctx" == *"Not ours, still running with no reaper: lonely_pg (20 minutes ago, testcontainers session abc12345 with no reaper)"* ]] || fail "foreign orphan not named: $ctx"
[[ "$(grep -c 'rm -f' "$DOCKER_LOG")" -eq 1 ]] || fail "a dead claimant's lane resources were removed: $(cat "$DOCKER_LOG")"
! grep -q 'colloid.lane=lost\|colloid.lane=e6' "$DOCKER_LOG" || fail "a dead claimant's lane was reaped: $(cat "$DOCKER_LOG")"
ok "a finished claimant's lane is reaped; a dead one's, an E6 one's and a dead cell's are named with their cause and keep their resources"
rm -rf "$dir/.git" "$dir/.agents/.readout/.agent-deaths-cache"
python3 - "$state" <<'EOF'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); r = s["runs"]["r1"]
del r["lanes"]["lost"], r["lanes"]["e6"], r["cells"]
json.dump(s, open(p, "w"))
EOF

# with no run and no state file, the lead's prompt still names a dead agent of
# the checkout, here one launched from it that left an uncommitted edit
norun="$scratch/norun"
mkdir -p "$norun/.agents"; cp -R "$dir/.agents/hooks" "$dir/.agents/config.json" "$norun/.agents/"
git -C "$norun" init -q; printf 'x\n' > "$norun/x.txt"
git -C "$norun" add x.txt; git -C "$norun" -c user.name=t -c user.email=t@example.com commit -qm base; printf 'edited\n' > "$norun/x.txt"
python3 - "$HOME" "$norun" <<'EOF'
import json, os, sys, time
home, repo = sys.argv[1:3]; now = time.time()
folder = os.path.join(home, ".claude", "projects", "-norun", "s-gone", "subagents"); os.makedirs(folder)
def iso(at): return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(at))
records = [{"type": "user", "timestamp": iso(now - 3000), "cwd": repo, "message": {"role": "user", "content": "go"}},
           {"type": "assistant", "timestamp": iso(now - 2900), "cwd": repo, "message": {"role": "assistant", "stop_reason": "tool_use",
            "content": [{"type": "tool_use", "id": "e", "name": "Write", "input": {"file_path": os.path.join(repo, "x.txt"), "content": "edited"}}]}},
           {"type": "assistant", "timestamp": iso(now - 2800), "cwd": repo, "isApiErrorMessage": True, "error": "server_error", "apiError": "connection_failed",
            "message": {"role": "assistant", "content": [{"type": "text", "text": "API Error"}]}}]
open(os.path.join(folder, "agent-anorun.jsonl"), "w").write("".join(json.dumps(r, separators=(",", ":")) + "\n" for r in records))
open(os.path.join(folder, "agent-anorun.meta.json"), "w").write(json.dumps(
    {"agentType": "implementer", "description": "write x", "requestShape": "background", "toolUseId": "t", "finished": True}))
open(os.path.join(home, ".claude", "projects", "-norun", "s-gone.jsonl"), "w").write("")
EOF
out="$(printf '{"project_dir":"%s","event":"UserPromptSubmit","session_id":"s1","agent_id":""}' "$norun" | bash "$norun/.agents/hooks/policy/workloop-inbox.sh")"
ctx="$(context "$out")"
[[ "$ctx" == *'AGENT DIED: "write x" (implementer, anorun) connection_failed at'*"session s-gone (ended); 1 of its 1 edited files uncommitted in"*"\`claude --resume s-gone\`"* ]] \
  || fail "a dead agent of a checkout with no run was not shown at the prompt: $ctx"
[[ ! -e "$norun/.agents/.workloop-state.json" ]] || fail "the prompt created a workloop state file"
ok "with no run, the lead's prompt names a dead agent of the checkout with its leftovers and remedy"

# all lanes reviewed on a multi-lane run: told to integrate
python3 - "$state" <<'EOF'
import json, sys
p = sys.argv[1]; s = json.load(open(p))
for lane in s["runs"]["r1"]["lanes"].values():
    lane["state"] = "reviewed"; lane["attention"] = None; lane["env"] = "ready"
s["runs"]["r1"]["messages"] = []
json.dump(s, open(p, "w"))
EOF
ctx="$(context "$(fire UserPromptSubmit '')")"
[[ "$ctx" == *"all lanes reviewed; integrate r1"* ]] || fail "integrate prompt missing: $ctx"
ok "a run with every lane reviewed tells the lead to integrate"

# closing steps and lane size are read from state and fixture repositories
fx="$scratch/fixture-repo"
git init -q -b main "$fx"
git -C "$fx" config user.email t@example.com; git -C "$fx" config user.name t
mkdir -p "$fx/src" "$fx/other"; printf 'x\n' > "$fx/src/seed.txt"; printf 'x\n' > "$fx/other/seed.txt"
git -C "$fx" add -A; git -C "$fx" commit -q -m base
fbase="$(git -C "$fx" rev-parse HEAD)"
longago="$(date -u -v-30H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
recent="$(date -u -v-2H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)"

# put_state: runs the python script on stdin with (state path, repo, base, now, 30h ago, 2h ago)
put_state() { python3 - "$state" "$fx" "$fbase" "$now" "$longago" "$recent"; }
digest() { context "$(fire UserPromptSubmit '')"; }
has() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
lacks() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }

# closing steps: one-writer run (main lane)
put_state <<'EOF'
import json, sys
path, repo, base, now, longago, recent = sys.argv[1:7]
def run(lanes, **extra):
    r = {"objective": "o", "verify": "make test", "repo": repo, "base": base, "shared": [], "lanes": lanes,
         "messages": [], "qa": None, "integration": None, "events": [{"id": "e0", "at": recent, "action": "init", "lane": None, "detail": "o"}]}
    r.update(extra); return r
main = {"state": "reviewed", "place": "main", "workspace": repo, "branch": None, "paths": ["src"], "start": base, "tip": "t1", "accepted_tip": "t1", "attention": None, "env": "main"}
ok_v = {"at": now, "head": "t1", "lane_tips": {"solo": "t1"}, "verify": "make test", "result": "pass", "tail": "", "dirty": []}
runs = {
  "m-none": run({"solo": dict(main)}),
  "m-fail": run({"solo": dict(main)}, verified=dict(ok_v, result="fail")),
  "m-stale": run({"solo": dict(main)}, verified=dict(ok_v, lane_tips={"solo": "t0"})),
  "m-qa": run({"solo": dict(main)}, verified=ok_v),
  "m-done": run({"solo": dict(main)}, verified=ok_v, qa={"at": now, "evidence": "e"}),
  "m-open": run({"solo": dict(main, state="review", accepted_tip=None)}),
}
json.dump({"version": 1, "runs": runs}, open(path, "w"))
EOF
ctx="$(digest)"
has "$ctx" "WORKLOOP m-none: ready for QA; record it with qa m-none --evidence" "no verification: land runs it"
has "$ctx" "WORKLOOP m-fail: the composed test failed at the accepted commit; see status" "failed verification"
has "$ctx" "WORKLOOP m-stale: ready for QA; record it with qa m-stale --evidence" "stale verification: land runs it again"
has "$ctx" "WORKLOOP m-qa: ready for QA; record it with qa m-qa --evidence" "passing verification, no QA"
has "$ctx" "WORKLOOP m-done: land m-done" "QA recorded: accepted and not landed"
lacks "$ctx" "m-open: lane reviewed" "an unreviewed lane"
lacks "$ctx" "m-open: all lanes" "an unreviewed lane"
ok "a one-writer run names QA, a failed composed test, then land"

# cells still out are named with the remedy of the moment: at a prompt the lead
# records each as it returns; at a session start no cell outlives its session
put_state <<'EOF'
import json, sys
path, repo, base, now, longago, recent = sys.argv[1:7]
def run(cells, **extra):
    r = {"objective": "o", "verify": "make test", "repo": repo, "base": base, "shared": [], "lanes": {}, "cells": cells,
         "messages": [], "qa": None, "integration": None, "events": [{"id": "e0", "at": recent, "action": "init", "lane": None, "detail": "o"}]}
    r.update(extra); return r
cell = {"role": "research", "model": "opus", "state": "out", "added_at": now, "out_since": now}
runs = {
  "c-two": run({"scout": dict(cell), "critic": dict(cell), "done": dict(cell, state="returned", result="reply"), "dead": dict(cell, state="failed", reason="x")}),
  "c-one": run({"scout": dict(cell)}),
  "c-back": run({"scout": dict(cell, state="returned", result="reply")}),
  "c-fanout": run({"scout": dict(cell, state="returned", result="reply"), "dead": dict(cell, state="failed", reason="x")}, verify=None),
  "c-fanout-open": run({"scout": dict(cell)}, verify=None),
}
json.dump({"version": 1, "runs": runs}, open(path, "w"))
EOF
ctx="$(digest)"
has "$ctx" "WORKLOOP c-two: 2 cells out (critic, scout); returned c-two <name> when each comes back" "two cells out"
has "$ctx" "WORKLOOP c-one: 1 cell out (scout); returned c-one scout when it comes back" "one cell out"
lacks "$ctx" "c-back" "a run with --verify whose cell is back waits for its lane"
has "$ctx" "WORKLOOP c-fanout: every cell is back; check c-fanout, then teardown c-fanout" "a fan-out whose cells are back"
has "$ctx" "WORKLOOP c-fanout-open: 1 cell out (scout); returned c-fanout-open scout" "a fan-out with a cell out"
# the session start's call, as session-start.sh makes it: the start source follows the agent id
start_digest() { python3 "$dir/.agents/hooks/lib/workloop-inbox.py" "$state" "$dir/.agents" s1 SessionStart "" "$1"; }
for source in startup resume; do
  ctx="$(start_digest "$source")"
  has "$ctx" "WORKLOOP c-two: 2 cells out (critic, scout); no cell outlives its session: each one's AGENT DIED line says how to resume it in the session that owns it; to send it again instead, dismiss that line, then brief c-two <name> --again" "two cells out at a $source"
  has "$ctx" "its AGENT DIED line says how to resume it in the session that owns it; to send it again instead, dismiss that line, then brief c-one scout --again" "one cell out at a $source"
done
# a compaction or /clear ends no cell, so its cells keep the prompt's remedy
for source in compact clear; do
  ctx="$(start_digest "$source")"
  has "$ctx" "WORKLOOP c-two: 2 cells out (critic, scout); returned c-two <name> when each comes back" "cells out at a $source"
  lacks "$ctx" "no cell outlives its session" "a $source"
done
# a run another live session leads keeps its cells running; one this session also leads does not
records="$dir/.agents/worktrees/.records"; mkdir -p "$records"
# Stamps as the records write them, `host` and `start`, of this shell: the fake ps
# reports its start as the real one gives it. An ended session's stamp holds a
# start text and a start this shell never had.
printf '%s\t%s\n' $$ "$(LC_ALL=C TZ=UTC "$real_ps" -o lstart= -p $$ | awk '{$1=$1};1')" >> "$PS_STARTS"
stamp_of() {  # <live|ended>: the stamp's keys, to go inside a record line
  (cd "$dir/.agents/hooks/lib" && python3 -c '
import json, sys, worktree_records as wr
pid = int(sys.argv[1]); start, text = wr.ps.read(pid), wr.ps_row(pid)[1]
if sys.argv[2] == "ended":
    start = dict(start, ticks=start["ticks"] + 1) if "ticks" in start else {"epoch": start["epoch"] - 3600}
    text = "Thu Jan  1 00:00:00 2026"
print(json.dumps({"host": [pid, text], "start": start})[1:-1])' $$ "$1")
}
live_host="$(stamp_of live)" ended_host="$(stamp_of ended)"
printf '{"type": "run", "run": "c-two", "state": "x", %s}\n{"type": "run", "run": "c-one", "state": "x", %s}\n' "$live_host" "$live_host" > "$records/other.jsonl"
printf '{"type": "run", "run": "c-one", "state": "x", %s}\n' "$ended_host" > "$records/s1.jsonl"
ctx="$(start_digest startup)"
has "$ctx" "WORKLOOP c-two: 2 cells out (critic, scout); returned c-two <name> when each comes back" "another live session's run at a start"
has "$ctx" "its AGENT DIED line says how to resume it in the session that owns it; to send it again instead, dismiss that line, then brief c-one scout --again" "a run this session leads beside a live one"
printf '{"type": "run", "run": "c-two", "state": "x", %s}\n' "$ended_host" > "$records/other.jsonl"
has "$(start_digest startup)" "no cell outlives its session: each one's AGENT DIED line" "a run whose only other lead has ended"
rm -rf "$records"
ok "cells still out are named at a prompt with returned, and at a startup or resume sent to their AGENT DIED lines, with brief --again only after a dismiss, for runs this session or no live session leads"

# closing steps: worktree run
put_state <<'EOF'
import json, sys
path, repo, base, now, longago, recent = sys.argv[1:7]
def lane(name, tip="t1"):
    return {"state": "reviewed", "workspace": "/nonexistent/" + name, "branch": "b-" + name, "paths": [name], "accepted_tip": tip, "attention": None, "env": "ready"}
def run(integration=None, qa=None, lanes=None):
    return {"objective": "o", "verify": "make test", "repo": repo, "base": base, "shared": [], "messages": [], "qa": qa, "integration": integration,
            "lanes": lanes or {"a": lane("a"), "b": lane("b", "t2")}, "events": [{"id": "e0", "at": recent, "action": "init", "lane": None, "detail": "o"}]}
heads = {"a": "t1", "b": "t2"}
runs = {
  "w-none": run(),
  "w-one": run(lanes={"a": lane("a")}),
  "w-moved": run(integration={"result": "pass", "base_head": base, "lane_heads": {"a": "t1", "b": "old"}}),
  "w-fail": run(integration={"result": "fail", "base_head": base, "lane_heads": heads}),
  "w-qa": run(integration={"result": "pass", "base_head": base, "lane_heads": heads}),
  "w-done": run(integration={"result": "pass", "base_head": base, "lane_heads": heads}, qa={"at": now, "evidence": "e"}),
  # a share after the merge: the run now rebuilds lock.txt, the record merged without it
  "w-share": dict(run(integration={"result": "pass", "base_head": base, "lane_heads": heads, "shared": [], "rebuilt": {}}), shared=["lock.txt"], rebuild={"lock.txt": "make lock"}),
  "w-shared": dict(run(integration={"result": "pass", "base_head": base, "lane_heads": heads, "shared": ["lock.txt"], "rebuilt": {"lock.txt": "make lock"}}), shared=["lock.txt"], rebuild={"lock.txt": "make lock"}),
  # a record from before the two fields reads as none, and a run with none is current
  "w-old": run(integration={"result": "pass", "base_head": base, "lane_heads": heads}),
}
json.dump({"version": 1, "runs": runs}, open(path, "w"))
EOF
ctx="$(digest)"
has "$ctx" "WORKLOOP w-none: all lanes reviewed; integrate w-none" "no integration"
has "$ctx" "WORKLOOP w-one: all lanes reviewed; integrate w-one" "one worktree lane"
has "$ctx" "WORKLOOP w-moved: all lanes reviewed; integrate w-moved" "a lane moved after integration"
has "$ctx" "WORKLOOP w-fail: the composed test failed at integrate; see status" "failed integration"
has "$ctx" "WORKLOOP w-qa: ready for QA; record it with qa w-qa --evidence" "passing integration, no QA"
has "$ctx" "WORKLOOP w-done: land w-done" "QA recorded: accepted and not landed"
has "$ctx" "WORKLOOP w-share: all lanes reviewed; integrate w-share" "a share changed the rebuild rule after the integration"
has "$ctx" "WORKLOOP w-shared: ready for QA; record it with qa w-shared --evidence" "an integration that used the run's shared paths and rebuild commands"
has "$ctx" "WORKLOOP w-old: ready for QA; record it with qa w-old --evidence" "an integration record from before the two fields, in a run that shares nothing"
ok "a worktree run names integrate, the failed composed test, QA, then land; a share after the merge is not ready for QA"

# lane size: each limit names the lane with its figure and remedy; lanes under every limit are silent
remedy="split what remains into a new lane after this one is reviewed"
big="$fx/src/big.txt"; seq 1 801 > "$big"; git -C "$fx" add -- src/big.txt; git -C "$fx" commit -q -m big
exact="$fx/other/exact.txt"; seq 1 800 > "$exact"; git -C "$fx" add -- other/exact.txt; git -C "$fx" commit -q -m exact
put_state <<'EOF'
import json, sys
path, repo, base, now, longago, recent = sys.argv[1:7]
def lane(paths, **extra):
    l = {"state": "active", "workspace": repo, "branch": "b", "paths": paths, "attention": None, "env": "ready", "claimed_by": "a1", "claimed_at": now, "heartbeat_at": now}
    l.update(extra); return l
def ev(i, action, lane_name=None, at=recent):
    return {"id": f"e{i}", "at": at, "action": action, "lane": lane_name, "detail": ""}
runs = {"sz": {"objective": "o", "verify": "v", "repo": repo, "base": base, "shared": [], "messages": [], "qa": None, "integration": None,
  "lanes": {
    "huge": lane(["src"]),
    "edge": lane(["other"]),
    "wide": lane([f"d{i}" for i in range(16)]),
    "fifteen": lane([f"e{i}" for i in range(15)]),
    "twice": lane(["x1"]),
    "once": lane(["x2"]),
    "reviewed-huge": lane(["src"], state="reviewed"),
  },
  "events": [ev(0, "init"), ev(1, "widen", "twice"), ev(2, "widen", "twice"), ev(3, "widen", "once")]}}
json.dump({"version": 1, "runs": runs}, open(path, "w"))
EOF
ctx="$(digest)"
has "$ctx" "huge has 801 changed lines (over 800): $remedy" "a lane over 800 lines"
has "$ctx" "wide owns 16 paths (over 15): $remedy" "a lane over 15 paths"
has "$ctx" "twice was widened 2 times (the second widen is the limit): $remedy" "a lane widened twice"
for quiet in "edge " "fifteen " "once " "reviewed-huge "; do lacks "$ctx" "$quiet" "a lane under every limit or already reviewed"; done
lacks "$ctx" "past its base" "a run open for two hours"
ok "a lane over 800 lines, 15 paths or one widen is named with its remedy; one at the limit is not"

# a run open over a day while the default branch moved past its base
put_state <<'EOF'
import json, sys
path, repo, base, now, longago, recent = sys.argv[1:7]
def lane(**extra):
    l = {"state": "active", "workspace": repo, "branch": "b", "paths": ["nothing"], "attention": None, "env": "ready", "claimed_by": "a1", "claimed_at": now, "heartbeat_at": now}
    l.update(extra); return l
def run(at, lanes):
    return {"objective": "o", "verify": "v", "repo": repo, "base": base, "shared": [], "messages": [], "qa": None, "integration": None, "lanes": lanes,
            "events": [{"id": "e0", "at": at, "action": "init", "lane": None, "detail": "o"}]}
runs = {"old": run(longago, {"slow": lane(), "done": lane(state="reviewed")}),
        "fresh": run(recent, {"quick": lane()}),
        "old-main": run(longago, {"solo": lane(place="main", start=base)})}
json.dump({"version": 1, "runs": runs}, open(path, "w"))
EOF
ctx="$(digest)"
has "$ctx" "slow's run has been open over a day and main has 2 commit(s) past its base: $remedy" "an old run behind its default branch"
lacks "$ctx" "done's run" "a reviewed lane"
lacks "$ctx" "quick's run" "a run open two hours"
lacks "$ctx" "solo's run" "a main-tree lane"
ok "a worktree run open over a day names the commits its default branch gained"

# a main lane counts changes from its start, and is silent until it has one
put_state <<'EOF'
import json, sys
path, repo, base, now, longago, recent = sys.argv[1:7]
lane = {"state": "active", "place": "main", "workspace": repo, "branch": None, "paths": ["src"], "attention": None, "env": "main", "claimed_by": "a1", "claimed_at": now, "heartbeat_at": now}
runs = {"mn": {"objective": "o", "verify": "v", "repo": repo, "base": base, "shared": [], "messages": [], "qa": None, "integration": None,
               "lanes": {"unclaimed": dict(lane), "fromstart": dict(lane, start=base), "after": dict(lane, start="HEAD")},
               "events": [{"id": "e0", "at": recent, "action": "init", "lane": None, "detail": "o"}]}}
json.dump({"version": 1, "runs": runs}, open(path, "w"))
EOF
ctx="$(digest)"
has "$ctx" "fromstart has 801 changed lines (over 800)" "a main lane counts from its start"
lacks "$ctx" "unclaimed has" "a main lane with no start"
lacks "$ctx" "after has" "a main lane with nothing since its start"
ok "a main lane counts changed lines from its start and is silent before it has one"

# a run whose repository and workspaces are gone still prints its other notes, and the hook exits 0
put_state <<'EOF'
import json, sys
path, repo, base, now, longago, recent = sys.argv[1:7]
lane = {"state": "review", "workspace": "/nonexistent/ws", "branch": "b", "paths": [f"p{i}" for i in range(16)], "attention": None, "env": "ready"}
runs = {"gone": {"objective": "o", "verify": "v", "repo": "/nonexistent/repo", "base": base, "shared": [], "messages": [], "qa": None, "integration": None,
                 "lanes": {"ghost": lane, "gmain": dict(lane, place="main", start=base)},
                 "events": [{"id": "e0", "at": longago, "action": "init", "lane": None, "detail": "o"}]}}
json.dump({"version": 1, "runs": runs}, open(path, "w"))
EOF
set +e
raw="$(printf '{"project_dir":"%s","event":"UserPromptSubmit","session_id":"s1","agent_id":""}' "$dir" | bash "$policy" 2>"$scratch/gone.err")"; code=$?
set -e
[[ "$code" -eq 0 ]] || fail "the hook exited $code with a run whose workspace is gone"
ctx="$(context "$raw")"
has "$ctx" "ghost awaits review" "a lane whose workspace is gone"
has "$ctx" "ghost owns 16 paths (over 15)" "a lane whose workspace is gone"
lacks "$ctx" "changed lines" "a figure that cannot be measured"
ok "a run whose repository and workspaces are gone still prints its other notes and exits 0"

# Git behaviour of the size figures: a fake git logs each call, can be slow or
# failing, and otherwise runs the real one.
realgit="$(command -v git)"
mkdir -p "$scratch/gitbin"
cat > "$scratch/gitbin/git" <<EOF
#!/usr/bin/env python3
import os, sys, time
with open(os.environ["WRAP_LOG"], "a") as log:
    log.write(" ".join(sys.argv[1:]) + "\n")
if os.environ.get("WRAP_FAIL"):
    sys.stderr.write("fatal: induced\n"); sys.exit(1)
time.sleep(float(os.environ.get("WRAP_SLEEP", "0")))
os.execv("$realgit", ["git", *sys.argv[1:]])
EOF
chmod +x "$scratch/gitbin/git"
git_log="$scratch/git.log"
tracked_lane_state() {  # <lane names...>: unclaimed-free main lanes, each 801 lines from the base
  put_state <<'EOF'
import json, sys
path, repo, base, now, longago, recent = sys.argv[1:7]
lane = {"state": "active", "place": "main", "workspace": repo, "branch": None, "paths": ["src"], "start": base, "attention": None, "env": "main", "claimed_by": "a1", "claimed_at": now, "heartbeat_at": now}
runs = {"gt": {"objective": "o", "verify": "v", "repo": repo, "base": base, "shared": [], "messages": [], "qa": None, "integration": None,
               "lanes": {name: dict(lane) for name in ("l1", "l2", "l3")},
               "events": [{"id": "e0", "at": recent, "action": "init", "lane": None, "detail": "o"}]}}
json.dump({"version": 1, "runs": runs}, open(path, "w"))
EOF
}
tracked_lane_state

# location variables inherited from a git hook must not redirect the figures
ctx="$(GIT_DIR="$scratch/nowhere" GIT_WORK_TREE="$scratch/nowhere" digest)"
has "$ctx" "l1 has 801 changed lines (over 800)" "a digest run with GIT_DIR in its environment"
ok "the digest's Git calls ignore inherited GIT_* variables"

# a figure Git could not give reads "size unknown" in the digest itself
: > "$git_log"
ctx="$(PATH="$scratch/gitbin:$PATH" WRAP_LOG="$git_log" WRAP_FAIL=1 digest)"
has "$ctx" "size unknown for l1" "a failing git"
has "$ctx" "size unknown for l3" "a failing git"
lacks "$ctx" "changed lines" "a failing git"
ok "a figure dropped by a Git failure reads 'size unknown' in the digest"

# measuring leaves the checkout's index untouched
sleep 1.1; touch "$fx/src/seed.txt"  # git diff refreshes, and rewrites the index for, a file that is stat-dirty yet unchanged from the base; only once it is newer than the index
before="$(cksum < "$fx/.git/index")"
digest >/dev/null
[[ "$(cksum < "$fx/.git/index")" == "$before" ]] || fail "the digest rewrote the checkout's index"
ok "measuring changed lines leaves the checkout's index alone"
: > "$git_log"
PATH="$scratch/gitbin:$PATH" WRAP_LOG="$git_log" digest >/dev/null
grep -q ' diff-index --numstat ' "$git_log" || fail "no diff-index call: $(cat "$git_log")"
! grep -q ' diff ' "$git_log" || fail "the digest ran git diff"

# one deadline for all of a digest's Git calls
started=$SECONDS
ctx="$(PATH="$scratch/gitbin:$PATH" WRAP_LOG="$git_log" WRAP_SLEEP=3 digest)"
elapsed=$((SECONDS - started))
[[ "$elapsed" -le 7 ]] || fail "three 3 s Git calls took ${elapsed}s; the deadline is 5 s in total"
has "$ctx" "size unknown for l3" "a lane measured after the shared deadline"
ok "the digest's Git calls share one 5 s deadline"

# the default branch is read only while an unreviewed worktree lane exists
put_state <<'EOF'
import json, sys
path, repo, base, now, longago, recent = sys.argv[1:7]
def lane(**extra):
    l = {"state": "reviewed", "workspace": "/nonexistent/ws", "branch": "b", "paths": ["nothing"], "accepted_tip": "t1", "attention": None, "env": "ready"}
    l.update(extra); return l
runs = {"old": {"objective": "o", "verify": "v", "repo": repo, "base": base, "shared": [], "messages": [], "qa": None, "integration": None,
                "lanes": {"done": lane(), "main-open": lane(state="active", attention={"severity": "P1"}, place="main", start=base, workspace=repo, claimed_by="a1", claimed_at=now, heartbeat_at=now)},
                "events": [{"id": "e0", "at": longago, "action": "init", "lane": None, "detail": "o"}]}}
json.dump({"version": 1, "runs": runs}, open(path, "w"))
EOF
: > "$git_log"
PATH="$scratch/gitbin:$PATH" WRAP_LOG="$git_log" digest >/dev/null
! grep -q 'for-each-ref' "$git_log" || fail "the default branch was read for a run with no unreviewed worktree lane: $(cat "$git_log")"
ok "an old run with no unreviewed worktree lane does not read the default branch"

# a subagent's tool batch stamps its lane (bound by claim) or its cell (bound by the brief
# header in its own transcript) with the time and its last tool call, once a minute
tdir="$scratch/transcripts"; mkdir -p "$tdir/s1/subagents"
call() {  # <name> <input json> -> one assistant record holding a tool call
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"x"},{"type":"tool_use","name":"%s","input":%s}]}}\n' "$1" "$2"
}
{ printf '{"type":"user","message":{"role":"user","content":"READ-ONLY — this cell reads.\\nWORKLOOP CELL BRIEF — r1/scout\\nRead the brief."}}\n'
  call Read '{"file_path":"/x/y/plan.md"}'; } > "$tdir/s1/subagents/agent-c1.jsonl"
{ printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"WORKLOOP WORKER BRIEF — r1/api\\nRead."}]}}\n'
  call Bash '{"command":"pytest -q tests/test_api.py","description":"Run the api tests"}'; } > "$tdir/s1/subagents/agent-a1.jsonl"
put_cells() {
  python3 - "$state" "$1" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p))
s["runs"]["r1"]["cells"] = {"scout": {"role": "research", "model": "haiku", "state": sys.argv[2], "out_since": "2026-01-01T00:00:00Z"}}
json.dump(s, open(p, "w"))
PY
}
field() {  # <kind> <name> <key>
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["runs"]["r1"]; print(r[sys.argv[2]][sys.argv[3]].get(sys.argv[4],""))' "$state" "$@"
}
fire_t() {  # <event> <agent_id> [tool_name] [tool_input json], with a transcript; stderr lands in $hook_err
  local input="${4:-}"; [[ -n "$input" ]] || input='{}'
  printf '{"project_dir":"%s","event":"%s","session_id":"s1","agent_id":"%s","transcript_path":"%s","tool_name":"%s","tool_input":%s}' \
    "$dir" "$1" "$2" "$tdir/main.jsonl" "${3:-}" "$input" | bash "$policy" >/dev/null 2>"$hook_err"
}
hook_err="$scratch/hook.err"
ledgers="$dir/.agents/.readout"
cat > "$state" <<EOF
{"version":1,"runs":{"r1":{"objective":"o","supervised":false,"messages":[],"lanes":{
  "api":{"state":"active","claimed_by":"a1","claimed_at":"$now","attention":null,"env":"ready"}}}}}
EOF
rm -f "$ledgers"/.activity-s1-*
put_cells out
# the cell's transcript ends on a Read of plan.md; the action shown is the payload's call, not the transcript's
fire_t PostToolBatch c1 Grep '{"pattern":"TODO","path":"/x"}'
[[ "$(field cells scout activity)" == "Grep TODO" && -n "$(field cells scout activity_at)" ]] || fail "a cell was not stamped from its payload: $(field cells scout activity)"
[[ "$(field cells scout agent_id)" == "c1" ]] || fail "the bound cell did not take its agent's id: $(field cells scout agent_id)"
ok "a cell is bound by the brief header in its transcript, takes its agent's id, and is stamped with the batch's last tool call from the payload"
fire_t PostToolBatch a1 Bash '{"command":"pytest -q tests/test_api.py","description":"Run the api tests"}'
[[ "$(field lanes api activity)" == "Bash Run the api tests" && -n "$(field lanes api activity_at)" ]] || fail "a lane was not stamped by its claim: $(field lanes api activity)"
ok "a lane is bound by its claim and stamped with its last tool call"
fire_t PostToolBatch c1 Edit '{"file_path":"/x/z.py"}'
[[ "$(field cells scout activity)" == "Grep TODO" ]] || fail "a second stamp inside a minute was written"
rm -f "$ledgers/.activity-s1-c1"
fire_t PostToolBatch c1 Edit '{"file_path":"/x/z.py"}'
[[ "$(field cells scout activity)" == "Edit z.py" ]] || fail "the stamp did not follow once the minute passed: $(field cells scout activity)"
ok "an agent is stamped at most once a minute"
put_cells returned; rm -f "$ledgers/.activity-s1-c1"
fire_t PostToolBatch c1
[[ -z "$(field cells scout activity)" ]] || fail "a cell already back was stamped"
ok "a cell that is back is not stamped"

# the Claude normalizer hands the policy a batch's last call, name and input only: the responses stay behind
normalized="$(printf '%s' '{"hook_event_name":"PostToolBatch","session_id":"s1","agent_id":"c1","transcript_path":"/t/main.jsonl","tool_calls":[{"tool_name":"Read","tool_input":{"file_path":"/a"},"tool_use_id":"u1","tool_response":"BIGONE"},{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"u2","tool_response":"BIGTWO"}]}' \
  | python3 "$repo/.agents/claude/normalize-hook.py" workloop-inbox.sh "$repo")"
python3 - "$normalized" <<'PY' || fail "the normalizer did not pass the batch's last call alone: $normalized"
import json, sys
out = json.loads(sys.argv[1])
assert out["tool_name"] == "Bash" and out["tool_input"] == {"command": "ls"}, out
assert "BIG" not in sys.argv[1] and out["event"] == "PostToolBatch" and out["agent_id"] == "c1", out
PY
ok "the Claude normalizer passes a batch's last tool call, never its responses"

# the stamp ledger lives in the gitignored readout folder: a stamp leaves the work tree clean
cp "$repo/.gitignore" "$dir/.gitignore"
git -C "$dir" init -q 2>/dev/null
git -C "$dir" add -A >/dev/null
git -C "$dir" -c user.name=t -c user.email=t@example.com commit -qm fixture
put_cells out; rm -f "$ledgers"/.activity-s1-* "$dir"/.agents/.activity-s1-*
fire_t PostToolBatch c1 Edit '{"file_path":"/x/z.py"}'
[[ -f "$ledgers/.activity-s1-c1" ]] || fail "the stamp wrote no ledger in the readout folder"
[[ -z "$(git -C "$dir" status --porcelain --untracked-files=all)" ]] || fail "a stamp left the work tree dirty: $(git -C "$dir" status --porcelain --untracked-files=all)"
ok "a stamp leaves git status --porcelain --untracked-files=all clean"

# an agent bound to nothing costs one lookup a minute at a tool batch, and none at its start
rm -f "$ledgers"/.activity-s1-*
fire_t SubagentStart stranger
[[ ! -e "$ledgers/.activity-s1-stranger" ]] || fail "a start that bound to nothing wrote the ledger"
fire_t PostToolBatch stranger
[[ -e "$ledgers/.activity-s1-stranger" ]] || fail "a tool batch that bound to nothing wrote no ledger"
ok "a miss writes the ledger on a tool batch only"

# a lane's claim binds it before any transcript is read; a cell with no transcript is named as not stamped
rm -f "$ledgers"/.activity-s1-* "$tdir/s1/subagents/agent-a1.jsonl"
fire_t PostToolBatch a1 Read '{"file_path":"/x/q.py"}'
[[ "$(field lanes api activity)" == "Read q.py" && ! -s "$hook_err" ]] || fail "a lane's stamp read its transcript: $(field lanes api activity) / $(cat "$hook_err")"
rm -f "$tdir/s1/subagents/agent-c1.jsonl"
fire_t PostToolBatch c1 Read '{"file_path":"/x/q.py"}'
grep -q 'c1 is not stamped' "$hook_err" || fail "an unreadable cell transcript did not say the cell is not stamped: $(cat "$hook_err")"
ok "a lane is bound by its claim without its transcript; an unreadable cell transcript says it is not stamped"

# the state lock is taken without blocking: a holder past the retry window costs a stderr line and exit 0
rm -f "$ledgers"/.activity-s1-*
python3 - "$state.lock" > "$scratch/held" <<'PY' &
import fcntl, sys, time
lock = open(sys.argv[1], "a+"); fcntl.flock(lock, fcntl.LOCK_EX); print("held", flush=True); time.sleep(6)
PY
holder=$!
for _ in $(seq 50); do grep -q held "$scratch/held" && break; sleep 0.1; done
started=$SECONDS
fire_t PostToolBatch a1 Read '{"file_path":"/x/w.py"}' || fail "the hook failed while the state lock was held"
elapsed=$((SECONDS - started))
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
grep -q 'a1 is not stamped' "$hook_err" || fail "a held state lock was not reported on stderr: $(cat "$hook_err")"
[[ "$elapsed" -le 4 && "$(field lanes api activity)" == "Read q.py" ]] || fail "a held state lock blocked the hook ${elapsed}s or still stamped: $(field lanes api activity)"
ok "the state lock is taken without blocking and a busy lock is reported, exit 0"

# the readout names the agents out and the oldest silence, and is empty when none is out
readout() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$dir/.agents/.readout/workloop.json" "$1"; }
put_cells out
rm -f "$ledgers"/.activity-s1-*
{ printf '{"type":"user","message":{"role":"user","content":"READ-ONLY — this cell reads.\\nWORKLOOP CELL BRIEF — r1/scout\\nRead the brief."}}\n'; } > "$tdir/s1/subagents/agent-c1.jsonl"
fire_t PostToolBatch c1 Edit '{"file_path":"/x/z.py"}'
python3 - "$state" <<'PY'
import json, sys, time
p = sys.argv[1]; s = json.load(open(p))
s["runs"]["r1"]["cells"]["scout"]["activity_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 1200))
json.dump(s, open(p, "w"))
PY
fire UserPromptSubmit '' >/dev/null
[[ "$(readout strip)" == "2 agents out, oldest silent 20m" && "$(readout note)" == *"r1/scout (research) silent 20m: Edit z.py"* ]] || fail "the readout did not name the agents out: $(readout strip) / $(readout note)"
put_cells returned
python3 - "$state" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["runs"]["r1"]["lanes"]["api"]["state"] = "reviewed"; json.dump(s, open(p, "w"))
PY
fire UserPromptSubmit '' >/dev/null
[[ -z "$(readout strip)" && -z "$(readout note)" ]] || fail "the readout stayed after every agent was back: $(readout strip)"
ok "the readout names the agents out and the oldest silence, and is empty once none is out"

# an agent with no stamp and no heartbeat is counted apart: the oldest silence is over stamped agents only
put_cells out
fire UserPromptSubmit '' >/dev/null
[[ "$(readout strip)" == "1 agent out, 1 unstamped" && "$(readout note)" == "r1/scout (research) unstamped" ]] || fail "the readout did not count the unstamped cell apart: $(readout strip) / $(readout note)"
python3 - "$state" <<'PY'
import json, sys, time
p = sys.argv[1]; s = json.load(open(p)); r = s["runs"]["r1"]
at = lambda seconds: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - seconds))
r["lanes"]["api"].update(state="active", claimed_at=at(3600), activity_at=at(300))
json.dump(s, open(p, "w"))
PY
fire UserPromptSubmit '' >/dev/null
[[ "$(readout strip)" == "2 agents out, oldest silent 5m, 1 unstamped" ]] || fail "the oldest silence took in the unstamped cell: $(readout strip)"
put_cells returned
python3 - "$state" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["runs"]["r1"]["lanes"]["api"]["state"] = "reviewed"; json.dump(s, open(p, "w"))
PY
ok "the readout counts an unstamped agent apart from the oldest silence"

# the header may follow any first line the delegation guide sanctions, and no other
for first in 'NOTES-ONLY — this cell writes notes.' 'WORKSPACE: /tmp/elsewhere' 'Please read this first.'; do
  printf '{"type":"user","message":{"role":"user","content":"%s\\nWORKLOOP CELL BRIEF — r1/scout\\nRead the brief."}}\n' "$first" > "$tdir/s1/subagents/agent-c2.jsonl"
  put_cells out; rm -f "$ledgers/.activity-s1-c2"
  fire_t PostToolBatch c2 Grep '{"pattern":"x"}'
  if [[ "$first" == Please* ]]; then
    [[ -z "$(field cells scout agent_id)" ]] || fail "a header after an unsanctioned first line bound the cell"
  else
    [[ "$(field cells scout agent_id)" == "c2" ]] || fail "a header after '$first' did not bind the cell"
  fi
done
ok "a header after a NOTES-ONLY or WORKSPACE line binds the cell, as one after READ-ONLY does; one after any other line does not"

# disabled
printf '{"hooks":{"workloop_inbox":{"enabled":false}}}\n' > "$dir/.agents/config.json"
[[ -z "$(fire UserPromptSubmit '')" ]] || fail "toggle did not disable"
ok "the config toggle turns the policy off"

printf '\nall workloop-inbox tests passed\n'
