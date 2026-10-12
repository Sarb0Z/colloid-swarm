#!/usr/bin/env bash
# Direct firing tests for the worktree-sessions policy: a session that enters a
# worktree under .claude/worktrees/ stays filed under its repository's
# project folder, no transcript is lost, and the hook is opt-in.

set -euo pipefail
# A caller such as `git rebase -x` exports these; the git calls below must
# reach only their own temporary repositories.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR
# The operator-wide registration sets this; the opt-in cases need it absent.
unset WORKTREE_SESSIONS_DEFAULT

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
policy="$repo/.agents/hooks/policy/worktree-sessions.sh"
lib="$repo/.agents/hooks/lib/worktree-sessions.py"
adapter="$repo/.agents/claude/adapter.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# git reports the resolved path (/private/var on macOS), and so does the
# session's cwd; build every expected folder name from that same form.
work="$(cd "$scratch" && pwd -P)"
export CLAUDE_CONFIG_DIR="$work/config"
store="$CLAUDE_CONFIG_DIR/projects"
mkdir -p "$store"

slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

new_repo() {
  local dir="$work/$1"
  mkdir -p "$dir/.claude/worktrees"
  git -C "$dir" init -q
  printf '%s\n' "$dir"
}

payload() {  # event tool_name tool_input_json cwd
  printf '{"project_dir":"%s","event":"%s","tool_name":"%s","tool_input":%s,"cwd":"%s"}' \
    "$4" "$1" "$2" "$3" "$4"
}

fire() { bash "$policy" >"$work/stdout" 2>"$work/stderr"; }

# --- opt-in: silent without a switch -----------------------------------------
r="$(new_repo off)"
payload PreToolUse EnterWorktree '{"name":"a"}' "$r" | fire
[[ ! -e "$store/$(slug "$r/.claude/worktrees/a")" ]] || fail "linked with the switch absent"

# --- switch on in the repository: a named EnterWorktree links before it runs --
r="$(new_repo named)"
mkdir -p "$r/.agents"; printf '{"hooks":{"worktree_sessions":{"enabled":true}}}\n' > "$r/.agents/config.json"
payload PreToolUse EnterWorktree '{"name":"a"}' "$r" | fire
link="$store/$(slug "$r/.claude/worktrees/a")"
[[ -L "$link" && "$(readlink "$link")" == "$(slug "$r")" ]] || fail "named EnterWorktree did not link to the root folder"

# --- a name that escapes .claude/worktrees is ignored --------------------------
payload PreToolUse EnterWorktree '{"name":"../../escape"}' "$r" | fire
[[ -z "$(ls "$store" | grep -F escape || true)" ]] || fail "a traversing name produced a link"

# --- operator default: an unnamed worktree's real folder is folded afterwards ---
r="$(new_repo unnamed)"
w="$r/.claude/worktrees/gen-name"; mkdir -p "$w"
root_folder="$store/$(slug "$r")"; mkdir -p "$root_folder"; echo old > "$root_folder/s0.jsonl"
folder="$store/$(slug "$w")"; mkdir -p "$folder/s1/subagents"
echo line1 > "$folder/s1.jsonl"; echo sub > "$folder/s1/subagents/x.jsonl"
payload PostToolUse EnterWorktree '{}' "$w" | WORKTREE_SESSIONS_DEFAULT=true fire
[[ -L "$folder" ]] || fail "unnamed EnterWorktree: folder not replaced by a link"
[[ "$(cat "$root_folder/s1.jsonl")" == line1 && -f "$root_folder/s1/subagents/x.jsonl" && -f "$root_folder/s0.jsonl" ]] \
  || fail "unnamed EnterWorktree: a transcript is missing from the root folder"
echo line2 >> "$folder/s1.jsonl"
[[ "$(tail -n1 "$root_folder/s1.jsonl")" == line2 ]] || fail "a write through the worktree path missed the root file"

