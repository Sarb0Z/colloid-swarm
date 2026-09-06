#!/usr/bin/env bash
# Firing tests for the worktree-provision policy: a subagent starting in a
# linked worktree gets that worktree provisioned; one starting in the main
# checkout, at any depth, never triggers an install there.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
# Canonicalize once: provision.sh resolves its target with `pwd -P`, so any
# path comparison built from an un-resolved mktemp root (e.g. macOS's
# /var -> /private/var) would otherwise misread a real match as a mismatch.
scratch="$(cd "$scratch" && pwd -P)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

# --- a fake npm on PATH, controllable through files in $scratch -------------
mkdir -p "$scratch/bin"
cat > "$scratch/bin/npm" <<'FAKE'
#!/usr/bin/env bash
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
printf '%s\n' "$*" >> "$dir/npm.log"
pwd >> "$dir/npm.pwd.log"
: > "$dir/npm.ran"
[[ -f "$dir/npm.sleep" ]] && sleep "$(cat "$dir/npm.sleep")"
rc=0
[[ -f "$dir/npm.rc" ]] && rc="$(cat "$dir/npm.rc")"
exit "$rc"
FAKE
chmod +x "$scratch/bin/npm"
export PATH="$scratch/bin:$PATH"

# --- the fixture: a copy of the policy, its script, and its libraries -------
fixture="$scratch/fixture"
mkdir -p "$fixture/.agents/hooks/policy" "$fixture/.agents/hooks/lib" "$fixture/src"
cp "$repo/.agents/provision.sh" "$fixture/.agents/"
cp "$repo/.agents/hooks/policy/worktree-provision.sh" "$fixture/.agents/hooks/policy/"
cp "$repo/.agents/hooks/lib/config.py" "$repo/.agents/hooks/lib/emit-context.py" "$fixture/.agents/hooks/lib/"
printf '{"hooks":{"worktree_provision":{"enabled":true}}}\n' > "$fixture/.agents/config.json"
printf '{"name":"x","lockfileVersion":3}\n' > "$fixture/package-lock.json"
git -C "$fixture" init -q
git -C "$fixture" config user.email t@t
git -C "$fixture" config user.name t
git -C "$fixture" add -A
git -C "$fixture" commit -q -m first

policy="$fixture/.agents/hooks/policy/worktree-provision.sh"

call() {  # <cwd> -> sets out, err, rc
  local payload
  payload="$(printf '{"project_dir":"%s","cwd":"%s","agent_type":"implementer"}' "$fixture" "$1")"
  set +e
  out="$(printf '%s' "$payload" | bash "$policy" 2>"$scratch/err.txt")"
  rc=$?
  set -e
  err="$(cat "$scratch/err.txt")"
}

# 1. the main checkout's root is not a worktree
rm -f "$scratch/npm.ran"
call "$fixture"
[[ $rc -eq 0 ]] || fail "main-checkout root exit code: $rc"
[[ -z "$out" ]] || fail "main-checkout root produced stdout: $out"
[[ ! -f "$scratch/npm.ran" ]] || fail "main-checkout root ran an install"
ok "the main checkout's own root is left alone"

# 2. a subdirectory of the main checkout is still not a worktree — the case
# that must never provision in the operator's own tree
rm -f "$scratch/npm.ran"
call "$fixture/src"
[[ $rc -eq 0 ]] || fail "main-checkout subdir exit code: $rc"
[[ -z "$out" ]] || fail "main-checkout subdir produced stdout: $out"
[[ ! -f "$scratch/npm.ran" ]] || fail "main-checkout subdir ran an install"
ok "a subdirectory of the main checkout is left alone"

# 3. a linked worktree's root gets provisioned, with a SubagentStart context
git -C "$fixture" worktree add "$scratch/wt" -q -b wt
wt="$(cd "$scratch/wt" && pwd -P)"
mkdir -p "$wt/sub"
rm -f "$scratch/npm.ran"
call "$wt"
[[ $rc -eq 0 ]] || fail "worktree root exit code: $rc"
event="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["hookEventName"])')"
ctx="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')"
[[ "$event" == "SubagentStart" ]] || fail "worktree root hookEventName: $event"
[[ "$ctx" == *"installed npm:"* ]] || fail "worktree root context missing install: $ctx"
[[ "$ctx" == *"environment failure"* ]] || fail "worktree root context missing environment-failure language: $ctx"
[[ -f "$scratch/npm.ran" ]] || fail "worktree root did not run an install"
ok "a subagent starting in a linked worktree gets it provisioned"

