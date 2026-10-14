#!/usr/bin/env bash
# Firing tests for the hook and statusLine commands in .agents/claude/settings.json:
# each finds its adapter from the launch folder, else from the working folder
# upward, and says so when it finds none. HOOK_LOOKUP_SETTINGS names another
# settings file to test (default: the committed one).
set -euo pipefail
# A caller such as `git rebase -x` exports these; nothing below may reach a
# repository other than the one named.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
settings="${HOOK_LOOKUP_SETTINGS:-$repo/.agents/claude/settings.json}"
scratch="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$scratch"' EXIT
fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
ok() { printf 'ok    %s\n' "$*"; }
RELAUNCH='relaunch Claude Code from inside the repository'

home="$scratch/home"
pf="$scratch/pf"
other="$scratch/other"
lane="$pf/repo/.claude/worktrees/lane"
workloop_lane="$pf/repo/.agents/worktrees/r/l"
mkdir -p "$home" "$scratch/outside" "$pf/.claude" "$pf/repo/sub" "$workloop_lane/sub"

# A stub repository answers with the folder it was given and what it received.
stub() {  # <root> <name>
  mkdir -p "$1/.claude/hooks" "$1/.agents/claude"
  for f in "$1/.claude/hooks/adapter.sh" "$1/.agents/claude/statusline.sh"; do
    printf '#!/usr/bin/env bash\necho "%s CLAUDE_PROJECT_DIR=$CLAUDE_PROJECT_DIR POST_EDIT_MODE=${POST_EDIT_MODE-} args=$*"\n' "$2" > "$f"
    chmod +x "$f"
  done
  # The status line never reads the project variable; it only has to be found.
  printf '#!/usr/bin/env bash\necho "%s statusline"\n' "$2" > "$1/.agents/claude/statusline.sh"
}
stub "$pf/repo" repo
stub "$other" other
stub "$lane" lane
stub "$workloop_lane" workloop-lane

events=(); cmds=()
while IFS=$'\t' read -r event cmd; do
  events+=("$event"); cmds+=("$cmd")
done < <(jq -r '.hooks | to_entries[] | .key as $e | .value[].hooks[] | "\($e)\t\(.command)"' "$settings")
status_cmd="$(jq -r '.statusLine.command' "$settings")"
[[ "${#cmds[@]}" -ge 1 && -n "$status_cmd" && "$status_cmd" != null ]] \
  || fail "expected at least one hook command and a statusLine command in $settings, found ${#cmds[@]}"

# run <command> <launch folder or -> <working folder> -> sets out, err, rc
run() {
  local envs=(PATH="$PATH" HOME="$home")
  [[ "$2" == "-" ]] || envs+=(CLAUDE_PROJECT_DIR="$2")
  out="$(cd "$3" && env -i "${envs[@]}" /bin/sh -c "$1" 2>"$scratch/err" <<<'{}')" && rc=0 || rc=$?
  err="$(<"$scratch/err")"
}
args_of() { printf '%s' "$1" | sed -E 's/.*adapter\.sh"? //'; }
expected() {  # <command> <stub name> <project dir> -> the line the stub prints
  local pem="" args=""
  [[ "$1" == "$status_cmd" ]] && { printf '%s statusline' "$2"; return; }
  case "$1" in *POST_EDIT_MODE=write*) pem=write ;; esac
  case "$1" in *.claude/hooks/adapter.sh*) args="$(args_of "$1")" ;; esac
  printf '%s CLAUDE_PROJECT_DIR=%s POST_EDIT_MODE=%s args=%s' "$2" "$3" "$pem" "$args"
}

