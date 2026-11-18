#!/usr/bin/env bash
# Firing tests for the phone link's permission hook (.agents/iterm/phone), with
# no Signal, no launchd and no real Claude Code. Seams:
#   (a) every module's own tests (iterm/phone/test_*.py, stdlib unittest): the
#       decisions, with clocks and sockets passed in. Each file's header says
#       what it catches and misses.
#   (b) the hook as Claude Code runs it: the adapter hooks/phone-permission.sh
#       through its ~/.local/bin link, the payload on stdin, below a process
#       named `claude`, against a real phone_link.py and a stand-in for
#       signal-cli's socket (fake_signal_cli.py) in a scratch state folder.
#       Catches a hook that prints or waits where it must not, a decision that
#       does not reach stdout, a reply sent before the transcript shows the
#       ending, a hook left running after its session or the service ended, a
#       state file other users can read and a TCP listener. Misses Claude Code
#       applying the decision, the real signal-cli and the phone, which the
#       live checkpoint shows (acceptance 1, 2, 5, 11 and 17 of the spec).
set -uo pipefail
unset CLAUDE_CONFIG_DIR CLAUDE_PROJECT_DIR CLAUDE_PROFILE PHONE_LINK_STATE
export PYTHONDONTWRITEBYTECODE=1

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
phone="$repo/.agents/iterm/phone"
fails=0
ok() { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }
eq() { # name expected actual
  if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi
}

# --- (a) the modules ---------------------------------------------------------
if python3 -m unittest discover -s "$phone" -p 'test_*.py' 2>"${TMPDIR:-/tmp}/phone-unit.$$"; then
  ok "module tests: $(tail -3 "${TMPDIR:-/tmp}/phone-unit.$$" | head -1)"
else
  cat "${TMPDIR:-/tmp}/phone-unit.$$" >&2
  bad "module tests"
fi
rm -f "${TMPDIR:-/tmp}/phone-unit.$$"

# --- (b) the hook as Claude Code runs it ---------------------------------------
# A short folder: a Unix socket's path holds about 100 characters.
T=$(mktemp -d /tmp/pl.XXXXXX)
service_pid="" signal_pid=""
stop() { [[ -n $1 ]] && kill "$1" 2>/dev/null && wait "$1" 2>/dev/null; return 0; }
trap 'stop "$service_pid"; stop "$signal_pid"; kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT

export HOME="$T/home" PHONE_LINK_STATE="$T/s"
S=$PHONE_LINK_STATE
mkdir -p "$HOME/.local/bin" "$HOME/.claude/projects/p" "$T/repo/.agents" "$T/repo/src" "$T/plain" "$T/control" "$T/bin"
echo '# harness' >"$T/repo/.agents/AGENTS.md"
ln -s "$phone/hooks/phone-permission.sh" "$HOME/.local/bin/phone-permission.sh"
hook="$HOME/.local/bin/phone-permission.sh"
transcript="$HOME/.claude/projects/p/5e55.jsonl"
token="ghp_$(printf 'a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8')"

# Claude Code, as far as the hook can tell: a process named `claude` that starts the
# hook command with the payload on stdin. run.py keeps what the hook did.
ln -s "$(command -v bash)" "$T/bin/claude"
cat >"$T/run.py" <<'PY'
import json, os, subprocess, sys, time
out, cwd, tool_input = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
os.makedirs(out, exist_ok=True)
payload = {"session_id": "5e55", "transcript_path": os.environ["TRANSCRIPT"], "cwd": cwd, "prompt_id": "prompt-1",
           "permission_mode": "default", "hook_event_name": "PermissionRequest", "tool_name": os.environ.get("TOOL", "Bash"),
           "tool_input": tool_input}
