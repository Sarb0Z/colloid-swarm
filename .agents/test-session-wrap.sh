#!/usr/bin/env bash
# Firing tests for session-wrap's no-diff branch: a session is long by the
# agent's tool calls, not by transcript lines, which also carry titles, mode
# changes and attachments. Both transcript schemas it reads are covered.
set -euo pipefail
# A caller such as `git rebase -x` exports these; the git calls below must
# reach only their own temporary repositories.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
proj="$scratch/proj"
mkdir -p "$proj/.agents/hooks/policy" "$proj/.agents/hooks/lib"
cp "$repo/.agents/hooks/policy/session-wrap.sh" "$proj/.agents/hooks/policy/"
cp "$repo"/.agents/hooks/lib/*.py "$repo"/.agents/hooks/lib/*.sh "$proj/.agents/hooks/lib/"
printf '{"hooks":{"session_wrap":{"enabled":true,"heavy_tool_calls":60}}}\n' > "$proj/.agents/config.json"
printf '.agents/\n' > "$proj/.gitignore"
git -C "$proj" init -q
git -C "$proj" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
policy="$proj/.agents/hooks/policy/session-wrap.sh"

claude_transcript() {  # <path> <tool calls> <filler lines>
  python3 - "$@" <<'EOF'
import json, sys
path, calls, filler = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(path, "w") as out:
    for _ in range(filler):
        out.write(json.dumps({"type": "attachment", "attachment": {}}) + "\n")
    for i in range(calls):
        out.write(json.dumps({"type": "assistant", "message": {"content": [
            {"type": "text", "text": "x"}, {"type": "tool_use", "name": "Bash", "input": {}}]}}) + "\n")
        out.write(json.dumps({"type": "user", "message": {"content": [{"type": "tool_result"}]}}) + "\n")
EOF
}

codex_transcript() {  # <path> <tool calls> [session source]
  python3 - "$@" <<'EOF'
import json, sys
path, calls = sys.argv[1], int(sys.argv[2])
source = sys.argv[3] if len(sys.argv) > 3 else None
with open(path, "w") as out:
    if source:
        out.write(json.dumps({"type": "session_meta", "payload": {"source": source}}) + "\n")
    for i in range(calls):
        kind = "function_call" if i % 2 else "custom_tool_call"
        out.write(json.dumps({"type": "response_item", "payload": {"type": kind}}) + "\n")
        out.write(json.dumps({"type": "event_msg", "payload": {"type": "token_count"}}) + "\n")
EOF
}

stop() {  # <session> <transcript> -> combined output
  printf '{"project_dir":"%s","session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$proj" "$1" "$2" \
    | bash "$policy" 2>&1 || true
}

# First stop seeds the baseline and says nothing; the second judges the session.
judged() {  # <session> <transcript>
  stop "$1" "$2" >/dev/null
  stop "$1" "$2"
}

# This session's own shape: 268 transcript lines, 32 tool calls. Not long.
claude_transcript "$scratch/short.jsonl" 32 204
[[ "$(wc -l <"$scratch/short.jsonl" | tr -d ' ')" -eq 268 ]] || fail "fixture is not 268 lines"
out="$(judged short "$scratch/short.jsonl")"
[[ "$out" != *"A long session"* ]] || fail "32 tool calls in 268 lines was called long: $out"
ok "a 268-line transcript with 32 tool calls is not a long session"

claude_transcript "$scratch/long.jsonl" 61 0
out="$(judged long "$scratch/long.jsonl")"
[[ "$out" == *"A long session (61 tool calls)"* ]] || fail "61 Claude tool calls did not fire: $out"
ok "61 Claude tool calls fire the investigation prompt, counted in tool calls"

out="$(stop long "$scratch/long.jsonl")"
[[ "$out" != *"A long session"* ]] || fail "the prompt repeated in the same session"
ok "the prompt fires once per session"

codex_transcript "$scratch/codex.jsonl" 61
out="$(judged codex "$scratch/codex.jsonl")"
[[ "$out" == *"A long session (61 tool calls)"* ]] || fail "61 Codex tool calls did not fire: $out"
ok "Codex function_call and custom_tool_call items count as tool calls"

# `codex exec` has no one to answer the full-wrap/skip question; the prompt would
# end in a failed request_user_input. Codex records the launch mode as
# session_meta.payload.source, which the Stop payload does not carry.
codex_transcript "$scratch/codex-exec.jsonl" 61 exec
out="$(judged codex-exec "$scratch/codex-exec.jsonl")"
[[ -z "$out" ]] || fail "a codex exec session was prompted: $out"
ok "a codex exec session is never prompted"

codex_transcript "$scratch/codex-cli.jsonl" 61 cli
out="$(judged codex-cli "$scratch/codex-cli.jsonl")"
[[ "$out" == *"A long session (61 tool calls)"* ]] || fail "an interactive Codex session did not fire: $out"
ok "an interactive Codex session still fires"

printf 'not json\n{"type":"assistant","message":{"content":"plain"}}\n' > "$scratch/odd.jsonl"
out="$(judged odd "$scratch/odd.jsonl")"
[[ "$out" != *"A long session"* ]] || fail "an unreadable transcript fired"
ok "unreadable lines and string content are skipped"

printf '\nall session-wrap tests passed\n'
