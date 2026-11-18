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
lacks() { if [[ $3 != *"$2"* ]]; then ok "$1"; else bad "$1: unexpected [$2] in: $3"; fi; }
mode() { ls -ld "$1" | cut -c1-10; }
tree() { (cd "$1" && find . | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort); }
count() { grep -cxF -- "$1" "$2"; }

PIN_RESURRECT=e87d7d592cac97fa38c12395ebec042c154a1844
PIN_CONTINUUM=46e0e0023476018ddb4cc0d44783eede27e5a8ec
KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBl4w1YqQ0dTn0f8dYw0mJc9yJ2m3Y8w0q6V5o3P1a2b mac@test"
MAC_VERSION=2.1.325

# --- stand-ins ----------------------------------------------------------------
# The package's postinst starts et unless policy-rc.d answers 101, as Debian's
# deb-systemd-invoke does; the unit is enabled either way.
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
printf "URIs: https://ppa.launchpadcontent.net/jgmath2000/et/ubuntu/\n" >"$SETUP_ROOT/etc/apt/sources.list.d/jgmath2000-ubuntu-et-noble.sources"
touch "$STATE/lists"'
# et's candidate needs any fetched lists; tailscale's needs lists fetched while
# its repository was listed.
stub apt-cache '[[ $1 == policy ]] || exit 0
case $2 in
  et) [[ -e $STATE/lists ]] && printf "et:\n  Installed: (none)\n  Candidate: 7.1.1-noble1\n" ;;
  tailscale) [[ -e $STATE/ts-lists ]] && printf "tailscale:\n  Installed: (none)\n  Candidate: 1.90.6\n" ;;
esac; true'
# The real tailscale postinst enables tailscaled only on a reinstall of a unit
# that was enabled ($STATE/tailscaled-was-enabled), and starts only an enabled one.
stub apt-get 'packages=(); for a in "${@:2}"; do [[ $a == -* ]] || packages+=("$a"); done
case $1 in
  -s)
    [[ -e $STATE/sim-upgrade ]] && echo "Inst libc6 [2.39-0ubuntu8.6] (2.39-0ubuntu8.7 Ubuntu:24.04/noble-updates [amd64])"
    for p in "${packages[@]:1}"; do
      [[ $p == et ]] && echo "Inst libprotobuf32t64 (3.21.12-8.2build1 Ubuntu:24.04/noble [amd64])"
      echo "Inst $p (1.0-1 Ubuntu:24.04/noble [amd64])"; echo "Conf $p"
    done ;;
  update) echo "apt-get update" >>"$CALLS"; touch "$STATE/lists"
    [[ -e $SETUP_ROOT/etc/apt/sources.list.d/tailscale.list ]] && touch "$STATE/ts-lists"; true ;;
  install)
    gate=$SETUP_ROOT/usr/sbin/policy-rc.d; answer=none
    [[ -x $gate ]] && { "$gate"; answer=$?; }
    echo "apt-get $* policy-rc.d=$answer NEEDRESTART_SUSPEND=${NEEDRESTART_SUSPEND:-} DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-}" >>"$CALLS"
    for p in "${packages[@]}"; do touch "$STATE/installed-$p"; done
    set -- "$1" "$2" "${packages[@]}"
    if [[ $3 == et ]]; then
      touch "$STATE/et-enabled"
      [[ $answer == 101 ]] || touch "$STATE/et-active"
      printf "[Networking]\nport = 2022\n\n[Debug]\nverbose = 0\ntelemetry = true\nlogdirectory = /tmp\n" >"$SETUP_ROOT/etc/et.cfg"
      echo "Setting up et (7.1.1-noble1) ..."
    fi
    if [[ $3 == tailscale ]]; then
      if [[ -e $STATE/tailscaled-was-enabled ]]; then
        touch "$STATE/tailscaled-enabled"
        [[ $answer == 101 ]] || touch "$STATE/tailscaled-active"
      fi
      mkdir -p "$SETUP_ROOT/etc/default"
      printf "# Set the port to listen on for incoming VPN packets.\nPORT=\"41641\"\n\n# Extra flags you might want to pass to tailscaled.\nFLAGS=\"\"\n" >"$SETUP_ROOT/etc/default/tailscaled"
      echo "Setting up tailscale (1.90.6) ..."
    fi ;;
  *) echo "apt-get stand-in: unexpected $*" >&2; exit 3 ;;
esac'
stub dpkg-query '[[ -e $STATE/installed-${*: -1} ]] && { printf "ii "; exit 0; }; echo "dpkg-query: no packages found matching ${*: -1}" >&2; exit 1'
stub systemctl 'unit=${*: -1}
case $1 in
  is-enabled) [[ -e $STATE/$unit-enabled ]] ;;
  is-active) [[ -e $STATE/$unit-active ]] ;;
  enable|restart) echo "systemctl $*" >>"$CALLS"; touch "$STATE/$unit-enabled" "$STATE/$unit-active"
    [[ $unit == tailscaled ]] && echo "tailscaled starts with $(grep FLAGS= "$SETUP_ROOT/etc/default/tailscaled")" >>"$CALLS"; true ;;
  *) echo "systemctl stand-in: unexpected $*" >&2; exit 3 ;;
