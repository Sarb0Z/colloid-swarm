#!/usr/bin/env bash
# Run the repository's suite (`owed.suite` in .agents/policy.json) and, when it
# passes, record the tree it passed on, so `owed.py` stops reporting the suite
# as owed until the next edit. Owed means owed before the next push: the suite
# runs once on the tree about to be pushed, not after each edit
# (.agents/playbooks/commits.md).
#
# The checks run in a copy of the checkout built from that tree, under a
# temporary HOME, so a check that writes relative to its own script or under
# `~` writes the copy or the temporary home and never the checkout or the real
# home. A check that changes the checkout's core or extensions git settings, or
# writes a tracked or unignored file of the copy, fails the run.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
owed="$repo/.agents/hooks/lib/owed.py"
cd "$repo" || exit 1

command="$(python3 "$owed" suite-command)" || exit 1

# A scratch folder is named for the suite.sh that made it. A killed run cannot
# remove its own, so each run removes those whose maker is gone, and leaves a
# concurrent run's alone. Only the kernel's "no such process" counts as gone:
# a lookup that fails any other way, such as a sandbox refusing it, keeps the
# folder.
gone() {
  local answer
  answer="$(LC_ALL=C; kill -0 "$1" 2>&1)" && return 1
  [[ "$answer" == *"No such process"* ]]
}
tmp="$(cd "${TMPDIR:-/tmp}" && pwd -P)" || exit 1
for old in "$tmp"/colloid-suite.*; do
  [[ -d "$old" ]] || continue
  maker="${old##*/colloid-suite.}"; maker="${maker%%.*}"
  [[ "$maker" =~ ^[0-9]+$ ]] || continue
  if gone "$maker"; then rm -rf "$old"; fi
done
scratch="$(mktemp -d "$tmp/colloid-suite.$$.XXXXXX")" || exit 1
copy="$scratch/copy"
home="$scratch/home"

# The checks run in a session of their own, started by python3's os.setsid()
# because macOS ships no setsid command: their process group is stopped on
# every exit before the copy they run in is removed, and with no controlling
# terminal a check that opens /dev/tty fails instead of stopping the run. A
# watchdog in that group kills it once this script is gone, so a SIGKILL to
# this script's own group does not leave the checks running.
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

# HEAD, the index and the tree are read together: when another session commits
# or stages while they are read, they are read again.
for attempt in 1 2 3; do
  head="$(git rev-parse -q --verify HEAD)" || head=""
  git ls-files --stage -z > "$scratch/index" || exit 1
  tree="$(python3 "$owed" tree)" || exit 1
  if [[ "$(git rev-parse -q --verify HEAD)" == "$head" ]] \
    && git ls-files --stage -z | cmp -s - "$scratch/index"; then
    break
  fi
  if (( attempt == 3 )); then
    echo "suite.sh: HEAD or the index changed each time the tree was read; run it again" >&2
    exit 1
  fi
done

# The copy shares the checkout's objects, where `owed.py tree` wrote the tree's.
# Its branch is the commit read above and its working files are the tree, so
# every uncommitted edit, untracked unignored file, deletion and symlink is
# there and no ignored file is; its index and info/exclude are the checkout's,
# so `git status` reads as it does there; with no remote, no git call in the
# copy reaches the checkout.
git clone -q --shared --no-checkout "$repo" "$copy" || exit 1
if [[ -n "$head" ]]; then git -C "$copy" update-ref HEAD "$head" || exit 1; fi
git -C "$copy" read-tree -u --reset "$tree" || exit 1
git -C "$copy" read-tree --empty || exit 1
git -C "$copy" update-index -z --index-info < "$scratch/index" || exit 1
git -C "$copy" remote remove origin || exit 1
exclude="$(git rev-parse --git-path info/exclude)" || exit 1
if [[ -f "$exclude" ]]; then
  mkdir -p "$copy/.git/info" && cp "$exclude" "$copy/.git/info/exclude" || exit 1
fi

# The checks' environment, which CI gives its steps too (check-env.sh): a
# temporary home holding only a git identity, no outside git setting or GitHub
# token, and the real tool caches.
environment="$("$repo/.agents/check-env.sh" print "$home")" || exit 1
echo "suite.sh: checks run in $copy"

# The checkout's git settings a check could break and no live tool writes:
# GitLens and `git push -u` write branch settings while a suite runs. Included
# files count, and so does the worktree level once extensions.worktreeConfig
# is on.
read_scope() {  # <git config scope option>
  local out status=0
  out="$(git -C "$repo" config "$1" --includes --get-regexp '^(core|extensions)\.')" || status=$?
  case "$status" in
    0) printf '%s\n' "$out" ;;
    1) ;;  # none set
    *) echo "suite.sh: git cannot read $repo's settings" >&2; return 1 ;;
  esac
}
settings() {
  read_scope --local || return 1
  if [[ "$(git -C "$repo" config --local --includes --bool extensions.worktreeConfig)" == true ]]; then
    read_scope --worktree | sed 's/^/worktree:/'
  fi
}
value_in() {  # <settings> <key>: the key's values, or "absent"
  local found
  found="$(awk -v k="$2" '$1 == k { sub(/^[^ ]+ ?/, ""); print }' <<<"$1")"
  printf '%s' "${found:-absent}"
}
settings_before="$(settings)" || exit 1

# The session's first process: the watchdog, then the suite command. Its PID
# names the session's process group, which the watchdog kills by that number,
# so a leader that did not get its own group kills no one else's.
leader="$(cat <<'SH'
( while kill -0 "$1" 2>/dev/null; do sleep 0.5; done; kill -KILL -- "-$$" ) >/dev/null 2>&1 &
exec bash -c "$2"
SH
)"
(
  cd "$copy" || exit 1
  while IFS= read -r setting; do
    case "$setting" in
      "unset "*) unset "${setting#unset }" ;;
      *) export "$setting" ;;
    esac
  done <<<"$environment"
  # bash starts a background command with interrupts ignored, and a check
  # inherits that through exec; the leader restores the default first.
  exec python3 -c 'import os, signal, sys
for name in ("SIGINT", "SIGQUIT"):
    signal.signal(getattr(signal, name), signal.SIG_DFL)
os.setsid()
os.execvp(sys.argv[1], sys.argv[1:])' \
    bash -c "$leader" watchdog "$$" "$command"
) </dev/null &
group=$!
wait "$group"
status=$?
stop_checks
group=""

escaped=0
settings_after="$(settings)" || exit 1
# A sparse-cone lane turns extensions.worktreeConfig on in the shared
# configuration (workloop_git.py's worktree_add); that is not a check's doing.
if [[ "$(value_in "$settings_before" extensions.worktreeconfig)" == absent \
  && "$(value_in "$settings_after" extensions.worktreeconfig)" == true ]]; then
  settings_after="$(grep -v '^extensions\.worktreeconfig ' <<<"$settings_after" || true)"
fi
if [[ "$settings_before" != "$settings_after" ]]; then
  keys="$(diff <(printf '%s\n' "$settings_before") <(printf '%s\n' "$settings_after") \
    | sed -n 's/^[<>] \([^ ]*\).*/\1/p' | sort -u)"
  for key in $keys; do
    printf 'suite.sh: a check changed the checkout'\''s git setting %s: %s -> %s\n' \
      "$key" "$(value_in "$settings_before" "$key")" "$(value_in "$settings_after" "$key")" >&2
  done
  escaped=1
fi
if [[ ! -d "$copy/.git" ]]; then
  echo "suite.sh: the copy $copy was removed during the run; no pass recorded" >&2
  exit 1
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
