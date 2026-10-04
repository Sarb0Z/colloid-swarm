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
cp "$repo/.agents/hooks/lib/config.py" "$repo/.agents/hooks/lib/emit-context.py" "$dir/.agents/hooks/lib/"
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
  "$repo/.agents/hooks/lib/guard-destructive.py" "$gitdir/.agents/hooks/lib/"
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

# ── Codex adapter end to end ─────────────────────────────────────────────────
rm -f "$dir/.agents/.teardown-pending-"*
x() { bash "$dir/.codex/hooks/adapter.sh" teardown-gate.sh; }
printf '{"hook_event_name":"PostToolUse","cwd":"%s","session_id":"x1","tool_name":"Bash","tool_input":{"command":"docker compose up -d"}}' "$dir" | x >/dev/null
grep -q '^docker' "$dir/.agents/.teardown-pending-x1" || fail "codex adapter must record"
ok "the Codex adapter records through the shared contract"

printf '\nall teardown-gate tests passed\n'