# --- a repository that says false wins over the operator default ---------------
r="$(new_repo refused)"
mkdir -p "$r/.agents"; printf '{"hooks":{"worktree_sessions":{"enabled":false}}}\n' > "$r/.agents/policy.json"
payload PreToolUse EnterWorktree '{"name":"a"}' "$r" | WORKTREE_SESSIONS_DEFAULT=true fire
[[ ! -e "$store/$(slug "$r/.claude/worktrees/a")" ]] || fail "linked although policy.json says false"

# --- SessionStart inside a worktree (claude --worktree), from a subdirectory ----
r="$(new_repo flag)"
w="$r/.claude/worktrees/f"; mkdir -p "$w/src"
payload SessionStart '' '{}' "$w/src" | WORKTREE_SESSIONS_DEFAULT=true fire
[[ -L "$store/$(slug "$w")" ]] || fail "SessionStart in a worktree did not link its folder"
payload SessionStart '' '{}' "$r" | WORKTREE_SESSIONS_DEFAULT=true fire
[[ "$(ls "$store" | grep -c "^$(slug "$r")" )" -eq 2 ]] || fail "SessionStart at the root created a link"

# --- through the adapter, with Claude's own payload shape ----------------------
r="$(new_repo adapter)"
printf '{"hook_event_name":"PreToolUse","tool_name":"EnterWorktree","tool_input":{"name":"via"},"cwd":"%s"}' "$r" |
  CLAUDE_PROJECT_DIR="$r" WORKTREE_SESSIONS_DEFAULT=true bash "$adapter" worktree-sessions.sh 2>"$work/stderr" \
  || fail "adapter run exited non-zero: $(cat "$work/stderr")"
[[ -L "$store/$(slug "$r/.claude/worktrees/via")" ]] || fail "adapter run did not link"

# --- a clash is parked and named, never deleted --------------------------------
r="$(new_repo clash)"
w="$r/.claude/worktrees/c"; mkdir -p "$w"
root_folder="$store/$(slug "$r")"; mkdir -p "$root_folder/memory"; echo theirs > "$root_folder/memory/m.md"
folder="$store/$(slug "$w")"; mkdir -p "$folder/memory"; echo mine > "$folder/memory/m.md"
payload SessionStart '' '{}' "$w" | WORKTREE_SESSIONS_DEFAULT=true fire
python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))["systemMessage"]; sys.exit("memory/m.md" not in m)' "$work/stdout" \
  || fail "the clash did not reach the person as a systemMessage"
parked="$(ls -d "$folder".unmerged-* 2>/dev/null | head -n1)"
[[ -n "$parked" && "$(cat "$parked/memory/m.md")" == mine && "$(cat "$root_folder/memory/m.md")" == theirs ]] \
  || fail "the clashing file was not kept on both sides"

python3 "$lib" sweep 2>"$work/stderr"
grep -q 'merge them by hand' "$work/stderr" || fail "sweep did not list the parked folder"

# --- an unreadable policy file keeps the hook off, whatever the default -------
r="$(new_repo corrupt)"
mkdir -p "$r/.agents"; printf '<<<<<<< HEAD\n' > "$r/.agents/policy.json"
payload PreToolUse EnterWorktree '{"name":"a"}' "$r" | WORKTREE_SESSIONS_DEFAULT=true fire
[[ ! -e "$store/$(slug "$r/.claude/worktrees/a")" ]] || fail "linked although policy.json is unreadable"
grep -q 'not running' "$work/stderr" || fail "an unreadable policy.json was not reported"

# --- a default that is neither true nor false is reported and means off --------
r="$(new_repo badflag)"
payload PreToolUse EnterWorktree '{"name":"a"}' "$r" | WORKTREE_SESSIONS_DEFAULT=yes fire
[[ ! -e "$store/$(slug "$r/.claude/worktrees/a")" ]] || fail "linked with WORKTREE_SESSIONS_DEFAULT=yes"
grep -q 'neither true nor false' "$work/stderr" || fail "an invalid default was not reported"

