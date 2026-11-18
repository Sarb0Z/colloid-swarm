#!/usr/bin/env bash
# Tests for .agents/iterm: pane-base over fixture repositories, pane-diff with a
# stub nvim recording its argv, install.sh in a temporary HOME, then every
# test-*.sh beside this file, one per prompt-pane script and one for the phone
# link's install, then the phone link's own tests (.agents/test-phone-hooks.sh).
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

# install.sh installs the phone link too: it writes each Claude account's
# settings and loads launchd agents. Every run of it here gets a home with one
# account folder, and stand-ins for launchctl and signal-cli.
printf '#!/bin/sh\n' >"$T/signal-cli"
chmod +x "$T/signal-cli"
export PHONE_LINK_LAUNCHCTL=$IT/tests/fake-launchctl FAKE_LAUNCHCTL_STATE=$T/launchd PHONE_LINK_SIGNAL_CLI=$T/signal-cli

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

# Revisions and path names reach diffview with only tokenizer syntax escaped.
eq "pane-diff HEAD~2 unescaped" "-c${nl}DiffviewOpen HEAD~2" "$(run_diff "$T/up" 'HEAD~2')"
eq "pane-diff @{u} unescaped" "-c${nl}DiffviewOpen @{u}" "$(run_diff "$T/up" '@{u}')"
eq "pane-diff main^ unescaped" "-c${nl}DiffviewOpen main^" "$(run_diff "$T/up" 'main^')"
eq "pane-diff % in file name" "-c${nl}DiffviewOpen $c1 -- a\\%b.txt" "$(run_diff "$T/up" HEAD -- 'a%b.txt')"
eq "pane-diff # in file name" "-c${nl}DiffviewOpen $c1 -- c\\#d.txt" "$(run_diff "$T/up" HEAD -- 'c#d.txt')"
eq "pane-diff [ ] in file name" "-c${nl}DiffviewOpen $c1 -- e\\[1\\].txt" "$(run_diff "$T/up" HEAD -- 'e[1].txt')"

# Without PANE_DIFF_NVIM, nvim comes from PATH (the Linux server's tmux PATH
# included).
mkdir "$T/fakebin"
cp "$T/nvim-stub" "$T/fakebin/nvim"
rm -f "$T/argv"
(cd "$T/up" && env -u PANE_DIFF_NVIM PATH="$T/fakebin:$PATH" "$IT/bin/pane-diff" </dev/null >/dev/null 2>&1)
eq "pane-diff finds nvim on PATH without PANE_DIFF_NVIM" "-c${nl}DiffviewOpen $c1" "$(cat "$T/argv" 2>/dev/null)"

# Untracked files: a commit base gets a second tab, with tab 1 current and a message.
repo "$T/ut"
u1=$(commit "$T/ut" one)
tail1="-c${nl}1tabclose${nl}-c${nl}tabfirst"
printf 'x' >"$T/ut/new1.txt"
eq "pane-diff one untracked file: second tab" \
  "-c${nl}DiffviewOpen $u1${nl}-c${nl}DiffviewOpen${nl}$tail1${nl}-c${nl}echomsg '1 untracked file: see tab 2 (gt)'" "$(run_diff "$T/ut")"
printf 'x' >"$T/ut/new2.txt"
eq "pane-diff two untracked files: plural message" \
  "-c${nl}DiffviewOpen $u1${nl}-c${nl}DiffviewOpen${nl}$tail1${nl}-c${nl}echomsg '2 untracked files: see tab 2 (gt)'" "$(run_diff "$T/ut")"
eq "pane-diff @ with untracked files: one view" "-c${nl}DiffviewOpen" "$(run_diff "$T/ut" @)"
eq "pane-diff untracked file named: both tabs carry the path" \
  "-c${nl}DiffviewOpen $u1 -- new1.txt${nl}-c${nl}DiffviewOpen -- new1.txt${nl}$tail1${nl}-c${nl}echomsg '1 untracked file: see tab 2 (gt)'" "$(run_diff "$T/ut" HEAD -- new1.txt)"
git -C "$T/ut" add new1.txt new2.txt
eq "pane-diff nothing untracked: one view" "-c${nl}DiffviewOpen $u1" "$(run_diff "$T/ut")"

# Through the link install.sh makes: pane-diff finds pane-base beside its target.
mkdir -p "$T/linkhome/.claude"
HOME=$T/linkhome "$IT/install.sh" >/dev/null
rm -f "$T/argv"
(cd "$T/up" && "$T/linkhome/.local/bin/pane-diff" </dev/null >/dev/null 2>&1)
eq "pane-diff through the installed link" "-c${nl}DiffviewOpen $c1" "$(cat "$T/argv" 2>/dev/null)"

# Failures hold the pane for a key and say why; nvim never runs.
msg=$(cd "$T/up" && printf x | "$IT/bin/pane-diff" a b c 2>&1 >/dev/null); rc=$?
[[ $rc -ne 0 && $msg == *usage:* && $msg == *"Press any key"* ]] && ok "pane-diff usage error holds the pane" || bad "pane-diff usage (rc=$rc): $msg"
repo "$T/empty"
msg=$(cd "$T/empty" && printf x | "$IT/bin/pane-diff" 2>&1 >/dev/null); rc=$?
[[ $rc -ne 0 && $msg == *"no commits"* && $msg == *"Press any key"* ]] && ok "pane-diff shows pane-base's own reason" || bad "pane-diff pane-base reason (rc=$rc): $msg"