esac'
stub ufw 'case $1 in
  status) echo "Status: active"; echo; echo "To Action From"; cat "$STATE/ufw-rules" 2>/dev/null ;;
  allow) echo "ufw $*" >>"$CALLS"; printf "%-27s%-12sAnywhere\n" "$2" ALLOW >>"$STATE/ufw-rules" ;;
  *) echo "ufw stand-in: unexpected $*" >&2; exit 3 ;;
esac'
# sysctl -p <file> loads the file's keys into the pretend /proc.
stub sysctl '[[ $1 == -p ]] || { echo "sysctl stand-in: unexpected $*" >&2; exit 3; }
echo "sysctl $*" >>"$CALLS"
while IFS=" =" read -r key value; do
  [[ -n $key ]] && echo "$value" >"$SETUP_ROOT/proc/sys/${key//.//}"
done <"$SETUP_ROOT$2"'
# apply reads the Mac checkout's origin. The stand-in answers with a fixed one in
# the checkout's https form, since suite.sh runs the checks in a copy with no remote.
stub git 'dir=; while [[ $1 == -C || $1 == -c ]]; do [[ $1 == -C ]] && dir=$2; shift 2; done
case $1 in
  remote) [[ $* == "remote get-url origin" ]] || { echo "git stand-in: unexpected $*" >&2; exit 3; }
    echo "https://github.com/Sarb0Z/colloid-swarm.git" ;;
  clone) echo "git clone ${*: -1} USER=$USER LOGNAME=$LOGNAME PWD=$PWD XDG=${XDG_RUNTIME_DIR:-unset}" >>"$CALLS"; mkdir -p "${*: -1}/.git"; echo none >"${*: -1}/.git/sha" ;;
  rev-parse) cat "$dir/.git/sha" ;;
  checkout) echo "git -C $dir checkout ${*: -1}" >>"$CALLS"; echo "${*: -1}" >"$dir/.git/sha" ;;
  config)
    [[ $2 == --global ]] || { echo "git stand-in: unexpected $*" >&2; exit 3; }
    if [[ $3 == --get ]]; then
      sed -n "s/^$4=//p" "$HOME/.gitconfig" 2>/dev/null | grep . || exit 1
    else
      echo "git config --global $3 $4 HOME=$HOME USER=$USER" >>"$CALLS"
      { grep -v "^$3=" "$HOME/.gitconfig" 2>/dev/null; echo "$3=$4"; } >"$HOME/.gitconfig.new"
      mv "$HOME/.gitconfig.new" "$HOME/.gitconfig"
    fi ;;
  *) echo "git stand-in: unexpected $*" >&2; exit 3 ;;
esac'
stub ss '[[ -e $STATE/et-active ]] && echo "LISTEN 0 4096 0.0.0.0:2022 0.0.0.0:*"; true'
if ! command -v tmux >/dev/null; then
  stub tmux 'true'
  echo "skip loading tmux.conf into a real tmux (no tmux on PATH)"
fi
export PATH=$T/bin:$PATH

# A pretend server: what contabo-hop held on 2026-11-16, reduced to what the script reads.
BASHRC='# ~/.bashrc
case $- in
    *i*) ;;
      *) return;;