# --- the three registrations exist in the Claude settings ----------------------
for spec in 'PreToolUse EnterWorktree' 'PostToolUse EnterWorktree' 'SessionStart -'; do
  read -r event matcher <<<"$spec"
  python3 - "$repo/.agents/claude/settings.json" "$event" "$matcher" <<'EOF' || fail "no $event registration ($matcher)"
import json, sys
groups = json.load(open(sys.argv[1]))["hooks"].get(sys.argv[2], [])
want = None if sys.argv[3] == "-" else sys.argv[3]
sys.exit(not any(g.get("matcher") == want and any(h["command"].endswith("adapter.sh\" worktree-sessions.sh") for h in g["hooks"]) for g in groups))
EOF
done

# --- a live writer keeps every line through a fold -----------------------------
# The writer appends by path and recreates a missing folder, as Claude Code
# does; the fold must never leave the name missing long enough to split it.
r="$(new_repo live)"
root_folder="$store/$(slug "$r")"
for i in $(seq 1 40); do
  w="$r/.claude/worktrees/l$i"; mkdir -p "$w"
  folder="$store/$(slug "$w")"; mkdir -p "$folder"
  python3 - "$folder/s.jsonl" "$work/count" <<'EOF' &
import os, sys, time
path, count = sys.argv[1], 0
end = time.time() + 0.4
while time.time() < end:
    try:
        with open(path, "a") as f: f.write(f"{count}\n")
    except FileNotFoundError:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        continue
    count += 1
open(sys.argv[2], "w").write(str(count))
EOF
  writer=$!
  sleep 0.1
  payload SessionStart '' '{}' "$w" | WORKTREE_SESSIONS_DEFAULT=true fire
  wait "$writer"
  [[ -L "$folder" ]] || fail "live round $i: folder not linked ($(cat "$work/stderr"))"
  [[ "$(wc -l < "$root_folder/s.jsonl" | tr -d ' ')" == "$(cat "$work/count")" ]] \
    || fail "live round $i: root copy has $(wc -l < "$root_folder/s.jsonl") of $(cat "$work/count") lines"
  [[ -z "$(ls -d "$folder".unmerged-* 2>/dev/null)" ]] || fail "live round $i: a fragment was parked"
  rm "$root_folder/s.jsonl"
done

# --- malformed input never blocks ---------------------------------------------
printf 'not json' | fire || fail "malformed payload exited non-zero"
grep -q 'hook failed' "$work/stderr" || fail "malformed payload was not reported"

# --- concurrent folds never delete the root's files ----------------------------
r="$(new_repo race)"
root_folder="$store/$(slug "$r")"; mkdir -p "$root_folder"; echo keep > "$root_folder/s0.jsonl"
for i in $(seq 1 12); do
  folder="$store/$(slug "$r/.claude/worktrees/w$i")"
  mkdir -p "$folder"; echo "t$i" > "$folder/s$i.jsonl"
  for _ in 1 2 3 4; do python3 "$lib" sweep 2>/dev/null & done
  wait
  [[ -L "$folder" ]] || fail "race round $i: folder not linked"
  for j in $(seq 0 "$i"); do
    [[ -s "$root_folder/s$j.jsonl" ]] || fail "race round $i: s$j.jsonl lost from the root folder"
  done
done

# --- sweep: a dry run changes nothing, a second sweep is a no-op ---------------
r="$(new_repo sweep)"
folder="$store/$(slug "$r/.claude/worktrees/old")"; mkdir -p "$folder"; echo x > "$folder/s.jsonl"
python3 "$lib" sweep --dry-run 2>/dev/null | grep -q "would fold" || fail "dry run did not list the folder"
[[ -d "$folder" && ! -L "$folder" ]] || fail "dry run changed the folder"
python3 "$lib" sweep 2>/dev/null
[[ -L "$folder" ]] || fail "sweep did not fold"
before="$(ls -la "$store")"
python3 "$lib" sweep 2>/dev/null
[[ "$(ls -la "$store")" == "$before" ]] || fail "a second sweep changed the store"

echo "worktree-sessions: all checks passed"
