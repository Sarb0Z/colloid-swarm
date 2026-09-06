#!/usr/bin/env bash
# Bring one checkout's dependencies to the state its lockfiles describe.
#
#   .agents/provision.sh <dir>          install, or confirm current
#   .agents/provision.sh --hash <dir>   print the lockfile hash and stop
#
# A linked worktree is a fresh checkout with no node_modules, .venv, or
# vendor tree, so a writer isolated in one cannot run its tests until
# something installs. This is that something, and it is the only thing
# in the scaffold that installs: the SubagentStart hook calls it for a
# subagent that starts inside a worktree, and workloop.py calls it for
# each lane and for the integration tree.
#
# THE RULES, each chosen because a harness that ships them was read:
#   * Install only from a lockfile, and only in its frozen form. An
#     unlocked manifest is named and skipped; the environment must be
#     what the branch declares, never what a resolver picks today.
#   * Hash the lockfiles and remember the hash inside the checkout's own
#     git dir. Same hash next time → nothing runs. A branch that only
#     changes source pays nothing; one that changes a lockfile reinstalls.
#   * Lifecycle scripts stay off unless PROVISION_ALLOW_SCRIPTS=1. This
#     script runs from a hook and from the controller, neither of which
#     passes a PreToolUse guard, so an install here executes whatever a
#     lockfile names with no prompt. Native modules that need a build
#     step are the tradeoff, and the config key that flips it says so.
#   * A failed or expired install leaves no memo, so the next caller
#     tries again rather than trusting a half-built tree, and the block
#     it prints says what kind of failure this is. Agents read a red test
#     as a code defect; a missing module is not one.
#   * One install per checkout at a time. Two isolated subagents starting
#     in the same worktree would otherwise race inside node_modules.
#
# Environment:
#   PROVISION_ALLOW_SCRIPTS=1   run package lifecycle scripts
#   PROVISION_DEADLINE=<secs>   kill an install past this (default 540,
#                               under the host's 600 s hook budget, so the
#                               failure is ours to report, not the host's
#                               to discard)
#
# Exit 0 with a `provision:` line on success or when nothing was needed;
# exit 1 with the reason on stderr otherwise. Bash 3.2 (stock macOS).

set -uo pipefail

FAILURE_SENTENCE='This is an environment failure, not a code failure. Do not edit source to satisfy it.'

