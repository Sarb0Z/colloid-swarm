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

mode_of() { python3 -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$1"; }

# With the marker: the exact bytes, nothing printed, only mv on PATH, and a
# copy only its owner reads.
touch "$folder/sess-1.on"
bin="$scratch/bin"
mkdir -p "$bin"
ln -s "$(command -v mv)" "$bin/mv"
relay_run PATH="$bin"
[[ -z "$out" && -z "$err" ]] || fail "with the marker the relay printed or failed: out=$out err=$err"
cmp -s <(printf '%s' "$payload") "$folder/sess-1.json" || fail "the copy differs from stdin: $(od -c "$folder/sess-1.json" | head -5)"
[[ ! -e "$calls" ]] || fail "with the marker the person's own line still ran"
[[ -z "$(find "$folder" -name '*.tmp')" ]] || fail "the relay left a temporary file: $(ls -A "$folder")"
[[ "$(mode_of "$folder/sess-1.json")" == 0o600 ]] || fail "the copy is readable beyond its owner: $(mode_of "$folder/sess-1.json")"
ok "with the marker the relay writes stdin byte for byte as 0600, prints nothing, and starts no process but mv"

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

# --- the first run of a session waits for the band's marker -----------------
# A checkout with the band installed: its skills link resolves.
banded="$scratch/banded"
mkdir -p "$banded/.agents/claude" "$banded/.agents/claude/mods/status-band/.claude-plugin" "$banded/.claude/skills"
cp "$repo/.agents/claude/statusline.sh" "$banded/.agents/claude/"
ln -s ../../.agents/claude/mods/status-band "$banded/.claude/skills/colloid-status-band"
waited=0
banded_run() {  # <session> -> sets out, waited (seconds, to the tenth)
  local start="$EPOCHREALTIME"
  out="$(printf '{"session_id":"%s"}' "$1" | env -u CLAUDE_PROFILE -u COLLOID_STATUS_DELEGATED HOME="$scratch" USER=tester \
    TMPDIR="$tmp" CLAUDE_CONFIG_DIR="$own" bash "$banded/.agents/claude/statusline.sh")"
  waited="$(python3 -c 'import sys; print(round(float(sys.argv[2]) - float(sys.argv[1]), 1))' "$start" "$EPOCHREALTIME")"
}
slower() { python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)' "$1" "$2"; }

( sleep 0.4; touch "$folder/late.on" ) &
banded_run late
wait
[[ -z "$out" && -f "$folder/late.json" ]] || fail "a marker that appeared mid-wait did not take the line: out=$out"
slower "$waited" 0.3 && ! slower "$waited" 1.4 || fail "the run did not end soon after the marker appeared: ${waited}s"
ok "a marker that appears while the first run waits takes the line: nothing printed, the JSON written"

banded_run absent
[[ "$out" == "own-line" && -f "$folder/absent.nomod" && ! -e "$folder/absent.json" ]] \
  || fail "with no marker the wait did not end in the person's line and a .nomod: out=$out $(ls -A "$folder")"
slower "$waited" 1.4 || fail "the person's line came before the wait ran out: ${waited}s"
ok "with no marker the first run waits about 1.5 s, writes <id>.nomod and draws the person's line"

banded_run absent
[[ "$out" == "own-line" ]] || fail "a run after .nomod did not draw the person's line: $out"
! slower "$waited" 0.5 || fail "a run after .nomod waited again: ${waited}s"
ok "a later run for that id sees <id>.nomod and hands over with no wait"

touch "$folder/absent.on"
banded_run absent
[[ -z "$out" && -f "$folder/absent.json" ]] || fail "a marker beside .nomod did not win: out=$out"
ok "a marker that appears after <id>.nomod still wins"

rm "$banded/.claude/skills/colloid-status-band"
banded_run nolink
[[ "$out" == "own-line" && ! -e "$folder/nolink.nomod" ]] || fail "with no band link the relay did not hand over at once: out=$out"
! slower "$waited" 0.5 || fail "with no band link the relay waited: ${waited}s"
ok "a checkout without the band hands over with no wait"

# The person's line running this script again stops before any wait.
ln -s ../../.agents/claude/mods/status-band "$banded/.claude/skills/colloid-status-band"
start="$EPOCHREALTIME"
out="$(printf '{"session_id":"loop"}' | env HOME="$scratch" USER=tester TMPDIR="$tmp" COLLOID_STATUS_DELEGATED=1 bash "$banded/.agents/claude/statusline.sh")"
waited="$(python3 -c 'import sys; print(round(float(sys.argv[2]) - float(sys.argv[1]), 1))' "$start" "$EPOCHREALTIME")"
[[ -z "$out" ]] && ! slower "$waited" 0.5 || fail "the second pass waited or drew: ${waited}s $out"
ok "the second pass of a looping status line stops before any wait"
