#!/usr/bin/env bash
# Firing tests for the status strip: rendering, the account badge, the toggle's
# hand-over to the person's own status line, and a missing jq.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

fixture="$scratch/repo"
mkdir -p "$fixture/.agents/claude" "$fixture/.agents/hooks/lib"
cp "$repo/.agents/claude/statusline.sh" "$fixture/.agents/claude/"
cp "$repo/.agents/hooks/lib/config.py" "$fixture/.agents/hooks/lib/"
strip="$fixture/.agents/claude/statusline.sh"
home="$scratch/home"
plain="$scratch/plain"
mkdir -p "$home/.claude/projects" "$home/.claude-personal/projects" "$plain"

payload() {  # <transcript_path> <current_dir> -> stdin JSON
  printf '{"transcript_path":"%s","workspace":{"current_dir":"%s"},"model":{"display_name":"Fable 5.1"},"context_window":{"used_percentage":42,"context_window_size":1000000,"current_usage":{"input_tokens":420000}}}' "$1" "$2"
}
run() {  # <transcript_path> <current_dir> [VAR=value ...] -> the strip, colours stripped
  local transcript="$1" dir="$2"
  shift 2
  payload "$transcript" "$dir" | env -u CLAUDE_PROFILE -u CLAUDE_CONFIG_DIR -u COLLOID_STATUS_DELEGATED HOME="$home" "$@" bash "$strip" \
    | sed -E $'s/\x1b\\[[0-9;]*m//g'
}

out="$(run "$home/.claude/projects/s.jsonl" "$plain")"
[[ "$out" == *"Fable 5.1"* && "$out" == *"420K/1.0M"* ]] || fail "model or context missing: $out"
ok "draws the model and the context fill"

out="$(run "$home/.claude/projects/s.jsonl" "$plain" CLAUDE_PROFILE=work)"
[[ "$out" == *"● WORK"* ]] || fail "CLAUDE_PROFILE did not label the badge: $out"
ok "the launcher's CLAUDE_PROFILE labels the badge"

out="$(run "$home/.claude-personal/projects/s.jsonl" "$plain")"
[[ "$out" == *"● PERSONAL"* ]] || fail "a named config folder did not label the badge: $out"
ok "a ~/.claude-<name> folder labels the badge"

out="$(run "$home/.claude/projects/s.jsonl" "$plain")"
[[ "$out" != *"● "* ]] || fail "the default folder got a badge with no label: $out"
ok "the default folder with no CLAUDE_PROFILE shows no badge"

git -C "$scratch" init -q -b trunk tree
printf 'x\n' > "$scratch/tree/new.txt"
out="$(run "$home/.claude/projects/s.jsonl" "$scratch/tree")"
[[ "$out" == *"trunk"* && "$out" == *"●1"* ]] || fail "branch or dirty count missing: $out"
ok "draws the branch and the dirty count"

# Switched off, the person's own status line draws instead.
printf '%s\n' '{"hooks": {"status_strip": {"enabled": false}}}' > "$fixture/.agents/policy.json"
own="$scratch/own"
mkdir -p "$own"
printf '%s\n' '{"statusLine": {"type": "command", "command": "cat >/dev/null; echo own-strip"}}' > "$own/settings.json"
out="$(run "$home/.claude/projects/s.jsonl" "$plain" CLAUDE_CONFIG_DIR="$own")"
[[ "$out" == "own-strip" ]] || fail "switched off, the person's own status line did not run: $out"
ok "switched off in policy.json, the person's own status line draws"

printf '%s\n' '{}' > "$own/settings.json"
out="$(run "$home/.claude/projects/s.jsonl" "$plain" CLAUDE_CONFIG_DIR="$own")"
[[ -z "$out" ]] || fail "switched off with no status line of the person's, it drew: $out"
ok "switched off with no status line of the person's, it draws nothing"

# A person's status line that is this script must not recurse; the alarm turns
# a loop into a failure instead of a hung test.
printf '{"statusLine": {"type": "command", "command": "bash %s"}}\n' "$strip" > "$own/settings.json"
out="$(payload "$home/.claude/projects/s.jsonl" "$plain" \
  | env -u CLAUDE_PROFILE -u COLLOID_STATUS_DELEGATED HOME="$home" CLAUDE_CONFIG_DIR="$own" perl -e 'alarm 10; exec @ARGV' bash "$strip")" \
  || fail "a status line that runs this script looped or failed"
[[ -z "$out" ]] || fail "a status line that runs this script drew: $out"
ok "a status line that runs this script stops on the second pass"

# A machine with no jq: everything the script needs except jq.
bin="$scratch/bin"
mkdir -p "$bin"
for tool in bash cat dirname python3; do ln -s "$(command -v "$tool")" "$bin/$tool"; done

printf '%s\n' '{"statusLine": {"type": "command", "command": "cat >/dev/null; echo own-strip"}}' > "$own/settings.json"
out="$(payload "$home/.claude/projects/s.jsonl" "$plain" | env -i HOME="$home" PATH="$bin" CLAUDE_CONFIG_DIR="$own" "$bin/bash" "$strip")"
[[ "$out" == "own-strip" ]] || fail "switched off without jq, the person's own status line did not run: $out"
ok "switched off on a machine without jq, the person's own status line still draws"

printf '%s\n' '{"statusLine": ' > "$own/settings.json"
out="$(run "$home/.claude/projects/s.jsonl" "$plain" CLAUDE_CONFIG_DIR="$own" 2>"$scratch/err")"
[[ "$out" == "status strip: switched off, and $own/settings.json is unreadable" ]] \
  || fail "a malformed user settings.json was not reported: $out"
grep -q JSONDecodeError "$scratch/err" || fail "the parse error did not reach stderr: $(cat "$scratch/err")"
ok "switched off with a malformed user settings.json, the strip says so"
rm "$fixture/.agents/policy.json"

# The committed wiring, not just the script: the command string from settings.json
# resolves the script through CLAUDE_PROJECT_DIR.
wired="$(jq -r '.statusLine.command' "$repo/.agents/claude/settings.json")"
out="$(payload "$home/.claude/projects/s.jsonl" "$plain" \
  | env -u CLAUDE_PROFILE HOME="$home" CLAUDE_PROJECT_DIR="$fixture" bash -c "$wired" | sed -E $'s/\x1b\\[[0-9;]*m//g')"
[[ "$out" == *"Fable 5.1"* ]] || fail "the statusLine command in settings.json did not draw: $out"
ok "the statusLine command committed in settings.json draws the strip"

# Without jq the strip says so instead of drawing a row of blanks.
out="$(payload "$home/.claude/projects/s.jsonl" "$plain" | env -i HOME="$home" PATH="$bin" "$bin/bash" "$strip")"
[[ "$out" == "status strip: install jq to draw it" ]] || fail "missing jq was not reported: $out"
ok "a missing jq is reported on the strip"
