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
# Spec acceptance 22: a session launched in a lane worktree (CLAUDE_PROJECT_DIR is
# the lane, which carries its own adapter) runs the main checkout's copy.
runs_stub 12 "launched in a workloop lane under .agents/worktrees that has its own adapter: the checkout's adapter runs" \
  "$workloop_lane" "$workloop_lane/sub" repo "$pf/repo"
runs_stub 13 "launched in a lane under .claude/worktrees that has its own adapter: the checkout's adapter runs" \
  "$lane" "$lane" repo "$pf/repo"
# The command exports the folder it was launched in, which the adapter falls back
# to for a policy the main checkout lacks.
before=$fails
for i in "${!cmds[@]}"; do
  [[ "${cmds[$i]}" == *'COLLOID_HOOK_LAUNCH=\"$o\"'* || "${cmds[$i]}" == *'COLLOID_HOOK_LAUNCH="$o"'* ]] \
    || fail "row 12: ${events[$i]} '$(args_of "${cmds[$i]}")' does not export COLLOID_HOOK_LAUNCH"
done
printf '#!/usr/bin/env bash\necho "workloop-lane COLLOID_HOOK_LAUNCH=$COLLOID_HOOK_LAUNCH"\n' > "$scratch/launch-probe.sh"
run "$(printf '%s' "${cmds[0]}" | sed -E 's#exec bash "\$d/\.claude/hooks/adapter\.sh" .*$#exec bash '"$scratch"'/launch-probe.sh#')" "$workloop_lane" "$workloop_lane"
[[ "$out" == "workloop-lane COLLOID_HOOK_LAUNCH=$workloop_lane" ]] || fail "row 12: the launch folder was not exported: '$out'"
[[ "$fails" -eq "$before" ]] && ok "row 12: every hook command exports the folder it was launched in as COLLOID_HOOK_LAUNCH"

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

# Spec acceptance 21: a registration saved before its script does not lock the
# session. A present policy without its executable bit runs through bash and
# warns; an absent one denies every call in auto mode except a Write or Edit of
# its own path.
# Seam: the real adapter and normalizer run from a scratch repository; it
# catches a policy that does not run, a missing warning, and an allowance that
# leaks to other paths or tools, and misses how a live session renders them.
before=$fails
adapter_repo="$scratch/adapter-repo"
mkdir -p "$adapter_repo/.agents/claude" "$adapter_repo/.agents/hooks/policy" "$adapter_repo/.agents/hooks/lib"
cp "$repo/.agents/claude/adapter.sh" "$repo/.agents/claude/normalize-hook.py" "$adapter_repo/.agents/claude/"
cp "$repo/.agents/hooks/lib/write_targets.py" "$adapter_repo/.agents/hooks/lib/"
printf '#!/usr/bin/env bash\necho "plain ran"\n' > "$adapter_repo/.agents/hooks/policy/plain.sh"
chmod 644 "$adapter_repo/.agents/hooks/policy/plain.sh"
pretool='{"hook_event_name":"PreToolUse","permission_mode":"bypassPermissions","tool_name":"Bash","tool_input":{"command":"true"}}'
adapt() { bash "$adapter_repo/.agents/claude/adapter.sh" "$1" 2>"$scratch/aerr"; }
out="$(adapt plain.sh <<<"$pretool")" && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$out" == "plain ran" && "$(<"$scratch/aerr")" == *"not executable"*"chmod +x .agents/hooks/policy/plain.sh"* ]] \
  || fail "adapter: a policy without its executable bit did not run with a warning: exit $rc, stdout '$out', stderr '$(<"$scratch/aerr")'"
reason="$(adapt absent.sh <<<"$pretool" | jq -r '.hookSpecificOutput.permissionDecision + " " + .hookSpecificOutput.permissionDecisionReason')"
[[ "$reason" == "deny "*"absent.sh policy is missing from this checkout"* ]] \
  || fail "adapter: a Bash call under an absent policy was not denied in auto mode: $reason"
