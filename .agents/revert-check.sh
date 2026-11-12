#!/usr/bin/env bash
# Prove that a fix's test catches the defect.
#
#   .agents/revert-check.sh <base> --tests <path>... -- <command> [args...]
#
# Run from inside the repository whose fix is committed at HEAD; `<base>` is the
# commit before the fix. In one provisioned scratch worktree at HEAD:
#   1. the command runs and must pass. This proves the environment works, so a
#      missing dependency or a missing test file never counts as the failure.
#   2. every file that changed between <base> and HEAD, except the named test
#      paths (a file, or a folder holding them), goes back to its content at
#      <base>, and the command runs again. It must fail.
# Exit 0 when step 2 fails (the test catches the defect). Exit 1 when step 1
# fails (environment, not a verdict on the test) or when step 2 passes (the test
# does not catch the defect), or when the scratch worktree cannot be made. Exit 2
# for a usage error, including a test path that is absolute, holds `..`, or
# matches no file at HEAD. Exit 129, 130 or 143 on HUP, INT or TERM.
#
# The scratch worktree is removed and the command's process group stopped on
# every path, interrupts included. Bash 3.2 (stock macOS).
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { echo "usage: revert-check.sh <base> --tests <path>... -- <command> [args...]" >&2; exit 2; }

[[ $# -ge 1 ]] || usage
base="$1"; shift
[[ "${1:-}" == "--tests" ]] || usage
shift
tests=()
while [[ $# -gt 0 && "$1" != "--" ]]; do tests+=("$1"); shift; done
[[ "${1:-}" == "--" ]] && shift
cmd=("$@")
[[ ${#tests[@]} -gt 0 && ${#cmd[@]} -gt 0 ]] || usage

root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "revert-check: not inside a git repository" >&2; exit 2; }
git -C "$root" rev-parse --verify --quiet "$base^{commit}" >/dev/null || { echo "revert-check: base '$base' is not a commit" >&2; exit 2; }

# A test path is read from the repository root. Anything that would not match a
# restored file by its text, or that matches no file at HEAD, is refused: a
# path that silently matched nothing would let the restore delete the test and
# the missing-file failure pose as proof.
normalized=()
for path in "${tests[@]}"; do
  while [[ "$path" == ./* ]]; do path="${path#./}"; done
  path="${path%/}"
  case "/$path/" in
    //*|*/../*) echo "revert-check: --tests path '$path' must be relative to the repository root, with no '..'" >&2; exit 2 ;;
  esac
  [[ -n "$path" ]] || usage
  [[ -n "$(git -C "$root" ls-tree -r --name-only HEAD -- "$path")" ]] || {
    echo "revert-check: --tests path '$path' matches no file at HEAD" >&2; exit 2; }
  normalized+=("$path")
done
tests=("${normalized[@]}")

if [[ -n "$(git -C "$root" status --porcelain)" ]]; then
  echo "revert-check: warning: uncommitted changes in $root are not in the scratch worktree, which is at HEAD" >&2
fi

scratch="$(mktemp -d)"
wt="$scratch/wt"
running=""
set -m  # each command runs in its own process group, so cleanup can stop all of it

cleanup() {
  trap - EXIT INT TERM HUP
  if [[ -n "$running" ]]; then
    kill -TERM -- "-$running" 2>/dev/null
    sleep 0.2
    kill -KILL -- "-$running" 2>/dev/null
  fi
  git -C "$root" worktree remove --force "$wt" >/dev/null 2>&1
  git -C "$root" worktree prune >/dev/null 2>&1
  rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

git -C "$root" worktree add --detach "$wt" HEAD >/dev/null 2>&1 || { echo "revert-check: cannot create a scratch worktree" >&2; exit 1; }

run_command() {  # <log>: the command's exit status
  ( cd "$wt" && exec "${cmd[@]}" ) >"$1" 2>&1 &
  running=$!
  wait "$running"
  local status=$?
  running=""
  return $status
}

tail_of() { tail -n 20 "$1" | sed 's/^/    /'; }

if ! provision_out="$(PROVISION_SHARE_FROM="$root" "$here/provision.sh" "$wt" 2>&1)"; then
  echo "revert-check: the environment cannot be provisioned in the scratch worktree; the command cannot run at the fix, so the test was not judged:" >&2
  printf '%s\n' "$provision_out" | sed 's/^/    /' >&2
  exit 1
fi

if ! run_command "$scratch/fixed.log"; then
  echo "revert-check: the command fails at the fix, so either the environment or the fix is wrong (the command cannot run at the fix); the test was not judged. The last lines below say which; fix that and rerun:" >&2
  tail_of "$scratch/fixed.log" >&2
  exit 1
fi

in_tests() {  # <file>
  local file="$1" path
  for path in "${tests[@]}"; do
    path="${path%/}"
    [[ "$file" == "$path" || "$file" == "$path"/* ]] && return 0
  done
  return 1
}

restored=0
while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  in_tests "$file" && continue
  if git -C "$wt" cat-file -e "$base:$file" 2>/dev/null; then
    git -C "$wt" checkout "$base" -- "$file" || { echo "revert-check: cannot restore $file to $base" >&2; exit 2; }
  else
    rm -rf "${wt:?}/$file"
  fi
  restored=$((restored + 1))
done < <(git -C "$wt" -c core.quotepath=off diff --name-only --no-renames "$base" HEAD)

for path in "${tests[@]}"; do
  [[ -e "$wt/$path" ]] || { echo "revert-check: the restore removed the named test '$path'; the reverted run proves nothing" >&2; exit 1; }
done

if run_command "$scratch/reverted.log"; then
  echo "revert-check: FAIL: the command still passes with $restored changed file(s) restored to $base: the test does not catch the defect. Last lines:" >&2
  tail_of "$scratch/reverted.log" >&2
  exit 1
fi

echo "revert-check: pass: the command passes at the fix and fails with $restored changed file(s) restored to $base; the test catches the defect if the failure below is the test's own assertion; confirm that from the reverted run's last lines:"
tail_of "$scratch/reverted.log"
exit 0
