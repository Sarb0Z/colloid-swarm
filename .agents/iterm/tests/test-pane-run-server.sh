#!/usr/bin/env bash
# Tests for pane-run's server path: no claude-tab-state folder, no `defaults`,
# it2 under ~/.iterm2/bin, the lead found in the account folders' session
# registries and, inside tmux, by the terminals of the pane's window. The
# fixture: links to /bin/sleep named `claude` are the sessions' processes, a
# fake `ps` answers terminals from files, a fake `tmux` prints panes from files,
# and fake-inbox.py is the inbox socket. PATH holds no `defaults`.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

IT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
RUN=$IT/bin/pane-run
INBOX=$IT/tests/fake-inbox.py
T=$(cd "$(mktemp -d /tmp/pane-srv.XXXXXX)" && pwd -P)
pids=()
cleanup() {
  ((${#pids[@]})) && kill "${pids[@]}" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT
fails=0

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fails=$((fails + 1)); }
eq() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }
has() { if [[ $3 == *"$2"* ]]; then ok "$1"; else bad "$1: [$2] not in [$3]"; fi; }
lacks() { if [[ $3 != *"$2"* ]]; then ok "$1"; else bad "$1: [$2] is in [$3]"; fi; }

export HOME=$T/home PANE_RUN_SETTLE=0
export CLAUDE_TAB_STATE_DIR=$T/no-tab-state
unset CLAUDE_CONFIG_DIR TMUX TMUX_PANE ITERM_SESSION_ID
SOCK=$T/in.sock
SID1=11111111-2222-4333-8444-555555555555
SID2=66666666-7777-4888-8999-000000000000
mkdir -p "$HOME/.claude-work/sessions" "$HOME/.claude-personal/sessions" "$HOME/.iterm2/bin" "$T/bin" "$T/path" "$T/ttys"

# PATH: the tools pane-run runs, a fake ps and tmux, and nothing else.
for tool in python3 git cat bash; do ln -s "$(command -v "$tool")" "$T/path/$tool"; done
cat >"$T/path/ps" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"tty="* ]]; then cat "$FAKE_TTYS/${@: -1}"; else exec /bin/ps "$@"; fi
STUB
cat >"$T/path/tmux" <<'STUB'
#!/usr/bin/env bash
case $1 in
  list-panes) cat "$FAKE_PANES" ;;
  show-options) [[ -f $FAKE_WG ]] && cat "$FAKE_WG" || exit 1 ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$T/path/ps" "$T/path/tmux"
export FAKE_TTYS=$T/ttys FAKE_PANES=$T/panes FAKE_WG=$T/wg
[[ -z $(PATH=$T/path command -v defaults) ]] && ok "fixture: no defaults on PATH" || bad "fixture: defaults is on PATH"

ln -s /bin/sleep "$T/bin/claude"
"$T/bin/claude" 100000 &
A=$!
"$T/bin/claude" 100000 &
B=$!
pids+=("$A" "$B")

mkdir -p "$T/proj/.agents/playbooks" "$T/plain" "$T/elsewhere"
git init -q -b main "$T/plain" 2>/dev/null
git init -q -b main "$T/proj" 2>/dev/null
: >"$T/proj/.agents/playbooks/hostile-review.md"