esac
export KEEP_ME=1'
# Ubuntu's ~/.profile, reduced to the line that reads ~/.bashrc.
PROFILE='if [ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi'
LOADER='# bash reads this file instead of ~/.profile at login, so it loads ~/.profile
[ -f ~/.profile ] && . ~/.profile'
fresh() { # folder
  local r=$1 h=$1/home/openclawops
  rm -rf "$r" "$STATE"
  mkdir -p "$STATE" "$r/etc/apt/sources.list.d" "$r/etc/ufw" "$r/etc/sysctl.d" "$r/root" "$r/usr/sbin" "$h/.ssh" "$h/.claude" "$h/.local/bin" \
    "$r/proc/sys/net/ipv4" "$r/proc/sys/net/ipv6/conf/all"
  # contabo-hop on 2026-11-18: Docker's IPv4 forwarding on, IPv6 forwarding off.
  echo 1 >"$r/proc/sys/net/ipv4/ip_forward"
  echo 0 >"$r/proc/sys/net/ipv6/conf/all/forwarding"
  mkdir -p "$r/etc/default"
  printf 'IPV6=yes\nDEFAULT_INPUT_POLICY="DROP"\nDEFAULT_FORWARD_POLICY="DROP"\n' >"$r/etc/default/ufw"
  printf 'PRETTY_NAME="Ubuntu 24.04.4 LTS"\nVERSION_CODENAME=noble\n' >"$r/etc/os-release"
  echo "Types: deb" >"$r/etc/apt/sources.list.d/ubuntu.sources"
  echo "### tuple ### limit tcp 22 0.0.0.0/0 any 0.0.0.0/0 in" >"$r/etc/ufw/user.rules"
  echo "### tuple ### limit tcp 22 ::/0 any ::/0 in" >"$r/etc/ufw/user6.rules"
  echo "22/tcp                     LIMIT       Anywhere" >"$STATE/ufw-rules"
  printf '%s\n' "$BASHRC" >"$h/.bashrc"
  printf '%s\n' "$PROFILE" >"$h/.profile"
  echo '{"note": "uzair login, must stay"}' >"$h/.claude/settings.json"
  # Claude Code made an empty ~/.bash_profile where none existed on contabo-hop, at
  # the update (2026-11-16) and again at a first sign-in after it was removed
  # (2026-11-17), so the stand-in does too.
  printf '#!/usr/bin/env bash\ncase $1 in\n  --version) echo "$(cat "$STATE/claude-version" 2>/dev/null || echo 2.1.207) (Claude Code)" ;;\n  update) echo "claude update HOME=$HOME USER=$USER CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR" >>"$CALLS"; echo %s >"$STATE/claude-version"; [ -e "$HOME/.bash_profile" ] || : >"$HOME/.bash_profile" ;;\nesac\n' \
    "$MAC_VERSION" >"$h/.local/bin/claude"
  chmod +x "$h/.local/bin/claude"
  : >"$CALLS"
}
B=$T/bundle
mkdir -p "$B" "$T/roothome" "$T/tmpd"
cp "$HERE/setup-server.sh" "$HERE/tmux.conf" "$HERE/launchers.bash" "$HERE/settings.json" "$HERE/github-known-hosts" "$HERE/tailscale-archive-keyring.asc" "$B/"
echo "$MAC_VERSION" >"$B/claude-version"
echo "$KEY" >"$B/mac.pub"
R=$T/root
H=$R/home/openclawops
run() { (cd / && SETUP_ROOT=$R HOME=$T/roothome TMPDIR=$T/tmpd bash "$B/setup-server.sh" "$@"); }

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
  "enable and start the et service" "ufw allow 2022/tcp" "write openclawops's ~/.tmux.conf" \
  "check out tmux-resurrect at e87d7d592cac" "check out tmux-continuum at 46e0e0023476" \
  "write the account launchers" "make ~/.claude-work" "make ~/.claude-guest" \
  "write ~/.claude-family/settings.json" "update Claude Code from 2.1.207 to at least the Mac's $MAC_VERSION" \
  "install ripgrep fd-find neovim" "link fd to fdfind" "set openclawops's git identity to Sarb0z <93070907+Sarb0Z@users.noreply.github.com>" \
  "add GitHub's published host key" "make openclawops's ~/Projects" \
  "install Tailscale's apt signing key" "list Tailscale's apt repository" "apt-get update, to fetch Tailscale's package list" \
  "install tailscale" "set FLAGS=\"--no-logs-no-support\"" "enable and start the tailscaled service" \
  "write /etc/sysctl.d/99-tailscale.conf" "ufw allow 41641/udp"; do
  has "check lists: $line" "would: $line" "$out"
done
has "check counts every change" "check: 33 change(s) to make; nothing was changed" "$out"
eq "check leaves the server unchanged" "$before" "$(tree "$R")"
eq "check calls nothing that changes state" "" "$(cat "$CALLS")"
eq "check leaves no tmux socket or scratch folder" "" "$(find "$T/tmpd" -mindepth 1)"

# --- a run makes every change ---------------------------------------------------
out=$(run "$B/mac.pub" 2>&1); rc=$?
eq "run exits 0" 0 "$rc"
calls=$(cat "$CALLS")
has "run adds the PPA" "add-apt-repository -y ppa:jgmath2000/et" "$calls"
has "run installs et with its start held and needrestart suspended" \
  "apt-get install -y et policy-rc.d=101 NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive" "$calls"
[[ ! -e $R/usr/sbin/policy-rc.d ]] && ok "run removes its policy-rc.d" || bad "policy-rc.d left behind"
has "run starts et itself, after telemetry is off" "systemctl enable --now et" "$calls"
lacks "run does not restart et" "systemctl restart" "$calls"
has "run opens 2022 without a rate limit" "ufw allow 2022/tcp" "$calls"
has "run shows the packages before installing" "Inst libprotobuf32t64" "$out"
has "run shows what apt set up" "Setting up et (7.1.1-noble1)" "$out"
eq "authorized_keys holds the key" "$KEY" "$(cat "$H/.ssh/authorized_keys")"
eq "authorized_keys mode" "-rw-------" "$(mode "$H/.ssh/authorized_keys")"
eq "et.cfg telemetry off" "telemetry = false" "$(grep telemetry "$R/etc/et.cfg")"
cmp -s "$HERE/tmux.conf" "$H/.tmux.conf" && ok "tmux.conf installed as shipped" || bad "tmux.conf differs"
eq "resurrect pinned" "$PIN_RESURRECT" "$(cat "$H/.tmux/plugins/tmux-resurrect/.git/sha")"
eq "continuum pinned" "$PIN_CONTINUUM" "$(cat "$H/.tmux/plugins/tmux-continuum/.git/sha")"
has "git runs as openclawops, from its home, without root's runtime folder" \
  "USER=openclawops LOGNAME=openclawops PWD=$H XDG=unset" "$calls"
