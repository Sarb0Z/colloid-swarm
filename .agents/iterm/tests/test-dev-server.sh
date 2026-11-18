#!/usr/bin/env bash
# Tests for connect/dev-server. A fake it2ssh replays "<status> <seconds>" lines
# (the status it exits with, the seconds the connection lasted on a fake clock)
# and records its arguments; a fake sleep records each delay and does not wait.
set -uo pipefail

IT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
LOOP=$IT/connect/dev-server
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fails=$((fails + 1)); }
eq() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }
has() { if [[ $3 == *"$2"* ]]; then ok "$1"; else bad "$1: [$2] not in [$3]"; fi; }

cat >"$T/it2ssh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_ARGS"
n=$(($(cat "$FAKE_CALLS" 2>/dev/null || echo 0) + 1))
echo "$n" >"$FAKE_CALLS"
line=$(sed -n "${n}p" "$FAKE_PLAN")
[[ -z $line ]] && line=$(tail -n 1 "$FAKE_PLAN")
read -r status seconds message <<<"$line"
[[ -n $message ]] && echo "$message" >&2
echo $(($(cat "$FAKE_CLOCK") + seconds)) >"$FAKE_CLOCK"
exit "$status"
STUB
cat >"$T/sleep" <<'STUB'
#!/usr/bin/env bash
echo "$1" >>"$FAKE_DELAYS"
STUB
cat >"$T/now" <<'STUB'
#!/usr/bin/env bash
cat "$FAKE_CLOCK"
STUB
chmod +x "$T/it2ssh" "$T/sleep" "$T/now"
export FAKE_ARGS=$T/args FAKE_CALLS=$T/calls FAKE_PLAN=$T/plan FAKE_CLOCK=$T/clock FAKE_DELAYS=$T/delays
export IT2SSH=$T/it2ssh DEV_SERVER_HOST=testhost DEV_SERVER_SLEEP=$T/sleep DEV_SERVER_NOW=$T/now

play() { # plan lines...: run the loop, a key waiting on stdin
  rm -f "$FAKE_ARGS" "$FAKE_CALLS" "$FAKE_DELAYS"
  echo 1000 >"$FAKE_CLOCK"
  printf '%s\n' "$@" >"$FAKE_PLAN"
  out=$(printf x | "$LOOP" 2>&1)
  rc=$?
  calls=$(cat "$FAKE_CALLS")
  delays=
  [[ -f $FAKE_DELAYS ]] && delays=$(tr '\n' ' ' <"$FAKE_DELAYS")
}

play "255 1" "255 1" "0 5"
eq "255 twice then a clean exit: three tries" 3 "$calls"
eq "255 twice then a clean exit: delays" "2 4 " "$delays"
eq "clean exit: status 0" 0 "$rc"
eq "the remote command and the agent flag" "-A testhost tmux -CC new -A -s main" "$(head -n 1 "$FAKE_ARGS")"
has "one line per retry names the next delay" "lost (status 255, try 1 of 40); retrying in 2 s" "$out"
has "one line per retry names the next delay (2)" "try 2 of 40); retrying in 4 s" "$out"
has "the stop says the status and why" "stopped with status 0: the session ended or was detached." "$out"
has "the tab waits for a key" "Press any key to close." "$out"

play "1 1" "0 1"
eq "status 1 stops: one try" 1 "$calls"
eq "status 1 stops: no sleep" "" "$delays"
eq "status 1 stops: its status is the exit status" 1 "$rc"
has "status 1 says why" "stopped with status 1: ssh or the remote command failed." "$out"

for refusal in "Permission denied (publickey)." "Host key verification failed." \
  "Received disconnect: Too many authentication failures" "ssh: Could not resolve hostname testhost: nodename nor servname provided"; do
  play "255 1 $refusal"
  eq "255 with [$refusal]: one try, no retry" 1 "$calls"
  eq "255 with [$refusal]: status 255" 255 "$rc"
  has "255 with [$refusal]: ssh's own words stay visible" "$refusal" "$out"
  has "255 with [$refusal]: says retrying cannot help" "will not retry" "$out"
  has "255 with [$refusal]: waits for a key" "Press any key to close." "$out"
done
play "255 1 Connection timed out" "0 1"
eq "255 with another message still retries" 2 "$calls"

play "255 1" "255 1" "255 1" "255 1" "255 1" "255 1" "255 1" "255 1"
eq "backoff doubles and holds at 30" "2 4 8 16 30 30 30 " "$(printf '%s' "$delays" | head -c 18)"

play "255 1"
eq "the cap: 40 consecutive failed tries" 40 "$calls"
eq "the cap: 39 sleeps" 39 "$(wc -w <"$FAKE_DELAYS" | tr -d ' ')"
eq "the cap: status 255" 255 "$rc"
has "the cap says so" "40 failed tries in a row" "$out"

play "255 1" "255 1" "255 1" "255 61" "255 1" "0 1"
eq "a connection over 60 s resets the delay and the count" "2 4 8 2 4 " "$(printf '%s' "$delays" | head -c 10)"
eq "a connection over 60 s: then the clean exit" 0 "$rc"

play "255 60" "255 60" "255 60" "0 1"
eq "a 60 s connection is not over 60 s: backoff continues" "2 4 8 " "$delays"

[[ -x $IT/connect/dev-server ]] && ok "dev-server is executable" || bad "dev-server is not executable"
cmd=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["Profiles"][0]["Command"])' "$IT/connect/dev-server.json")
eq "the profile's command is the installed script" "/Users/alice/.local/bin/dev-server" "$cmd"

((fails == 0)) && echo "dev-server tests passed" || { echo "$fails dev-server tests failed" >&2; exit 1; }
