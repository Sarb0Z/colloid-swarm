#!/usr/bin/env bash
# Firing tests for session-wrap. The no-diff branch: a session is long by the
# agent's tool calls, not by transcript lines, which also carry titles, mode
# changes and attachments; both transcript schemas it reads are covered.
# Attribution: with edit-record.sh's per-session record, each wrap measures its
# own session's edits and commits in a tree several sessions share. The work
# log's advisory line rides inside a wrap that fires.
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

# ───────────────────────────── attribution ─────────────────────────────
# Each scenario gets its own repository: the wrap's throttle fires once per
# tier, so a reused session would stay silent for the wrong reason.
fixture() {  # <name> -> path of a fresh repository carrying the policies
  local dir="$scratch/$1"
  mkdir -p "$dir/.agents/hooks/policy" "$dir/.agents/hooks/lib" "$dir/.agents/playbooks" \
    "$dir/.agents/claude" "$dir/.agents/codex" "$dir/.codex/hooks" "$dir/.kimi/hooks"
  cp "$repo/.agents/hooks/policy/session-wrap.sh" "$repo/.agents/hooks/policy/edit-record.sh" \
     "$repo/.agents/hooks/policy/session-start.sh" "$dir/.agents/hooks/policy/"
  cp "$repo"/.agents/hooks/lib/*.py "$repo"/.agents/hooks/lib/*.sh "$dir/.agents/hooks/lib/"
  cp "$repo/.agents/playbooks/worklog.md" "$dir/.agents/playbooks/"
  cp "$repo/.agents/claude/adapter.sh" "$repo/.agents/claude/normalize-hook.py" "$dir/.agents/claude/"
  cp "$repo/.agents/codex/normalize-hook.py" "$dir/.agents/codex/"
  cp "$repo/.codex/hooks/adapter.sh" "$dir/.codex/hooks/"
  # A repository that dropped Kimi has no Kimi adapter to copy or drive.
  if [[ -d "$repo/.kimi" ]]; then
    cp "$repo/.kimi/hooks/adapter.sh" "$repo/.kimi/hooks/normalize-hook.py" "$dir/.kimi/hooks/"
  fi
  # trivial_files=0: one changed file already crosses into `diff`, so each
  # scenario can stay at one or two files.
  printf '{"hooks":{"session_wrap":{"enabled":true,"trivial_files":0}%s}}\n' "${2:-}" > "$dir/.agents/config.json"
  printf '.agents/\n.codex/\n.kimi/\n' > "$dir/.gitignore"
  git -C "$dir" init -q
  git -C "$dir" add .gitignore
  git -C "$dir" -c user.name=t -c user.email=t@t commit -q -m init
  printf '%s\n' "$dir"
}

start() {  # <repo> <session> [source]
  printf '{"project_dir":"%s","source":"%s","session_id":"%s","transcript_path":""}' "$1" "${3:-startup}" "$2" \
    | bash "$1/.agents/hooks/policy/session-start.sh" >/dev/null
}

wrap() {  # <repo> <session> -> the wrap's output
  printf '{"project_dir":"%s","session_id":"%s","transcript_path":"","stop_hook_active":false}' "$1" "$2" \
    | bash "$1/.agents/hooks/policy/session-wrap.sh" 2>&1 || true
}

edit() {  # <repo> <session> <file>: write the file as an editor tool would, and record it
  printf 'line one\nline two\n' > "$1/$3"
  python3 -c 'import json, sys; print(json.dumps({"project_dir": sys.argv[1], "session_id": sys.argv[2],
    "tool_name": "Write", "files": [sys.argv[1] + "/" + sys.argv[3]]}))' "$1" "$2" "$3" \
    | bash "$1/.agents/hooks/policy/edit-record.sh"
}

# A shell call as a host runs it: the PreToolUse half snapshots HEAD, the
# command runs, the PostToolUse half records what HEAD gained.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
calls=0
shell() {  # <repo> <session> <command> [tool output]
  local event status=0
  calls=$((calls + 1))
  for event in PreToolUse PostToolUse; do
    if [[ "$event" == PostToolUse ]]; then
      (cd "$1" && bash -c "$3") >/dev/null 2>&1 || status=$?
    fi
    python3 -c 'import json, sys; print(json.dumps({"project_dir": sys.argv[1], "session_id": sys.argv[2],
      "event": sys.argv[3], "tool_name": "Bash", "tool_use_id": "call_" + sys.argv[4], "command": sys.argv[5],
      "tool_response": sys.argv[6]}))' "$1" "$2" "$event" "$calls" "$3" "${4:-}" \
      | bash "$1/.agents/hooks/policy/edit-record.sh"
  done
  return 0
}

commit() {  # <repo> <session> <file>: commit the file through a shell call
  printf 'line one\nline two\n' > "$1/$3"
  shell "$1" "$2" "git add '$3' && git commit -q -m 'add $3'"
}

commits_of() { cat "$1/.agents/.wrap-commits-$(printf '%s' "$2" | cksum | tr -d ' ')" 2>/dev/null || true; }

listed() { [[ "$1" == *"  - $2"* ]]; }

# Two sessions edit one file each; a third file reaches the tree through a
# shell command neither recorder saw.
two="$(fixture two-sessions)"
start "$two" alpha
start "$two" beta
edit "$two" alpha a.txt
edit "$two" beta b.txt
printf 'shell\n' > "$two/c.txt"
out="$(wrap "$two" alpha)"
listed "$out" a.txt && ! listed "$out" b.txt || fail "alpha's wrap is not alpha's own: $out"
listed "$out" c.txt || fail "the unclaimed file did not count for the stopping session: $out"
[[ "$out" == *"(2 file(s), ~3 changed lines)"* ]] || fail "alpha's size counts beta's lines: $out"
out="$(wrap "$two" beta)"
listed "$out" b.txt && ! listed "$out" a.txt || fail "beta's wrap is not beta's own: $out"
ok "two sessions each wrap only their own edits; an unclaimed file counts for the one that stops"

# A session that wrote only through the shell has no edits file: it measures
# what no other session claims.
bash_only="$(fixture bash-only)"
start "$bash_only" alpha
start "$bash_only" gamma
edit "$bash_only" alpha a.txt
printf 'shell\n' > "$bash_only/g.txt"
out="$(wrap "$bash_only" gamma)"
listed "$out" g.txt && ! listed "$out" a.txt || fail "a Bash-only session counted a claimed file: $out"
ok "a Bash-only session counts unclaimed files and not another session's"

# A finished session's claim ends at the path's next commit: beta edited and
# committed x.txt and left; alpha's later shell append is alpha's work.
stale="$(fixture stale-claim)"
start "$stale" beta
start "$stale" alpha
edit "$stale" beta x.txt
shell "$stale" beta "git add x.txt && git commit -q -m x"
shell "$stale" alpha "seq 200 >> x.txt"
out="$(wrap "$stale" alpha)"
listed "$out" x.txt && [[ "$out" == *"~200 changed lines"* ]] || fail "a committed peer claim hid alpha's shell edit: $out"
ok "a peer's claim older than the path's last commit no longer hides later work"

# Renames and names with spaces: the destination is measured, not `old -> new`.
renamed="$(fixture renamed)"
seq 10 > "$renamed/old.txt"
git -C "$renamed" add old.txt
git -C "$renamed" commit -q -m old
start "$renamed" alpha
shell "$renamed" alpha "git mv old.txt new.txt"
printf 'extra\n' >> "$renamed/new.txt"
python3 -c 'import json, sys; print(json.dumps({"project_dir": sys.argv[1], "session_id": "alpha",
  "tool_name": "Edit", "files": [sys.argv[1] + "/new.txt"]}))' "$renamed" \
  | bash "$renamed/.agents/hooks/policy/edit-record.sh"
printf 'a\nb\nc\n' > "$renamed/sp ace.txt"
out="$(wrap "$renamed" alpha)"
listed "$out" new.txt && listed "$out" "sp ace.txt" && ! listed "$out" old.txt \
  && [[ "$out" == *"(2 file(s), ~4 changed lines)"* ]] || fail "a rename or a spaced name was mismeasured: $out"
ok "a git mv plus edit is measured at its destination, and spaced names are read whole"

# Committed work: each session's recorded commits, commits nobody recorded, and
# a workloop wave that one session integrated.
landed="$(fixture committed)"
start "$landed" alpha
start "$landed" beta
commit "$landed" alpha a.txt
commit "$landed" beta b.txt
shell "$landed" alpha "git commit -m failed"
[[ "$(commits_of "$landed" alpha | wc -l | tr -d ' ')" == 1 ]] || fail "a commit command that failed was recorded"
out="$(wrap "$landed" alpha)"
[[ "$out" == *"Committed and unwrapped (1 commit(s), 1 file(s)"* ]] && listed "$out" a.txt && ! listed "$out" b.txt \
  || fail "alpha's committed ladder counted beta's commit: $out"
ok "the committed ladder does not count a peer's recorded commit"

printf 'u\n' > "$landed/u.txt"
git -C "$landed" add u.txt
git -C "$landed" commit -q -m "made where no recorder ran"
out="$(wrap "$landed" alpha)"
listed "$out" u.txt || fail "a commit no session recorded did not count for the stopping session: $out"
ok "a commit no session recorded counts for the session that stops"

git -C "$landed" worktree add -q -b wave/integration "$scratch/integration" HEAD
for lane in one two; do
  git -C "$landed" branch -q "wave/$lane" HEAD
  git -C "$landed" worktree add -q "$scratch/lane-$lane" "wave/$lane"
  printf 'lane %s\n' "$lane" > "$scratch/lane-$lane/$lane.txt"
  git -C "$scratch/lane-$lane" add "$lane.txt"
  git -C "$scratch/lane-$lane" commit -q -m "lane $lane"
  git -C "$scratch/integration" merge -q --no-ff --no-edit -m "integrate $lane" "wave/$lane"
done
shell "$landed" alpha "true # python3 .agents/workloop.py integrate wave --workspace $scratch/integration" \
  "PASS: integrated one, two in $scratch/integration; verify passed"
git -C "$landed" merge -q --ff-only wave/integration
out="$(wrap "$landed" alpha)"
[[ "$out" == *"Committed and unwrapped (2 commit(s), 2 file(s)"* ]] && listed "$out" one.txt && listed "$out" two.txt \
  || fail "the wave alpha integrated did not count for alpha: $out"
out="$(wrap "$landed" beta)"
! listed "$out" one.txt && ! listed "$out" two.txt || fail "the wave alpha integrated counted for beta: $out"
listed "$out" b.txt || fail "beta's own commit vanished behind the wave: $out"
ok "a merged wave counts for the session that integrated it and not for another"

# A fixup folded by an autosquash rebase rewrites every recorded sha; the
# rebase's own shell call records the rewritten commits, so the wrap still fires.
fixup="$(fixture fixup)"
start "$fixup" alpha
start "$fixup" beta
base="$(git -C "$fixup" rev-parse HEAD)"
for n in 1 2 3 4 5 6; do edit "$fixup" alpha "f$n.txt"; done
shell "$fixup" alpha "git add f*.txt && git commit -q -m six"
printf 'more\n' >> "$fixup/f1.txt"
shell "$fixup" alpha "git commit -q -a --fixup=HEAD"
shell "$fixup" alpha "GIT_SEQUENCE_EDITOR=: git rebase -q -i --autosquash $base"
[[ "$(git -C "$fixup" rev-list --count "$base..HEAD")" == 1 ]] || fail "the fixture's autosquash did not fold"
out="$(wrap "$fixup" alpha)"
[[ "$out" == *"Committed and unwrapped (1 commit(s), 6 file(s)"* && "$out" == *"'large' threshold"* ]] \
  || fail "a fixup plus autosquash left the committed ladder silent: $out"
out="$(wrap "$fixup" beta)"
! listed "$out" f1.txt || fail "alpha's rebased commit counted for beta: $out"
ok "commits rewritten by a fixup and autosquash rebase still count for their session"

# Cherry-picking a run of commits records every one of them.
picked="$(fixture cherry-pick)"
git -C "$picked" checkout -q -b side
for n in 1 2 3; do
  printf '%s\n' "$n" > "$picked/p$n.txt"
  git -C "$picked" add "p$n.txt"
  git -C "$picked" commit -q -m "p$n"
done
git -C "$picked" checkout -q -
start "$picked" alpha
start "$picked" beta
shell "$picked" alpha "git cherry-pick side~3..side"
[[ "$(commits_of "$picked" alpha | wc -l | tr -d ' ')" == 3 ]] || fail "a three-commit cherry-pick was not recorded whole"
out="$(wrap "$picked" alpha)"
[[ "$out" == *"Committed and unwrapped (3 commit(s), 3 file(s)"* ]] || fail "the picked commits did not count for alpha: $out"
out="$(wrap "$picked" beta)"
! listed "$out" p1.txt || fail "alpha's picked commits counted for beta: $out"
ok "a cherry-pick of three commits records all three"

# A call that switches branches records nothing it did not make.
git -C "$picked" checkout -q -b elsewhere side
git -C "$picked" checkout -q -
shell "$picked" alpha "git checkout -q elsewhere"
[[ "$(commits_of "$picked" alpha | wc -l | tr -d ' ')" == 3 ]] || fail "a branch switch recorded the other branch's commits"
ok "a branch switch records nothing"

# The host adapters reach the same record: a Claude Write, a Codex apply_patch,
# a Codex shell commit, and Kimi's Write and shell commit.
hosts="$(fixture hosts)"
start "$hosts" claude-s
claims() { cut -f 2 "$1/.agents/.wrap-edits-$(printf '%s' "$2" | cksum | tr -d ' ')" 2>/dev/null || true; }
printf 'x\n' > "$hosts/claude.txt"
printf '{"hook_event_name":"PostToolUse","session_id":"claude-s","tool_name":"Write","tool_input":{"file_path":"%s/claude.txt"}}' "$hosts" \
  | CLAUDE_PROJECT_DIR="$hosts" bash "$hosts/.agents/claude/adapter.sh" edit-record.sh
claims "$hosts" claude-s | grep -qx claude.txt || fail "the Claude adapter did not record the Write"
printf '{"cwd":"%s","session_id":"codex-s","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\\n*** Add File: codex.txt\\n+x\\n*** End Patch"}}' "$hosts" \
  | (cd "$hosts" && bash .codex/hooks/adapter.sh edit-record.sh)
claims "$hosts" codex-s | grep -qx codex.txt || fail "the Codex adapter did not record the apply_patch"
host_commit() {  # <file> <adapter command> <session> <extra payload fields>
  local event
  for event in PreToolUse PostToolUse; do
    [[ "$event" == PostToolUse ]] && { printf 'x\n' > "$hosts/$1"; git -C "$hosts" add "$1"; git -C "$hosts" commit -q -m "$1"; }
    printf '{"hook_event_name":"%s","cwd":"%s","session_id":"%s","tool_name":"Bash","tool_input":{"command":"git commit"}%s}' \
      "$event" "$hosts" "$3" "$4" | (cd "$hosts" && bash $2 edit-record.sh)
  done
  commits_of "$hosts" "$3" | grep -qx "$(git -C "$hosts" rev-parse HEAD)"
}
host_commit k.txt .codex/hooks/adapter.sh codex-s ',"tool_use_id":"call_1"' || fail "the Codex adapter did not record the shell commit"
if [[ -d "$repo/.kimi" ]]; then
  printf '{"hook_event_name":"PostToolUse","cwd":"%s","session_id":"kimi-s","tool_name":"Write","tool_input":{"file_path":"%s/claude.txt"}}' "$hosts" "$hosts" \
    | bash "$hosts/.kimi/hooks/adapter.sh" edit-record.sh
  claims "$hosts" kimi-s | grep -qx claude.txt || fail "the Kimi adapter did not record the Write"
  host_commit m.txt .kimi/hooks/adapter.sh kimi-s '' || fail "the Kimi adapter did not record the shell commit"
fi
host_commit n.txt .agents/claude/adapter.sh claude-s ',"tool_use_id":"toolu_1"' || fail "the Claude adapter did not record the shell commit"
ok "the Claude, Codex and Kimi adapters feed the same record"

# The record belongs to one sitting: a fresh start clears it, a resume or a
# compaction continues it.
cycle="$(fixture start-cycle)"
start "$cycle" alpha
edit "$cycle" alpha a.txt
commit "$cycle" alpha c.txt
printf '{"project_dir":"%s","session_id":"alpha","event":"PreToolUse","tool_name":"Bash","tool_use_id":"orphan"}' "$cycle" \
  | bash "$cycle/.agents/hooks/policy/edit-record.sh"
record="$cycle/.agents/.wrap-edits-$(printf alpha | cksum | tr -d ' ')"
start "$cycle" alpha resume
start "$cycle" alpha compact
[[ -s "$record" && -s "${record/edits/commits}" ]] || fail "a resume or compaction cleared the record"
start "$cycle" alpha startup
[[ ! -e "$record" && ! -e "${record/edits/commits}" && ! -e "${record/edits/head}-orphan" ]] \
  || fail "a fresh start kept the previous record"
ok "startup clears the record; resume and compact keep it"

# ───────────────────────────── work log ─────────────────────────────
log_on="$(fixture worklog-on ',"worklog":{"enabled":true,"dir":""}')"
start "$log_on" alpha
commit "$log_on" alpha a.txt
out="$(wrap "$log_on" alpha)"
day="$(cd "$log_on" && pwd -P)/.agents/worklog/$(date +%Y-%m-%d).md"
[[ "$out" == *"Work log: $day is older than this session's last commit"* ]] \
  || fail "a commit after the day's log did not raise the work-log line: $out"
mkdir -p "$log_on/.agents/worklog"
touch "$day"
sleep 1
commit "$log_on" alpha b.txt
touch "$day"
out="$(wrap "$log_on" alpha)"
[[ "$out" == *"Committed and unwrapped"* && "$out" != *"Work log:"* ]] \
  || fail "a current day's log still raised the work-log line: $out"
ok "the work-log line appears inside a wrap when the day's file predates the last commit"

log_off="$(fixture worklog-off)"
start "$log_off" alpha
commit "$log_off" alpha a.txt
out="$(wrap "$log_off" alpha)"
[[ "$out" == *"Committed and unwrapped"* && "$out" != *"Work log"* ]] || fail "the work log is off and still spoke: $out"
ok "the work log is silent when off"

printf '\nall session-wrap tests passed\n'