eq "bashrc keeps its own lines" "export KEEP_ME=1" "$(grep KEEP_ME "$H/.bashrc")"
eq "bashrc holds the launcher block once" 1 "$(count "$(head -n 1 "$HERE/launchers.bash")" "$H/.bashrc")"
for a in work personal family guest; do
  if cmp -s "$HERE/settings.json" "$H/.claude-$a/settings.json"; then
    eq "settings for $a, mode" "-rw-------" "$(mode "$H/.claude-$a/settings.json")"
  else
    bad "settings for $a differ"
  fi
  eq "folder for $a, mode" "drwx------" "$(mode "$H/.claude-$a")"
done
eq "the login in ~/.claude is untouched" '{"note": "uzair login, must stay"}' "$(cat "$H/.claude/settings.json")"
has "update runs in the work folder as openclawops" \
  "claude update HOME=$H USER=openclawops CLAUDE_CONFIG_DIR=$H/.claude-work" "$calls"
bk=$R/root/backups/unit5-$(date +%Y%m%d)
cmp -s "$bk/home/openclawops/.bashrc" <(printf '%s\n' "$BASHRC") && ok "bashrc backed up before its change" || bad "bashrc backup"
[[ -f $bk/etc/ufw/user.rules && -f $bk/ufw-status.txt && -d $bk/etc/apt/sources.list.d ]] &&
  ok "firewall and apt sources backed up" || bad "firewall or apt backup missing"
[[ -f $bk/apt-get-install.log && -f $bk/add-apt-repository.log ]] && ok "apt's output is kept in the backup folder" ||
  bad "apt logs missing"
has "run names the backup folder" "backups: /root/backups/unit5-" "$out"
eq "run makes the empty ~/.bash_profile the update left load ~/.profile" \
  "$(printf '%s\n' "$LOADER")" "$(cat "$H/.bash_profile")"
[[ -f $bk/home/openclawops/.bash_profile ]] && ok "the empty ~/.bash_profile is backed up" || bad ".bash_profile backup missing"
has "run reports it" "do:    make openclawops's ~/.bash_profile load ~/.profile" "$out"
eq "a login shell then has the launchers" "claudef" \
  "$(env -i HOME="$H" PATH=/usr/bin:/bin bash --login -i -c 'type -t claudef >/dev/null && echo claudef' 2>/dev/null </dev/null)"
has "run installs the tools with needrestart suspended" \
  "apt-get install -y ripgrep fd-find neovim policy-rc.d=none NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive" "$calls"
[[ -f $bk/apt-get-install-tools.log ]] && ok "the tools' apt output is kept in the backup folder" || bad "tools apt log missing"
eq "fd names fdfind" /usr/bin/fdfind "$(readlink "$H/.local/bin/fd")"
has "git identity is set as openclawops, in its home" \
  "git config --global user.email 93070907+Sarb0Z@users.noreply.github.com HOME=$H USER=openclawops" "$calls"
eq "git identity" "user.name=Sarb0z user.email=93070907+Sarb0Z@users.noreply.github.com" "$(tr '\n' ' ' <"$H/.gitconfig" | sed 's/ $//')"
eq "known_hosts pins GitHub's key" "$(cat "$HERE/github-known-hosts")" "$(cat "$H/.ssh/known_hosts")"
eq "known_hosts mode" "-rw-------" "$(mode "$H/.ssh/known_hosts")"
[[ -d $H/Projects ]] && ok "the Projects folder exists" || bad "the Projects folder is missing"
cmp -s "$HERE/tailscale-archive-keyring.asc" "$R/usr/share/keyrings/tailscale-archive-keyring.asc" &&
  ok "Tailscale's key is installed as shipped" || bad "Tailscale's key differs"
eq "Tailscale's repository is listed, signed by that key" \
  "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.asc] https://pkgs.tailscale.com/stable/ubuntu noble main" \
  "$(cat "$R/etc/apt/sources.list.d/tailscale.list")"
has "run fetches Tailscale's lists after listing the repository" "apt-get update" "$calls"
has "run installs tailscale without the keyring package, its start held and needrestart suspended" \
  "apt-get install -y --no-install-recommends tailscale policy-rc.d=101 NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive" "$calls"
[[ ! -e $R/usr/sbin/policy-rc.d ]] && ok "run removes its policy-rc.d after both installs" || bad "policy-rc.d left behind"
eq "the list is written before the update that makes tailscale installable" 1 \
  "$(grep -c 'apt-get install -y --no-install-recommends tailscale' "$CALLS")"