# every_command <row> <description> <launch> <cwd> <stub name> <project dir>
runs_stub() {
  local before=$fails i cmd
  for i in "${!cmds[@]}"; do
    cmd="${cmds[$i]}"
    run "$cmd" "$3" "$4"
    [[ "$rc" -eq 0 && "$out" == "$(expected "$cmd" "$5" "$6")" ]] \
      || fail "row $1: ${events[$i]} '$(args_of "$cmd")': exit $rc, stdout '$out', stderr '${err:0:120}'"
  done
  run "$status_cmd" "$3" "$4"
  [[ "$rc" -eq 0 && "$out" == "$(expected "$status_cmd" "$5" "$6")" ]] \
    || fail "row $1: statusLine: exit $rc, stdout '$out', stderr '${err:0:120}'"
  [[ "$fails" -eq "$before" ]] && ok "row $1: $2"
  return 0
}
runs_nothing() {  # <row> <description> <launch> <cwd>
  local before=$fails i cmd want
  for i in "${!cmds[@]}"; do
    cmd="${cmds[$i]}"
    want=1; [[ "${events[$i]}" == "PreToolUse" ]] && want=2
    run "$cmd" "$3" "$4"
    [[ "$rc" -eq "$want" && -z "$out" && "$err" == *"$RELAUNCH"* ]] \
      || fail "row $1: ${events[$i]} '$(args_of "$cmd")': exit $rc (want $want), stdout '$out', stderr '${err:0:120}'"
  done
  run "$status_cmd" "$3" "$4"
  [[ "$rc" -eq 0 && "$out" == "guards unavailable: $RELAUNCH" ]] \
    || fail "row $1: statusLine: exit $rc, stdout '$out', stderr '${err:0:120}'"
  [[ "$fails" -eq "$before" ]] && ok "row $1: $2"
  return 0
}

runs_stub 1 "the launch folder holds the adapter: it runs there, from any working folder" \
  "$pf/repo" "$scratch/outside" repo "$pf/repo"
runs_stub 2 "a product folder as launch folder: the walk from the working folder finds the repository" \
  "$pf" "$pf/repo/sub" repo "$pf/repo"
runs_stub 3 "no launch folder: the walk from the working folder finds the repository" \
  - "$pf/repo" repo "$pf/repo"
runs_nothing 4 "no adapter anywhere: guards block, other hooks notice, the status line warns" \
  "$pf" "$pf"
# Every tool call, reads included, is blocked by one match-all PreToolUse group.
before=$fails
jq -e '[.hooks.PreToolUse[] | select((.matcher // "") | IN("", "*")) | select(any(.hooks[]; .command | contains("exit 2")))] | length >= 1' "$settings" >/dev/null \
  || fail "row 4: no match-all PreToolUse group whose command carries exit 2"
[[ "$fails" -eq "$before" ]] && ok "row 4: a match-all PreToolUse group blocks every tool call when nothing is found"
runs_stub 5 "the launch folder wins over a repository in the working folder" \
  "$pf/repo" "$other" repo "$pf/repo"
runs_nothing 6 "a bogus launch folder and a walk to the root end as row 4" \
  "$scratch/does-not-exist" /
# Row 7 rides on the stub comparison: every row above checks the arguments and
# POST_EDIT_MODE the stub received against the ones written in the command.
runs_stub 9 "a lane under .claude/worktrees maps back to the checkout's adapter" \
  "$pf" "$lane" repo "$pf/repo"
runs_stub 11 "no launch folder, working inside a workloop lane under .agents/worktrees: the checkout's adapter runs, so the lane's hooks read the run state where it lives" \
  - "$workloop_lane/sub" repo "$pf/repo"

before=$fails
for i in "${!cmds[@]}"; do
  case "${cmds[$i]}" in
    *'*/.claude/worktrees/*)'*'*/.agents/worktrees/*)'*) ;;
    *) fail "row 11: ${events[$i]} '$(args_of "${cmds[$i]}")' lacks the .claude/worktrees or the .agents/worktrees fallback" ;;
  esac
done
case "$status_cmd" in
  *'*/.claude/worktrees/*)'*'*/.agents/worktrees/*)'*) ;;
  *) fail "row 11: the statusLine command lacks the .claude/worktrees or the .agents/worktrees fallback" ;;
esac
[[ "$fails" -eq "$before" ]] && ok "row 11: every hook command and the statusLine carry both nested-worktree fallbacks"

before=$fails
write_count=0
for i in "${!cmds[@]}"; do
  case "${cmds[$i]}" in *POST_EDIT_MODE=write*) write_count=$((write_count + 1)) ;; esac
