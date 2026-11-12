#!/usr/bin/env bash
# Firing tests for revert-check.sh: a fix's test must pass at the fix and fail
# once every other changed file is back at its base content.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo/.agents/revert-check.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

git_fx() { git -C "$fx" -c user.name=t -c user.email=t@example.com "$@"; }

# A fixture repository: lib.txt is the code, check.sh the test. The base commit
# holds the defect; the fix commit corrects lib.txt. Prints the root.
fixture() {  # <test file content committed with the fix>
  fx="$(mktemp -d "$scratch/fx.XXXXXX")"
  git -C "$fx" init -q
  printf 'bad\n' > "$fx/lib.txt"
  git_fx add -A
  git_fx commit -qm base
  git -C "$fx" rev-parse HEAD > "$fx/.base"
  printf 'good\n' > "$fx/lib.txt"
  printf '%s\n' "$1" > "$fx/check.sh"
  git_fx add -A
  git_fx commit -qm fix
  base="$(cat "$fx/.base")"
  rm "$fx/.base"
}
rc_of() { set +e; out="$(cd "$fx" && "$@" 2>&1)"; rc=$?; set -e; }
leaks() { git -C "$fx" worktree list | wc -l | tr -d ' '; }

STRICT='[[ "$(cat lib.txt)" == good ]] || { echo "assertion failed: lib.txt is not good"; exit 1; }'

# A test that fails without its fix, added by the fix itself: the success path,
# and the test file must survive the restore.
fixture "$STRICT"
rc_of "$script" "$base" --tests check.sh -- bash check.sh
[[ $rc -eq 0 ]] || fail "a test that catches its defect must exit 0 (got $rc): $out"
grep -qF 'assertion failed: lib.txt is not good' <<<"$out" || fail "the reverted run must fail on the assertion, not on a missing test: $out"
grep -qF 'catches the defect' <<<"$out" || fail "pass line missing: $out"
grep -qF 'confirm' <<<"$out" || fail "the pass line must ask the reader to confirm the failure is the test's assertion: $out"
[[ "$(leaks)" -eq 1 ]] || fail "worktree leaked after success"
ok "a test added by the fix passes at the fix and fails reverted, and the worktree is gone"

# A test that passes without the fix is weak.
fixture 'exit 0'
rc_of "$script" "$base" --tests check.sh -- bash check.sh
[[ $rc -eq 1 ]] || fail "a weak test must exit 1 (got $rc): $out"
grep -qF 'does not catch the defect' <<<"$out" || fail "weak-test message missing: $out"
[[ "$(leaks)" -eq 1 ]] || fail "worktree leaked after a weak test"
ok "a test that passes with the fix reverted is refused as not catching the defect"

# A command that cannot run at the fix is an environment failure, not proof.
fixture "$STRICT"
rc_of "$script" "$base" --tests check.sh -- bash missing-test.sh
[[ $rc -eq 1 ]] || fail "a command that cannot run at the fix must exit 1 (got $rc): $out"
grep -qF 'cannot run at the fix' <<<"$out" && grep -qF 'environment' <<<"$out" || fail "environment message missing: $out"
grep -qF 'either the environment or the fix is wrong' <<<"$out" || fail "the failure at the fix must name both causes: $out"
grep -qF 'does not catch' <<<"$out" && fail "an environment failure was reported as a weak test: $out"
[[ "$(leaks)" -eq 1 ]] || fail "worktree leaked after an environment failure"
ok "a command that fails at the fix is named an environment failure"

# Cleanup on an interrupt: the worktree goes and the command's child stops.
fixture 'sleep 60 & echo $! > "$PIDFILE"; wait'
export PIDFILE="$scratch/child.pid"
( cd "$fx" && exec "$script" "$base" --tests check.sh -- bash check.sh ) >/dev/null 2>&1 &
runner=$!
for _ in $(seq 40); do [[ -s "$PIDFILE" ]] && break; sleep 0.25; done
[[ -s "$PIDFILE" ]] || fail "the command never started"
kill -TERM "$runner"
set +e; wait "$runner"; interrupted=$?; set -e
[[ $interrupted -eq 143 ]] || fail "TERM must exit 143 (got $interrupted)"
child="$(cat "$PIDFILE")"
for _ in $(seq 20); do kill -0 "$child" 2>/dev/null || break; sleep 0.25; done
kill -0 "$child" 2>/dev/null && { kill "$child"; fail "the command's child outlived the interrupt"; }
[[ "$(leaks)" -eq 1 ]] || fail "worktree leaked after an interrupt"
ok "an interrupt exits 143, removes the worktree and stops the command's child"

# A test path is read relative to the repository root. A leading ./ is the same
# file; a misspelt, absolute or .. path is a usage error, never a false proof.
fixture "$STRICT"
rc_of "$script" "$base" --tests ./check.sh -- bash check.sh
[[ $rc -eq 0 ]] || fail "./check.sh must name check.sh (got $rc): $out"
grep -qF 'assertion failed: lib.txt is not good' <<<"$out" || fail "./check.sh was restored away: $out"
for bad in chek.sh /abs/check.sh ../check.sh sub/../../check.sh; do
  rc_of "$script" "$base" --tests "$bad" -- bash check.sh
  [[ $rc -eq 2 ]] || fail "--tests $bad must exit 2 (got $rc): $out"
  grep -qF 'catches the defect' <<<"$out" && fail "--tests $bad was proved: $out"
done
[[ "$(leaks)" -eq 1 ]] || fail "worktree leaked after a refused test path"
ok "./check.sh is accepted; a misspelt, absolute or .. test path exits 2"

# A worktree that cannot be created is a failure of the run, not a usage error.
fixture "$STRICT"
touch "$fx/.git/worktrees"
rc_of "$script" "$base" --tests check.sh -- bash check.sh
[[ $rc -eq 1 ]] || fail "a worktree that cannot be created must exit 1 (got $rc): $out"
ok "a worktree that cannot be created exits 1"

# Uncommitted changes at HEAD are not in the scratch worktree; say so.
fixture "$STRICT"
printf 'edited\n' >> "$fx/lib.txt"
rc_of "$script" "$base" --tests check.sh -- bash check.sh
grep -qF 'uncommitted changes' <<<"$out" || fail "a dirty tree must be named: $out"
ok "uncommitted changes are named on stderr"