session() { # config-folder pid session-id cwd name tty
  printf '{"pid":%s,"sessionId":"%s","cwd":"%s","name":"%s","kind":"interactive","status":"idle","messagingSocketPath":"%s","peerProtocol":1}' \
    "$2" "$3" "$4" "$5" "$SOCK" >"$1/sessions/$2.json"
  printf "%s\n" "${6#/dev/}" >"$T/ttys/$2"
}
reset() {
  rm -f "$HOME"/.claude-*/sessions/*.json "$T/panes" "$T/wg"
  unset TMUX TMUX_PANE CLAUDE_CONFIG_DIR
  cd "$T/proj" || exit 1
}

n=0
send() { # keys args...
  local keys=$1
  shift
  n=$((n + 1))
  O=$T/o$n
  mkdir "$O"
  python3 "$INBOX" serve "$SOCK" "$O"
  out=$(printf '%s' "$keys" | PATH=$T/path "$RUN" "$@" 2>"$O/err")
  rc=$?
  err=$(cat "$O/err")
  python3 "$INBOX" stop "$SOCK"
  posts=$(find "$O" -name 'post-*' | wc -l | tr -d ' ')
  msg=
  [[ -f $O/post-1 ]] && msg=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["message"]["content"])' "$O/post-1")
}
nl=$'\n'

# --- one live session of the folder, in another account folder -----------------
reset
session "$HOME/.claude-work" "$A" "$SID1" "$T/proj" "Server-lead" /dev/pts/1
send x 'fix the typo'
eq "one session: rc" 0 "$rc"
eq "one session: one post" 1 "$posts"
has "one session: the entry reaches it" "fix the typo" "$msg"
has "one session: names it by its registry name and account" "Lead: Server-lead [work, session 11111111]" "$out"

# A session of another folder, a dead pid and a registry without a socket are not candidates.
session "$HOME/.claude-personal" "$B" "$SID2" "$T/elsewhere" "Other-folder" /dev/pts/2
send x 'fix the typo'
eq "other folder's session is not the lead: still one post" 1 "$posts"
has "other folder's session is not the lead" "Server-lead" "$out"
rm -f "$HOME/.claude-work/sessions/$A.json"
send x 'fix the typo'
eq "no live session of the folder: refused, nothing posted" 0 "$posts"
has "no live session of the folder: reason" "no live Claude session is recorded for $T/proj" "$err"
has "no live session of the folder: pane held" "Nothing was sent." "$out"
session "$HOME/.claude-work" 999999 "$SID1" "$T/proj" "Dead" /dev/pts/1
send x 'fix the typo'
eq "a registry of a dead process: refused" 0 "$posts"
has "a dead process: the reason names it" "the session of process 999999 is over" "$err"

# --- several sessions of the folder --------------------------------------------
reset
session "$HOME/.claude-work" "$A" "$SID1" "$T/proj" "First" /dev/pts/1
session "$HOME/.claude-personal" "$B" "$SID2" "$T/proj" "Second" /dev/pts/2
send 2 'do it'
eq "several, outside tmux: the menu picks one" 1 "$posts"
has "several: the menu lists both" "  1  First" "$out"
has "several: the menu lists both (2)" "  2  Second  [personal, session 66666666]" "$out"
has "several: the key chosen got the message" "Lead: Second [personal" "$out"
send z 'do it'
eq "several: an unlisted key sends nothing" 0 "$posts"

# CLAUDE_CONFIG_DIR narrows the search to one account.
CLAUDE_CONFIG_DIR=$HOME/.claude-work send x 'do it'
has "CLAUDE_CONFIG_DIR: only that account's sessions" "Lead: First [work" "$out"

# --- inside tmux: the terminal of this pane's window wins ------------------------
export TMUX=/tmp/tmux-1/default,1,0 TMUX_PANE=%1
printf '%%1 /dev/pts/9 @1\n%%2 /dev/pts/2 @1\n%%3 /dev/pts/1 @2\n' >"$T/panes"
send x 'do it'
eq "tmux: the session on a pane of this window, no menu" 1 "$posts"
has "tmux: it is the second one" "Lead: Second [personal" "$out"
lacks "tmux: no menu was shown" "Press the key" "$out"

# A workgroup peer sits in its own window; @iterm2_wg names the leader pane.
printf '%%1 /dev/pts/9 @7\n%%2 /dev/pts/2 @1\n%%3 /dev/pts/1 @2\n' >"$T/panes"
send 1 'do it'
has "tmux, peer in its own window and no option: the menu" "Press the key" "$out"
printf '%%3\n' >"$T/wg"
send x 'do it'
has "tmux, @iterm2_wg names the leader pane: its session" "Lead: First [work" "$out"
lacks "tmux, @iterm2_wg: no menu" "Press the key" "$out"

# Two sessions in the window: the menu offers those two only.
session "$HOME/.claude-work" "$A" "$SID1" "$T/proj" "First" /dev/pts/2
send 1 'do it'
has "tmux, two in the window: the menu" "Press the key" "$out"
unset TMUX TMUX_PANE

# --- saved prompt without defaults ---------------------------------------------
reset
session "$HOME/.claude-work" "$A" "$SID1" "$T/plain" "Plain-lead" /dev/pts/1
cd "$T/plain" || exit 1
send x '#! background model=sonnet kind=review'
eq "kind=review without defaults: one post" 1 "$posts"
has "kind=review without defaults: the catalog's brief" "--- review brief ---${nl}Review the pending changes in this repo." "$msg"
lacks "kind=review without defaults: no failure text" "defaults" "$err"
out=$(printf x | PATH=$T/path "$RUN" --help)
has "--help says where the prompt comes from" "default_review_prompt" "$out"

# --- it2 under ~/.iterm2/bin ------------------------------------------------------
printf '#!/usr/bin/env bash\necho "[{\\"id\\":\\"11111111-0000-4000-8000-000000000000\\",\\"window_id\\":\\"w\\",\\"tab_id\\":\\"t\\"}]"\n' >"$HOME/.iterm2/bin/it2"
chmod +x "$HOME/.iterm2/bin/it2"
out=$(printf x | ITERM_SESSION_ID=w0t0p0:11111111-0000-4000-8000-000000000000 PATH=$T/path "$RUN" --probe 2>&1)
has "probe: it2 is taken from ~/.iterm2/bin" '"id": "11111111-0000-4000-8000-000000000000"' "$out"

((fails == 0)) && echo "pane-run server tests passed" || { echo "$fails pane-run server tests failed" >&2; exit 1; }