# 4. a subdirectory of that worktree provisions the worktree's root, not the cwd
printf '{"name":"x","lockfileVersion":3,"v":4}\n' > "$wt/package-lock.json"
rm -f "$scratch/npm.ran" "$scratch/npm.pwd.log"
call "$wt/sub"
[[ $rc -eq 0 ]] || fail "worktree subdir exit code: $rc"
ctx="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')"
[[ "$ctx" == *"installed npm:"* ]] || fail "worktree subdir context missing install: $ctx"
[[ -f "$scratch/npm.ran" ]] || fail "worktree subdir did not run an install"
[[ "$(tail -n1 "$scratch/npm.pwd.log")" == "$wt" ]] || fail "install ran at $(tail -n1 "$scratch/npm.pwd.log"), expected worktree root $wt"
wt_gitdir="$(git -C "$wt" rev-parse --path-format=absolute --git-dir)"
[[ -f "$wt_gitdir/colloid-provisioned" ]] || fail "worktree memo missing at $wt_gitdir/colloid-provisioned"
ok "a subdirectory of a worktree still provisions at the worktree's root"

# 5. a failing install blocks the subagent's start with the environment-failure reason
printf '1' > "$scratch/npm.rc"
printf '{"name":"x","lockfileVersion":3,"v":5}\n' > "$wt/package-lock.json"
call "$wt"
[[ $rc -eq 2 ]] || fail "failing worktree install exit code: $rc"
[[ -z "$out" ]] || fail "failing worktree install produced stdout: $out"
[[ "$err" == *"This is an environment failure, not a code failure. Do not edit source to satisfy it."* ]] \
  || fail "failing worktree install missing the environment-failure sentence: $err"
printf '0' > "$scratch/npm.rc"
ok "a failing install blocks the subagent's start and names it an environment failure"

# 6. the config toggle turns the policy off entirely
printf '{"hooks":{"worktree_provision":{"enabled":false}}}\n' > "$fixture/.agents/config.json"
printf '{"name":"x","lockfileVersion3":3,"v":6}\n' > "$wt/package-lock.json"
rm -f "$scratch/npm.ran"
call "$wt"
[[ $rc -eq 0 ]] || fail "disabled policy exit code: $rc"
[[ -z "$out" ]] || fail "disabled policy produced stdout: $out"
[[ ! -f "$scratch/npm.ran" ]] || fail "disabled policy still ran an install"
printf '{"hooks":{"worktree_provision":{"enabled":true}}}\n' > "$fixture/.agents/config.json"
ok "the config toggle turns the policy off"

# 7. a missing or non-directory cwd is silently ignored
rm -f "$scratch/npm.ran"
call "$scratch/does-not-exist"
[[ $rc -eq 0 ]] || fail "missing cwd exit code: $rc"
[[ -z "$out" && -z "$err" ]] || fail "missing cwd was not silent: out=$out err=$err"
[[ ! -f "$scratch/npm.ran" ]] || fail "missing cwd ran an install"
ok "a missing or non-directory cwd is silently ignored"


# 8. the session's own directory is never provisioned, even when the operator
# launched from a linked worktree — project_dir and cwd coincide there
own="$scratch/own-session"
git -C "$fixture" worktree add -q "$own" -b own-session
rm -f "$scratch/npm.ran"
set +e
out="$(printf '{"project_dir":"%s","cwd":"%s","agent_type":"implementer"}' "$own" "$own" | bash "$policy" 2>"$scratch/err.txt")"; rc=$?
set -e
[[ $rc -eq 0 && -z "$out" && ! -e "$scratch/npm.ran" ]] || fail "own-session worktree was provisioned: rc=$rc out=$out"
ok "the session's own linked worktree is left alone"
# …but an isolation cell under .claude/worktrees/ is provisioned even if the
# host ever reported project_dir equal to its cwd
iso="$fixture/.claude/worktrees/agent-x"
mkdir -p "$fixture/.claude/worktrees"
git -C "$fixture" worktree add -q "$iso" -b iso-cell
rm -f "$scratch/npm.ran"
set +e
out="$(printf '{"project_dir":"%s","cwd":"%s","agent_type":"implementer"}' "$iso" "$iso" | bash "$policy" 2>"$scratch/err.txt")"; rc=$?
set -e
[[ $rc -eq 0 && "$out" == *installed* && -e "$scratch/npm.ran" ]] || fail "an isolation worktree under .claude/worktrees was skipped: rc=$rc out=$out"
ok "an isolation worktree under .claude/worktrees is provisioned regardless"


# 9. an isolation worktree with the session checkout's lockfile links its
# node_modules from there instead of installing
mkdir -p "$fixture/node_modules/left-pad"
sh_wt="$fixture/.claude/worktrees/agent-share"
git -C "$fixture" worktree add -q "$sh_wt" -b share-cell
rm -f "$scratch/npm.ran"
set +e
out="$(printf '{"project_dir":"%s","cwd":"%s","agent_type":"implementer"}' "$fixture" "$sh_wt" | bash "$policy" 2>"$scratch/err.txt")"; rc=$?
set -e
[[ $rc -eq 0 && "$out" == *"shared from"* && -L "$sh_wt/node_modules" && ! -e "$scratch/npm.ran" ]] || fail "isolation worktree did not share the session's node_modules: rc=$rc out=$out"
ok "an isolation worktree shares the session checkout's node_modules when the lockfile matches"

printf '\nall worktree-provision tests passed\n'