began = time.time()
hook = subprocess.Popen([os.environ["HOOK"]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
open(os.path.join(out, "pid"), "w").write(str(hook.pid))
try:
    stdout, stderr = hook.communicate(json.dumps(payload), timeout=60)
except subprocess.TimeoutExpired:
    # No row waits this long: a hook still running is the failure, and the test must end.
    hook.kill()
    stdout, stderr = hook.communicate()
    stderr += "\nrun.py: the hook still ran after 60 s and was killed"
for name, value in (("stdout", stdout), ("stderr", stderr), ("code", str(hook.returncode)),
                    ("seconds", f"{time.time() - began:.2f}")):
    open(os.path.join(out, name), "w").write(value)
PY
cat >"$T/claude.sh" <<'SH'
mkdir -p "$1"
echo "$$" >"$1/claude-pid"
python3 "$(dirname "$0")/run.py" "$@"
SH
claude() { # outdir cwd tool-input-json: one permission prompt, to the hook's end
  HOOK=$hook TRANSCRIPT=$transcript "$T/bin/claude" "$T/claude.sh" "$@"
}
job=""
prompt() { # the same, not waited for: `wait "$job"` is the hook's end, and $job is the `claude` process
  HOOK=$hook TRANSCRIPT=$transcript "$T/bin/claude" "$T/claude.sh" "$@" &
  job=$!
}
writes() { python3 "$phone/fixtures.py" "$transcript" "$@"; }
wait_for() { # seconds command...: true once the command holds
  local limit=$(( $1 * 10 )) n=0
  shift
  until "$@" >/dev/null 2>&1; do
    n=$((n + 1))
    ((n >= limit)) && return 1
    sleep 0.1
  done
}
sends() { python3 - "$T/requests.jsonl" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    request = json.loads(line)
    if request.get("method") == "send":
        print(json.dumps(request["params"]["message"]))
PY
}
sent_count() { sends | wc -l | tr -d ' '; }
last_sent() { sends | tail -1 | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()))'; }
has_sent() { [[ $(sent_count) -ge $1 ]]; }
last_id() { last_sent | head -1 | sed -E 's/^\[([a-z]-[a-z]{5})\].*/\1/'; }
phone_says() { printf '%s\n' "$1" >"$T/control/say.tmp" && mv "$T/control/say.tmp" "$T/control/say"; }
# A message typed as a Signal reply to the last message the phone got.
phone_replies() { printf '%s\n' "$1" >"$T/control/reply.tmp" && mv "$T/control/reply.tmp" "$T/control/reply"; }
state_of() { python3 - "$S/events.jsonl" "$1" <<'PY'
import json, sys
last = [json.loads(line) for line in open(sys.argv[1]) if json.loads(line)["id"] == sys.argv[2]][-1]
print(last["state"], "|", (last["answer"] or {}).get("text", ""))
PY
}
start_service() {
  python3 "$phone/phone_link.py" --zone UTC --state "$S" 2>>"$T/service.err" &
  service_pid=$!
  wait_for 10 test -S "$S/hook.sock"
}
gone() { ! kill -0 "$1" 2>/dev/null; }

: >"$T/requests.jsonl"
# The folder signal-cli's socket lives in, as install.sh makes it.
python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import log, pathlib; log.prepare(pathlib.Path(sys.argv[2]))' "$phone" "$S/signal"
python3 "$phone/fake_signal_cli.py" "$S/signal/socket" "$T/requests.jsonl" "$T/control" 2>>"$T/signal.err" &
signal_pid=$!
wait_for 10 test -S "$S/signal/socket" || bad "the stand-in for signal-cli did not start: $(cat "$T/signal.err")"
start_service || bad "phone-link did not start: $(cat "$T/service.err")"
wait_for 10 grep -q listAccounts "$T/requests.jsonl" || bad "phone-link did not ask signal-cli for its account"

# 1. Acceptance 19: a session outside the harness gets nothing, and the hook says nothing.
writes use toolu_0 Bash '{"command":"ls","description":"List"}'
claude "$T/o1" "$T/plain" '{"command":"ls","description":"List"}'
eq "outside the harness: exit 0, no stdout, no stderr" "0||" "$(cat "$T/o1/code")|$(cat "$T/o1/stdout")|$(cat "$T/o1/stderr")"
eq "outside the harness: no alert" 0 "$(sent_count)"
[[ ! -s $S/events.jsonl ]] && ok "outside the harness: no event" || bad "outside the harness: an event was written"

# 2. Acceptance 2 and 13: yes from the phone, sent as a Signal reply to the alert with no id,
#    is printed as allow; done follows the transcript.
command_2="git push https://$token@github.com/o/r"
input_2=$(python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1], "description": "Push"}))' "$command_2")
writes use toolu_2 Bash "$input_2"
prompt "$T/o2" "$T/repo/src" "$input_2"
wait_for 10 has_sent 1 || bad "yes: no alert was sent"
id_2=$(last_id)
eq "yes: the alert's first line" "[$id_2] repo · Mac · claude · repo" "$(last_sent | head -1)"
eq "yes: the alert shows the command with its token masked" 'git push https://[REDACTED]@github.com/o/r' "$(last_sent | sed -n 3p)"
eq "yes: the alert says how to answer" "Reply to this: yes   or   no <reason>" "$(last_sent | tail -1)"
phone_replies "Yes"
wait "$job"
eq "yes: the hook prints allow" '{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}' "$(cat "$T/o2/stdout")"
eq "yes: exit 0, no stderr" "0|" "$(cat "$T/o2/code")|$(cat "$T/o2/stderr")"
sleep 1.5
eq "yes: no reply before the transcript shows the call's ending" 1 "$(sent_count)"
writes allowed-by-hook toolu_2
wait_for 5 has_sent 2 || bad "yes: no reply after the call's result"
eq "yes: the reply" "[$id_2] done" "$(last_sent)"
eq "yes: the event" "answered | yes" "$(state_of "$id_2")"
if grep -rqs "$token" "$S" "$T/requests.jsonl"; then bad "the token reached the state folder or Signal"; else ok "acceptance 13: the log and the alert hold no raw tool input"; fi

