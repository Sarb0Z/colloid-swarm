#!/usr/bin/env bash
# Tests for .agents/iterm/server: setup-server.sh over a pretend server folder
# (SETUP_ROOT), with apt, systemctl, ufw, git, runuser, chown, id, ss and
# Claude Code replaced by stand-ins that log each state-changing call; the
# launchers in bash; tmux.conf in a throwaway tmux server; apply end to end with
# ssh replaced by a local shell.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() {
  printf 'FAIL %s\n' "$1" >&2
  fails=$((fails + 1))
}
eq() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }
has() { if [[ $3 == *"$2"* ]]; then ok "$1"; else bad "$1: no [$2] in: $3"; fi; }
mode() { ls -ld "$1" | cut -c1-10; }
tree() { (cd "$1" && find . | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort); }
count() { grep -cxF -- "$1" "$2"; }

PIN_RESURRECT=e87d7d592cac97fa38c12395ebec042c154a1844
PIN_CONTINUUM=46e0e0023476018ddb4cc0d44783eede27e5a8ec
KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBl4w1YqQ0dTn0f8dYw0mJc9yJ2m3Y8w0q6V5o3P1a2b mac@test"
MAC_VERSION=2.1.325

# --- stand-ins ----------------------------------------------------------------
export STATE=$T/state CALLS=$T/calls
mkdir -p "$T/bin" "$STATE"
stub() { # name body
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$T/bin/$1"
  chmod +x "$T/bin/$1"
}
stub id '[[ $1 == -u ]] && echo "${FAKE_UID:-0}"'
stub chown 'echo "chown $*" >>"$CALLS"'
stub runuser 'while [[ $1 != -- ]]; do shift; done; shift; exec "$@"'
stub add-apt-repository 'echo "add-apt-repository $*" >>"$CALLS"
printf "URIs: https://ppa.launchpadcontent.net/jgmath2000/et/ubuntu/\n" >"$SETUP_ROOT/etc/apt/sources.list.d/jgmath2000-ubuntu-et-noble.sources"'
stub apt-get 'if [[ $1 == -s ]]; then echo "Inst et (7.1.1-noble1 Eternal Terminal)"; echo "Conf et"; exit 0; fi
echo "apt-get $* NEEDRESTART_SUSPEND=${NEEDRESTART_SUSPEND:-} DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-}" >>"$CALLS"
touch "$STATE/et-installed"
printf "[Networking]\nport = 2022\n\n[Debug]\nverbose = 0\ntelemetry = true\nlogdirectory = /tmp\n" >"$SETUP_ROOT/etc/et.cfg"'
stub dpkg-query '[[ -e $STATE/et-installed ]] && { printf "ii "; exit 0; }; echo "dpkg-query: no packages found matching et" >&2; exit 1'
stub systemctl 'case $1 in
  is-enabled) [[ -e $STATE/et-enabled ]] ;;
  is-active) [[ -e $STATE/et-active ]] ;;
  enable) echo "systemctl $*" >>"$CALLS"; touch "$STATE/et-enabled" "$STATE/et-active" ;;
  restart) echo "systemctl $*" >>"$CALLS" ;;
  *) echo "systemctl stand-in: unexpected $*" >&2; exit 3 ;;
esac'
stub ufw 'case $1 in
  status) echo "Status: active"; echo; echo "To Action From"; cat "$STATE/ufw-rules" 2>/dev/null ;;
  limit) echo "ufw $*" >>"$CALLS"; echo "2022/tcp                   LIMIT       Anywhere" >>"$STATE/ufw-rules" ;;
  *) echo "ufw stand-in: unexpected $*" >&2; exit 3 ;;
esac'
stub git 'dir=; while [[ $1 == -C || $1 == -c ]]; do [[ $1 == -C ]] && dir=$2; shift 2; done
case $1 in
  clone) echo "git clone ${*: -1}" >>"$CALLS"; mkdir -p "${*: -1}/.git"; echo none >"${*: -1}/.git/sha" ;;
  rev-parse) cat "$dir/.git/sha" ;;
  checkout) echo "git -C $dir checkout ${*: -1}" >>"$CALLS"; echo "${*: -1}" >"$dir/.git/sha" ;;
  *) echo "git stand-in: unexpected $*" >&2; exit 3 ;;
