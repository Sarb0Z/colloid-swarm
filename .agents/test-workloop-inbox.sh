#!/usr/bin/env bash
# Firing tests for the workloop-inbox policy: a cell hears its host id at
# start and its lane's unread messages between tool calls, once each; the
# lead hears a digest of what needs them.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

dir="$scratch/fixture"
mkdir -p "$dir/.agents/hooks/policy" "$dir/.agents/hooks/lib"
cp "$repo/.agents/hooks/policy/workloop-inbox.sh" "$dir/.agents/hooks/policy/"
cp "$repo/.agents/hooks/lib/config.py" "$repo/.agents/hooks/lib/emit-context.py" "$repo/.agents/hooks/lib/workloop-inbox.py" "$dir/.agents/hooks/lib/"
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

old="$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$state" <<EOF
{"version":1,"runs":{
 "r1":{"objective":"o","lanes":{
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

# a cell holding no lane hears only its id at start, nothing later
ctx="$(context "$(fire SubagentStart zz)")"
[[ "$ctx" == *"AGENT_ID: zz"* && "$ctx" != *"WORKLOOP MESSAGE"* ]] || fail "unclaimed cell heard messages: $ctx"
[[ -z "$(fire PostToolBatch zz)" ]] || fail "unclaimed cell heard something between tools"
ok "a cell without a lane hears only its id"

# the lead hears a digest: review, attention, stale, broken, pending acks; not the torn-down run
ctx="$(context "$(fire UserPromptSubmit '')")"
[[ "$ctx" == *"WORKLOOP r1:"* ]] || fail "no digest: $ctx"
[[ "$ctx" == *"web awaits review"* && "$ctx" == *"db carries P0"* && "$ctx" == *"db stale "* && "$ctx" == *"db environment broken"* ]] || fail "digest missing items: $ctx"
[[ "$ctx" == *"2 message(s) await acknowledgement"* ]] || fail "pending ack count wrong: $ctx"
[[ "$ctx" != *"api stale"* ]] || fail "a fresh heartbeat was called stale"
[[ "$ctx" != *"WORKLOOP done"* ]] || fail "a torn-down run was reported"
ok "the lead hears review, attention, stale, broken, and pending acknowledgements"

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

# disabled
printf '{"hooks":{"workloop_inbox":{"enabled":false}}}\n' > "$dir/.agents/config.json"
[[ -z "$(fire UserPromptSubmit '')" ]] || fail "toggle did not disable"
ok "the config toggle turns the policy off"

printf '\nall workloop-inbox tests passed\n'