write_own() {  # <tool> <file_path> -> the adapter's stdout for that call under absent.sh
  jq -nc --arg t "$1" --arg f "$2" '{hook_event_name:"PreToolUse",permission_mode:"bypassPermissions",tool_name:$t,tool_input:{file_path:$f}}' | adapt absent.sh
}
for target in "$adapter_repo/.agents/hooks/policy/absent.sh" ".agents/hooks/policy/absent.sh" "$scratch/lane/.agents/hooks/policy/absent.sh"; do
  for tool in Write Edit; do
    out="$(write_own "$tool" "$target")" && rc=0 || rc=$?
    [[ "$rc" -eq 0 && -z "$out" ]] || fail "adapter: $tool of the missing policy's own path $target was not allowed: exit $rc, '$out'"
  done
done
[[ "$(write_own Write "$adapter_repo/.agents/hooks/policy/other.sh" | jq -r .hookSpecificOutput.permissionDecision)" == deny ]] \
  || fail "adapter: a Write to another policy's path passed under an absent policy"
[[ "$(write_own Write "$adapter_repo/absent.sh" | jq -r .hookSpecificOutput.permissionDecision)" == deny ]] \
  || fail "adapter: a Write to a file of the same name outside the policy folder passed under an absent policy"
[[ "$(write_own Read "$adapter_repo/.agents/hooks/policy/absent.sh" | jq -r .hookSpecificOutput.permissionDecision)" == deny ]] \
  || fail "adapter: a Read of the missing policy's path passed: only a Write or Edit repairs it"
# A policy only the launch folder has runs from there.
launch_repo="$scratch/launch-repo"
mkdir -p "$launch_repo/.agents/claude" "$launch_repo/.agents/hooks/policy" "$launch_repo/.agents/hooks/lib"
cp "$adapter_repo/.agents/claude/"*.{sh,py} "$launch_repo/.agents/claude/"; cp "$adapter_repo/.agents/hooks/lib/"*.py "$launch_repo/.agents/hooks/lib/"
printf '#!/usr/bin/env bash\necho "lane copy ran"\n' > "$launch_repo/.agents/hooks/policy/new.sh"; chmod +x "$launch_repo/.agents/hooks/policy/new.sh"
out="$(COLLOID_HOOK_LAUNCH="$launch_repo" adapt new.sh <<<"$pretool")" && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$out" == "lane copy ran" && "$(<"$scratch/aerr")" == *"running the copy in $launch_repo"* ]] \
  || fail "adapter: a policy only the launch folder has did not run from there: exit $rc, '$out', '$(<"$scratch/aerr")'"
[[ "$fails" -eq "$before" ]] && ok "row 21: a non-executable policy runs through bash and warns; an absent one denies all but a Write or Edit of its own path; a policy only the launch folder has runs from there"

# Every policy a host configuration names exists and is executable: a
# registration goes live the moment it is saved, and the adapter denies every
# call a gate it cannot run covers. HOOK_LOOKUP_POLICY_DIR names another policy
# folder to test (default: the committed one).
# Seam: the three host files and the policy folder; it catches a registered name
# with no file or no executable bit and misses a policy that is executable and wrong.
before=$fails
policy_dir="${HOOK_LOOKUP_POLICY_DIR:-$repo/.agents/hooks/policy}"
named_count=0
for host_file in "$repo/.agents/claude/settings.json" "$repo/.agents/codex/hooks.json" "$repo/.kimi/config.toml.example"; do
  names="$(grep -v '^ *#' "$host_file" | grep -oE '[A-Za-z0-9_-]+\.sh' | sort -u | grep -vxE 'adapter\.sh|statusline\.sh' || true)"
  [[ -n "$names" ]] || fail "policy names: found none in $host_file"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    named_count=$((named_count + 1))
    if [[ ! -e "$policy_dir/$name" ]]; then
      fail "policy names: $host_file names $name, which is absent from $policy_dir"
    elif [[ ! -x "$policy_dir/$name" ]]; then
      fail "policy names: $host_file names $name, which lacks its executable bit in $policy_dir"
    fi
  done <<<"$names"
done
[[ "$fails" -eq "$before" ]] && ok "policy names: all $named_count registrations name an executable policy"

[[ "$fails" -eq 0 ]] || { printf '%s hook-lookup rows failed\n' "$fails" >&2; exit 1; }