esac'
stub ss '[[ -e $STATE/et-active ]] && echo "LISTEN 0 4096 0.0.0.0:2022 0.0.0.0:*"; true'
if ! command -v tmux >/dev/null; then
  stub tmux 'true'
  echo "skip loading tmux.conf into a real tmux (no tmux on PATH)"
fi
export PATH=$T/bin:$PATH

# A pretend server: what contabo-hop held on 2026-11-16, reduced to what the script reads.
fresh() { # folder
  local r=$1 h=$1/home/openclawops
  rm -rf "$r" "$STATE"
  mkdir -p "$STATE" "$r/etc/apt/sources.list.d" "$r/etc/ufw" "$r/root" "$h/.ssh" "$h/.claude" "$h/.local/bin"
  printf 'PRETTY_NAME="Ubuntu 24.04.4 LTS"\nVERSION_CODENAME=noble\n' >"$r/etc/os-release"
  echo "Types: deb" >"$r/etc/apt/sources.list.d/ubuntu.sources"
  echo "### tuple ### limit tcp 22 0.0.0.0/0 any 0.0.0.0/0 in" >"$r/etc/ufw/user.rules"
  echo "### tuple ### limit tcp 22 ::/0 any ::/0 in" >"$r/etc/ufw/user6.rules"
  echo "22/tcp                     LIMIT       Anywhere" >"$STATE/ufw-rules"
  printf '# ~/.bashrc\ncase $- in\n    *i*) ;;\n      *) return;;\nesac\nexport KEEP_ME=1\n' >"$h/.bashrc"
  echo '{"note": "uzair login, must stay"}' >"$h/.claude/settings.json"
  printf '#!/usr/bin/env bash\ncase $1 in\n  --version) echo "$(cat "$STATE/claude-version" 2>/dev/null || echo 2.1.207) (Claude Code)" ;;\n  update) echo "claude update HOME=$HOME CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR" >>"$CALLS"; echo %s >"$STATE/claude-version" ;;\nesac\n' \
    "$MAC_VERSION" >"$h/.local/bin/claude"
  chmod +x "$h/.local/bin/claude"
  : >"$CALLS"
}
B=$T/bundle
mkdir -p "$B"
cp "$HERE/setup-server.sh" "$HERE/tmux.conf" "$HERE/launchers.bash" "$HERE/settings.json" "$B/"
echo "$MAC_VERSION" >"$B/claude-version"
echo "$KEY" >"$B/mac.pub"
R=$T/root
H=$R/home/openclawops
run() { (cd / && SETUP_ROOT=$R HOME=$T/roothome bash "$B/setup-server.sh" "$@"); }
mkdir -p "$T/roothome"

# --- syntax -------------------------------------------------------------------
for f in setup-server.sh apply launchers.bash test.sh; do
  bash -n "$HERE/$f" && ok "bash -n $f" || bad "bash -n $f"
done

# --- --check changes nothing --------------------------------------------------
fresh "$R"
before=$(tree "$R")
out=$(run --check "$B/mac.pub" 2>&1); rc=$?
eq "check exits 0" 0 "$rc"
for line in "add the Mac's key" "add ppa:jgmath2000/et" "install et" "set telemetry = false" \
  "enable and start the et service" "ufw limit 2022/tcp" "write openclawops's ~/.tmux.conf" \
  "check out tmux-resurrect at e87d7d592cac" "check out tmux-continuum at 46e0e0023476" \
  "write the account launchers" "make ~/.claude-work" "make ~/.claude-guest" \
  "write ~/.claude-family/settings.json" "update Claude Code from 2.1.207 to at least the Mac's $MAC_VERSION"; do
  has "check lists: $line" "would: $line" "$out"
done
has "check counts every change" "check: 19 change(s) to make; nothing was changed" "$out"
eq "check leaves the server unchanged" "$before" "$(tree "$R")"
eq "check calls nothing that changes state" "" "$(cat "$CALLS")"