# One real run: headless Neovim with diffview resolves the same arguments.
DV=${PANE_DIFF_TEST_DIFFVIEW:-$HOME/.local/share/nvim/lazy/diffview-plus.nvim}
NVIM_BIN=$(command -v nvim || echo /opt/homebrew/bin/nvim)
if [[ -d $DV && -x $NVIM_BIN ]]; then
  repo "$T/real"
  printf 'one\n' >"$T/real/a%b.txt"
  git -C "$T/real" add -A
  commit "$T/real" first >/dev/null
  printf 'two\n' >"$T/real/a%b.txt"
  git -C "$T/real" commit -qam second
  git -C "$T/real" commit -q --allow-empty -m third
  cat >"$T/nvim-real" <<WRAP
#!/usr/bin/env bash
exec "$NVIM_BIN" --headless --clean --cmd 'set rtp+=$DV' "\$@" -c 'lua vim.wait(1000, function() return false end); local cur = vim.api.nvim_get_current_tabpage(); local tabs = vim.api.nvim_list_tabpages(); for _, t in ipairs(tabs) do vim.api.nvim_set_current_tabpage(t); vim.wait(800, function() return false end) end; vim.api.nvim_set_current_tabpage(cur); local out = {}; for i, t in ipairs(tabs) do local names = {}; for _, view in ipairs(require("diffview.lib").views) do if view.tabpage == t then for _, f in view.files:iter() do names[#names + 1] = f.path end end end; out[#out + 1] = "tab" .. i .. (t == cur and "*" or "") .. ": " .. table.concat(names, ",") end; out[#out + 1] = (vim.fn.execute("messages"):gsub("\\n", "")); vim.fn.writefile(out, vim.env.PANE_DIFF_REAL_OUT)' -c 'qa!'
WRAP
  chmod +x "$T/nvim-real"
  real_diff() { # args...: prints one line per tab (* marks the current one) then the messages
    rm -f "$T/real-out"
    (cd "$T/real" && PANE_DIFF_NVIM=$T/nvim-real PANE_DIFF_REAL_OUT=$T/real-out "$IT/bin/pane-diff" "$@" </dev/null >/dev/null 2>&1)
    cat "$T/real-out" 2>/dev/null
  }
  # With nothing untracked, a file named a%b.txt opens in the one view diffview makes after the empty startup tab.
  eq "pane-diff real diffview: HEAD~2 and a file named a%b.txt" "tab1: ${nl}tab2*: a%b.txt" "$(real_diff 'HEAD~2' -- 'a%b.txt')"
  printf 'x\n' >"$T/real/new.txt"
  eq "pane-diff real diffview: untracked file gets tab 2, tab 1 stays current" \
    "tab1*: a%b.txt${nl}tab2: new.txt${nl}1 untracked file: see tab 2 (gt)" "$(real_diff 'HEAD~2')"
else
  echo "skip pane-diff real diffview run (no diffview at $DV or no nvim)"
fi

# --- (c) install.sh in a temporary HOME ------------------------------------
H=$T/home
mkdir -p "$H/.claude"
out1=$(HOME=$H "$IT/install.sh" 2>&1); rc=$?
eq "install first run exits 0" 0 "$rc"
[[ -L $H/.local/bin/pane-base && -L $H/.local/bin/pane-diff ]] && ok "install links pane-base and pane-diff" || bad "install links pane-base and pane-diff"
for script in "$IT"/bin/*; do
  name=$(basename "$script")
  [[ -x $script ]] && ok "$name is executable" || bad "$script is not executable"
  eq "install links $name to its file here" "$script" "$(readlink "$H/.local/bin/$name")"
done
eq "install links the pane commands, the phone link's hooks and nothing else" \
  "$({ ls "$IT/bin"; ls "$IT/phone/hooks"; } | LC_ALL=C sort)" "$(ls "$H/.local/bin" | LC_ALL=C sort)"
[[ $out1 == *linked:* ]] && ok "install reports what it did" || bad "install reports: $out1"
links1=$(ls -l "$H/.local/bin")
out2=$(HOME=$H "$IT/install.sh" 2>&1); rc=$?
eq "install second run exits 0" 0 "$rc"
[[ $out2 != *linked:* && $out2 == *unchanged:* ]] && ok "install second run reports nothing new" || bad "install second run: $out2"
eq "install second run leaves every link as it was" "$links1" "$(ls -l "$H/.local/bin")"
rm "$H/.local/bin/pane-diff"
echo mine >"$H/.local/bin/pane-diff"
err=$(HOME=$H "$IT/install.sh" 2>&1 >/dev/null); rc=$?
[[ $rc -ne 0 && $err == *"$H/.local/bin/pane-diff"* ]] && ok "install refuses a foreign file, naming it" || bad "install foreign file (rc=$rc): $err"
eq "install left the foreign file intact" mine "$(cat "$H/.local/bin/pane-diff")"

# --- (d) the prompt pane and the phone link's install: each one's own test file
# Named, not globbed: lint-suite.py reaches a test only by its file name, and
# the count check fails a test file added here without a line below.
suites=(test-pane-run.sh test-phone-install.sh test-prompt-catalog.sh test-review-snapshot.sh)
on_disk=$(cd "$IT/tests" && ls test-*.sh | LC_ALL=C sort | tr '\n' ' ')
eq "every test file here is run" "$(printf '%s\n' "${suites[@]}" | LC_ALL=C sort | tr '\n' ' ')" "$on_disk"
for suite in "${suites[@]}"; do
  "$IT/tests/$suite" || bad "$suite"
done

# --- (e) the phone link: its modules and its hook, fired as Claude Code fires it
"$IT/../test-phone-hooks.sh" || bad "test-phone-hooks.sh"

((fails == 0)) && echo "iterm tests passed" || { echo "$fails failed" >&2; exit 1; }
