#!/usr/bin/env bash
# Run the repository's suite (`owed.suite` in .agents/policy.json) and, when it
# passes, record the tree it passed on, so `owed.py` stops reporting the suite
# as owed until the next edit.
#
# The checks run in a copy of the checkout built from that tree, under a
# temporary HOME, so a check that writes relative to its script, to
# CLAUDE_PROJECT_DIR or under `~` writes the copy or the temporary home and
# never the checkout or the real home.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
owed="$repo/.agents/hooks/lib/owed.py"
cd "$repo" || exit 1

command="$(python3 "$owed" suite-command)" || exit 1
tree="$(python3 "$owed" tree)" || exit 1

# A scratch folder is named for the suite.sh that made it. A killed run cannot
# remove its own, so each run removes those whose maker is gone, and leaves a
# concurrent run's alone.
tmp="$(cd "${TMPDIR:-/tmp}" && pwd -P)" || exit 1
for old in "$tmp"/colloid-suite.*; do
  [[ -d "$old" ]] || continue
  maker="${old##*/colloid-suite.}"; maker="${maker%%.*}"
  [[ "$maker" =~ ^[0-9]+$ ]] || continue
  ps -p "$maker" >/dev/null || rm -rf "$old"
done
scratch="$(mktemp -d "$tmp/colloid-suite.$$.XXXXXX")" || exit 1
copy="$scratch/copy"
home="$scratch/home"

# The checks run as a job of their own (`set -m`), which makes them a process
# group in bash 3.2 and later with no `setsid`, which macOS lacks. Every exit
# stops that group before the copy it runs in is removed.
group=""
stop_checks() {
  [[ -n "$group" ]] || return 0
  kill -TERM -- "-$group" 2>/dev/null || return 0
  for _ in $(seq 50); do
    kill -0 -- "-$group" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -KILL -- "-$group" 2>/dev/null
  return 0
}
trap 'stop_checks; rm -rf "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# The copy shares the checkout's objects, where `owed.py tree` wrote the tree's.
# Its working files are the tree itself, so every uncommitted edit, untracked
# unignored file, deletion and symlink is there and no ignored file is; its
# index is the checkout's, so `git status` reads as it does there; with no
# remote, no git call in the copy reaches the checkout.
git clone -q --shared --no-checkout "$repo" "$copy" || exit 1
git -C "$copy" read-tree -u --reset "$tree" || exit 1
git -C "$copy" read-tree --empty || exit 1
git ls-files --stage -z | git -C "$copy" update-index -z --index-info || exit 1
git -C "$copy" remote remove origin || exit 1

# Tool caches, uv's Python installs and Playwright's browsers keep their real
# folders, read before HOME changes, so nothing downloads and no browser layer
# skips. Each tool honours its own variable when one is inherited.
if command -v uv >/dev/null; then
  UV_CACHE_DIR="$(uv cache dir)" || { echo "suite.sh: uv cache dir failed" >&2; exit 1; }
  UV_PYTHON_INSTALL_DIR="$(uv python dir)" || { echo "suite.sh: uv python dir failed" >&2; exit 1; }
  export UV_CACHE_DIR UV_PYTHON_INSTALL_DIR
fi
if command -v npm >/dev/null; then
  npm_config_cache="$(npm config get cache)" || { echo "suite.sh: npm config get cache failed" >&2; exit 1; }
  export npm_config_cache
fi
if [[ -z "${PLAYWRIGHT_BROWSERS_PATH:-}" ]]; then
  case "$(uname -s)" in
    Darwin) PLAYWRIGHT_BROWSERS_PATH="$HOME/Library/Caches/ms-playwright" ;;
    *) PLAYWRIGHT_BROWSERS_PATH="${XDG_CACHE_HOME:-$HOME/.cache}/ms-playwright" ;;
  esac
fi
export PLAYWRIGHT_BROWSERS_PATH

# The temporary home holds only a git identity. No system, global or inherited
# git setting reaches a check, so no credential helper does, and no GitHub
# token is set.
mkdir -p "$home/.claude" "$home/.codex"
printf '[user]\n\tname = colloid suite\n\temail = suite@colloid.invalid\n' > "$home/.gitconfig"
echo "suite.sh: checks run in $copy"

# The checkout's git settings a check could break and no live tool writes:
# GitLens and `git push -u` write branch settings while a suite runs.
settings() {
  local out status=0
  out="$(git -C "$repo" config --local --get-regexp '^(core|extensions)\.')" || status=$?
  case "$status" in
    0) printf '%s\n' "$out" ;;
    1) ;;  # none set
    *) echo "suite.sh: git cannot read $repo's settings" >&2; return 1 ;;
  esac
}
value_in() {  # <settings> <key>: the key's values, or "absent"
  local found
  found="$(awk -v k="$2" '$1 == k { sub(/^[^ ]+ ?/, ""); print }' <<<"$1")"
  printf '%s' "${found:-absent}"
}
settings_before="$(settings)" || exit 1

set -m
(
  cd "$copy" || exit 1
  unset GH_TOKEN GITHUB_TOKEN GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT \
    XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_STATE_HOME
  export HOME="$home" CLAUDE_CONFIG_DIR="$home/.claude" CODEX_HOME="$home/.codex" \
    CLAUDE_PROJECT_DIR="$copy" GIT_CONFIG_NOSYSTEM=1
  exec bash -c "$command"
) </dev/null &
group=$!
set +m
wait "$group"
status=$?
stop_checks

escaped=0
settings_after="$(settings)" || exit 1
if [[ "$settings_before" != "$settings_after" ]]; then
  keys="$(diff <(printf '%s\n' "$settings_before") <(printf '%s\n' "$settings_after") \
    | sed -n 's/^[<>] \([^ ]*\).*/\1/p' | sort -u)"
  for key in $keys; do
    printf 'suite.sh: a check changed the checkout'\''s git setting %s: %s -> %s\n' \
      "$key" "$(value_in "$settings_before" "$key")" "$(value_in "$settings_after" "$key")" >&2
  done
  escaped=1
fi
# A check that writes a tracked or unignored file writes the copy, which is
# then removed unseen; the copy must still hold the tree the run recorded.
copy_tree="$(python3 "$owed" tree --repo "$copy")" || exit 1
if [[ "$copy_tree" != "$tree" ]]; then
  git -C "$copy" diff --name-only --no-renames "$tree" "$copy_tree" \
    | sed 's/^/suite.sh: a check wrote the copy'\''s file /' >&2
  escaped=1
fi

if (( status != 0 )); then exit "$status"; fi
if (( escaped )); then echo "suite.sh: no pass recorded" >&2; exit 1; fi
python3 "$owed" record-pass "$tree"