# 3. Acceptance 3: no <id> <reason> is printed as deny with the reason.
input_3='{"command":"rm -rf build","description":"Clean"}'
writes use toolu_3 Bash "$input_3"
CLAUDE_PROFILE=personal prompt "$T/o3" "$T/repo" "$input_3"
wait_for 10 has_sent 3 || bad "no: no alert was sent"
id_3=$(last_id)
eq "acceptance 19: the alert names the session's account" "[$id_3] repo · Mac · personal · repo" "$(last_sent | head -1)"
phone_says "no $id_3 too risky"
wait "$job"
eq "no: the hook prints deny with the reason" '{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "deny", "message": "too risky"}}}' "$(cat "$T/o3/stdout")"
writes denied-by-hook toolu_3
wait_for 5 has_sent 4 || bad "no: no reply after the call's result"
eq "no: the reply" "[$id_3] done" "$(last_sent)"

# 4. Acceptance 4: an allow at the Mac ends the hook with no decision; a later yes is refused.
input_4='{"command":"make test","description":"Test"}'
writes use toolu_4 Bash "$input_4"
prompt "$T/o4" "$T/repo" "$input_4"
wait_for 10 has_sent 5 || bad "mac allow: no alert was sent"
id_4=$(last_id)
writes allowed-at-mac toolu_4
if wait_for 5 gone "$(cat "$T/o4/pid")"; then ok "mac allow: no hook process is left 5 s after the call's result"; else bad "mac allow: the hook still runs"; fi
wait "$job"
eq "mac allow: the hook printed no decision" "0||" "$(cat "$T/o4/code")|$(cat "$T/o4/stdout")|$(cat "$T/o4/stderr")"
eq "mac allow: the event" "settled_at_mac | allow" "$(state_of "$id_4")"
phone_says "yes $id_4"
wait_for 5 has_sent 6 || bad "mac allow: no reply to the late yes"
eq "mac allow: a later yes" "[$id_4] refused: settled at the Mac" "$(last_sent)"
phone_says "no $id_4"
wait_for 5 has_sent 7 || bad "mac allow: no reply to the late no"
eq "mac allow: a later no" "[$id_4] refused: the Mac allowed it first" "$(last_sent)"

# 5. Acceptance 10: the session's process ends while its hook waits.
input_5='{"command":"sleep 600","description":"Wait"}'
writes use toolu_5 Bash "$input_5"
prompt "$T/o5" "$T/repo" "$input_5"
wait_for 10 has_sent 8 || bad "session end: no alert was sent"
id_5=$(last_id)
kill -KILL "$(cat "$T/o5/claude-pid")"
{ wait "$job"; } 2>/dev/null  # reaped here, so the shell's own "Killed" line for the stand-in goes nowhere
if wait_for 5 gone "$(cat "$T/o5/pid")"; then ok "session end: no hook process is left"; else bad "session end: the hook still runs"; fi
wait_for 5 test "$(state_of "$id_5")" = "closed | the session's process ended" || true
eq "session end: the event" "closed | the session's process ended" "$(state_of "$id_5")"

# 6. Acceptance 9 and 14: the service stops while a hook waits, and stays stopped.
input_6='{"command":"terraform apply","description":"Apply"}'
writes use toolu_6 Bash "$input_6"
prompt "$T/o6" "$T/repo" "$input_6"
wait_for 10 has_sent 9 || bad "restart: no alert was sent"
id_6=$(last_id)
if command -v lsof >/dev/null; then
  eq "acceptance 12: phone-link listens on no TCP port" "" "$(lsof -nP -a -p "$service_pid" -iTCP -sTCP:LISTEN 2>/dev/null)"
