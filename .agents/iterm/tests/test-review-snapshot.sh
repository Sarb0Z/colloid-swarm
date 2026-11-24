#!/usr/bin/env bash
# Tests for review-snapshot over fixture repositories: what it prints, what the
# snapshot holds, that the checkout is left as it was, and the record the
# session's end reads (written by the repository's real worktree_records.py).
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR CLAUDE_PID
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

IT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
SNAP=$IT/bin/review-snapshot
LIB=$IT/../hooks/lib
T=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$T"' EXIT
fails=0

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fails=$((fails + 1)); }
eq() { # name expected actual
  if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi
}
field() { sed -n "s/^$1: //p" <<<"$out"; }
nl=$'\n'
# The record stamps the session's process: the first ancestor no shell or
# interpreter carries. perl stands in for a Claude session that has exited by
# the time the hourly check runs.
session() { perl -e 'exit(system(@ARGV) >> 8)' "$@"; }

# --- upstream ahead, with uncommitted, staged, deleted, untracked and ignored files
git init -q --bare -b main "$T/remote.git" 2>/dev/null
R=$T/up
git init -q -b main "$R" 2>/dev/null
mkdir -p "$R/.agents/hooks/lib"
cp "$LIB"/*.py "$R/.agents/hooks/lib/"
printf '.agents/worktrees/\n*.log\n' >"$R/.gitignore"
printf 'one\n' >"$R/a.txt"
printf 'gone soon\n' >"$R/del.txt"
git -C "$R" add -A
git -C "$R" commit -q -m one
c1=$(git -C "$R" rev-parse HEAD)
git -C "$R" remote add origin "$T/remote.git"
git -C "$R" push -q -u origin main 2>/dev/null
printf 'two\n' >"$R/b.txt"
git -C "$R" add b.txt
git -C "$R" commit -q -m two
c2=$(git -C "$R" rev-parse HEAD)

printf 'one, edited\n' >"$R/a.txt"
printf 'staged\n' >"$R/staged-new.txt"
git -C "$R" add staged-new.txt
rm "$R/del.txt"
printf 'untracked\n' >"$R/new.txt"
mkdir "$R/sub"
printf 'deep\n' >"$R/sub/u.txt"
printf 'noise\n' >"$R/ignored.log"

status_before=$(git -C "$R" status --porcelain)
# A tracked file with a new time and the same text: a plain `git status` would
# rewrite the index to note it.
touch -t 202001010000 "$R/b.txt"
index_before=$(shasum "$R/.git/index")
refs_before=$(git -C "$R" for-each-ref)
out=$(cd "$R" && CLAUDE_CODE_SESSION_ID=sess-1 session "$SNAP" 2>"$T/err"); rc=$?
index_after=$(shasum "$R/.git/index")
eq "uncommitted work: rc" 0 "$rc"
S=$(field snapshot)
U=$(field uncommitted)
eq "uncommitted work: the lines printed" \
  "base: $c1${nl}tip: $c2${nl}committed: no${nl}uncommitted: $U${nl}snapshot: $S${nl}registered: yes" "$out"
[[ $S == "$R"/.agents/worktrees/pane-review-?* && -d $S ]] && ok "snapshot under .agents/worktrees/pane-review-<id>" || bad "snapshot path: [$S]"
eq "snapshot HEAD is the uncommitted commit" "$U" "$(git -C "$S" rev-parse HEAD)"
eq "the uncommitted commit sits on the tip" "$c2" "$(git -C "$S" rev-parse HEAD^)"
git -C "$S" symbolic-ref -q HEAD >/dev/null && bad "snapshot is on a branch" || ok "snapshot is detached"
eq "snapshot holds the edit, the staged file, the untracked files and the tip's file; not the deleted or ignored ones" \
  ".gitignore${nl}a.txt${nl}b.txt${nl}new.txt${nl}staged-new.txt${nl}sub/u.txt" \
  "$(git -C "$S" ls-files | grep -v '^\.agents/')"
eq "snapshot: the edited file's text" "one, edited" "$(cat "$S/a.txt")"
eq "snapshot: the untracked file's text" "deep" "$(cat "$S/sub/u.txt")"
[[ ! -e $S/del.txt && ! -e $S/ignored.log ]] && ok "snapshot: no deleted file, no ignored file" || bad "snapshot holds del.txt or ignored.log"
eq "snapshot: nothing uncommitted in it" "" "$(git -C "$S" status --porcelain)"
eq "checkout: git status unchanged" "$status_before" "$(git -C "$R" status --porcelain)"
eq "checkout: the index file unchanged" "$index_before" "$index_after"
eq "checkout: no branch or ref added" "$refs_before" "$(git -C "$R" for-each-ref)"
eq "the record the hourly check reads names the snapshot's commit" "worktree $S review-snapshot $U" \
  "$(python3 -c 'import json,sys; [print(e["type"], e["path"], e["by"], e["head"]) for e in map(json.loads, open(sys.argv[1]))]' "$R/.agents/worktrees/.records/sess-1.jsonl" 2>&1)"

# An edit after the snapshot stays out of it.
printf 'later\n' >"$R/a.txt"
eq "a later edit does not reach the snapshot" "one, edited" "$(cat "$S/a.txt")"

# A second snapshot gets its own folder.
out=$(cd "$R" && CLAUDE_CODE_SESSION_ID=sess-1 session "$SNAP" 2>/dev/null)
[[ -n $(field snapshot) && $(field snapshot) != "$S" ]] && ok "second snapshot: its own folder" || bad "second snapshot: [$(field snapshot)]"
S2=$(field snapshot)

# Three more snapshots, each holding work of its own: a reviewer writes a file
# in one, commits in another and resets back to the snapshot's commit, and
# moves the third to a commit of its own.
out=$(cd "$R" && CLAUDE_CODE_SESSION_ID=sess-1 session "$SNAP" 2>/dev/null)
S3=$(field snapshot)
printf 'a reviewer note\n' >"$S3/note.txt"
out=$(cd "$R" && CLAUDE_CODE_SESSION_ID=sess-1 session "$SNAP" 2>/dev/null)
S4=$(field snapshot)
printf 'tried\n' >"$S4/try.txt"
git -C "$S4" add try.txt
git -C "$S4" commit -q -m tried
git -C "$S4" reset -q --hard HEAD^
out=$(cd "$R" && CLAUDE_CODE_SESSION_ID=sess-1 session "$SNAP" 2>/dev/null)
S5=$(field snapshot)
git -C "$S5" checkout -q --detach "$(git -C "$S5" commit-tree 'HEAD^{tree}' -p HEAD -m moved)"

# The session ends as session-end.sh marks it, and another session's hourly
# check removes the two untouched snapshots unasked and saves nothing: each is
# a copy of work the checkout holds. Each one holding work is put to the operator.
python3 -B "$R/.agents/hooks/lib/worktree_sweep.py" end "$R" sess-1 prompt_input_exit
checked=$(python3 -B "$R/.agents/hooks/lib/worktree_sweep.py" check "$R" sess-2 "$IT/../workloop.py" 2>&1)
[[ ! -e $S && -n $S2 && ! -e $S2 ]] && ok "the hourly check removes the untouched snapshots" || bad "the hourly check left a snapshot: $checked"
grep -q "^removed $S: a review snapshot still at the commit it was made at$" <<<"$checked" && ok "the removal says it was a snapshot" || bad "removal line: $checked"
[[ -d $S3 ]] && grep -q "^dead session sess-1 left $S3: .* 1 uncommitted files" <<<"$checked" \
  && ok "a snapshot a reviewer wrote in is kept and put to the operator" || bad "the written snapshot: $checked"
[[ -d $S4 ]] && grep -q "^dead session sess-1 left $S4: .*1 commit(s) only its HEAD log" <<<"$checked" \
  && ok "a snapshot a reviewer committed in, then reset to its commit, is kept and put to the operator" || bad "the reset snapshot: $checked"
[[ -d $S5 ]] && grep -q "^dead session sess-1 left $S5: 2 commits not in main" <<<"$checked" \
  && ok "a snapshot moved off its commit is kept and put to the operator" || bad "the moved snapshot: $checked"
eq "the hourly check: no saved/ branch, no ref added" "$refs_before" "$(git -C "$R" for-each-ref)"
eq "the hourly check: the checkout and the three snapshots holding work are left in git's worktree list" 4 \
  "$(git -C "$R" worktree list | wc -l | tr -d ' ')"
for kept in "$S3" "$S4" "$S5"; do git -C "$R" worktree remove --force "$kept"; done

# After /clear the session's process runs on, and a reviewer cell it started
# may still read the snapshot: it stays, unasked, until that process is gone.
(cd "$R" && CLAUDE_CODE_SESSION_ID=sess-3 exec perl -e 'system(@ARGV); sleep 300' "$SNAP" >"$T/held.out" 2>/dev/null) &
holder=$!
for _ in $(seq 100); do grep -q '^registered:' "$T/held.out" 2>/dev/null && break; sleep 0.1; done
S6=$(sed -n 's/^snapshot: //p' "$T/held.out")
python3 -B "$R/.agents/hooks/lib/worktree_sweep.py" end "$R" sess-3 clear
rm -f "$R/.agents/worktrees/.dead-session-check"
checked=$(python3 -B "$R/.agents/hooks/lib/worktree_sweep.py" check "$R" sess-2 "$IT/../workloop.py" 2>&1)
[[ -n $S6 && -d $S6 && $checked != *"$S6"* ]] && ok "/clear: the snapshot stays, unasked, while the session's process runs" || bad "/clear: [$S6] $checked"
kill "$holder"
wait "$holder" 2>/dev/null
rm -f "$R/.agents/worktrees/.dead-session-check"
checked=$(python3 -B "$R/.agents/hooks/lib/worktree_sweep.py" check "$R" sess-2 "$IT/../workloop.py" 2>&1)
[[ ! -e $S6 ]] && grep -q "^removed $S6: a review snapshot" <<<"$checked" \
  && ok "/clear: once the process is gone the next check removes the snapshot" || bad "/clear, process gone: $checked"

# No session in the environment: nothing is recorded, and the script says so.
out=$(cd "$R" && env -u CLAUDE_CODE_SESSION_ID "$SNAP" 2>/dev/null)
eq "no session id: says only step 5 removes it" \
  "no (CLAUDE_CODE_SESSION_ID is not set, so no Claude session ran this): only step 5 removes the snapshot" "$(field registered)"

# From a linked worktree the snapshot still lands under the main checkout.
git -C "$R" worktree add -q --detach "$T/linked" "$c2" 2>/dev/null
out=$(cd "$T/linked" && CLAUDE_CODE_SESSION_ID=sess-2 "$SNAP" 2>/dev/null)
[[ $(field snapshot) == "$R"/.agents/worktrees/pane-review-?* ]] && ok "linked worktree: snapshot under the main checkout" || bad "linked worktree: [$(field snapshot)]"
eq "linked worktree: nothing uncommitted there" "yes" "$(field committed)"

# --- everything committed ----------------------------------------------------
C=$T/clean
git clone -q "$T/remote.git" "$C" 2>/dev/null
printf 'three\n' >"$C/c.txt"
git -C "$C" add c.txt
git -C "$C" commit -q -m three
c3=$(git -C "$C" rev-parse HEAD)
out=$(cd "$C" && CLAUDE_CODE_SESSION_ID=sess-3 "$SNAP" 2>/dev/null); rc=$?
S=$(field snapshot)
eq "all committed: the lines printed" \
  "base: $c1${nl}tip: $c3${nl}committed: yes${nl}snapshot: $S${nl}registered: yes" "$out"
eq "all committed: snapshot HEAD is the tip" "$c3" "$(git -C "$S" rev-parse HEAD)"

# --- arguments: help prints, anything else is refused; neither makes a snapshot
trees_before=$(git -C "$C" worktree list)
for flag in --help -h; do
  out=$(cd "$C" && CLAUDE_CODE_SESSION_ID=sess-args "$SNAP" "$flag" 2>"$T/err"); rc=$?
  [[ $rc -eq 0 && $out == "usage: review-snapshot (no arguments)"* && ! -s $T/err ]] && ok "$flag: prints the usage" || bad "$flag (rc=$rc): $out $(cat "$T/err")"
done
for args in "--frobnicate" "HEAD" "--help extra"; do
  # shellcheck disable=SC2086
  out=$(cd "$C" && CLAUDE_CODE_SESSION_ID=sess-args "$SNAP" $args 2>"$T/err"); rc=$?
  [[ $rc -ne 0 && -z $out && $(cat "$T/err") == *"it takes no arguments, and got: $args"* ]] && ok "argument [$args]: usage error" || bad "argument [$args] (rc=$rc): $out $(cat "$T/err")"
done
eq "arguments: no worktree made" "$trees_before" "$(git -C "$C" worktree list)"
[[ ! -e $C/.agents/worktrees/.records/sess-args.jsonl ]] && ok "arguments: nothing recorded" || bad "arguments: a record was written"

# --- no upstream: the remote's default branch --------------------------------
git -C "$C" push -q origin main 2>/dev/null
git -C "$C" checkout -q -b topic
printf 'four\n' >"$C/d.txt"
git -C "$C" add d.txt
git -C "$C" commit -q -m four
out=$(cd "$C" && "$SNAP" 2>/dev/null)
eq "no upstream: base is the remote default branch's tip" "$c3" "$(field base)"
eq "no upstream: tip" "$(git -C "$C" rev-parse HEAD)" "$(field tip)"

# --- no remote, through the installed link -----------------------------------
N=$T/solo
git init -q -b main "$N" 2>/dev/null
printf '.agents/worktrees/\n' >"$N/.gitignore"
git -C "$N" add -A
git -C "$N" commit -q -m one
n1=$(git -C "$N" rev-parse HEAD)
# install.sh installs the phone link too, so this home has an account folder,
# and stand-ins take the place of launchctl and signal-cli.
mkdir -p "$T/linkhome/.claude"
printf '#!/bin/sh\n' >"$T/signal-cli"
chmod +x "$T/signal-cli"
HOME=$T/linkhome PHONE_LINK_LAUNCHCTL=$IT/tests/fake-launchctl FAKE_LAUNCHCTL_STATE=$T/launchd \
  PHONE_LINK_SIGNAL_CLI=$T/signal-cli "$IT/install.sh" >/dev/null
out=$(cd "$N" && CLAUDE_CODE_SESSION_ID=sess-5 "$T/linkhome/.local/bin/review-snapshot" 2>/dev/null); rc=$?
eq "no remote, installed link: base is HEAD" "0 $n1 $n1 yes" "$rc $(field base) $(field tip) $(field committed)"
eq "repository without worktree_records.py: says only step 5 removes it" \
  "no (this repository has no .agents/hooks/lib/worktree_records.py): only step 5 removes the snapshot" "$(field registered)"
[[ ! -e $N/.agents/worktrees/.records ]] && ok "repository without worktree_records.py: nothing recorded" || bad "a record was written without worktree_records.py"

# --- refusals ----------------------------------------------------------------
X=$T/unignored
git init -q -b main "$X" 2>/dev/null
git -C "$X" commit -q --allow-empty -m one
out=$(cd "$X" && "$SNAP" 2>"$T/err"); rc=$?
[[ $rc -ne 0 && -z $out && $(cat "$T/err") == *"does not ignore .agents/worktrees/"* ]] && ok "repository that does not ignore .agents/worktrees/: refused with the fix" || bad "unignored (rc=$rc): $out $(cat "$T/err")"
eq "refused: no worktree made" 1 "$(git -C "$X" worktree list | wc -l | tr -d ' ')"
[[ ! -e $X/.agents ]] && ok "refused: no folder made" || bad "refused: $X/.agents exists"

mkdir "$T/plain"
out=$(cd "$T/plain" && "$SNAP" 2>"$T/err"); rc=$?
[[ $rc -ne 0 && -z $out && $(cat "$T/err") == *"is not inside a git checkout"* ]] && ok "outside a repository: refused" || bad "outside a repository (rc=$rc): $(cat "$T/err")"

E=$T/empty
git init -q -b main "$E" 2>/dev/null
out=$(cd "$E" && "$SNAP" 2>"$T/err"); rc=$?
[[ $rc -ne 0 && -z $out && $(cat "$T/err") == *"no commits"* ]] && ok "repository with no commits: pane-base's reason" || bad "no commits (rc=$rc): $(cat "$T/err")"

# Untracked files past the save cap: refused with the size, nothing made. The
# cap is the repository's own SAVE_CAP when its worktree_removal.py gives one.
K=$T/capped
git init -q -b main "$K" 2>/dev/null
mkdir -p "$K/.agents/hooks/lib"
printf '.agents/worktrees/\n' >"$K/.gitignore"
printf 'SAVE_CAP = 10\n' >"$K/.agents/hooks/lib/worktree_removal.py"
printf 'tracked file, larger than the cap\n' >"$K/tracked.txt"
git -C "$K" add -A
git -C "$K" commit -q -m one
printf 'tracked file, edited, larger than the cap\n' >"$K/tracked.txt"
printf '1234567' >"$K/seven.txt"
printf '1234' >"$K/four.txt"
out=$(cd "$K" && "$SNAP" 2>"$T/err"); rc=$?
[[ $rc -ne 0 && -z $out && $(cat "$T/err") == *"hold 11 bytes (0 MB), more than the 10 bytes"* ]] && ok "untracked files past the repository's cap: refused with the size" || bad "past the cap (rc=$rc): $out $(cat "$T/err")"
eq "past the cap: no worktree made" 1 "$(git -C "$K" worktree list | wc -l | tr -d ' ')"
printf '123' >"$K/four.txt"
out=$(cd "$K" && "$SNAP" 2>/dev/null); rc=$?
eq "untracked files at the cap, a larger tracked edit beside them: snapshot made" "0 no" "$rc $(field committed)"

# Without worktree_removal.py the cap is 200 MB. The file is sparse: its size counts, its blocks do not exist.
dd if=/dev/zero of="$N/big.bin" bs=1 count=0 seek=210763776 2>/dev/null
out=$(cd "$N" && "$SNAP" 2>"$T/err"); rc=$?
[[ $rc -ne 0 && -z $out && $(cat "$T/err") == *"hold 210763776 bytes (201 MB), more than the 209715200 bytes (200 MB)"* ]] && ok "201 MB untracked without worktree_removal.py: refused at 200 MB" || bad "201 MB (rc=$rc): $out $(cat "$T/err")"
rm "$N/big.bin"

# A worktree_records.py that fails: the snapshot stands, and the script says who removes it.
B=$T/broken
git init -q -b main "$B" 2>/dev/null
mkdir -p "$B/.agents/hooks/lib"
printf '.agents/worktrees/\n' >"$B/.gitignore"
printf 'raise RuntimeError("records are broken")\n' >"$B/.agents/hooks/lib/worktree_records.py"
git -C "$B" add -A
git -C "$B" commit -q -m one
out=$(cd "$B" && CLAUDE_CODE_SESSION_ID=sess-4 "$SNAP" 2>"$T/err"); rc=$?
[[ $rc -eq 0 && -d $(field snapshot) && $(field registered) == "no ($B/.agents/hooks/lib/worktree_records.py failed, see above): only step 5 removes the snapshot" && $(cat "$T/err") == *"records are broken"* ]] \
  && ok "failing worktree_records.py: snapshot kept, failure shown" || bad "failing records (rc=$rc): $out $(cat "$T/err")"

((fails == 0)) && echo "review-snapshot tests passed" || { echo "$fails review-snapshot tests failed" >&2; exit 1; }
