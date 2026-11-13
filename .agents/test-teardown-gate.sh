#!/usr/bin/env bash
# Firing tests for the teardown-gate policy: record, remind, clear, tier, block.
set -euo pipefail
# A caller such as `git rebase -x` exports these; the git calls below must
# reach only their own temporary repositories.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

dir="$scratch/fixture"
mkdir -p "$dir/.agents/hooks/policy" "$dir/.agents/hooks/lib" "$dir/.agents/claude" "$dir/.agents/codex" "$dir/.codex/hooks"
cp "$repo/.agents/hooks/policy/teardown-gate.sh" "$dir/.agents/hooks/policy/"
cp "$repo"/.agents/hooks/lib/{config,emit-context,write_targets,worktree_records,process_start,guard-destructive}.py "$dir/.agents/hooks/lib/"
cp "$repo/.agents/claude/adapter.sh" "$repo/.agents/claude/normalize-hook.py" "$dir/.agents/claude/"
cp "$repo/.agents/codex/normalize-hook.py" "$dir/.agents/codex/"
cp "$repo/.codex/hooks/adapter.sh" "$dir/.codex/hooks/"
gate="$dir/.agents/hooks/policy/teardown-gate.sh"
pending="$dir/.agents/.teardown-pending-s1"

# The fixture deliberately starts OUTSIDE any git repository, so the completion
# signal is absent and the docker/build tier can be tested on its own terms.
sh() {  # <command> [run_in_background] -> stdout
  printf '{"project_dir":"%s","event":"PostToolUse","session_id":"s1","tool_name":"Bash","tool_input":{"command":%s,"run_in_background":%s}}' \
    "$dir" "$(printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" "${2:-false}" \
    | bash "$gate"
}
mcp() {  # <tool_name> [json tool_input] -> stdout
  local input="{}"
  [[ $# -gt 1 ]] && input="$2"
  printf '{"project_dir":"%s","event":"PostToolUse","session_id":"s1","tool_name":"%s","tool_input":%s}' \
    "$dir" "$1" "$input" | bash "$gate"
}
stop() {  # [stop_hook_active] -> sets rc, err
  set +e
  err="$(printf '{"project_dir":"%s","event":"Stop","session_id":"s1","stop_hook_active":%s}' "$dir" "${1:-false}" | bash "$gate" 2>&1 >/dev/null)"
  rc=$?
  set -e
}

stop; [[ $rc -eq 0 ]] || fail "a clean session must stop freely"
ok "nothing recorded, nothing blocked"

# ── what must NOT be recorded ────────────────────────────────────────────────
[[ -z "$(sh 'npm test')" && ! -e "$pending" ]] || fail "a plain test run recorded"
[[ -z "$(sh 'npm run dev')" && ! -e "$pending" ]] || fail "a FOREGROUND dev server recorded"
[[ -z "$(sh 'npm run build')" && ! -e "$pending" ]] || fail "a build recorded"
[[ -z "$(sh 'vitest run' true)" && ! -e "$pending" ]] || fail "a backgrounded one-shot vitest recorded"
[[ -z "$(sh 'docker compose down')" && ! -e "$pending" ]] || fail "a teardown command recorded"
ok "short-lived and foreground work is ignored"

# A command that NAMES a launch is not a launch. This class fired for real: a
# shell loop over quoted fixture commands recorded a container nobody started.
[[ -z "$(sh 'grep -rn "docker compose up -d" .' true)" && ! -e "$pending" ]] || fail "a grep for a launch recorded"
[[ -z "$(sh 'for c in "npm run dev" "docker compose up -d"; do echo $c; done' true)" && ! -e "$pending" ]] \
  || fail "a quoted fixture list recorded: $(cat "$pending")"
[[ -z "$(sh 'echo "starting: npm run dev" >> notes.md' true)" && ! -e "$pending" ]] || fail "an echo recorded"
ok "a quoted mention of a launch is not a launch"

# Quoting the thing being RUN is ordinary. Blanking quoted spans deleted the
# script name, the subcommand, and the app name, and recorded none of these.
rm -f "$pending"
sh 'npm run "dev"' true >/dev/null
sh 'docker compose "up" -d' >/dev/null
sh 'open -a "Simulator"' >/dev/null
[[ "$(grep -c '^server' "$pending")" == 1 && "$(grep -c '^docker' "$pending")" == 1 && "$(grep -c '^emulator' "$pending")" == 1 ]] \
  || fail "a quoted keyword must still classify: $(cat "$pending" 2>/dev/null)"
rm -f "$pending"
ok "quoting the thing being run does not hide it"

# Command substitution executes whatever quoting surrounds it.
sh 'echo "$(docker compose up -d)"' >/dev/null
grep -q '^docker' "$pending" || fail "a substitution inside quotes must classify"
rm -f "$pending"
sh 'RESULT=`npm run dev &`' >/dev/null
grep -q '^server' "$pending" || fail "a backtick substitution must classify"
rm -f "$pending"
ok "command substitution is executed, not quoted away"

# A -c/-e payload for a non-shell interpreter is that language's source. This
# exact shape recorded a phantom container against this repository.
[[ -z "$(sh 'python3 -c "t = '"'"'echo \"$(docker compose up -d)\"'"'"'; print(t)"' true)" && ! -e "$pending" ]] \
  || fail "a python payload recorded: $(cat "$pending" 2>/dev/null)"
[[ -z "$(sh 'bash -c "echo \"docker compose up -d\""')" && ! -e "$pending" ]] \
  || fail "an escaped-quote echo recorded: $(cat "$pending" 2>/dev/null)"
ok "an interpreter payload is source, and an escaped-quote echo is a mention"

# A read-only probe is not a teardown.
sh 'emulator -avd Pixel &' >/dev/null
sh 'pgrep -f qemu-system-x86_64' >/dev/null
grep -q '^emulator' "$pending" || fail "pgrep must not count as killing the emulator"
sh 'ps aux | grep qemu-system-x86_64' >/dev/null
grep -q '^emulator' "$pending" || fail "ps|grep must not count as killing the emulator"
sh 'pkill -f qemu-system-x86_64' >/dev/null
[[ ! -e "$pending" ]] || fail "an actual kill must clear the emulator"
ok "checking whether a device is alive is not stopping it"

# The gap between the package manager and the script name cannot cross a
# redirect: a log file named dev.log is not a dev server.
[[ -z "$(sh 'nohup npm test > dev.log 2>&1 &')" && ! -e "$pending" ]] \
  || fail "a redirect to dev.log recorded: $(cat "$pending" 2>/dev/null)"
ok "a redirect target is not a script name"

# A literal heredoc is data. This class fired twice for real against this very
# repository, whose own fixtures are lists of these commands.
[[ -z "$(sh "$(printf 'cat > fixtures.txt <<%s\ndocker compose up -d\nnpm run dev\nEOF\n' "'EOF'")" true)" && ! -e "$pending" ]] \
  || fail "a literal heredoc body recorded: $(cat "$pending" 2>/dev/null)"
# Only `<<-` accepts an indented terminator. Accepting one for a plain `<<`
# ended the heredoc early at a line that merely looked like the delimiter, and
# read the rest of the body — still data to bash — as commands.
[[ -z "$(sh "$(printf 'cat > doc.txt <<%s\nsome data\n  EOF\ndocker compose up -d\nEOF\n' "'EOF'")" true)" && ! -e "$pending" ]] \
  || fail "an indented look-alike must not end a plain heredoc: $(cat "$pending" 2>/dev/null)"
# With `<<-` the indented terminator is real, and the body genuinely ends there.
sh "$(printf 'cat > doc.txt <<-%s\n\tsome data\n\tEOF\ndocker compose up -d\n' "'EOF'")" >/dev/null
grep -q '^docker' "$pending" || fail "a <<- heredoc must end at its indented terminator"
rm -f "$pending"
ok "the heredoc terminator follows the form that opened it"

# An unquoted heredoc is expanded and may be fed to a shell, so it still counts.
sh "$(printf 'bash <<EOF\nnpm run dev &\nEOF\n')" true >/dev/null
grep -q '^server' "$pending" || fail "an unquoted heredoc must still classify"
rm -f "$pending"
ok "a literal heredoc is data; an expanded one is not"

# The argument of `sh -c` IS executed, so the quote strip must not swallow it.
sh 'nohup bash -c "cd app && npm run dev" &' >/dev/null
grep -q '^server' "$pending" || fail "a -c wrapped launch must record: $(cat "$pending" 2>/dev/null)"
rm -f "$pending"
sh 'sh -c "docker compose up -d"' >/dev/null
grep -q '^docker' "$pending" || fail "a -c wrapped container must record"
rm -f "$pending"
ok "a command wrapped in sh -c is classified, not stripped"

# A tool call is not one command: order across clauses decides the outcome.
sh 'docker compose down && docker compose up -d' >/dev/null
grep -q '^docker' "$pending" || fail "close-then-open must leave the new container recorded"
rm -f "$pending"
sh 'docker compose up -d && sleep 1 && docker compose down' >/dev/null
[[ ! -e "$pending" ]] || fail "open-then-close must leave nothing: $(cat "$pending")"
ok "clauses are replayed in shell order"

# ── browser: the always tier ─────────────────────────────────────────────────
out="$(mcp mcp__playwright__browser_navigate '{"url":"http://localhost:5014/login"}')"
[[ "$out" == *"keeps running"* && "$out" == *"browser_close"* ]] || fail "first navigate must remind: $out"
grep -q 'localhost:5014/login' "$pending" || fail "navigate must record"
[[ -z "$(mcp mcp__playwright__browser_navigate '{"url":"http://localhost:5014/payers"}')" ]] || fail "a second open must stay quiet"
[[ "$(grep -c '^browser' "$pending")" == 2 ]] || fail "both navigations must record"
ok "browser opens record; only the first reminds"

stop
[[ $rc -eq 2 && "$err" == *"[browser]"* && "$err" == *"login"* && "$err" == *"payers"* ]] \
  || fail "stop must block listing both pages (rc=$rc): $err"
ok "a live browser blocks the stop"

stop true; [[ $rc -eq 0 ]] || fail "stop_hook_active must pass"
grep -q 'login' "$pending" || fail "a pass on the host flag must not clear the pending set"
ok "a sibling block passes without clearing"

stop; [[ $rc -eq 0 ]] || fail "a second judged stop must pass (one-shot)"
ok "the gate blocks once per batch"

mcp mcp__playwright__browser_navigate '{"url":"http://localhost:5014/audit"}' >/dev/null
stop; [[ $rc -eq 2 && "$err" == *"audit"* ]] || fail "a new resource must re-arm the one-shot: $err"
ok "a newly opened resource re-arms the block"

mcp mcp__playwright__browser_close
[[ ! -e "$pending" ]] || fail "browser_close must clear every browser line"
stop; [[ $rc -eq 0 ]] || fail "stop after teardown must pass"
ok "browser_close clears the class"

# ── server and watcher: the this-turn tier ───────────────────────────────────
out="$(sh 'npm run dev' true)"
[[ "$out" == *"TaskStop"* ]] || fail "a backgrounded dev server must remind with its stop path: $out"
sh 'pnpm exec vitest --watch' true >/dev/null
sh 'nohup uvicorn app.main:app &' >/dev/null
[[ "$(grep -c '^server' "$pending")" == 2 && "$(grep -c '^watcher' "$pending")" == 1 ]] \
  || fail "server/watcher classification: $(cat "$pending")"
ok "backgrounded servers and test watchers record, trailing & included"

# Monorepo launch forms put a workspace selector between the manager and the
# script; requiring them to be adjacent missed every one of them.
rm -f "$pending"
sh 'yarn workspace web dev' true >/dev/null
sh 'pnpm --filter api start --port 4000' true >/dev/null
[[ "$(grep -c '^server' "$pending")" == 2 ]] || fail "monorepo launch forms: $(cat "$pending")"
rm -f "$pending"
# `:dev` and `dev:` are both ordinary npm-script naming, on either side of the
# separator; neither names a server.
for task in 'npm run dev:check' 'npm run test:dev' 'npm run lint:dev' 'npm run build:dev' 'npm run build'; do
  [[ -z "$(sh "$task" true)" && ! -e "$pending" ]] || fail "'$task' is a task, not a server"
done
ok "monorepo selectors match; a dev-prefixed or -suffixed task name does not"

# Docker spellings that the first pass missed entirely.
sh 'docker run -itd --name pg postgres:17' >/dev/null
grep -q '^docker' "$pending" || fail "a combined -itd short flag must record"
sh 'docker container stop pg' >/dev/null
[[ ! -e "$pending" ]] || fail "'docker container stop' must clear: $(cat "$pending")"
ok "combined short flags record; the container subcommand clears"

# The workloop controller removes lane-labelled containers itself.
for verb in "reap burndown gates" "release-stale burndown gates" "teardown burndown"; do
  sh 'docker compose up -d' >/dev/null
  sh ".agents/workloop.py --state .agents/.workloop-state.json $verb" >/dev/null
  [[ ! -e "$pending" ]] || fail "'workloop.py $verb' must clear containers: $(cat "$pending")"
done
sh 'docker compose up -d' >/dev/null
sh '.agents/workloop.py status burndown' >/dev/null
sh 'git commit -m "treat workloop reap and release-stale as teardowns"' >/dev/null
sh 'gh pr create --body "the workloop teardown step"' >/dev/null
grep -q '^docker' "$pending" || fail "prose naming a workloop verb must not clear containers"
grep -q '^docker' "$pending" || fail "'workloop.py status' removes nothing and must not clear"
sh 'docker compose down' >/dev/null
ok "the controller's reap, release-stale and teardown clear containers"

# A server started through `npm run dev` is stopped through `npm run stop`.
sh 'npm run dev' true >/dev/null
sh 'npm run stop' >/dev/null
[[ ! -e "$pending" ]] || fail "'npm run stop' must clear the server class"
ok "the run-prefixed stop script clears"

# Monitor runs its command in the background by definition; it carries no flag.
printf '{"project_dir":"%s","event":"PostToolUse","session_id":"s1","tool_name":"Monitor","tool_input":{"command":"npm run dev"}}' "$dir" | bash "$gate" >/dev/null
grep -q '^server' "$pending" || fail "a Monitor launch must record without a background flag"
rm -f "$pending"
ok "Monitor counts as backgrounded"

# ── mobile: Appium sessions, emulators, Metro ────────────────────────────────
# The official appium-mcp exposes no close-shaped tool name: one
# `appium_session_management` tool carries both directions in an `action` arg.
out="$(mcp mcp__appium-mcp__appium_session_management '{"action":"create","deviceName":"Pixel 8 API 35"}')"
[[ "$out" == *"action=delete"* ]] || fail "an appium session must remind with its real close call: $out"
grep -q '^device	.*Pixel 8' "$pending" || fail "an appium session must record: $(cat "$pending")"
[[ -z "$(mcp mcp__appium-mcp__appium_session_management '{"action":"list"}')" ]] || fail "action=list must not record"
[[ -z "$(mcp mcp__appium-mcp__appium_session_management '{"action":"select"}')" ]] || fail "action=select must not record"
# `attach` takes a remote session the server's own disconnect cleanup skips, so
# nothing would contain it if this gate did not. `detach` releases this end
# without ending that session, so it is not a teardown.
mcp mcp__appium-mcp__appium_session_management '{"action":"attach","sessionId":"remote-abc123"}' >/dev/null
grep -q 'remote-abc123' "$pending" || fail "action=attach must record: $(cat "$pending")"
mcp mcp__appium-mcp__appium_session_management '{"action":"detach"}' >/dev/null
grep -q '^device' "$pending" || fail "action=detach must not clear the entry"
mcp mcp__appium-mcp__appium_session_management '{"action":"delete"}' >/dev/null
# The label comes from the fields the server really accepts, not a deviceName
# key that no schema has.
mcp mcp__appium-mcp__appium_session_management '{"action":"create","capabilities":"{\"appium:deviceName\":\"Pixel 8\",\"platformName\":\"Android\"}"}' >/dev/null
grep -q 'Pixel 8' "$pending" || fail "the label must come from capabilities: $(cat "$pending")"
mcp mcp__appium-mcp__appium_session_management '{"action":"delete"}' >/dev/null
mcp mcp__appium-mcp__prepare_ios_simulator '{"udid":"A1B2-C3D4"}' >/dev/null
grep -q 'A1B2-C3D4' "$pending" || fail "a simulator must be labelled by udid: $(cat "$pending")"
rm -f "$pending"
mcp mcp__appium-mcp__appium_session_management '{"action":"delete"}' >/dev/null
[[ ! -e "$pending" ]] || fail "action=delete must clear the device class"
# A fork that publishes under another npm name uses the close-shaped spelling.
mcp mcp__appium__start_session '{"deviceName":"iPhone 15"}' >/dev/null
grep -q '^device' "$pending" || fail "a fork's start_session must record"
mcp mcp__appium__end_session
[[ ! -e "$pending" ]] || fail "a fork's end_session must clear"
ok "an appium session is read from the action, not the tool name"

# ── stealth: Scrapling's persistent browser, closed by close_session ─────────
out="$(mcp mcp__scrapling__browser_open '{"session_id":"cf-demo"}')"
[[ "$out" == *"keeps running"* && "$out" == *"close_session"* ]] || fail "browser_open must remind and name close_session: $out"
grep -q '^stealth	.*cf-demo' "$pending" || fail "browser_open must record: $(cat "$pending")"
stop
[[ $rc -eq 2 && "$err" == *"[stealth]"* && "$err" == *"close_session"* ]] \
  || fail "a live stealth browser must block the stop naming close_session (rc=$rc): $err"
mcp mcp__scrapling__close_session '{"session_id":"cf-demo"}' >/dev/null
[[ ! -e "$pending" ]] || fail "close_session from the opening server must clear: $(cat "$pending")"
mcp mcp__scrapling__browser_open >/dev/null
grep -q '^stealth	waiting	-	(unnamed) \[scrapling\]$' "$pending" || fail "an open without a session_id records as unnamed: $(cat "$pending")"
rm -f "$pending"
ok "browser_open records, blocks the stop, and its server's close_session clears it"

mcp mcp__stealthy__browser_open '{"session_id":"a"}' >/dev/null
mcp mcp__appium__start_session '{"deviceName":"iPhone 15"}' >/dev/null
grep -q '^device	.*iPhone 15 \[appium\]$' "$pending" || fail "a device entry carries its server tag: $(cat "$pending")"
stop
[[ $rc -eq 2 && "$err" == *"iPhone 15 [appium]"* && "$err" == *"a [stealthy]"* ]] || fail "the stop text names the server on device and stealth lines (rc=$rc): $err"
mcp mcp__appium__close_session >/dev/null
grep -q '^stealth' "$pending" || fail "an Appium close_session must leave stealth: $(cat "$pending")"
grep -q '^device' "$pending" && fail "an Appium close_session must clear its device: $(cat "$pending")"
mcp mcp__playwright__browser_close >/dev/null
grep -q '^stealth' "$pending" || fail "a Playwright browser_close must leave stealth"
mcp mcp__stealthy__close_session >/dev/null
grep -q '^stealth	.*a \[stealthy\]' "$pending" || fail "a close naming no session clears no named entry: $(cat "$pending")"
mcp mcp__stealthy__close_session '{"session_id":"a"}' >/dev/null
[[ ! -e "$pending" ]] || fail "a close naming the session must clear it: $(cat "$pending")"
ok "close_session clears stealth only for its own server and only the session it names; Appium and Playwright closes do not"

# Two named sessions on one server: a close clears the one it names.
mcp mcp__scrapling__browser_open '{"session_id":"one"}' >/dev/null
mcp mcp__scrapling__browser_open '{"session_id":"two"}' >/dev/null
mcp mcp__scrapling__close_session '{"session_id":"one"}' >/dev/null
stop
[[ $rc -eq 2 && "$err" == *"two [scrapling]"* && "$err" != *"one [scrapling]"* ]] \
  || fail "closing one of two sessions must leave the other blocking Stop (rc=$rc): $err"
mcp mcp__scrapling__close_session '{"session_id":"nothing"}' >/dev/null
grep -q 'two \[scrapling\]' "$pending" || fail "a close naming an ID that matches nothing must clear nothing: $(cat "$pending")"
mcp mcp__other__close_session '{"session_id":"two"}' >/dev/null
grep -q 'two \[scrapling\]' "$pending" || fail "another server's close must not clear it: $(cat "$pending")"
mcp mcp__scrapling__close_session '{"session_id":"two"}' >/dev/null
stop; [[ $rc -eq 0 && ! -e "$pending" ]] || fail "closing the last session must let Stop pass (rc=$rc): $err"
ok "a close clears the session it names, by ID and server, and nothing else"

# A hostile ID is not a name: it records as unnamed and cannot forge a field.
mcp mcp__scrapling__browser_open '{"session_id":"x\ty\nstealth\tz"}' >/dev/null
[[ "$(grep -c "" "$pending")" == 1 ]] && grep -q '^stealth	waiting	-	(unnamed) \[scrapling\]$' "$pending" \
  || fail "an ID outside the token pattern must record as unnamed: $(cat "$pending")"
mcp mcp__scrapling__browser_open '{"session_id":"named"}' >/dev/null
mcp mcp__scrapling__close_session '{"session_id":"nothing"}' >/dev/null
[[ "$(grep -c '^stealth' "$pending")" == 2 ]] || fail "unnamed entries sweep only when no named entry remains: $(cat "$pending")"
mcp mcp__scrapling__close_session '{"session_id":"named"}' >/dev/null
mcp mcp__scrapling__close_session >/dev/null
[[ ! -e "$pending" ]] || fail "a close with no match sweeps a server whose entries are all unnamed: $(cat "$pending")"
ok "unnamed sessions clear only when no named one matches"

# A Scrapling close never touches an Appium device (G1, T3), and an Appium close
# never touches stealth.
mcp mcp__appium-mcp__appium_session_management '{"action":"create","deviceName":"Pixel 8"}' >/dev/null
mcp mcp__scrapling__close_session '{"session_id":"cf-demo"}' >/dev/null
grep -q '^device	.*Pixel 8 \[appium-mcp\]$' "$pending" || fail "a Scrapling close must leave an Appium device: $(cat "$pending" 2>/dev/null)"
mcp mcp__scrapling__browser_open '{"session_id":"keep"}' >/dev/null
mcp mcp__appium-mcp__appium_session_management '{"action":"delete"}' >/dev/null
grep -q '^device' "$pending" && fail "an Appium delete must clear its device: $(cat "$pending")"
grep -q 'keep \[scrapling\]' "$pending" || fail "an Appium delete must leave stealth: $(cat "$pending" 2>/dev/null)"
rm -f "$pending"
ok "a Scrapling close leaves a device; an Appium close clears its device and leaves stealth"

# Each device close drops one device entry of its own server (D1): N opens and
# M closes leave N-M, and Stop blocks while any is held.
dev() { mcp "mcp__$1__appium_session_management" "{\"action\":\"$2\",\"deviceName\":\"${3:-}\"}" >/dev/null; }
dev appium-mcp create "Pixel A"; dev appium-mcp create "Pixel B"
dev appium-mcp delete
[[ "$(grep -c '^device' "$pending")" == 1 ]] || fail "two devices, one delete, must leave one entry: $(cat "$pending" 2>/dev/null)"
stop; [[ $rc -eq 2 ]] || fail "a device still held must block the stop (rc=$rc): $err"
dev appium-mcp delete
[[ ! -e "$pending" ]] || fail "the second delete must clear the last device: $(cat "$pending")"
ok "a device close drops one entry, so Stop blocks while any device is held"

# T1: devices on two Appium servers; a close clears only its own server's.
dev appium-mcp create "Pixel"; mcp mcp__appium__start_session '{"deviceName":"iPhone"}' >/dev/null
dev appium-mcp delete
grep -q 'iPhone \[appium\]$' "$pending" && ! grep -q 'Pixel' "$pending" \
  || fail "a delete on one server must leave the other server's device: $(cat "$pending" 2>/dev/null)"
dev appium-mcp create "Pixel"
mcp mcp__appium__end_session >/dev/null
grep -q 'Pixel \[appium-mcp\]$' "$pending" && ! grep -q 'iPhone' "$pending" \
  || fail "an end_session on one server must leave the other server's device: $(cat "$pending" 2>/dev/null)"
mcp mcp__appium__start_session '{"deviceName":"iPhone"}' >/dev/null
mcp mcp__appium__close_session >/dev/null
grep -q 'Pixel \[appium-mcp\]$' "$pending" && ! grep -q 'iPhone' "$pending" \
  || fail "a close_session on a fork must clear one of its own devices only: $(cat "$pending" 2>/dev/null)"
rm -f "$pending"
ok "a device close never touches another server's device"

# T6: a tag in the middle of a label is not the entry's server.
dev appium create "Pixel [other] phone"
dev other delete
grep -q 'Pixel \[other\] phone \[appium\]$' "$pending" || fail "a mid-label tag must not match: $(cat "$pending" 2>/dev/null)"
rm -f "$pending"
ok "a device is matched by the server tag it ends with"

# T2: one ID a prefix of another.
mcp mcp__scrapling__browser_open '{"session_id":"s1"}' >/dev/null
mcp mcp__scrapling__browser_open '{"session_id":"s10"}' >/dev/null
mcp mcp__scrapling__close_session '{"session_id":"s1"}' >/dev/null
grep -q 's10 \[scrapling\]$' "$pending" && ! grep -q 's1 \[scrapling\]$' "$pending" \
  || fail "closing s1 must leave s10: $(cat "$pending" 2>/dev/null)"
rm -f "$pending"
ok "a close names an ID exactly, never by prefix"

# T3 and D3: ID-less closes sweep one unnamed entry of their own server.
mcp mcp__scrapling__browser_open >/dev/null
mcp mcp__other__browser_open >/dev/null
mcp mcp__scrapling__close_session >/dev/null
grep -q '(unnamed) \[other\]$' "$pending" && ! grep -q '\[scrapling\]' "$pending" \
  || fail "an ID-less close must clear its own server's unnamed entry and keep the other's: $(cat "$pending" 2>/dev/null)"
rm -f "$pending"
mcp mcp__scrapling__browser_open >/dev/null
mcp mcp__scrapling__browser_open >/dev/null
mcp mcp__scrapling__close_session >/dev/null
[[ "$(grep -c '^stealth' "$pending")" == 1 ]] || fail "one close must drop one unnamed entry: $(cat "$pending" 2>/dev/null)"
mcp mcp__scrapling__close_session '{"session_id":"nothing"}' >/dev/null
[[ ! -e "$pending" ]] || fail "a second close must drop the last unnamed entry: $(cat "$pending" 2>/dev/null)"
ok "an unmatched close on an all-unnamed server drops one unnamed entry"

# T4: a close with no ID names nothing, even beside an unnamed entry.
mcp mcp__scrapling__browser_open >/dev/null
mcp mcp__scrapling__browser_open '{"session_id":"named"}' >/dev/null
mcp mcp__scrapling__close_session >/dev/null
[[ "$(grep -c '^stealth' "$pending")" == 2 ]] || fail "a close with no ID must clear nothing here: $(cat "$pending" 2>/dev/null)"
rm -f "$pending"
ok "a close with no ID is not a close naming the fallback"

# D4: a session really named `unnamed` is not the fallback.
mcp mcp__scrapling__browser_open '{"session_id":"unnamed"}' >/dev/null
mcp mcp__scrapling__browser_open '{"session_id":"a b"}' >/dev/null
mcp mcp__scrapling__close_session '{"session_id":"nothing"}' >/dev/null
[[ "$(grep -c '^stealth' "$pending")" == 2 ]] || fail "a session named unnamed must not be swept as the fallback: $(cat "$pending" 2>/dev/null)"
mcp mcp__scrapling__close_session '{"session_id":"unnamed"}' >/dev/null
grep -q '^stealth	waiting	-	(unnamed) \[scrapling\]$' "$pending" && [[ "$(grep -c '^stealth' "$pending")" == 1 ]] \
  || fail "closing unnamed must leave the malformed-ID entry: $(cat "$pending" 2>/dev/null)"
rm -f "$pending"
ok "the fallback name cannot be a session ID"

# T5: the ID pattern's edges.
long64="$(printf 'a%.0s' $(seq 64))"
mcp mcp__scrapling__browser_open "{\"session_id\":\"$long64\"}" >/dev/null
grep -q "^stealth	waiting	-	$long64 \[scrapling\]\$" "$pending" || fail "a 64-character ID must be recorded whole: $(cat "$pending")"
rm -f "$pending"
for bad in "${long64}b" 'a b' 'a]b' 'a[b' 'a.b' 'a\\b'; do
  mcp mcp__scrapling__browser_open "{\"session_id\":\"$bad\"}" >/dev/null
  grep -q '^stealth	waiting	-	(unnamed) \[scrapling\]$' "$pending" && [[ "$(grep -c '' "$pending")" == 1 ]] \
    || fail "ID '$bad' must record as (unnamed): $(cat "$pending" 2>/dev/null)"
  rm -f "$pending"
done
ok "an ID is 1 to 64 of letters, digits, underscore and hyphen"

# D5: when awk fails the entries stay and the gate says why.
mkdir -p "$scratch/failbin"
printf '#!/bin/sh\nexit 1\n' > "$scratch/failbin/awk"
chmod +x "$scratch/failbin/awk"
mcp mcp__scrapling__browser_open '{"session_id":"keep"}' >/dev/null
dev appium-mcp create "Pixel"
before="$(cat "$pending")"
err="$(PATH="$scratch/failbin:$PATH" mcp mcp__scrapling__close_session '{"session_id":"keep"}' 2>&1 >/dev/null)"
[[ "$(cat "$pending")" == "$before" && "$err" == *awk* ]] || fail "a failing awk must keep the pending file and say so: $err"
err="$(PATH="$scratch/failbin:$PATH" mcp mcp__appium-mcp__appium_session_management '{"action":"delete"}' 2>&1 >/dev/null)"
[[ "$(cat "$pending")" == "$before" && "$err" == *awk* ]] || fail "a failing awk on a device close must keep the file and say so: $err"
rm -f "$pending"
ok "a failing awk keeps the pending file and reports on stderr"

# H1: Stop's advice for a device names its own server's calls.
mcp mcp__appium__start_session '{"deviceName":"iPhone"}' >/dev/null
stop
[[ $rc -eq 2 && "$err" == *"mcp__appium__appium_session_management"* && "$err" == *"mcp__appium__end_session"* ]] \
  || fail "device advice must name the server's own delete and end_session (rc=$rc): $err"
rm -f "$pending"
ok "a device's advice names the server that opened it"

[[ -z "$(mcp mcp__scrapling__browser_fetch_once '{"url":"https://example.com"}')" && ! -e "$pending" ]] \
  || fail "browser_fetch_once opens and closes inside the call and must record nothing"
ok "browser_fetch_once is not an open"

# The hosts call this hook only for tool names their hand-written matcher lets
# through, so a class the gate knows but a matcher omits never fires.
# Catches: a host (Claude, Codex, and Kimi where its example file exists) that stops
# running the gate on Stop, or on SubagentStop for Claude; a PreToolUse/PostToolUse
# matcher that drops a native tool name listed below; a PostToolUse matcher that
# rejects any name a gate regex accepts (each regex is enumerated, the server segment
# standing in as a name with an underscore, hyphen, digit and both cases); a gate
# expression that reads `tool` as a literal, regex, equality or membership test and
# names a tool no host table lists; a form of reading `tool` the reader cannot parse
# (alias, concatenated pattern, startswith/endswith) that is not allowlisted below.
# Misses: a host that renames a tool, a gate regex outside the grammar the expander
# reads (it raises, so that is loud), a gate pattern looser than its `$` anchor,
# tool names reaching the gate through a variable other than `tool`, and whether the
# host really fires on a matching name. Kimi's missing TaskStop is a known gap kept
# in breadcrumbs.md.
python3 - "$repo" <<'PY' || fail "a host trigger misses a tool name the gate classifies"
import ast, json, os, re, sys, tomllib
repo = sys.argv[1]
bad = []

# ── host registrations ───────────────────────────────────────────────────────
def claude_like(path):
    hooks = json.load(open(path))["hooks"]
    return [(event, g.get("matcher")) for event, groups in hooks.items()
            for g in groups if "teardown-gate" in json.dumps(g)]

found = {"claude": claude_like(f"{repo}/.agents/claude/settings.json"),
         "codex": claude_like(f"{repo}/.agents/codex/hooks.json")}
kimi_path = f"{repo}/.kimi/config.toml.example"
if os.path.isfile(kimi_path):
    with open(kimi_path, "rb") as stream:
        kimi = tomllib.load(stream)
    found["kimi"] = [(h["event"], h.get("matcher")) for h in kimi["hooks"]
                     if "teardown-gate" in h.get("command", "")]

# The gate must run when a turn ends, or it records and never blocks.
stop_events = {"claude": {"Stop", "SubagentStop"}, "codex": {"Stop"}, "kimi": {"Stop"}}
for host, groups in found.items():
    for event in sorted(stop_events[host] - {e for e, _ in groups}):
        bad.append(f"{host}: no {event} group runs teardown-gate")

def accepts(matcher, name):
    """A missing, empty or `*` matcher matches every tool name."""
    return matcher in (None, "", "*") or re.fullmatch(matcher, name) is not None

# Each host's native tool names, by event, as the host itself calls them.
native = {
    "claude": {"PostToolUse": ["Bash", "PowerShell", "Monitor", "TaskStop", "KillShell", "KillBash", "EnterWorktree"],
               "PreToolUse": ["Bash", "EnterWorktree"]},
    "codex": {"PostToolUse": ["Bash"], "PreToolUse": ["Bash"]},
    "kimi": {"PostToolUse": ["Bash"], "PreToolUse": ["Bash"]},
}
known_native = {name for events in native.values() for names in events.values() for name in names}

for host, groups in found.items():
    for event, names in native[host].items():
        matchers = [m for e, m in groups if e == event]
        if not matchers:
            bad.append(f"{host}: no {event} teardown-gate matcher found")
        for name in names:
            if not any(accepts(m, name) for m in matchers):
                bad.append(f"{host} {event} matchers {matchers} miss {name}")

# ── the grammar the gate's tool-name regexes use ─────────────────────────────
SERVER_CLASS = "[A-Za-z0-9_-]+"
SERVER_SAMPLE = "plugin_vercel-Vercel2"

def expand(pattern):
    """Every string the pattern fully matches. Reads literal characters, a leading ^
    and trailing $, (...) and (?:...) groups with |, ? on a group, and the server
    class; raises on anything else."""
    text = pattern.replace(SERVER_CLASS, SERVER_SAMPLE)
    text = text[1:] if text.startswith("^") else text
    text = text[:-1] if text.endswith("$") else text

    def alternatives(pos):
        out, pos = sequence(pos)
        while pos < len(text) and text[pos] == "|":
            more, pos = sequence(pos + 1)
            out += more
        return out, pos

    def sequence(pos):
        parts = [""]
        while pos < len(text) and text[pos] not in "|)":
            ch = text[pos]
            if ch == "(":
                pos += 1
                if text.startswith("?:", pos):
                    pos += 2
                elif text.startswith("?", pos):
                    raise ValueError(f"unsupported group in {pattern!r}")
                inner, pos = alternatives(pos)
                if pos >= len(text) or text[pos] != ")":
                    raise ValueError(f"unclosed group in {pattern!r}")
                pos += 1
                if pos < len(text) and text[pos] == "?":
                    inner, pos = inner + [""], pos + 1
                parts = [p + i for p in parts for i in inner]
            elif ch in "^$.*+?[]{}\\":
                raise ValueError(f"unsupported {ch!r} in {pattern!r}")
            else:
                parts, pos = [p + ch for p in parts], pos + 1
        return parts, pos

    names, pos = alternatives(0)
    if pos != len(text):
        raise ValueError(f"unbalanced ) in {pattern!r}")
    return set(names)

# ── every expression of the gate that reads `tool` ───────────────────────────
gate_text = open(f"{repo}/.agents/hooks/policy/teardown-gate.sh").read()
heredocs = re.findall(r"read -r -d '' parse <<'PY' \|\| true\n(.*?)\nPY\n", gate_text, re.S)
if len(heredocs) != 1:
    sys.exit("the gate's classification heredoc was not found exactly once")
tree = ast.parse(heredocs[0])
for parent in ast.walk(tree):
    for child in ast.iter_child_nodes(parent):
        child.parent = parent

MATCHERS = ("match", "search", "fullmatch")
# Uses of `tool` that hand it on or measure it without classifying it.
NOT_CLASSIFICATION = {
    "records.snapshot": "stores the tool name with the worktree snapshot",
    "records.made": "passes the tool name to the worktree record reader",
    "tool.endswith('browser_tabs')": "narrows BROWSER_OPEN's action check inside a branch BROWSER_OPEN already chose",
}

def is_re_call(node, *attrs):
    return (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
            and isinstance(node.func.value, ast.Name) and node.func.value.id == "re"
            and node.func.attr in attrs)

def string(node):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    raise ValueError("the pattern is not one string literal")

def flags(node):
    if node is None:
        return 0
    if (isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id == "re"
            and isinstance(getattr(re, node.attr, None), re.RegexFlag)):
        return int(getattr(re, node.attr))
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.BitOr):
        return flags(node.left) | flags(node.right)
    raise ValueError("the flags are not re.<FLAG> names")

def pattern_of(call, position):
    keywords = {k.arg: k.value for k in call.keywords}
    extra = call.args[position] if len(call.args) > position else keywords.get("flags")
    return string(call.args[0]), flags(extra)

bound = {}  # variable -> (pattern, flags), or the reason it cannot be read
for node in ast.walk(tree):
    if (isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name)
            and is_re_call(node.value, "compile")):
        try:
            bound[node.targets[0].id] = pattern_of(node.value, 1)
        except ValueError as error:
            bound[node.targets[0].id] = str(error)

read = []        # (expression, pattern, flags) for each regex that classifies `tool`
gate_native = set()
for node in ast.walk(tree):
    if not (isinstance(node, ast.Name) and node.id == "tool" and isinstance(node.ctx, ast.Load)):
        continue
    up = node.parent
    expression = f"line {node.lineno}: {ast.unparse(up)}"
    try:
        if (isinstance(up, ast.Call) and isinstance(up.func, ast.Attribute) and up.func.attr in MATCHERS
                and isinstance(up.func.value, ast.Name) and up.func.value.id in bound and up.args[0] is node):
            spec = bound[up.func.value.id]
            if isinstance(spec, str):
                raise ValueError(spec)
            read.append((expression, *spec))
        elif is_re_call(up, *MATCHERS) and len(up.args) > 1 and up.args[1] is node:
            read.append((expression, *pattern_of(up, 2)))
        elif (isinstance(up, ast.Compare) and up.left is node and len(up.ops) == 1
              and isinstance(up.ops[0], ast.Eq)):
            gate_native.add(string(up.comparators[0]))
        elif (isinstance(up, ast.Compare) and up.left is node and len(up.ops) == 1
              and isinstance(up.ops[0], ast.In) and isinstance(up.comparators[0], (ast.Tuple, ast.List, ast.Set))):
            gate_native.update(string(item) for item in up.comparators[0].elts)
        else:
            if isinstance(up, ast.Attribute) and isinstance(up.parent, ast.Call):
                key = ast.unparse(up.parent)
            elif isinstance(up, ast.Call):
                key = ast.unparse(up.func)
            else:
                key = None
            if key not in NOT_CLASSIFICATION:
                raise ValueError("a form this reader cannot read; read it with a literal, or allowlist it with its reason")
    except (ValueError, IndexError) as error:
        bad.append(f"{expression}: {error}")

if not read:
    bad.append("no regex that reads `tool` was found in the gate")
mcp_names = set()
for expression, pattern, flag_bits in read:
    try:
        if flag_bits:
            raise ValueError("the expander reads no regex flags")
        names = expand(pattern)
    except ValueError as error:
        bad.append(f"{expression}: {error}")
        continue
    compiled = re.compile(pattern, flag_bits)
    for name in sorted(names):
        if not compiled.fullmatch(name):
            bad.append(f"{expression}: the expander produced {name}, which the regex rejects")
    mcp_names |= {n for n in names if n.startswith("mcp__")}
    gate_native |= {n for n in names if not n.startswith("mcp__")}

boot = bound.get("APPIUM_BOOT")
expected_boot = {f"mcp__{SERVER_SAMPLE}__{stem}" for stem in (
    "prepare_ios_simulator", "prepare_ios_real_device",
    "appium_prepare_ios_simulator", "appium_prepare_ios_real_device")}
if not isinstance(boot, tuple):
    bad.append("APPIUM_BOOT is not bound to a readable re.compile literal")
elif expand(boot[0]) != expected_boot:
    bad.append(f"APPIUM_BOOT must expand to exactly {sorted(expected_boot)}")

for name in sorted(gate_native - known_native):
    bad.append(f"the gate classifies tool {name!r}, which no host table above lists")
for host, groups in found.items():
    post = [m for e, m in groups if e == "PostToolUse"]
    for name in sorted(mcp_names):
        if not any(accepts(m, name) for m in post):
            bad.append(f"{host} PostToolUse matchers {post} reject {name}")
if bad:
    sys.exit("\n".join(bad))
PY
ok "each host runs the gate on Stop; each host matcher accepts every name the gate's regexes enumerate and every native name listed; every tool the gate reads is a listed one"

sh 'emulator -avd Pixel_8_API_35 &' >/dev/null
sh 'xcrun simctl boot "iPhone 15"' >/dev/null
[[ "$(grep -c '^emulator' "$pending")" == 2 ]] || fail "emulator boots: $(cat "$pending")"
stop; [[ $rc -eq 0 ]] || fail "a booted device must not block before the work completes: $err"
sh 'adb -s emulator-5554 emu kill' >/dev/null
sh 'xcrun simctl shutdown booted' >/dev/null
[[ ! -e "$pending" ]] || fail "both shutdown forms must clear: $(cat "$pending")"
ok "emulators boot into the on-completion tier and clear on shutdown"

sh 'npx appium --port 4723' true >/dev/null
sh 'npx react-native start' true >/dev/null
sh 'npx expo start --ios' true >/dev/null
[[ "$(grep -c '^server' "$pending")" == 3 ]] || fail "appium/metro/expo: $(cat "$pending")"
[[ -z "$(sh 'appium --version')" ]] || fail "'appium --version' is not a server"
sh 'pkill -f appium' >/dev/null
for c in 'npm install -g appium' 'appium driver install xcuitest' 'appium driver list --installed' \
         'appium plugin list' 'appium setup' 'npx appium driver list'; do
  sh "$c" true >/dev/null
  [[ ! -e "$pending" ]] || fail "'$c' exits when done and is not a server: $(cat "$pending")"
done
for c in 'appium' 'appium server --port 4723' 'nohup appium > appium.log 2>&1' 'npx -y appium --port 4723'; do
  sh "$c" true >/dev/null
  grep -q '^server' "$pending" || fail "'$c' starts the appium server and must record"
  rm -f "$pending"
done
mcp mcp__appium-mcp__prepare_ios_simulator '{"deviceName":"iPhone 15 Pro"}' >/dev/null
grep -q '^emulator' "$pending" || fail "prepare_ios_simulator boots a device and must record"
rm -f "$pending"
ok "the appium server, Metro, and Expo are servers; a simulator prepare is not"

# Two clears in flight at once must not discard an entry neither of them names.
sh 'npm run dev' true >/dev/null
mcp mcp__playwright__browser_navigate '{"url":"http://localhost:3000"}' >/dev/null
sh 'docker compose down' & sh 'pkill -f server' & wait
grep -q '^browser' "$pending" || fail "a concurrent clear must not drop an untouched class: $(cat "$pending" 2>/dev/null)"
[[ -z "$(find "$dir/.agents" -name '.teardown-pending-*.lock' -o -name '.teardown-pending-s1.[0-9]*')" ]] \
  || fail "the lock and tmp files must not survive"
mcp mcp__playwright__browser_close
rm -f "$pending"
ok "concurrent clears do not lose an unrelated entry"

# Rebuild the set the tier assertions below read, since the checks above
# cleared it.
sh 'npm run dev' true >/dev/null
sh 'pnpm exec vitest --watch' true >/dev/null
sh 'nohup uvicorn app.main:app &' >/dev/null

stop; [[ $rc -eq 2 && "$err" == *"[server]"* && "$err" == *"[watcher]"* ]] || fail "servers must block the turn: $err"
[[ "$err" == *"restarts in seconds"* ]] || fail "the block must carry the tier's reason: $err"
ok "a live server blocks this turn"

sh 'kill %1' >/dev/null
[[ ! -e "$pending" ]] || fail "kill must clear server and watcher lines"
ok "a kill clears the process classes"

printf '{"project_dir":"%s","event":"PostToolUse","session_id":"s1","tool_name":"TaskStop","tool_input":{"task_id":"x"}}' "$dir" | bash "$gate" >/dev/null
sh 'npm run dev' true >/dev/null
printf '{"project_dir":"%s","event":"PostToolUse","session_id":"s1","tool_name":"TaskStop","tool_input":{"task_id":"x"}}' "$dir" | bash "$gate" >/dev/null
[[ ! -e "$pending" ]] || fail "TaskStop must clear the process classes"
ok "the host's own stop tool clears"

# ── docker and build: the on-completion tier ─────────────────────────────────
sh 'docker compose up -d' >/dev/null
sh 'tsc --watch --preserveWatchOutput' true >/dev/null
[[ "$(grep -c '^docker' "$pending")" == 1 && "$(grep -c '^build' "$pending")" == 1 ]] \
  || fail "docker/build classification: $(cat "$pending")"
stop; [[ $rc -eq 0 ]] || fail "docker and a build watcher must not block before the work completes: $err"
ok "containers and build watchers survive a mid-work stop"

sh 'docker run -d --name pg postgres:17' >/dev/null
[[ "$(grep -c '^docker' "$pending")" == 2 ]] || fail "a detached docker run must record"
[[ -z "$(sh 'docker run --rm alpine echo hi')" ]] || fail "a foreground docker run must not record"
ok "only detached containers record"

# They ride along on a block another class caused, without causing one.
mcp mcp__playwright__browser_navigate '{"url":"http://localhost:5014/"}' >/dev/null
stop
[[ $rc -eq 2 && "$err" == *"[browser]"* ]] || fail "the browser must still block: $err"
[[ "$err" == *"Still useful while the work continues"* && "$err" == *"[docker]"* && "$err" == *"[build]"* ]] \
  || fail "not-yet-due resources must be reported alongside a block: $err"
ok "not-yet-due resources ride along without blocking alone"

mcp mcp__playwright__browser_close
sh 'docker compose down' >/dev/null
grep -q '^docker' "$pending" && fail "docker compose down must clear the container lines"
grep -q '^build' "$pending" || fail "docker compose down must not touch the build watcher"
ok "a teardown clears only its own class"

# ── the completion signal: a push, not a commit ─────────────────────────────
# A commit lands mid-unit, so it leaves the on-completion tier pending; a push
# hands the work off and makes it due.
gitdir="$scratch/repo"
mkdir -p "$gitdir/.agents/hooks/policy" "$gitdir/.agents/hooks/lib"
cp "$gate" "$gitdir/.agents/hooks/policy/"
cp "$repo/.agents/hooks/lib/config.py" "$repo/.agents/hooks/lib/emit-context.py" \
  "$repo/.agents/hooks/lib/guard-destructive.py" "$repo/.agents/hooks/lib/worktree_records.py" \
  "$repo/.agents/hooks/lib/process_start.py" "$gitdir/.agents/hooks/lib/"
git -C "$gitdir" init -q
git -C "$gitdir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m first
gate="$gitdir/.agents/hooks/policy/teardown-gate.sh"
pending="$gitdir/.agents/.teardown-pending-s1"
dir="$gitdir"

sh 'docker compose up -d' >/dev/null
sh 'tsc --watch' true >/dev/null
stop; [[ $rc -eq 0 ]] || fail "a container must not block mid-work: $err"
git -C "$gitdir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m second
sh 'git commit -m "wire the push signal"' >/dev/null
stop; [[ $rc -eq 0 ]] || fail "a landed commit must leave containers pending (rc=$rc): $err"
grep -q '^docker' "$pending" && grep -q '^build' "$pending" || fail "a commit must not drop the entries: $(cat "$pending")"
ok "a commit leaves containers and build watchers pending without blocking"

for command in 'git push --dry-run' 'git push -n origin main' 'echo git push' 'grep -rn "git push" .' \
               'git commit -m "git push later"' 'git log --grep push'; do
  sh "$command" >/dev/null
  stop; [[ $rc -eq 0 ]] || fail "'$command' is not a push and must not make containers due: $err"
done
ok "a dry run or a mention of a push is not a push"

sh 'git push origin HEAD' >/dev/null
stop; [[ $rc -eq 2 && "$err" == *"[docker]"* && "$err" == *"[build]"* && "$err" == *"push"* ]] \
  || fail "a push must make containers and build watchers due (rc=$rc): $err"
ok "a push makes containers and build watchers due and blocks"

sh 'docker compose down' >/dev/null
sh 'pkill -f tsc' >/dev/null
[[ ! -e "$pending" ]] || fail "teardown must clear: $(cat "$pending")"
sh 'git push' >/dev/null
sh 'docker compose up -d' >/dev/null
stop; [[ $rc -eq 0 ]] || fail "a container started after the push is not due until the next one: $err"
ok "a resource started after a push waits for the next push"

# A push after a spent block re-arms it: the block named other resources.
mcp mcp__playwright__browser_navigate '{"url":"http://localhost:3000"}' >/dev/null
stop; [[ $rc -eq 2 && "$err" == *"[browser]"* ]] || fail "the browser must block: $err"
mcp mcp__playwright__browser_close >/dev/null
stop; [[ $rc -eq 0 ]] || fail "the spent block must not repeat: $err"
sh 'git push -u origin feature' >/dev/null
stop; [[ $rc -eq 2 && "$err" == *"[docker]"* ]] || fail "a push must re-arm a spent block (rc=$rc): $err"
ok "a push re-arms the one-shot block"

for command in 'git -C /srv/app push origin main' 'timeout 60 git push' 'env GIT_SSH_COMMAND=ssh git push' \
               'bash -lc "git push origin main"' 'cd sub && git push' 'if true; then git push; fi' \
               'git -c push.default=current push'; do
  rm -f "$pending"
  sh 'docker compose up -d' >/dev/null
  sh "$command" >/dev/null
  stop; [[ $rc -eq 2 && "$err" == *"[docker]"* ]] || fail "'$command' is a push (rc=$rc): $err"
done
rm -f "$pending"
ok "every push spelling the shell parser reads counts"

# ── a worktree: on completion, cleared by its path ──────────────────────────
real="$(cd "$scratch" && pwd -P)"
made() {  # <tool_use_id> <command>: the PreToolUse snapshot, the command, PostToolUse
  local input; input="$(printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps({"command": sys.stdin.read()}))')"
  for event in PreToolUse PostToolUse; do
    [[ "$event" == PostToolUse ]] && (cd "$gitdir" && eval "$2")
    printf '{"project_dir":"%s","cwd":"%s","event":"%s","session_id":"s1","tool_name":"Bash","tool_use_id":"%s","tool_input":%s}' \
      "$gitdir" "$gitdir" "$event" "$1" "$input" | bash "$gate"
  done
}
reminder="$(made u1 "git worktree add -q $scratch/wt-a -b wt-a")"
made u2 "git worktree add -q ../wt-b -b wt-b" >/dev/null
[[ "$(grep -c '^worktree	waiting	' "$pending")" == 2 ]] || fail "both worktrees must be recorded as waiting: $(cat "$pending")"
[[ "$reminder" == *"Made a worktree: $real/wt-a"* && "$reminder" == *"git worktree remove $real/wt-a"* ]] \
  || fail "the reminder must name the worktree and its removal: $reminder"
grep -q "\"path\": \"$real/wt-a\"" "$gitdir/.agents/worktrees/.records/s1.jsonl" || fail "the session's record file must name the worktree"
stop; [[ $rc -eq 0 ]] || fail "a worktree before a push must not block alone: $err"
sh 'git push origin HEAD' >/dev/null
git -C "$gitdir" worktree remove "$scratch/wt-a"
stop; [[ $rc -eq 2 && "$err" == *"git worktree remove $real/wt-b"* ]] || fail "a push must make the worktree due (rc=$rc): $err"
[[ "$err" != *"wt-a"* ]] || fail "a removed worktree must clear by its path: $err"
git -C "$gitdir" worktree remove "$scratch/wt-b"
stop; [[ $rc -eq 0 && ! -e "$pending" ]] || fail "removing the last worktree must clear the record: $(cat "$pending" 2>/dev/null)"
ok "a worktree waits for a push, then blocks once, and clears when its path is gone"

# ── each stop judges only what its own agent started ────────────────────────
rm -f "$pending"
sh 'npm run dev' true >/dev/null
cell_call() {  # <agent_id> <event> [command]
  set +e
  err="$(printf '{"project_dir":"%s","event":"%s","session_id":"s1","agent_id":"%s","tool_name":"Bash","tool_input":{"command":"%s","run_in_background":true},"stop_hook_active":false}' \
    "$dir" "$2" "$1" "${3:-}" | bash "$gate" 2>&1 >/dev/null)"
  rc=$?
  set -e
}
cell_call cell-x Stop
[[ $rc -eq 0 ]] || fail "the lead's dev server must not block a cell's stop (rc=$rc): $err"
cell_call cell-x PostToolUse 'npm run dev'
cell_call cell-x Stop
[[ $rc -eq 2 && "$err" == *"[server]"* ]] || fail "a cell's own server must block its stop (rc=$rc): $err"
grep -qx '#blocked' "$pending" && fail "a cell's stop must not spend the lead's block"
stop; [[ $rc -eq 2 && "$err" == *"[server]"* ]] || fail "the lead's own server must still block the lead's stop (rc=$rc): $err"
rm -f "$pending"
ok "a cell's stop judges only its own entries; the lead's stop still blocks on the lead's"

# ── identity and the config toggle ───────────────────────────────────────────
[[ -z "$(printf '{"project_dir":"%s","event":"PostToolUse","session_id":"","tool_name":"mcp__playwright__browser_navigate","tool_input":{"url":"http://x"}}' "$dir" | bash "$gate")" ]] \
  || fail "no session id must do nothing"
[[ -z "$(find "$dir/.agents" -maxdepth 1 -name '.teardown-pending-' -o -maxdepth 1 -name '.teardown-pending-nosession')" ]] \
  || fail "no session id must write no state"
ok "no session identity means no state"

rm -f "$pending"
printf '{"hooks":{"teardown_gate":{"enabled":false}}}\n' > "$dir/.agents/config.json"
[[ -z "$(mcp mcp__playwright__browser_navigate '{"url":"http://x"}')" && ! -e "$pending" ]] || fail "disabled policy recorded"
rm "$dir/.agents/config.json"
ok "the config toggle turns the gate off"

# ── Claude adapter end to end, including SubagentStop ────────────────────────
dir="$scratch/fixture"
gate="$dir/.agents/hooks/policy/teardown-gate.sh"
pending="$dir/.agents/.teardown-pending-c9"
rm -f "$dir/.agents/.teardown-pending-"*
c() { CLAUDE_PROJECT_DIR="$dir" bash "$dir/.agents/claude/adapter.sh" teardown-gate.sh; }
out="$(printf '{"hook_event_name":"PostToolUse","cwd":"%s","session_id":"c9","tool_name":"mcp__playwright__browser_navigate","tool_input":{"url":"http://localhost:3000"}}' "$dir" | c)"
[[ "$out" == *"browser_close"* ]] || fail "claude adapter navigate path: $out"
set +e
err="$(printf '{"hook_event_name":"SubagentStop","cwd":"%s","session_id":"c9","stop_hook_active":false}' "$dir" | c 2>&1 >/dev/null)"
rc=$?
set -e
[[ $rc -eq 2 && "$err" == *"[browser]"* ]] || fail "SubagentStop must block a cell holding a browser (rc=$rc): $err"
ok "the Claude adapter carries PostToolUse and SubagentStop"

rm -f "$dir/.agents/.teardown-pending-"*
for call in 'browser_open","tool_input":{"session_id":"one"}' 'browser_open","tool_input":{"session_id":"two"}' \
            'close_session","tool_input":{"session_id":"one"}'; do
  printf '{"hook_event_name":"PostToolUse","cwd":"%s","session_id":"c9","tool_name":"mcp__scrapling__%s}' "$dir" "$call" | c >/dev/null
done
grep -q 'two \[scrapling\]' "$pending" && ! grep -q 'one \[scrapling\]' "$pending" \
  || fail "a Claude-shaped close_session must clear only the session it names: $(cat "$pending" 2>/dev/null)"
ok "the Claude adapter delivers session_id to the close"

# ── Codex adapter end to end ─────────────────────────────────────────────────
rm -f "$dir/.agents/.teardown-pending-"*
x() { bash "$dir/.codex/hooks/adapter.sh" teardown-gate.sh; }
printf '{"hook_event_name":"PostToolUse","cwd":"%s","session_id":"x1","tool_name":"Bash","tool_input":{"command":"docker compose up -d"}}' "$dir" | x >/dev/null
grep -q '^docker' "$dir/.agents/.teardown-pending-x1" || fail "codex adapter must record"
ok "the Codex adapter records through the shared contract"

printf '\nall teardown-gate tests passed\n'
