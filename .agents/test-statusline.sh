#!/usr/bin/env bash
# Firing tests for the status line relay: with the band's marker it copies the
# status JSON to the band's file and prints nothing, starting no process but
# mv; without it, the person's own status line runs once, never loops, and a
# missing jq, an unreadable settings.json or an id that is no file name changes
# nothing about that.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

fixture="$scratch/repo"
mkdir -p "$fixture/.agents/claude"
cp "$repo/.agents/claude/statusline.sh" "$fixture/.agents/claude/"
relay="$fixture/.agents/claude/statusline.sh"
tmp="$scratch/tmp"
folder="$tmp/colloid-status-tester"
mkdir -p "$folder"
chmod 700 "$folder"
own="$scratch/own"
mkdir -p "$own"
calls="$scratch/calls"

# A trailing newline and a backslash: the copy must keep every byte.
payload='{"session_id":"sess-1","model":{"display_name":"Fable 5.1"},"note":"a\\b"}
'
relay_run() {  # [VAR=value ...] -> runs the relay on $payload; sets out, err
  out="$(printf '%s' "$payload" | env -u CLAUDE_PROFILE -u COLLOID_STATUS_DELEGATED HOME="$scratch" USER=tester \
    TMPDIR="$tmp/" CLAUDE_CONFIG_DIR="$own" "$@" "$(command -v bash)" "$relay" 2>"$scratch/err")"
  err="$(cat "$scratch/err")"
}
printf '{"statusLine": {"type": "command", "command": "cat >/dev/null; echo own >> %s; echo own-line"}}\n' "$calls" > "$own/settings.json"

# With the marker: the exact bytes, nothing printed, and only mv on PATH.
touch "$folder/sess-1.on"
bin="$scratch/bin"
mkdir -p "$bin"
ln -s "$(command -v mv)" "$bin/mv"
relay_run PATH="$bin"
[[ -z "$out" && -z "$err" ]] || fail "with the marker the relay printed or failed: out=$out err=$err"
cmp -s <(printf '%s' "$payload") "$folder/sess-1.json" || fail "the copy differs from stdin: $(od -c "$folder/sess-1.json" | head -5)"
[[ ! -e "$calls" ]] || fail "with the marker the person's own line still ran"
[[ -z "$(find "$folder" -name '*.tmp')" ]] || fail "the relay left a temporary file: $(ls -A "$folder")"
ok "with the marker the relay writes stdin byte for byte, prints nothing, and starts no process but mv"

# Without the marker: the person's own line, once.
rm "$folder/sess-1.on" "$folder/sess-1.json"
relay_run
[[ "$out" == "own-line" && "$(grep -c own "$calls")" == 1 ]] || fail "without the marker the person's own line did not run once: $out"
[[ ! -e "$folder/sess-1.json" ]] || fail "without the marker the relay wrote the band's file"
ok "without the marker the person's own status line runs once and nothing is written"

# An id that is not a file name: nothing written, even beside a marker it names.
rm -f "$calls"
mkdir -p "$folder/a"
touch "$tmp/x.on" "$folder/a/b.on" "$folder/...on"
for id in '../x' 'a/b' '..'; do
  payload="{\"session_id\":\"$id\"}"
  relay_run
  [[ "$out" == "own-line" ]] || fail "session_id $id did not hand over to the person's own line: $out"
done
[[ -z "$(find "$tmp" -name '*.json')" ]] || fail "an id holding / or .. wrote a file: $(find "$tmp" -name '*.json')"
rm -r "$tmp/x.on" "$folder/a" "$folder/...on"
payload='{"session_id":"sess-1"}'
ok "a session_id holding / or .. writes nothing and hands over to the person's own line"

# A folder that is a link, or not this user's, is never written through.
mv "$folder" "$tmp/real"
ln -s "$tmp/real" "$folder"
touch "$tmp/real/sess-1.on"
relay_run
[[ "$out" == "own-line" && ! -e "$tmp/real/sess-1.json" ]] || fail "the relay wrote through a linked folder: $out"
rm "$folder"
mv "$tmp/real" "$folder"
rm "$folder/sess-1.on"
ok "a linked runtime folder is not written through"

printf '%s\n' '{}' > "$own/settings.json"
relay_run
[[ -z "$out" ]] || fail "with no status line of the person's, it drew: $out"
ok "with no status line of the person's, it draws nothing"

# A person's status line that is this script must not recurse; the alarm turns
# a loop into a failure instead of a hung test.
printf '{"statusLine": {"type": "command", "command": "bash %s"}}\n' "$relay" > "$own/settings.json"
out="$(printf '%s' "$payload" \
  | env -u CLAUDE_PROFILE -u COLLOID_STATUS_DELEGATED HOME="$scratch" USER=tester TMPDIR="$tmp" CLAUDE_CONFIG_DIR="$own" \
    perl -e 'alarm 10; exec @ARGV' bash "$relay")" \
  || fail "a status line that runs this script looped or failed"
[[ -z "$out" ]] || fail "a status line that runs this script drew: $out"
ok "a status line that runs this script stops on the second pass"

# A machine with no jq: everything the relay needs except jq.
nojq="$scratch/nojq"
mkdir -p "$nojq"
for tool in bash cat python3 mv; do ln -s "$(command -v "$tool")" "$nojq/$tool"; done
printf '%s\n' '{"statusLine": {"type": "command", "command": "cat >/dev/null; echo own-line"}}' > "$own/settings.json"
out="$(printf '%s' "$payload" | env -i HOME="$scratch" USER=tester TMPDIR="$tmp" PATH="$nojq" CLAUDE_CONFIG_DIR="$own" "$nojq/bash" "$relay")"
[[ "$out" == "own-line" ]] || fail "without jq the person's own status line did not run: $out"
ok "on a machine without jq the person's own status line still draws"

printf '%s\n' '{"statusLine": ' > "$own/settings.json"
relay_run
[[ "$out" == "status line: $own/settings.json is unreadable" ]] || fail "a malformed user settings.json was not reported: $out"
[[ "$err" == *JSONDecodeError* ]] || fail "the parse error did not reach stderr: $err"
ok "a malformed user settings.json is named on the line"

# The committed wiring, not just the script: the command string from settings.json
# resolves the script through the launch folder (CLAUDE_PROJECT_DIR) first.
printf '%s\n' '{"statusLine": {"type": "command", "command": "cat >/dev/null; echo own-line"}}' > "$own/settings.json"
touch "$folder/sess-1.on"
wired="$(jq -r '.statusLine.command' "$repo/.agents/claude/settings.json")"
out="$(printf '%s' '{"session_id":"sess-1","wired":true}' \
  | env -u CLAUDE_PROFILE HOME="$scratch" USER=tester TMPDIR="$tmp" CLAUDE_CONFIG_DIR="$own" CLAUDE_PROJECT_DIR="$fixture" bash -c "$wired")"
[[ -z "$out" && "$(cat "$folder/sess-1.json")" == *'"wired":true'* ]] || fail "the statusLine command in settings.json did not relay: $out"
ok "the statusLine command committed in settings.json relays the status"