usage() { echo "usage: provision.sh [--hash] <dir>" >&2; exit 1; }
hash_only=0
if [[ "${1:-}" == "--hash" ]]; then hash_only=1; shift; fi
[[ $# -eq 1 ]] || usage
[[ -d "$1" ]] || { echo "provision: not a directory: $1" >&2; exit 1; }
dir="$(cd "$1" && pwd -P)"

deadline="${PROVISION_DEADLINE:-540}"
allow_scripts="${PROVISION_ALLOW_SCRIPTS:-0}"
export CI=1

# Resolve the memo location inside the target, never the caller's cwd:
# `rev-parse --git-dir` prints a path relative to -C, so a caller elsewhere
# would otherwise land every checkout's memo in its own repository.
gitdir="$(git -C "$dir" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || {
  echo "provision: not a git checkout: $dir" >&2; exit 1; }
case "$gitdir" in
  /*) ;;
  *) echo "provision: git dir did not resolve to an absolute path: $gitdir" >&2; exit 1 ;;
esac
memo="$gitdir/colloid-provisioned"
lockdir="$gitdir/colloid-provision.lock"

# --- discover lockfiles -----------------------------------------------------
# One line per lockfile: "<manager>\t<path>". Per ecosystem, a lockfile at
# the root wins and nested ones are ignored (a workspace root installs its
# packages); with no root lockfile, every nested one runs.
js_root=""
for name in pnpm-lock.yaml bun.lock bun.lockb yarn.lock package-lock.json; do
  [[ -f "$dir/$name" ]] && { js_root="$name"; break; }
done

manager_for() {
  case "$1" in
    pnpm-lock.yaml) echo pnpm ;;
    bun.lock|bun.lockb) echo bun ;;
    yarn.lock) echo yarn ;;
    package-lock.json) echo npm ;;
    uv.lock) echo uv ;;
    poetry.lock) echo poetry ;;
    Gemfile.lock) echo bundle ;;
    Cargo.lock) echo cargo ;;
    go.sum) echo go ;;
  esac
}

nested() {
  find "$dir" -name "$1" -type f \
    -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/vendor/*' \
    -not -path '*/.venv/*' -not -path '*/target/*' 2>/dev/null | LC_ALL=C sort
}

lockfiles=""
add() { lockfiles="${lockfiles}${lockfiles:+
}$1	$2"; }

if [[ -n "$js_root" ]]; then
  add "$(manager_for "$js_root")" "$dir/$js_root"
else
  for name in pnpm-lock.yaml bun.lock bun.lockb yarn.lock package-lock.json; do
    while IFS= read -r path; do
      [[ -n "$path" ]] && add "$(manager_for "$name")" "$path"
    done <<<"$(nested "$name")"
  done
fi
for name in uv.lock poetry.lock Gemfile.lock Cargo.lock go.sum; do
  if [[ -f "$dir/$name" ]]; then
    add "$(manager_for "$name")" "$dir/$name"
  else
    while IFS= read -r path; do
      [[ -n "$path" ]] && add "$(manager_for "$name")" "$path"
    done <<<"$(nested "$name")"
  fi
done

if [[ -z "$lockfiles" ]]; then
  if (( hash_only )); then echo none; exit 0; fi
  unlocked=""
  for name in package.json pyproject.toml requirements.txt Gemfile Cargo.toml go.mod; do
    [[ -f "$dir/$name" ]] && unlocked="${unlocked}${unlocked:+, }$name"
  done
  if [[ -n "$unlocked" ]]; then
    echo "provision: no lockfile in $dir; skipped unlocked manifests: $unlocked"
  else
    echo "provision: nothing to install in $dir"
  fi
  exit 0
fi

# --- hash and memo ----------------------------------------------------------
hash_lockfiles() {
  local paths
  paths="$(printf '%s\n' "$lockfiles" | cut -f2)"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s\n' "$paths" | tr '\n' '\0' | xargs -0 cat | shasum -a 256 | cut -c1-64
  else
    printf '%s\n' "$paths" | tr '\n' '\0' | xargs -0 cat | sha256sum | cut -c1-64
  fi
}
hash="$(hash_lockfiles)"
if (( hash_only )); then echo "$hash"; exit 0; fi

current() { [[ -f "$memo" ]] && [[ "$(cat "$memo")" == "$hash" ]]; }
if current; then
  echo "provision: current $hash"
  exit 0
fi

# --- one install at a time per checkout -------------------------------------
# mkdir is the atomic test-and-set that stock macOS has; flock is not there.
# The holder writes its PID inside, so a lock left by a killed install is
# recognised and taken over rather than waited on until the deadline.
started=$(date +%s)
holder_alive() {
  local pid
  pid="$(cat "$lockdir/pid" 2>/dev/null)" || return 1
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}
until mkdir "$lockdir" 2>/dev/null; do
  if ! holder_alive; then
    # No live holder: a crashed install, or one that has not yet written
    # its PID. Give the second case a moment before treating it as the first.
    sleep 1
    holder_alive || rm -rf "$lockdir"
    continue
  fi
  if (( $(date +%s) - started >= deadline )); then
    echo "provision: another install has held $lockdir for ${deadline}s; giving up" >&2
    exit 1
  fi
  sleep 1
done
printf '%s' "$$" >"$lockdir/pid"
trap 'rm -rf "$lockdir" 2>/dev/null' EXIT
trap 'exit 130' INT TERM HUP
if current; then
  echo "provision: current $hash"
  exit 0
fi
rm -f "$memo"

# --- run each install under the deadline ------------------------------------
run_with_deadline() {
  # $1 = working dir, $2 = log path, rest = command. Returns the command's
  # exit code, or 124 when the deadline killed it.
  local cwd="$1" log="$2"; shift 2
  ( cd "$cwd" && exec "$@" ) >"$log" 2>&1 &
  local pid=$!
  local budget=$(( deadline - ($(date +%s) - started) ))
  (( budget < 1 )) && budget=1
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= budget )); then
      kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1; waited=$((waited + 1))
  done
  wait "$pid"
}

yarn_is_classic() {
  local v
  v="$(yarn --version 2>/dev/null)" || return 1
  [[ "$v" == 1.* ]]
}

# Emits one argv per line for the manager, honoring the scripts switch.
install_argv() {
  local manager="$1" cwd="$2"
  case "$manager" in
    npm)    printf '%s\n' npm ci; (( allow_scripts )) || printf '%s\n' --ignore-scripts ;;
    pnpm)   printf '%s\n' pnpm install --frozen-lockfile; (( allow_scripts )) || printf '%s\n' --ignore-scripts ;;
    bun)    printf '%s\n' bun install --frozen-lockfile; (( allow_scripts )) || printf '%s\n' --ignore-scripts ;;
    yarn)   if ( cd "$cwd" && yarn_is_classic ); then
              printf '%s\n' yarn install --frozen-lockfile; (( allow_scripts )) || printf '%s\n' --ignore-scripts
            else
              printf '%s\n' yarn install --immutable; (( allow_scripts )) || printf '%s\n' --mode=skip-build
            fi ;;
    uv)     printf '%s\n' uv sync --frozen ;;
    poetry) printf '%s\n' poetry install ;;
    bundle) printf '%s\n' bundle install ;;
    cargo)  printf '%s\n' cargo fetch ;;
    go)     printf '%s\n' go mod download ;;
  esac
}

report_failure() {
  # $1 = manager, $2 = command text, $3 = log, $4 = exit code
  {
    if [[ "$4" == 124 ]]; then
      echo "provision: $1 did not finish within ${deadline}s: $2"
    elif [[ "$4" == 127 ]]; then
      echo "provision: $1 is not installed on this machine: $2"
    else
      echo "provision: $1 failed (exit $4): $2"
    fi
    [[ -s "$3" ]] && { echo "--- last 20 lines ---"; tail -n 20 "$3"; }
    echo "$FAILURE_SENTENCE"
  } >&2
}

installed=""
while IFS=$'\t' read -r manager path; do
  [[ -n "$manager" ]] || continue
  cwd="$(dirname "$path")"
  command -v "$manager" >/dev/null 2>&1 || {
    report_failure "$manager" "$manager (not on PATH)" /dev/null 127; exit 1; }
  argv=()
  while IFS= read -r word; do argv+=("$word"); done <<<"$(install_argv "$manager" "$cwd")"
  log="$(mktemp -t provision-log)"
  run_with_deadline "$cwd" "$log" "${argv[@]}"; rc=$?
  if [[ $rc -ne 0 ]]; then
    report_failure "$manager" "${argv[*]} (in $cwd)" "$log" "$rc"
    rm -f "$log"
    exit 1
  fi
  rm -f "$log"
  rel="${cwd#"$dir"}"; rel="${rel#/}"
  installed="${installed}${installed:+, }$manager:${rel:-.}"
done <<<"$lockfiles"

printf '%s' "$hash" >"$memo"
echo "provision: installed $installed ($hash)"