# --- a run makes every change ---------------------------------------------------
out=$(run "$B/mac.pub" 2>&1); rc=$?
eq "run exits 0" 0 "$rc"
calls=$(cat "$CALLS")
has "run adds the PPA" "add-apt-repository -y ppa:jgmath2000/et" "$calls"
has "run installs et with needrestart suspended" "apt-get install -y et NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive" "$calls"
has "run enables et" "systemctl enable --now et" "$calls"
has "run rate-limits 2022" "ufw limit 2022/tcp" "$calls"
eq "authorized_keys holds the key" "$KEY" "$(cat "$H/.ssh/authorized_keys")"
eq "authorized_keys mode" "-rw-------" "$(mode "$H/.ssh/authorized_keys")"
eq "et.cfg telemetry off" "telemetry = false" "$(grep telemetry "$R/etc/et.cfg")"
cmp -s "$HERE/tmux.conf" "$H/.tmux.conf" && ok "tmux.conf installed as shipped" || bad "tmux.conf differs"
eq "resurrect pinned" "$PIN_RESURRECT" "$(cat "$H/.tmux/plugins/tmux-resurrect/.git/sha")"
eq "continuum pinned" "$PIN_CONTINUUM" "$(cat "$H/.tmux/plugins/tmux-continuum/.git/sha")"
eq "bashrc keeps its own lines" "export KEEP_ME=1" "$(grep KEEP_ME "$H/.bashrc")"
eq "bashrc holds the launcher block once" 1 "$(count "$(head -n 1 "$HERE/launchers.bash")" "$H/.bashrc")"
for a in work personal family guest; do
  cmp -s "$HERE/settings.json" "$H/.claude-$a/settings.json" && eq "settings for $a, mode" "-rw-------" "$(mode "$H/.claude-$a/settings.json")" ||
    bad "settings for $a differ"
  eq "folder for $a, mode" "drwx------" "$(mode "$H/.claude-$a")"
done
eq "the login in ~/.claude is untouched" '{"note": "uzair login, must stay"}' "$(cat "$H/.claude/settings.json")"
has "update runs in the work folder with openclawops' home" "claude update HOME=$H CLAUDE_CONFIG_DIR=$H/.claude-work" "$calls"
bk=$R/root/backups/unit5-$(date +%Y%m%d)
cmp -s "$bk/home/openclawops/.bashrc" <(printf '# ~/.bashrc\ncase $- in\n    *i*) ;;\n      *) return;;\nesac\nexport KEEP_ME=1\n') &&
  ok "bashrc backed up before its change" || bad "bashrc backup"
[[ -f $bk/etc/ufw/user.rules && -f $bk/ufw-status.txt && -d $bk/etc/apt/sources.list.d ]] &&
  ok "firewall and apt sources backed up" || bad "firewall or apt backup missing"
has "run names the backup folder" "backups: /root/backups/unit5-" "$out"

# --- a second run changes nothing -----------------------------------------------
after=$(tree "$R")
: >"$CALLS"
out=$(run "$B/mac.pub" 2>&1); rc=$?
eq "second run exits 0" 0 "$rc"
has "second run has nothing to change" "nothing to change" "$out"
eq "second run calls nothing that changes state" "" "$(cat "$CALLS")"
eq "second run leaves the server unchanged" "$after" "$(tree "$R")"

# --- the launcher block is replaced in place --------------------------------------
cp "$HERE/launchers.bash" "$T/launchers.orig"
awk 'NR == 2 { print "# a changed line" } { print }' "$T/launchers.orig" >"$B/launchers.bash"
echo "export AFTER_BLOCK=1" >>"$H/.bashrc"
run "$B/mac.pub" >/dev/null 2>&1
eq "changed block written once" 1 "$(count "# a changed line" "$H/.bashrc")"
eq "still one block" 1 "$(count "$(head -n 1 "$HERE/launchers.bash")" "$H/.bashrc")"
eq "lines after the block stay" "export AFTER_BLOCK=1" "$(tail -n 1 "$H/.bashrc")"
cp "$T/launchers.orig" "$B/launchers.bash"

# --- a key file without a final newline ------------------------------------------
fresh "$R"
printf 'ssh-ed25519 AAAAexisting other@host' >"$H/.ssh/authorized_keys"
run "$B/mac.pub" >/dev/null 2>&1
eq "an existing key line stays whole" 2 "$(wc -l <"$H/.ssh/authorized_keys" | tr -d ' ')"
eq "the Mac's key on its own line" "$KEY" "$(tail -n 1 "$H/.ssh/authorized_keys")"

