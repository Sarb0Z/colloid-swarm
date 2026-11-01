#!/usr/bin/env bash
# Firing tests for the keychain-notice policy: a shell command that reads the
# macOS keychain is named in a notification, in tmux and in the log; any other
# command passes silently, and no path blocks the command.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

dir="$scratch/shop-app"
mkdir -p "$dir/.agents/hooks/policy" "$dir/.agents/hooks/lib" "$dir/.agents/claude" "$dir/.agents/codex" "$dir/.codex/hooks"
cp "$repo/.agents/hooks/policy/keychain-notice.sh" "$dir/.agents/hooks/policy/"
cp "$repo"/.agents/hooks/lib/{config,payload,keychain-readers,write_targets}.py "$dir/.agents/hooks/lib/"
cp "$repo/.agents/claude/adapter.sh" "$repo/.agents/claude/normalize-hook.py" "$dir/.agents/claude/"
cp "$repo/.agents/codex/normalize-hook.py" "$dir/.agents/codex/"
cp "$repo/.codex/hooks/adapter.sh" "$dir/.codex/hooks/"
log="$dir/.agents/.keychain-notices.log"

# Stand-ins for the programs the policy calls, so no test posts a real
# notification. Each records its arguments one per line; KC_UNAME,
# KC_OSASCRIPT_FAIL and KC_OSASCRIPT_HANG steer them.
bin="$scratch/bin"
mkdir -p "$bin"
printf '#!/usr/bin/env bash\necho "${KC_UNAME:-Darwin}"\n' >"$bin/uname"
cat >"$bin/osascript" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$scratch/osascript.args"
[[ -z "\${KC_OSASCRIPT_HANG:-}" ]] || exec sleep 30
[[ -z "\${KC_OSASCRIPT_FAIL:-}" ]]
EOF
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >"%s/tmux.args"\n' "$scratch" >"$bin/tmux"
chmod +x "$bin"/*
export PATH="$bin:$PATH"
unset CLAUDE_PROJECT_DIR TMUX KC_UNAME KC_OSASCRIPT_FAIL KC_OSASCRIPT_HANG

reset() { rm -f "$scratch/osascript.args" "$scratch/tmux.args" "$log" "$dir/.agents/policy.json" "$dir/.agents/config.json"; }

run() {  # <adapter> <payload> -> rc, out, err
  set +e
  out="$(printf '%s' "$2" | bash "$1" keychain-notice.sh 2>"$scratch/err")"
  rc=$?
  set -e
  err="$(cat "$scratch/err")"
}

claude() {  # <command>
  run "$dir/.agents/claude/adapter.sh" "$(python3 -c 'import json, sys; print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))' "$1" "$dir/src")"
}

notified() {  # -> the folder, reader and command line the notification carried
  tail -n 3 "$scratch/osascript.args"
}

fires() {  # <command> <reader> <why>
  reset; claude "$1"
  [[ $rc -eq 0 && -z "$out" ]] || fail "$3: rc=$rc out=$out err=$err"
  grep -q "reader: $2\$" "$log" 2>/dev/null || fail "$3: the log must name $2: $(cat "$log" 2>/dev/null)"
}

quiet() {  # <command> <why>
  reset; claude "$1"
  [[ $rc -eq 0 && -z "$out" ]] || fail "$2: rc=$rc out=$out"
  [[ ! -e "$scratch/osascript.args" && ! -e "$log" ]] || fail "$2: a notice was posted"
}

reset; claude 'supabase projects list -o json | jq .'
[[ $rc -eq 0 && -z "$out" && -z "$err" ]] || fail "a reader must pass without output (rc=$rc out=$out err=$err)"
[[ "$(notified)" == $'shop-app\nsupabase\nsupabase projects list -o json | jq .' ]] ||
  fail "the notification must name the project folder, the reader and the command: $(notified)"
grep -q "$dir/src  reader: supabase" "$log" && grep -q "  supabase projects list -o json | jq ." "$log" ||
  fail "the log must hold the folder, the reader and the command: $(cat "$log")"
[[ ! -e "$scratch/tmux.args" ]] || fail "outside tmux the status line must stay untouched"
ok "the Supabase CLI is named in a notification and the log, and the command runs"

reset; claude $'cd api\nfor i in 1 2; do\n  s=$(supabase projects list -o json)\ndone'
[[ "$(notified | tail -n 1)" == 's=$(supabase projects list -o json)' ]] ||
  fail "the notification must show the line that runs the reader: $(notified)"
grep -q "  cd api" "$log" && grep -q "^done" "$log" || fail "the log must hold the whole command: $(cat "$log")"
ok "the notification shows the reader's own line; the log keeps the whole command"

reset; TMUX=/tmp/tmux-501/default,1,0 claude "supabase status | jq '\"#{x} #(id)\"'"
grep -q 'shop-app, supabase' "$scratch/tmux.args" && grep -qF '##{x} ##(id)' "$scratch/tmux.args" ||
  fail "inside tmux the status line must carry the notice with each # doubled: $(cat "$scratch/tmux.args" 2>/dev/null)"
ok "inside tmux the status line carries the notice, and tmux formats in it stay literal"

fires 'npx supabase@latest db push' supabase "an npx version pin"
fires 'bunx supabase login' supabase "bunx"
fires '/opt/homebrew/bin/supabase status' supabase "an absolute path"
fires $'supabase \\\n  db push' supabase "a line continuation right after the name"
fires 'security find-generic-password -s "Supabase CLI" -w' "security find-generic-password" "a password lookup"
fires 'security -q find-generic-password -s x' "security find-generic-password" "an option before the subcommand"
fires $'echo start\nsecurity  find-internet-password -s github.com' "security find-internet-password" "a reader on a later line"
ok "readers are found behind npx and bunx pins, paths, options and line breaks"

quiet 'ls -la' "a plain command"
quiet 'npx supabase-helper sync' "a program whose name only starts with a reader's"
quiet 'cd supabase/migrations && ls' "a folder named after a reader"
quiet 'security list-keychains' "a security subcommand that reads no password"
quiet 'git log --grep=supabaseurl' "a reader's name inside a longer word"
ok "commands that read no keychain item pass silently"

reset; run "$dir/.agents/claude/adapter.sh" '{}'
[[ $rc -eq 0 && -z "$out" && -z "$err" && ! -e "$log" ]] || fail "an empty payload must pass silently (rc=$rc err=$err)"
reset; run "$dir/.agents/claude/adapter.sh" ''
[[ $rc -eq 0 && -z "$out" && ! -e "$log" ]] || fail "a blank payload must pass (rc=$rc err=$err)"
ok "an empty or blank payload passes silently"

reset; printf '{"hooks":{"keychain_notice":{"readers":["environments.py"]}}}' >"$dir/.agents/policy.json"
claude 'uv run python scripts/environments.py --env prod'
grep -q "reader: environments.py" "$log" || fail "a reader the repository lists must be named"
ok "a repository lists its own readers in policy.json"
reset; quiet 'uv run python scripts/environments.py --env prod' "an unlisted script"

reset; printf '{"hooks":{"keychain_notice":{"readers":["environments.py"]}}}' >"$dir/.agents/policy.json"
python3 - "$repo/.agents/config.json.example" "$dir/.agents/config.json" <<'PY'
import json, sys
json.dump(json.load(open(sys.argv[1])), open(sys.argv[2], "w"))
PY
claude 'python3 environments.py'
grep -q "reader: environments.py" "$log" || fail "an operator's copy of config.json.example must not erase the repository's readers"
ok "an operator config copied from the example keeps the repository's readers"

reset; printf '{"hooks":{"keychain_notice":{"readers":"environments.py"}}}' >"$dir/.agents/policy.json"
claude 'supabase status'
[[ "$err" == *"must be a list of program names"* ]] || fail "a malformed reader list must be reported: $err"
grep -q "reader: supabase" "$log" || fail "a malformed reader list must leave the built-in readers working"
ok "a malformed reader list is reported and the built-in readers still fire"

reset; printf '{"hooks":{"keychain_notice":{"enabled":false}}}' >"$dir/.agents/config.json"
claude 'supabase status'
[[ $rc -eq 0 && ! -e "$scratch/osascript.args" && ! -e "$log" ]] || fail "the toggle must switch the notice off"
ok "hooks.keychain_notice.enabled false switches the notice off"

reset; KC_UNAME=Linux claude 'supabase status'
[[ $rc -eq 0 && ! -e "$scratch/osascript.args" && ! -e "$log" ]] || fail "off macOS the notice must not fire"
ok "off macOS the hook does nothing"

reset; KC_OSASCRIPT_FAIL=1 claude 'supabase status'
[[ $rc -eq 0 && "$err" == *"osascript's notification failed"* ]] || fail "a failed notification must be reported without blocking (rc=$rc err=$err)"
grep -q "reader: supabase" "$log" || fail "a failed notification must still log"
ok "a failed notification is reported on stderr, logged, and never blocks"

reset; started=$SECONDS
KC_OSASCRIPT_HANG=1 claude 'supabase status'
(( SECONDS - started < 15 )) || fail "a hung notifier must be stopped, not waited on ($((SECONDS - started)) s)"
[[ $rc -eq 0 && "$err" == *"did not finish within 5 s"* ]] || fail "a hung notifier must be reported (rc=$rc err=$err)"
ok "a hung notifier is stopped after five seconds and reported"

reset
run "$dir/.codex/hooks/adapter.sh" "$(python3 -c 'import json, sys; print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": "supabase link"}, "cwd": sys.argv[1]}))' "$dir")"
[[ $rc -eq 0 ]] || fail "the Codex adapter must run the notice (rc=$rc): $err"
[[ "$(notified | tail -n 1)" == 'supabase link' ]] || fail "a Codex shell command must be named: $(notified)"
ok "a Codex shell command is named too"

for settings in "$repo/.agents/claude/settings.json" "$repo/.agents/codex/hooks.json"; do
  python3 - "$settings" <<'PY' || fail "$settings must run keychain-notice.sh before Bash"
import json, sys
entries = json.load(open(sys.argv[1]))["hooks"]["PreToolUse"]
assert any(
    "Bash" in entry.get("matcher", "").split("|")
    and any("keychain-notice.sh" in hook.get("command", "") for hook in entry["hooks"])
    for entry in entries
)
PY
done
ok "Claude and Codex both run the notice before a shell command"