has "tailscaled first starts with its logs off" "tailscaled starts with FLAGS=\"--no-logs-no-support\"" "$calls"
has "run shows what apt set up for tailscale" "Setting up tailscale (1.90.6)" "$out"
eq "tailscaled uploads no logs" 'FLAGS="--no-logs-no-support"' "$(grep '^FLAGS=' "$R/etc/default/tailscaled")"
eq "tailscaled keeps its port line" 'PORT="41641"' "$(grep '^PORT=' "$R/etc/default/tailscaled")"
has "run starts tailscaled itself, after its flags are set" "systemctl enable --now tailscaled" "$calls"
eq "forwarding is kept across reboots" "$(printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1')" \
  "$(cat "$R/etc/sysctl.d/99-tailscale.conf")"
has "run loads the forwarding file" "sysctl -p /etc/sysctl.d/99-tailscale.conf" "$calls"
eq "IPv6 forwarding is on" 1 "$(cat "$R/proc/sys/net/ipv6/conf/all/forwarding")"
has "run opens Tailscale's port" "ufw allow 41641/udp" "$calls"
[[ -f $bk/apt-get-install-tailscale.log && -f $bk/etc/default/tailscaled ]] &&
  ok "tailscale's apt output and its first settings are kept in the backup folder" || bad "tailscale backups missing"

# --- a second run changes nothing -----------------------------------------------
after=$(tree "$R")
: >"$CALLS"
out=$(run "$B/mac.pub" 2>&1); rc=$?
eq "second run exits 0" 0 "$rc"
has "second run has nothing to change" "nothing to change" "$out"
eq "second run calls nothing that changes state" "" "$(cat "$CALLS")"
eq "second run leaves the server unchanged" "$after" "$(tree "$R")"

# --- settings Claude Code wrote since keep their keys ------------------------------
printf '{"model": "opus", "env": {"FOO": "1", "DISABLE_TELEMETRY": "0"}}\n' >"$H/.claude-work/settings.json"
out=$(run "$B/mac.pub" 2>&1); rc=$?
eq "merge run exits 0" 0 "$rc"
has "merge is reported" "merge the Mac's privacy settings into ~/.claude-work/settings.json" "$out"
eq "merge keeps other keys" "opus 1" "$(jq -r '"\(.model) \(.env.FOO)"' "$H/.claude-work/settings.json")"
eq "merge sets the privacy keys" "1 1" "$(jq -r '"\(.env.DISABLE_TELEMETRY) \(.env.DO_NOT_TRACK)"' "$H/.claude-work/settings.json")"
out=$(run "$B/mac.pub" 2>&1)
has "a merged file is left alone next time" "nothing to change" "$out"

# --- the launcher block is replaced in place --------------------------------------
cp "$HERE/launchers.bash" "$T/launchers.orig"
awk 'NR == 2 { print "# a changed line" } { print }' "$T/launchers.orig" >"$B/launchers.bash"
echo "export AFTER_BLOCK=1" >>"$H/.bashrc"
run "$B/mac.pub" >/dev/null 2>&1
eq "changed block written once" 1 "$(count "# a changed line" "$H/.bashrc")"
eq "still one block" 1 "$(count "$(head -n 1 "$HERE/launchers.bash")" "$H/.bashrc")"
eq "lines after the block stay" "export AFTER_BLOCK=1" "$(tail -n 1 "$H/.bashrc")"
cp "$T/launchers.orig" "$B/launchers.bash"
grep -vxF -- "$(tail -n 1 "$HERE/launchers.bash")" "$H/.bashrc" >"$T/rc" && cp "$T/rc" "$H/.bashrc"
before=$(cat "$H/.bashrc")
err=$(run "$B/mac.pub" 2>&1); rc=$?
[[ $rc -eq 1 && $err == *"first line but not its last"* ]] && ok "refuses a block without its last line" || bad "half block (rc=$rc): $err"
eq "a half block is left as it was" "$before" "$(cat "$H/.bashrc")"

# --- a key file without a final newline ------------------------------------------
fresh "$R"
printf 'ssh-ed25519 AAAAexisting other@host' >"$H/.ssh/authorized_keys"
run "$B/mac.pub" >/dev/null 2>&1
eq "an existing key line stays whole" 2 "$(wc -l <"$H/.ssh/authorized_keys" | tr -d ' ')"
eq "the Mac's key on its own line" "$KEY" "$(tail -n 1 "$H/.ssh/authorized_keys")"

# --- what the server already has for development is left alone ---------------------
fresh "$R"
touch "$STATE/installed-ripgrep" "$STATE/installed-neovim"
cp "$HERE/github-known-hosts" "$T/kh" && ssh-keygen -H -f "$T/kh" >/dev/null 2>&1 && cp "$T/kh" "$H/.ssh/known_hosts"
printf 'user.name=Sarb0z\nuser.email=93070907+Sarb0Z@users.noreply.github.com\n' >"$H/.gitconfig"
out=$(run --check "$B/mac.pub" 2>&1)
has "only the missing tool is installed" "would: install fd-find;" "$out"
lacks "a hashed GitHub entry counts as present" "GitHub's published host key" "$out"
lacks "a matching git identity is kept" "git identity" "$out"
echo "#!/bin/sh" >"$H/.local/bin/fd"
out=$(run "$B/mac.pub" 2>&1); rc=$?
eq "an fd that is not the link fails the run" 1 "$rc"
has "and is named" "PROBLEM: $H/.local/bin/fd exists and is not a link" "$out"
eq "that fd is left as it was" "#!/bin/sh" "$(cat "$H/.local/bin/fd")"