# --- refusals ---------------------------------------------------------------------
fresh "$R"
err=$(FAKE_UID=1000 run "$B/mac.pub" 2>&1); rc=$?
[[ $rc -eq 1 && $err == *"run as root"* ]] && ok "refuses a non-root run" || bad "non-root (rc=$rc): $err"
sed 's/noble/jammy/' "$R/etc/os-release" >"$T/os" && cp "$T/os" "$R/etc/os-release"
err=$(run "$B/mac.pub" 2>&1); rc=$?
[[ $rc -eq 1 && $err == *"noble"* ]] && ok "refuses another Ubuntu release" || bad "release (rc=$rc): $err"
fresh "$R"
echo "not a key" >"$T/bad.pub"
err=$(run "$T/bad.pub" 2>&1); rc=$?
[[ $rc -eq 1 && $err == *"not one public key line"* ]] && ok "refuses a file that is no public key" || bad "bad key (rc=$rc): $err"
err=$(run 2>&1); rc=$?
eq "usage without a key file" 2 "$rc"
eq "refusals change nothing" "" "$(cat "$CALLS")"
if [[ ! -e $T/bin/tmux ]]; then
  echo 'set -g no-such-option on' >>"$B/tmux.conf"
  err=$(run --check "$B/mac.pub" 2>&1); rc=$?
  [[ $rc -eq 1 && $err == *"rejects tmux.conf"*"no-such-option"* ]] && ok "refuses a tmux.conf its tmux rejects" || bad "tmux reject (rc=$rc): $err"
  cp "$HERE/tmux.conf" "$B/tmux.conf"
fi
grep -v '^[[:space:]]*#' "$HERE/tmux.conf" | grep -q extended-keys-format &&
  bad "tmux.conf uses extended-keys-format, which tmux 3.4 lacks" ||
  ok "tmux.conf avoids extended-keys-format (tmux 3.4)"

# --- the launchers ----------------------------------------------------------------
stub claude 'echo "profile=${CLAUDE_PROFILE:-} dir=${CLAUDE_CONFIG_DIR:-} args=$*"'
L=$HERE/launchers.bash
eq "claudep picks the personal folder" "profile=personal dir=/srv/h/.claude-personal args=-c" \
  "$(HOME=/srv/h bash -c "source '$L'; claudep -c")"
eq "claudew picks the work folder, not ~/.claude" "profile=work dir=/srv/h/.claude-work args=" \
  "$(HOME=/srv/h bash -c "source '$L'; claudew")"
err=$(bash -c "source '$L'; claude --resume x" 2>&1); rc=$?
[[ $rc -eq 1 && $err == *"pick an account"* ]] && ok "a bare claude names the accounts" || bad "bare claude (rc=$rc): $err"
eq "claude --version passes through" "profile= dir= args=--version" \
  "$(env -u CLAUDE_PROFILE -u CLAUDE_CONFIG_DIR bash -c "source '$L'; claude --version")"
rm "$T/bin/claude"

# --- apply, end to end with ssh replaced by a local shell --------------------------
if [[ $(uname) == Darwin ]]; then
  AH=$T/machome
  mkdir -p "$AH/.ssh"
  echo "$KEY" >"$AH/.ssh/id_ed25519.pub"
  stub claude "echo '$MAC_VERSION (Claude Code)'"
  stub ssh '[[ $1 == contabo-hop ]] || { echo "ssh stand-in: host $1" >&2; exit 3; }; echo "ssh $1" >>"$CALLS"; tee "$STATE/sent.tar" | bash -c "$2"'
  fresh "$R"
  before=$(tree "$R")
  out=$(HOME=$AH SETUP_ROOT=$R "$HERE/apply" --check 2>&1); rc=$?
  eq "apply --check exits 0" 0 "$rc"
  has "apply --check runs the check on the server" "check: 19 change(s) to make; nothing was changed" "$out"
  has "apply sends the Mac's version" "to at least the Mac's $MAC_VERSION" "$out"
  eq "apply --check changes nothing" "$before" "$(tree "$R")"
  eq "apply logs in once, to contabo-hop" "ssh contabo-hop" "$(cat "$CALLS")"
  eq "apply sends no macOS file tags, which GNU tar warns about" 0 \
    "$(LC_ALL=C grep -a -c 'LIBARCHIVE\.xattr' "$STATE/sent.tar")"
  err=$(HOME=$AH "$HERE/apply" --bogus 2>&1); rc=$?
  eq "apply refuses an unknown option" 2 "$rc"
  rm "$T/bin/claude" "$T/bin/ssh"
else
  echo "skip apply end to end (macOS tar flags; apply runs on the Mac)"
fi

((fails == 0)) && echo "server tests passed" || {
  echo "$fails failed" >&2
  exit 1
}