else
  echo "skip  acceptance 12: no lsof here to list phone-link's listeners"
fi
eq "acceptance 13: the state folder, its files and the two sockets are the owner's alone" \
  "700 s|600 events.jsonl|600 hook.sock|600 messages.jsonl|600 sessions.json|700 signal|600 signal/socket|" \
  "$(cd "$S/.." && python3 -c 'import os, stat, sys
for name in ["s"] + sorted("s/" + n for n in os.listdir("s")) + ["s/signal/socket"]:
    print(f"{stat.S_IMODE(os.stat(name).st_mode):o} {name[2:] or name}", end="|")')"
before=$SECONDS
stop "$service_pid"
service_pid=""
((SECONDS - before <= 2)) && ok "restart: phone-link ends within 2 s of SIGTERM" || bad "restart: phone-link took $((SECONDS - before)) s to end"
wait "$job"
eq "restart: the hook ends with no decision" "0|" "$(cat "$T/o6/code")|$(cat "$T/o6/stdout")"
eq "restart: one stderr line" 1 "$(wc -l <"$T/o6/stderr" | tr -d ' ')"
[[ ! -e $S/hook.sock ]] && ok "restart: a stopped service leaves no socket file" || bad "restart: hook.sock is still there"

input_7='{"command":"ls","description":"List"}'
writes use toolu_7 Bash "$input_7"
claude "$T/o7" "$T/repo" "$input_7"
eq "acceptance 14: with phone-link stopped the hook exits 0 with no decision" "0|" "$(cat "$T/o7/code")|$(cat "$T/o7/stdout")"
eq "acceptance 14: one stderr line" 1 "$(wc -l <"$T/o7/stderr" | tr -d ' ')"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 1.0 else 1)' "$(cat "$T/o7/seconds")" \
  && ok "acceptance 14: the hook took $(cat "$T/o7/seconds") s, under 1 s" || bad "acceptance 14: the hook took $(cat "$T/o7/seconds") s"

start_service || bad "phone-link did not start again: $(cat "$T/service.err")"
eq "restart: the event of the hook that waited" "closed | phone-link restarted" "$(state_of "$id_6")"
wait_for 10 test "$(grep -c listAccounts "$T/requests.jsonl")" -ge 2 || bad "phone-link did not reach signal-cli again"
phone_says "yes $id_6"
wait_for 5 has_sent 10 || bad "restart: no reply to the late yes"
eq "restart: a later yes" "[$id_6] refused: closed" "$(last_sent)"

# 7. Acceptance 11: a send that fails ends the hook at once, with one line in errors.log.
[[ ! -e $S/errors.log ]] && ok "no error was reported up to here" || bad "errors.log before the failed send: $(cat "$S/errors.log")"
echo error >"$T/control/send"
sleep 0.3
input_8='{"command":"npm publish","description":"Publish"}'
writes use toolu_8 Bash "$input_8"
claude "$T/o8" "$T/repo" "$input_8"
eq "failed send: the hook ends with no decision" "0|" "$(cat "$T/o8/code")|$(cat "$T/o8/stdout")"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 5.0 else 1)' "$(cat "$T/o8/seconds")" \
  && ok "failed send: the hook took $(cat "$T/o8/seconds") s, under 5 s" || bad "failed send: the hook took $(cat "$T/o8/seconds") s"
eq "failed send: one line in errors.log" 1 "$(wc -l <"$S/errors.log" | tr -d ' ')"
eq "acceptance 13: errors.log is the owner's alone" 600 "$(python3 -c 'import os, stat, sys; print(f"{stat.S_IMODE(os.stat(sys.argv[1]).st_mode):o}")' "$S/errors.log")"
grep -q 'was not sent: signal-cli: Failed to send message' "$S/errors.log" && ok "failed send: the line says why" || bad "failed send: $(cat "$S/errors.log")"
echo ok >"$T/control/send"

# 8. The question tool is not this hook's, whatever the settings' matcher lets through.
TOOL=AskUserQuestion claude "$T/o9" "$T/repo" '{"questions":[]}'
eq "the question tool: exit 0, no stdout, no stderr" "0||" "$(cat "$T/o9/code")|$(cat "$T/o9/stdout")|$(cat "$T/o9/stderr")"

[[ ! -s $T/service.err ]] && ok "phone-link wrote nothing to stderr" || bad "phone-link stderr: $(cat "$T/service.err")"

((fails == 0)) && echo "phone hook tests passed" || { echo "$fails failed" >&2; exit 1; }