# --- the PPA is listed but apt never fetched it ------------------------------------
fresh "$R"
echo "URIs: https://ppa.launchpadcontent.net/jgmath2000/et/ubuntu/" >"$R/etc/apt/sources.list.d/jgmath2000-ubuntu-et-noble.sources"
out=$(run --check "$B/mac.pub" 2>&1)
has "check sees the missing lists" "would: apt-get update" "$out"
run "$B/mac.pub" >/dev/null 2>&1
calls=$(cat "$CALLS")
has "run fetches the lists" "apt-get update" "$calls"
lacks "run does not add the PPA twice" "add-apt-repository" "$calls"
has "run then installs" "apt-get install -y et" "$calls"

# --- an install that would upgrade a package stops --------------------------------
fresh "$R"
touch "$STATE/sim-upgrade"
err=$(run "$B/mac.pub" 2>&1); rc=$?
[[ $rc -eq 1 && $err == *"would upgrade or remove installed packages"*"libc6"* ]] &&
  ok "refuses an install that upgrades libc6" || bad "upgrade refusal (rc=$rc): $err"
lacks "nothing installed" "apt-get install" "$(cat "$CALLS")"
out=$(run --check "$B/mac.pub" 2>&1); rc=$?
[[ $rc -eq 1 && $out == *"PROBLEM: installing et would upgrade"* ]] && ok "check reports the upgrade as a problem" ||
  bad "check upgrade (rc=$rc): $out"

# --- Tailscale's settings and forwarding on a server that already has some ---------
for line in 'FLAGS="--state=/var/lib/x"' 'FLAGS=--state=/var/lib/x' "FLAGS='--x'" 'FLAGS="" # mine'; do
  fresh "$R"
  touch "$STATE/installed-tailscale" "$STATE/tailscaled-enabled" "$STATE/tailscaled-active"
  printf 'PORT="41641"\n%s\n' "$line" >"$R/etc/default/tailscaled"
  out=$(run "$B/mac.pub" 2>&1); rc=$?
  eq "a FLAGS line the operator filled fails the run: $line" 1 "$rc"
  has "and is named: $line" "PROBLEM: /etc/default/tailscaled has $line" "$out"
  eq "and is left as it was: $line" "$line" "$(grep 'FLAGS=' "$R/etc/default/tailscaled")"
  lacks "and tailscaled is not restarted: $line" "restart tailscaled" "$(cat "$CALLS")"
done
lacks "an installed tailscale is not installed again" "tailscale policy-rc.d" "$(cat "$CALLS")"
# A stopped tailscaled with the operator's FLAGS is not started with logs on.
fresh "$R"
touch "$STATE/installed-tailscale"
printf 'PORT="41641"\nFLAGS="--x"\n' >"$R/etc/default/tailscaled"
out=$(run "$B/mac.pub" 2>&1)
lacks "a stopped tailscaled with the operator's FLAGS is not started" "enable --now tailscaled" "$(cat "$CALLS")"
lacks "and no start is reported" "enable and start the tailscaled service" "$out"
# The package's FLAGS="" on a running tailscaled: the check names the restart.
fresh "$R"
touch "$STATE/installed-tailscale" "$STATE/tailscaled-enabled" "$STATE/tailscaled-active"
printf 'PORT="41641"\nFLAGS=""\n' >"$R/etc/default/tailscaled"
out=$(run --check "$B/mac.pub" 2>&1)
has "check names the restart a FLAGS change brings" "would: restart tailscaled to read the new /etc/default/tailscaled" "$out"
run "$B/mac.pub" >/dev/null 2>&1
has "and the run restarts it" "systemctl restart tailscaled" "$(cat "$CALLS")"
# The same for et's telemetry line.
fresh "$R"
touch "$STATE/installed-et" "$STATE/et-enabled" "$STATE/et-active"
printf '[Debug]\ntelemetry = true\n' >"$R/etc/et.cfg"
out=$(run --check "$B/mac.pub" 2>&1)
has "check names the restart a telemetry change brings" "would: restart et to read the new /etc/et.cfg" "$out"
# Forwarding switched off at runtime is loaded again, and an older file is backed up.
fresh "$R"
echo 'net.ipv4.ip_forward = 1' >"$R/etc/sysctl.d/99-tailscale.conf"
run "$B/mac.pub" >/dev/null 2>&1
eq "an older forwarding file is backed up" 'net.ipv4.ip_forward = 1' "$(cat "$bk/etc/sysctl.d/99-tailscale.conf")"
eq "the forwarding before the change is kept for the rollback" \
  "$(printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 0')" "$(cat "$bk/forwarding-before.txt")"