done
[[ "$write_count" -eq 1 && "$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$settings")" == *"export POST_EDIT_MODE=write CLAUDE_PROJECT_DIR="* ]] \
  || fail "row 7: only the first PostToolUse entry carries POST_EDIT_MODE=write ($write_count carry it)"
[[ "$fails" -eq "$before" ]] && ok "row 7: only the post-edit entry carries POST_EDIT_MODE=write; arguments pass through intact"

before=$fails
for i in "${!cmds[@]}"; do
  if [[ "${events[$i]}" == "PreToolUse" ]]; then
    [[ "${cmds[$i]}" == *"exit 2"* ]] || fail "row 8: PreToolUse '$(args_of "${cmds[$i]}")' lacks exit 2"
  else
    [[ "${cmds[$i]}" != *"exit 2"* ]] || fail "row 8: ${events[$i]} '$(args_of "${cmds[$i]}")' carries exit 2"
  fi
done
[[ "$fails" -eq "$before" ]] && ok "row 8: exit 2 on every PreToolUse command and on no other"

# Row 10: with the exit code, the optional POST_EDIT_MODE and the trailing
# arguments removed, the hook commands are byte-identical, and the statusLine
# lookup matches them modulo the script name and the not-found branch.
before=$fails
shape() {  # <command> -> the command without its per-entry parts
  printf '%s' "$1" | sed -E -e 's/\{ echo ".*;exit [0-9];\};d=/{ NOT_FOUND;};d=/' \
    -e 's/export POST_EDIT_MODE=write /export /' -e 's/(exec bash "\$d\/\.claude\/hooks\/adapter\.sh") .*$/\1/'
}
first="$(shape "${cmds[0]}")"
for i in "${!cmds[@]}"; do
  [[ "$(shape "${cmds[$i]}")" == "$first" ]] || fail "row 10: ${events[$i]} '$(args_of "${cmds[$i]}")' differs from the first command; register a Claude hook by copying an existing .agents/claude/settings.json command and changing only its adapter arguments (and the exit code for its event: 2 for PreToolUse, 1 otherwise)"
done
lookup() { printf '%s' "$1" | sed -E -e 's/\{ echo ".*;exit [0-9];\};d=/{ NOT_FOUND;};d=/' -e 's/;(export|exec bash) .*$//'; }
status_lookup="$(lookup "$status_cmd" | sed 's#\.agents/claude/statusline\.sh#.claude/hooks/adapter.sh#g')"
[[ "$status_lookup" == "$(lookup "${cmds[0]}")" ]] || fail "row 10: the statusLine lookup differs from the hook lookup"
[[ "$fails" -eq "$before" ]] && ok "row 10: the hook commands and the statusLine lookup share one form"

# End to end: the real guard, launched from a product folder, working in this
# repository, denies a hard reset.
before=$fails
guard_cmd=""
for i in "${!cmds[@]}"; do
  case "${cmds[$i]}" in *"adapter.sh\" guard-destructive.sh"* | *"adapter.sh guard-destructive.sh"*) guard_cmd="${cmds[$i]}"; break ;; esac
done
payload="$(printf '{"hook_event_name":"PreToolUse","session_id":"hook-lookup","cwd":"%s","tool_name":"Bash","tool_input":{"command":"git reset --hard"}}' "$repo")"
out="$(cd "$repo" && env -i PATH="$PATH" HOME="$home" CLAUDE_PROJECT_DIR="$pf" /bin/sh -c "$guard_cmd" 2>"$scratch/err" <<<"$payload")" && rc=0 || rc=$?
err="$(<"$scratch/err")"
# Exit 2 with the guard's own text: the not-found path (relaunch line) and the
# adapter's missing-policy path (JSON deny, exit 0) must not pass for it.
if [[ "$rc" -eq 2 && "$err" == *"destroys uncommitted work"* && "$err" != *"$RELAUNCH"* ]]; then
  :
else
  fail "end to end: guard-destructive did not deny a hard reset from a product-folder launch: exit $rc, stdout '${out:0:120}', stderr '${err:0:120}'"
fi
[[ "$fails" -eq "$before" ]] && ok "end to end: the real guard-destructive denies a hard reset launched from a product folder"

[[ "$fails" -eq 0 ]] || { printf '%s hook-lookup rows failed\n' "$fails" >&2; exit 1; }
