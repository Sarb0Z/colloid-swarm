#!/usr/bin/env bash
# Tests for .agents/iterm: pane-base over fixture repositories, pane-diff with a
# stub nvim recording its argv, install.sh in a temporary HOME.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

IT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fails=$((fails + 1)); }
eq() { # name expected actual
  if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi
}

commit() { git -C "$1" commit -q --allow-empty -m "$2" && git -C "$1" rev-parse HEAD; }
repo() { git init -q -b main "$1" 2>/dev/null; }
mkbare() { git init -q --bare -b main "$1" 2>/dev/null; }

# --- (a) pane-base ----------------------------------------------------------
mkbare "$T/remote.git"
repo "$T/up"
c1=$(commit "$T/up" one)
git -C "$T/up" remote add origin "$T/remote.git"
git -C "$T/up" push -q -u origin main 2>/dev/null
c2=$(commit "$T/up" two)
out=$(cd "$T/up" && "$IT/bin/pane-base" 2>"$T/err")
eq "pane-base upstream ahead: pushed commit" "$c1" "$out"
grep -q upstream "$T/err" && ok "pane-base upstream ahead: rule named" || bad "pane-base upstream ahead: rule named"

# upstream ahead of us (behind): another clone pushes, we fetch
git clone -q "$T/remote.git" "$T/other" 2>/dev/null
c3=$(commit "$T/other" three)
git -C "$T/other" push -q origin main 2>/dev/null
git -C "$T/up" fetch -q origin
out=$(cd "$T/up" && "$IT/bin/pane-base" 2>/dev/null)
eq "pane-base upstream behind: common ancestor" "$c1" "$out"

# no upstream, origin/HEAD present
git clone -q "$T/remote.git" "$T/clone" 2>/dev/null
git -C "$T/clone" checkout -q -b topic
c4=$(commit "$T/clone" four)
out=$(cd "$T/clone" && "$IT/bin/pane-base" 2>"$T/err")
eq "pane-base origin/HEAD: default branch tip" "$c3" "$out"
grep -q 'origin/HEAD' "$T/err" && ok "pane-base origin/HEAD: rule named" || bad "pane-base origin/HEAD: rule named"

# no upstream, no origin/HEAD, only origin/main
git -C "$T/clone" remote set-head origin -d >/dev/null
out=$(cd "$T/clone" && "$IT/bin/pane-base" 2>"$T/err")
eq "pane-base origin/main only: default branch tip" "$c3" "$out"
grep -q 'origin/main' "$T/err" && ok "pane-base origin/main only: rule named" || bad "pane-base origin/main only: rule named"

# no remote at all
repo "$T/solo"
s1=$(commit "$T/solo" one)
out=$(cd "$T/solo" && "$IT/bin/pane-base" 2>"$T/err")
eq "pane-base no remote: HEAD" "$s1" "$out"
grep -q 'using HEAD' "$T/err" && ok "pane-base no remote: rule named" || bad "pane-base no remote: rule named"

# outside a repository
mkdir "$T/plain"
(cd "$T/plain" && "$IT/bin/pane-base" >"$T/out" 2>"$T/err"); rc=$?
[[ $rc -ne 0 && ! -s $T/out && -s $T/err ]] && ok "pane-base outside repo: non-zero, message, empty stdout" || bad "pane-base outside repo (rc=$rc)"

# --- (b) pane-diff with a stub nvim ----------------------------------------
cat >"$T/nvim-stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$PANE_DIFF_STUB_OUT"
STUB
chmod +x "$T/nvim-stub"
export PANE_DIFF_NVIM=$T/nvim-stub PANE_DIFF_STUB_OUT=$T/argv

run_diff() { # dir args...
  local d=$1
  shift
  rm -f "$T/argv"
  (cd "$d" && "$IT/bin/pane-diff" "$@" </dev/null >/dev/null 2>&1)
  [[ -f $T/argv ]] && cat "$T/argv" || echo "<not run>"
}
nl=$'\n'
eq "pane-diff no args maps HEAD to pane-base" "-c${nl}DiffviewOpen $c1" "$(run_diff "$T/up")"
eq "pane-diff HEAD maps to pane-base" "-c${nl}DiffviewOpen $c1" "$(run_diff "$T/up" HEAD)"
eq "pane-diff @ is uncommitted only" "-c${nl}DiffviewOpen" "$(run_diff "$T/up" @)"
eq "pane-diff explicit base as typed" "-c${nl}DiffviewOpen origin/main" "$(run_diff "$T/up" origin/main)"
eq "pane-diff file" "-c${nl}DiffviewOpen $c1 -- src/a.txt" "$(run_diff "$T/up" HEAD -- src/a.txt)"
eq "pane-diff file with space and quote" "-c${nl}DiffviewOpen $c1 -- it\\'s\\ here.txt" "$(run_diff "$T/up" HEAD -- "it's here.txt")"
eq "pane-diff @ with file" "-c${nl}DiffviewOpen -- a.txt" "$(run_diff "$T/up" @ -- a.txt)"
eq "pane-diff outside repo does not run nvim" "<not run>" "$(run_diff "$T/plain" HEAD)"
msg=$(cd "$T/plain" && printf x | "$IT/bin/pane-diff" 2>&1 >/dev/null)
[[ $msg == *"not inside a git repository"* ]] && ok "pane-diff outside repo: reason printed, key consumed" || bad "pane-diff outside repo message: $msg"

# --- (c) install.sh in a temporary HOME ------------------------------------
H=$T/home
mkdir "$H"
out1=$(HOME=$H "$IT/install.sh" 2>&1); rc=$?
eq "install first run exits 0" 0 "$rc"
[[ -L $H/.local/bin/pane-base && -L $H/.local/bin/pane-diff ]] && ok "install links every bin script" || bad "install links every bin script"
[[ $out1 == *linked:* ]] && ok "install reports what it did" || bad "install reports: $out1"
out2=$(HOME=$H "$IT/install.sh" 2>&1); rc=$?
eq "install second run exits 0" 0 "$rc"
[[ $out2 != *linked:* && $out2 == *unchanged:* ]] && ok "install second run changes nothing" || bad "install second run: $out2"
rm "$H/.local/bin/pane-diff"
echo mine >"$H/.local/bin/pane-diff"
err=$(HOME=$H "$IT/install.sh" 2>&1 >/dev/null); rc=$?
[[ $rc -ne 0 && $err == *"$H/.local/bin/pane-diff"* ]] && ok "install refuses a foreign file, naming it" || bad "install foreign file (rc=$rc): $err"
eq "install left the foreign file intact" mine "$(cat "$H/.local/bin/pane-diff")"

((fails == 0)) && echo "iterm tests passed" || { echo "$fails failed" >&2; exit 1; }