echo 0 >"$R/proc/sys/net/ipv4/ip_forward"
out=$(run --check "$B/mac.pub" 2>&1)
has "forwarding switched off at runtime is loaded again" "would: write /etc/sysctl.d/99-tailscale.conf" "$out"
# A firewall that would let forwarded packets through stops the forwarding change.
for ufwdefaults in 'IPV6=yes\nDEFAULT_FORWARD_POLICY="ACCEPT"\n' 'IPV6=no\nDEFAULT_FORWARD_POLICY="DROP"\n'; do
  fresh "$R"
  printf "$ufwdefaults" >"$R/etc/default/ufw"
  out=$(run "$B/mac.pub" 2>&1); rc=$?
  eq "forwarding refused under ufw defaults $(printf "$ufwdefaults" | tr '\n' ' ')" 1 "$rc"
  has "and named" "PROBLEM: /etc/default/ufw must hold" "$out"
  lacks "and nothing forwards" "sysctl -p" "$(cat "$CALLS")"
  eq "and IPv6 forwarding stays off" 0 "$(cat "$R/proc/sys/net/ipv6/conf/all/forwarding")"
done
# A reinstall of an enabled tailscaled: its start is still held until FLAGS is set.
fresh "$R"
touch "$STATE/tailscaled-was-enabled"
run "$B/mac.pub" >/dev/null 2>&1
has "a reinstall's start is held" "apt-get install -y --no-install-recommends tailscale policy-rc.d=101" "$(cat "$CALLS")"
has "and the script starts it only after FLAGS is set" "tailscaled starts with FLAGS=\"--no-logs-no-support\"" "$(cat "$CALLS")"

# --- an existing policy-rc.d is not replaced ---------------------------------------
fresh "$R"
printf '#!/bin/sh\nexit 0\n' >"$R/usr/sbin/policy-rc.d"
err=$(run "$B/mac.pub" 2>&1); rc=$?
[[ $rc -eq 1 && $err == *"policy-rc.d already exists"* ]] && ok "refuses to replace a policy-rc.d" || bad "policy-rc.d (rc=$rc): $err"
eq "the existing policy-rc.d stays" "exit 0" "$(tail -n 1 "$R/usr/sbin/policy-rc.d")"

# --- ~/.bash_profile, which bash reads before ~/.profile ------------------------------
# bash runs only the first of ~/.bash_profile, ~/.bash_login, ~/.profile, so the
# launchers in ~/.bashrc load only if ~/.bash_profile reaches ~/.profile or ~/.bashrc.
fresh "$R"
echo 'export OWN=1' >"$H/.bash_profile"
out=$(run "$B/mac.pub" 2>&1); rc=$?
eq "a .bash_profile that skips .profile fails the run" 1 "$rc"
has "the failure names the file" "PROBLEM: $H/.bash_profile" "$out"
eq "that .bash_profile is left as it was" "export OWN=1" "$(cat "$H/.bash_profile")"
fresh "$R"
echo '[ -f ~/.profile ] && . ~/.profile' >"$H/.bash_profile"
out=$(run "$B/mac.pub" 2>&1); rc=$?
eq "a .bash_profile that reads .profile passes" 0 "$rc"
eq "that .bash_profile is left as it was" '[ -f ~/.profile ] && . ~/.profile' "$(cat "$H/.bash_profile")"
lacks "and nothing is said about it" ".bash_profile" "$out"
# The same two lines written by hand pass as they stand.
fresh "$R"
printf '%s\n' "$LOADER" >"$H/.bash_profile"
out=$(run "$B/mac.pub" 2>&1); rc=$?
eq "the shipped loader passes unchanged" "$(printf '%s\n' "$LOADER")" "$(cat "$H/.bash_profile")"
lacks "and is not rewritten" "~/.bash_profile load" "$out"

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
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$T/et-agent"
mkdir -p "$T/lh/.ssh"
HOME=$T/lh SSH_AUTH_SOCK=$T/et-agent bash -c "source '$L'"
eq "a login with et's agent socket points ~/.ssh/agent.sock at it" "$T/et-agent" "$(readlink "$T/lh/.ssh/agent.sock")"
HOME=$T/lh SSH_AUTH_SOCK=$T/lh/.ssh/agent.sock bash -c "source '$L'"
eq "a tmux window, already on the fixed path, leaves it" "$T/et-agent" "$(readlink "$T/lh/.ssh/agent.sock")"
rm "$T/lh/.ssh/agent.sock"
HOME=$T/lh bash -c "unset SSH_AUTH_SOCK; source '$L'"
[[ ! -e $T/lh/.ssh/agent.sock && ! -L $T/lh/.ssh/agent.sock ]] && ok "a login with no agent links nothing" || bad "agent link without an agent"
grep -qx 'set-environment -g SSH_AUTH_SOCK "$HOME/.ssh/agent.sock"' "$HERE/tmux.conf" &&
  ! grep -E '^set -g update-environment' "$HERE/tmux.conf" | grep -q SSH_AUTH_SOCK &&
  ok "tmux windows read the fixed agent path, and an attach does not replace it" || bad "tmux agent path"

# --- apply, end to end with ssh replaced by a local shell --------------------------
if [[ $(uname) == Darwin ]]; then
  AH=$T/machome
  mkdir -p "$AH/.ssh"
  echo "$KEY" >"$AH/.ssh/id_ed25519.pub"
  stub claude "echo '$MAC_VERSION (Claude Code)'"
  # contabo-dev answers "test -d" from $STATE/cloned; a clone needs a forwarded
  # agent (-A) and GitHub's yes, which $STATE/github-refuses withholds.
  stub ssh 'case $1 in
  contabo-hop) echo "ssh $1" >>"$CALLS"; tee "$STATE/sent.tar" | bash -c "$2" ;;
  contabo-dev) echo "ssh $1 ${2%% *}" >>"$CALLS"; [[ -e $STATE/cloned ]] ;;
  -A) echo "ssh -A $2 $3 SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-unset}" >>"$CALLS"
    [[ -e $STATE/github-refuses ]] && { echo "git@github.com: Permission denied (publickey)." >&2; exit 128; }
    touch "$STATE/cloned" ;;
  *) echo "ssh stand-in: unexpected $*" >&2; exit 3 ;;
esac'
  stub ssh-agent 'if [[ $1 == -k ]]; then echo "ssh-agent -k" >>"$CALLS"; else echo "SSH_AUTH_SOCK=/agent.sock; export SSH_AUTH_SOCK; SSH_AGENT_PID=1; export SSH_AGENT_PID;"; fi'
  stub ssh-add 'echo "ssh-add $*" >>"$CALLS"'
  slug=Sarb0Z/colloid-swarm
  fresh "$R"
  before=$(tree "$R")
  out=$(HOME=$AH SETUP_ROOT=$R TMPDIR=$T/tmpd "$HERE/apply" --check 2>&1); rc=$?
  eq "apply --check exits 0" 0 "$rc"
  has "apply --check runs the check on the server" "check: 33 change(s) to make; nothing was changed" "$out"
  has "apply sends the Mac's version" "to at least the Mac's $MAC_VERSION" "$out"
  has "apply --check names the clone" "would: clone git@github.com:$slug.git into openclawops' ~/Projects/colloid-swarm" "$out"
  eq "apply --check changes nothing" "$before" "$(tree "$R")"
  eq "apply --check logs in to contabo-hop, then only looks on contabo-dev" \
    "ssh contabo-hop|ssh contabo-dev test" "$(paste -sd'|' "$CALLS")"
  eq "apply sends no macOS file tags, which GNU tar warns about" 0 \
    "$(LC_ALL=C grep -a -c 'LIBARCHIVE\.xattr' "$STATE/sent.tar")"
  : >"$CALLS"
  out=$(HOME=$AH SETUP_ROOT=$R TMPDIR=$T/tmpd "$HERE/apply" 2>&1); rc=$?
  eq "apply exits 0" 0 "$rc"
  calls=$(cat "$CALLS")
  has "apply adds the Mac's private key to a throwaway agent" "ssh-add -q $AH/.ssh/id_ed25519" "$calls"
  has "apply clones as openclawops with that agent forwarded" \
    "ssh -A contabo-dev git clone -q git@github.com:$slug.git ~/Projects/colloid-swarm SSH_AUTH_SOCK=/agent.sock" "$calls"
  has "apply stops the agent" "ssh-agent -k" "$calls"
  : >"$CALLS"
  out=$(HOME=$AH SETUP_ROOT=$R TMPDIR=$T/tmpd "$HERE/apply" 2>&1); rc=$?
  eq "a second apply exits 0" 0 "$rc"
  has "a second apply finds the clone" "colloid-swarm is already in ~/Projects/colloid-swarm" "$out"
  lacks "and clones nothing" "ssh -A" "$(cat "$CALLS")"
  rm "$STATE/cloned"
  touch "$STATE/github-refuses"
  err=$(HOME=$AH SETUP_ROOT=$R TMPDIR=$T/tmpd "$HERE/apply" 2>&1); rc=$?
  [[ $rc -eq 1 && $err == *"GitHub refused the clone"*"gh ssh-key add $AH/.ssh/id_ed25519.pub"* ]] &&
    ok "a clone GitHub refuses says which key to add" || bad "refused clone (rc=$rc): $err"
  err=$(HOME=$AH "$HERE/apply" --bogus 2>&1); rc=$?
  eq "apply refuses an unknown option" 2 "$rc"
  rm "$T/bin/claude" "$T/bin/ssh" "$T/bin/ssh-agent" "$T/bin/ssh-add"
else
  echo "skip apply end to end (macOS tar flags; apply runs on the Mac)"
fi

((fails == 0)) && echo "server tests passed" || {
  echo "$fails failed" >&2
  exit 1
}
