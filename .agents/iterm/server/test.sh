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
gl() { "$REAL_GIT" config --file "$H/.gitconfig" --get "user.$1"; }

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
# A folder made by a real `git init` (it has .git/HEAD) goes to the real git.
export REAL_GIT
REAL_GIT=$(command -v git)
stub git 'orig=("$@"); dir=; while [[ $1 == -C || $1 == -c ]]; do [[ $1 == -C ]] && dir=$2; shift 2; done
if [[ -n $dir && -f $dir/.git/HEAD ]]; then exec "$REAL_GIT" "${orig[@]}"; fi
case $1 in
  remote) [[ $* == "remote get-url origin" ]] || { echo "git stand-in: unexpected $*" >&2; exit 3; }
    echo "https://github.com/Sarb0Z/colloid-swarm.git" ;;
  clone) echo "git clone ${*: -1} USER=$USER LOGNAME=$LOGNAME PWD=$PWD XDG=${XDG_RUNTIME_DIR:-unset}" >>"$CALLS"; mkdir -p "${*: -1}/.git"; echo none >"${*: -1}/.git/sha" ;;
  rev-parse) cat "$dir/.git/sha" ;;
  checkout) echo "git -C $dir checkout ${*: -1}" >>"$CALLS"; echo "${*: -1}" >"$dir/.git/sha" ;;
  config)
    [[ $2 == --global ]] || { echo "git stand-in: unexpected $*" >&2; exit 3; }
    if [[ $3 == --get ]]; then
      "$REAL_GIT" config --file "$HOME/.gitconfig" --get "$4"
    else
      echo "git config --global $3 $4 HOME=$HOME USER=$USER" >>"$CALLS"
      "$REAL_GIT" config --file "$HOME/.gitconfig" "$3" "$4"
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
  mkdir -p "$STATE" "$r/usr/bin" "$r/etc/apt/sources.list.d" "$r/etc/ufw" "$r/etc/sysctl.d" "$r/root" "$r/usr/sbin" "$h/.ssh" "$h/.claude" "$h/.local/bin" \
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
  # A service's checkout under ~/apps, with an ssh remote the script must not touch.
  mkdir -p "$h/apps/svc"
  "$REAL_GIT" -C "$h/apps/svc" init -q
  "$REAL_GIT" -C "$h/apps/svc" remote add origin git@github.com:OwnerOne/svc.git
  echo "service code" >"$h/apps/svc/app.js"
  # The helper's tools and gh, present where the script looks for them; gh is
  # logged in only while $STATE/gh-login exists.
  : >"$r/usr/bin/jq"
  : >"$r/usr/bin/getent"
  chmod +x "$r/usr/bin/jq" "$r/usr/bin/getent"
  printf '#!/bin/sh\n[ "$1 $2" = "auth status" ] && [ -e "%s/gh-login" ]\n' "$STATE" >"$r/usr/bin/gh"
  chmod +x "$r/usr/bin/gh"
  # Claude Code made an empty ~/.bash_profile where none existed on contabo-hop, at
  # the update (2026-11-16) and again at a first sign-in after it was removed
  # (2026-11-17), so the stand-in does too.
  printf '#!/usr/bin/env bash\ncase $1 in\n  --version) echo "$(cat "$STATE/claude-version" 2>/dev/null || echo 2.1.207) (Claude Code)" ;;\n  update) echo "claude update HOME=$HOME USER=$USER CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR" >>"$CALLS"; echo %s >"$STATE/claude-version"; [ -e "$HOME/.bash_profile" ] || : >"$HOME/.bash_profile" ;;\nesac\n' \
    "$MAC_VERSION" >"$h/.local/bin/claude"
  chmod +x "$h/.local/bin/claude"
  : >"$CALLS"
}
# What only the Mac has, as a fixture: the device policy folder, one limited
# account's payload (named by a fixture email), the git identity registry and a
# skills folder. No real address is written here.
ACCT=someone@example.com
MACDEV=$T/macdev
MACSKILLS=$T/macskills
MACREG=$T/mac-git-identities.json
mkdir -p "$MACDEV/accounts" "$MACSKILLS/alpha/ref"
printf '%s\n' '{"appendSystemPrompt":"shared text","managedSettings":{"permissions":{"ask":["Artifact","Bash(git push:*)","Bash(gh pr create:*)"]}}}' >"$MACDEV/policy.json"
printf '%s\n' '{"appendSystemPrompt":"account text","managedSettings":{"deniedModels":["fable"],"permissions":{"ask":["Bash(git push:*)","Artifact"]}}}' >"$MACDEV/accounts/$ACCT.json"
printf '%s\n' '{"identities":{"Alpha":{"name":"Alpha","email":"someone@example.com","github_org":["OwnerOne","ownertwo"],"ssh_keys":["~/.ssh/k"]},"Beta":{"name":"Beta","email":"other@example.com","github_org":["Org3"],"ssh_keys":[]}}}' >"$MACREG"
printf '# alpha skill\n' >"$MACSKILLS/alpha/SKILL.md"
printf 'reference\n' >"$MACSKILLS/alpha/ref/notes.md"

B=$T/bundle
mkdir -p "$B/accounts" "$B/skills" "$T/roothome" "$T/tmpd"
cp "$HERE/setup-server.sh" "$HERE/tmux.conf" "$HERE/launchers.bash" "$HERE/settings.json" "$HERE/github-known-hosts" "$HERE/tailscale-archive-keyring.asc" \
  "$HERE/managed-settings.json" "$HERE/policy-helper.sh" "$HERE/server-asks.json" "$HERE/claude-statusline.sh" "$HERE/CLAUDE.md" \
  "$HERE/gitconfig-projects" "$HERE/colloid-diffview.lua" "$B/"
cp "$MACDEV/policy.json" "$B/policy.json"
cp "$MACDEV/accounts/$ACCT.json" "$B/accounts/"
cp "$HERE/../../claude/output-style.md" "$B/output-style.md"
jq '{identities: (.identities | map_values({name, email, github_org}))}' "$MACREG" >"$B/git-identities.json"
cp -R "$MACSKILLS/alpha" "$B/skills/alpha"
echo "$MAC_VERSION" >"$B/claude-version"
echo "$KEY" >"$B/mac.pub"
R=$T/root
H=$R/home/openclawops
run() { (cd / && SETUP_ROOT=$R HOME=$T/roothome TMPDIR=$T/tmpd bash "$B/setup-server.sh" "$@"); }

# --- syntax -------------------------------------------------------------------
for f in setup-server.sh apply launchers.bash test.sh claude-statusline.sh; do
  bash -n "$HERE/$f" && ok "bash -n $f" || bad "bash -n $f"
done
sh -n "$HERE/policy-helper.sh" && ok "sh -n policy-helper.sh" || bad "sh -n policy-helper.sh"
if command -v shellcheck >/dev/null; then
  shellcheck -S warning "$HERE/policy-helper.sh" >"$T/shellcheck.out" 2>&1 &&
    ok "shellcheck on the policy helper" || bad "shellcheck: $(cat "$T/shellcheck.out")"
fi

# --- --check changes nothing --------------------------------------------------
fresh "$R"
before=$(tree "$R")
apps_before=$(tree "$H/apps")
uzair_before=$(tree "$H/.claude")
remotes_before=$("$REAL_GIT" -C "$H/apps/svc" remote -v)
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
has "check counts every change" "check: 54 change(s) to make; nothing was changed" "$out"
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
# A launcher passes the clone's curated system prompt, and says so when the
# clone lacks it rather than failing to start.
mkdir -p "$T/fake-claude"
printf '#!/bin/sh\nprintf "%%s " "$@"\n' >"$T/fake-claude/claude"
chmod +x "$T/fake-claude/claude"
launch() { env -i HOME="$H" PATH="$T/fake-claude:/usr/bin:/bin" bash -c "source '$HERE/launchers.bash'; claudew -c" 2>&1; }
has "a launcher without the clone's prompt file says so" "this session gets Claude Code's default prompt" "$(launch)"
mkdir -p "$H/Projects/colloid-swarm/.agents/claude" && : >"$H/Projects/colloid-swarm/.agents/claude/system-prompt.md"
eq "a launcher passes the clone's prompt file" \
  "--system-prompt-file $H/Projects/colloid-swarm/.agents/claude/system-prompt.md -c " "$(launch)"
rm -rf "$H/Projects/colloid-swarm/.agents"
has "run installs the tools with needrestart suspended" \
  "apt-get install -y ripgrep fd-find neovim policy-rc.d=none NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive" "$calls"
[[ -f $bk/apt-get-install-tools.log ]] && ok "the tools' apt output is kept in the backup folder" || bad "tools apt log missing"
eq "fd names fdfind" /usr/bin/fdfind "$(readlink "$H/.local/bin/fd")"
has "git identity is set as openclawops, in its home" \
  "git config --global user.email 93070907+Sarb0Z@users.noreply.github.com HOME=$H USER=openclawops" "$calls"
eq "git identity" "Sarb0z 93070907+Sarb0Z@users.noreply.github.com" "$(gl name) $(gl email)"
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

# --- unit 2: policy, account settings, output style, status line, skills, CLAUDE.md ----
CC=$R/etc/claude-code
REPO_STYLE=$HERE/../../claude/output-style.md
cmp -s "$HERE/managed-settings.json" "$CC/managed-settings.json" && ok "managed-settings.json installed as shipped" || bad "managed-settings.json differs"
eq "managed-settings.json holds only the policy helper" '{"policyHelper":{"path":"/etc/claude-code/policy-helper.sh","timeoutMs":5000,"refreshIntervalMs":3600000}}' \
  "$(jq -c . "$CC/managed-settings.json")"
cmp -s "$HERE/policy-helper.sh" "$CC/policy-helper.sh" && ok "policy-helper.sh installed as shipped" || bad "policy-helper.sh differs"
eq "managed-settings.json mode" "-rw-r--r--" "$(mode "$CC/managed-settings.json")"
eq "policy-helper.sh mode" "-rwxr-xr-x" "$(mode "$CC/policy-helper.sh")"
eq "/etc/claude-code mode" "drwxr-xr-x" "$(mode "$CC")"
for f in "$CC" "$CC/managed-settings.json" "$CC/policy-helper.sh" "$CC/policy.json" "$CC/accounts/$ACCT.json"; do
  grep -qxF "chown root:root $f" "$CALLS" && ok "root owns ${f#"$R"}" || bad "root does not own ${f#"$R"}"
done
lacks "the user owns nothing under /etc/claude-code" "openclawops:openclawops $CC" "$calls"
# Acceptance 8: the helper's asks minus the Mac's are exactly the server-only asks.
asks_server=$(jq -r '.managedSettings.permissions.ask[]' "$CC/policy.json" | LC_ALL=C sort)
asks_mac=$(jq -r '.managedSettings.permissions.ask[]' "$MACDEV/policy.json" | LC_ALL=C sort)
eq "the server's asks minus the Mac's are the server-only list" "$(jq -r '.[]' "$HERE/server-asks.json" | LC_ALL=C sort)" \
  "$(comm -13 <(printf '%s\n' "$asks_mac") <(printf '%s\n' "$asks_server"))"
eq "the server's asks drop none of the Mac's" "" "$(comm -23 <(printf '%s\n' "$asks_mac") <(printf '%s\n' "$asks_server"))"
asks_acct=$(jq -r '.managedSettings.permissions.ask[]' "$CC/accounts/$ACCT.json" | LC_ALL=C sort)
eq "the account payload gets the server-only asks once" "$(jq -r '.[]' "$HERE/server-asks.json" | LC_ALL=C sort)" \
  "$(comm -13 <(jq -r '.managedSettings.permissions.ask[]' "$MACDEV/accounts/$ACCT.json" | LC_ALL=C sort) <(printf '%s\n' "$asks_acct"))"
eq "the account payload keeps its denied models" '["fable"]' "$(jq -c '.managedSettings.deniedModels' "$CC/accounts/$ACCT.json")"
eq "the policy keeps the system prompt text" "shared text" "$(jq -r .appendSystemPrompt "$CC/policy.json")"
for a in work personal family guest; do
  s=$H/.claude-$a/settings.json
  eq "settings for $a: model, effort, no output style (the device policy appends it), theme" "fable high null dark" "$(jq -r '"\(.model) \(.effortLevel) \(.outputStyle) \(.theme)"' "$s")"
  eq "settings for $a: fable 5.1 effort" xhigh "$(jq -r '.modelSettings["claude-fable-5-1"].effortLevel' "$s")"
  eq "settings for $a: ten hook events, each the iTerm2 hook with a 5 s timeout" "10 5" \
    "$(jq -r '"\(.hooks | length) \([.hooks[][0].hooks[0].timeout] | unique | join(","))"' "$s")"
  eq "settings for $a: status line" "bash ~/.local/bin/claude-statusline.sh" "$(jq -r .statusLine.command "$s")"
  eq "settings for $a: no plugins" null "$(jq -c '.enabledPlugins' "$s")"
  cmp -s "$REPO_STYLE" "$H/.claude-$a/output-styles/colloid.md" && ok "colloid output style in $a" || bad "output style differs in $a"
  cmp -s "$HERE/CLAUDE.md" "$H/.claude-$a/CLAUDE.md" && ok "server CLAUDE.md in $a" || bad "CLAUDE.md differs in $a"
  diff -r "$B/skills/alpha" "$H/.claude-$a/skills/alpha" >/dev/null && ok "skill alpha in $a" || bad "skill differs in $a"
done
cmp -s "$HERE/claude-statusline.sh" "$H/.local/bin/claude-statusline.sh" && ok "status line script installed" || bad "status line script differs"
eq "status line script mode" "-rwxr-xr-x" "$(mode "$H/.local/bin/claude-statusline.sh")"
eq "the status line labels the account from CLAUDE_PROFILE" GUEST \
  "$(echo '{"workspace":{"current_dir":"/"}}' | CLAUDE_PROFILE=guest bash "$H/.local/bin/claude-statusline.sh" | sed 's/\x1b\[[0-9;]*m//g' | head -n 1 | awk '{ print $2 }')"
eq "the status line reads the account from the transcript folder otherwise" FAMILY \
  "$(echo "{\"workspace\":{\"current_dir\":\"/\"},\"transcript_path\":\"$HOME/.claude-family/p/x.jsonl\"}" | env -u CLAUDE_PROFILE bash "$H/.local/bin/claude-statusline.sh" | sed 's/\x1b\[[0-9;]*m//g' | head -n 1 | awk '{ print $2 }')"
grep -E -q '[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$HERE/CLAUDE.md" &&
  ! grep -E -o '[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$HERE/CLAUDE.md" | grep -qvE '@users\.noreply\.github\.com$|^git@github\.com$' &&
  ok "CLAUDE.md names only the noreply address" || bad "CLAUDE.md carries another address"
# The shipped asks file is one array of strings.
eq "server-asks.json is an array of strings" true "$(jq 'type == "array" and all(.[]; type == "string")' "$HERE/server-asks.json")"

# Claude Code reads a single leading slash as relative to the settings source, so a
# path rule is absolute only with //, or starts at ~/ or **.
eq "every path rule in server-asks.json is absolute, home-relative or a glob" 0 \
  "$(jq -r '.[] | select(test("^(Read|Edit|Write)\\(")) | sub("^[A-Za-z]+\\("; "")' "$HERE/server-asks.json" | grep -cvE '^(//|~/|\*\*)')"

# --- the policy helper picks the account's payload ---------------------------------
HP=$T/hp
mkdir -p "$HP/accounts" "$T/hphome/.claude-guest" "$T/hphome/.claude-work" "$T/hpother"
cp "$CC/policy.json" "$HP/policy.json"
cp "$CC/accounts/$ACCT.json" "$HP/accounts/"
stub getent "echo \"openclawops:x:1000:1000::$T/hphome:/bin/bash\""
# The helper names /usr/bin/jq and /usr/bin/getent; the test machine's own stand in.
sed "s#/usr/bin/jq#$(command -v jq)#; s#/usr/bin/getent#$T/bin/getent#" "$HERE/policy-helper.sh" >"$HP/policy-helper.sh"
chmod +x "$HP/policy-helper.sh"
signin() { printf '{"oauthAccount":{"emailAddress":"%s"}}\n' "$2" >"$1/.claude.json"; }
helper() { env -i PATH=/usr/bin:/bin "$@" "$HP/policy-helper.sh"; }
signin "$T/hphome/.claude-guest" "Someone@Example.com"
signin "$T/hphome/.claude-work" "work@example.com"
signin "$T/hpother" "$ACCT"
eq "CLAUDE_CONFIG_DIR picks the account's payload, whatever the email's case" "account text" \
  "$(helper CLAUDE_CONFIG_DIR="$T/hphome/.claude-guest" | jq -r .appendSystemPrompt)"
eq "CLAUDE_PROFILE picks the profile folder from HOME" "account text" \
  "$(helper HOME="$T/hphome" CLAUDE_PROFILE=guest | jq -r .appendSystemPrompt)"
eq "without HOME the passwd entry's home is used" "account text" \
  "$(helper CLAUDE_PROFILE=guest | jq -r .appendSystemPrompt)"
eq "another account gets the shared policy" "shared text" \
  "$(helper HOME="$T/hphome" CLAUDE_PROFILE=work | jq -r .appendSystemPrompt)"
eq "a profile with no sign-in gets the shared policy" "shared text" \
  "$(helper HOME="$T/hphome" CLAUDE_PROFILE=family | jq -r .appendSystemPrompt)"
eq "an unknown profile name reads the home folder and gets the shared policy" "shared text" \
  "$(helper HOME="$T/hphome" CLAUDE_PROFILE=bogus | jq -r .appendSystemPrompt)"
signin "$T/hpother" "../$ACCT"
eq "an email with a slash is ignored" "shared text" "$(helper CLAUDE_CONFIG_DIR="$T/hpother" | jq -r .appendSystemPrompt)"
eq "a guest session's payload denies fable" '["fable"]' "$(helper CLAUDE_CONFIG_DIR="$T/hphome/.claude-guest" | jq -c .managedSettings.deniedModels)"
rm -f "$HP/policy.json"
helper CLAUDE_CONFIG_DIR="$T/hpother" >/dev/null 2>&1 && bad "a missing payload must fail the helper" || ok "a missing payload fails the helper"

# --- the server's checkout under ~/apps and uzair's login are untouched -----------------
eq "~/apps files and remotes are unchanged" "$apps_before" "$(tree "$H/apps")"
eq "~/apps remote is unchanged" "$remotes_before" "$("$REAL_GIT" -C "$H/apps/svc" remote -v)"
eq "the ~/.claude login is unchanged" "$uzair_before" "$(tree "$H/.claude")"

# --- a second run changes nothing -----------------------------------------------
after=$(tree "$R")
: >"$CALLS"
out=$(run "$B/mac.pub" 2>&1); rc=$?
eq "second run exits 0" 0 "$rc"
has "second run has nothing to change" "nothing to change" "$out"
eq "second run calls nothing that changes state" "" "$(cat "$CALLS")"
eq "second run leaves the server unchanged" "$after" "$(tree "$R")"

# --- settings Claude Code wrote since keep their keys ------------------------------
printf '{"model": "opus", "outputStyle": "colloid", "env": {"FOO": "1", "DISABLE_TELEMETRY": "0"}}\n' >"$H/.claude-work/settings.json"
out=$(run "$B/mac.pub" 2>&1); rc=$?
eq "merge run exits 0" 0 "$rc"
has "merge is reported" "merge the Mac's settings into ~/.claude-work/settings.json" "$out"
eq "merge keeps other keys" "opus 1" "$(jq -r '"\(.model) \(.env.FOO)"' "$H/.claude-work/settings.json")"
eq "merge sets the privacy keys" "1 1" "$(jq -r '"\(.env.DISABLE_TELEMETRY) \(.env.DO_NOT_TRACK)"' "$H/.claude-work/settings.json")"
out=$(run "$B/mac.pub" 2>&1)
has "a merged file is left alone next time" "nothing to change" "$out"
eq "merge keeps the model Claude Code wrote" opus "$(jq -r .model "$H/.claude-work/settings.json")"
eq "merge adds the keys the file lacked" "high dark" "$(jq -r '"\(.effortLevel) \(.theme)"' "$H/.claude-work/settings.json")"
eq "merge drops the output style the device policy already appends" null "$(jq -r .outputStyle "$H/.claude-work/settings.json")"

# --- the shipped hook replaces its own entries and keeps the others ---------------------
OLDHOOK='"$HOME/.iterm2/bin/it2" handle-agent-hook'
HANDHOOK='~/.iterm2/bin/it2 handle-agent-hook'
NEWHOOK=$(jq -r '.hooks.Stop[0].hooks[0].command' "$HERE/settings.json")
jq -n --arg h "$OLDHOOK" --arg g "$HANDHOOK" '{hooks: {Stop: [
    {hooks: [{type: "command", command: $h, timeout: 1}]},
    {hooks: [{type: "command", command: "mine"}]},
    {hooks: [{type: "command", command: $g}]}], Custom: [{matcher: "x"}],
    PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: "first"}, {type: "command", command: $h}, {type: "command", command: "last"}]}]},
    extraKey: 7}' >"$H/.claude-work/settings.json"
run "$B/mac.pub" >/dev/null 2>&1
s=$H/.claude-work/settings.json
eq "the older spellings collapse to one shipped hook, in place, with the shipped timeout" "$NEWHOOK#5|mine#0" \
  "$(jq -r '[.hooks.Stop[].hooks[0] | "\(.command)#\(.timeout // 0)"] | join("|")' "$s")"
eq "that Stop has two entries" 2 "$(jq '.hooks.Stop | length' "$s")"
eq "an entry with a matcher keeps its matcher and its other hooks, the shipped hook in the old one's place" \
  "Bash|first|$NEWHOOK|last" "$(jq -r '.hooks.PreToolUse[0] | "\(.matcher)|\(.hooks | map(.command) | join("|"))"' "$s")"
eq "and PreToolUse has no second entry" 1 "$(jq '.hooks.PreToolUse | length' "$s")"
eq "another event's own entries stay" '[{"matcher":"x"}]' "$(jq -c .hooks.Custom "$s")"
eq "a key of its own stays" 7 "$(jq .extraKey "$s")"
eq "the other eight events got the shipped hook once" "8" "$(jq '[.hooks | to_entries[] | select(.key != "Stop" and .key != "Custom" and .key != "PreToolUse") | .value | length] | add' "$s")"
before_hooks=$(jq -S . "$s")
out=$(run "$B/mac.pub" 2>&1)
has "a merged hook file is left alone next time" "nothing to change" "$out"
eq "and is byte for byte the same" "$before_hooks" "$(jq -S . "$s")"
# The shipped hook command never blocks or errors Claude Code.
mkdir -p "$T/hk/.iterm2/bin"
eq "without it2 the hook exits 0 quietly" "rc=0 err=" "$(HOME=$T/hk bash -c "$NEWHOOK" </dev/null 2>"$T/hk.err"; echo "rc=$? err=$(cat "$T/hk.err")")"
printf '#!/bin/sh\nexit 7\n' >"$T/hk/.iterm2/bin/it2"
chmod +x "$T/hk/.iterm2/bin/it2"
eq "an it2 that fails is reported on stderr and exits 0" "rc=0 err=it2 hook exit 7" "$(HOME=$T/hk bash -c "$NEWHOOK" </dev/null 2>"$T/hk.err"; echo "rc=$? err=$(cat "$T/hk.err")")"
printf '#!/bin/sh\ncat >"%s/hk.in"\n' "$T" >"$T/hk/.iterm2/bin/it2"
echo '{"x":1}' | HOME=$T/hk bash -c "$NEWHOOK"
eq "a working it2 gets the hook's input" '{"x":1}' "$(cat "$T/hk.in")"

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
printf '[user]\n\tname = Sarb0z\n\temail = 93070907+Sarb0Z@users.noreply.github.com\n' >"$H/.gitconfig"
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

# --- unit 4: git under ~/Projects, by owner ------------------------------------------
fresh "$R"
clone_of() { # folder origin
  mkdir -p "$1"
  "$REAL_GIT" -C "$1" init -q
  "$REAL_GIT" -C "$1" remote add origin "$2"
}
clone_of "$H/Projects/one" https://github.com/ownerone/x.git
clone_of "$H/Projects/Group/two" git@github.com:Org3/y.git
clone_of "$H/Projects/three" git@github.com:Unlisted/z.git
clone_of "$H/Projects/four" https://token@github.com/OwnerOne/w.git
"$REAL_GIT" -C "$H/Projects/four" config --local user.name Custom
clone_of "$H/Projects/five" ssh://git@github.com/ownertwo/v.git
"$REAL_GIT" -C "$H/Projects/five" config --local user.name Alpha
"$REAL_GIT" -C "$H/Projects/five" config --local user.email someone@example.com
clone_of "$H/Projects/six" https://example.org/OwnerOne/q.git
apps_before=$(tree "$H/apps")
remotes_before=$("$REAL_GIT" -C "$H/apps/svc" remote -v)
before=$(tree "$R")
out=$(run --check "$B/mac.pub" 2>&1)
has "check names a clone's identity change" "would: set the local git identity of /home/openclawops/Projects/one (name email)" "$out"
lacks "check leaves a clone whose identity matches" "Projects/five" "$out"
lacks "check leaves an owner the registry lacks" "Projects/three" "$out"
lacks "check leaves a remote that is not GitHub" "Projects/six" "$out"
eq "check left every clone unchanged" "$before" "$(tree "$R")"
out=$(run "$B/mac.pub" 2>&1); rc=$?
eq "the run exits 0" 0 "$rc"
gitc() { "$REAL_GIT" -C "$H/Projects/$1" config --local --get "user.$2" || echo unset; }
eq "owner matched whatever its case: name" Alpha "$(gitc one name)"
eq "owner matched whatever its case: email" someone@example.com "$(gitc one email)"
eq "an owner in a nested folder: name and email" "Beta other@example.com" "$(gitc Group/two name) $(gitc Group/two email)"
eq "an owner the registry lacks keeps the global identity" "unset unset" "$(gitc three name) $(gitc three email)"
eq "a different local name stays" Custom "$(gitc four name)"
has "and is named" "note: /home/openclawops/Projects/four keeps its own local user.name" "$out"
eq "its missing email is filled in" someone@example.com "$(gitc four email)"
eq "a matching local identity stays" "Alpha someone@example.com" "$(gitc five name) $(gitc five email)"
eq "a remote that is not GitHub is left alone" "unset" "$(gitc six name)"
eq "~/apps files and remotes are unchanged by unit 4" "$apps_before" "$(tree "$H/apps")"
eq "~/apps remote is unchanged by unit 4" "$remotes_before" "$("$REAL_GIT" -C "$H/apps/svc" remote -v)"
cmp -s "$HERE/gitconfig-projects" "$H/.gitconfig-projects" && ok "~/.gitconfig-projects installed as shipped" || bad ".gitconfig-projects differs"
gp=$(<"$H/.gitconfig-projects")
has "gh is the credential helper, after a reset" $'helper =\n\thelper = !/usr/bin/gh auth git-credential' "$gp"
has "scp-style remotes become https" "insteadOf = git@github.com:" "$gp"
has "ssh:// remotes become https" "insteadOf = ssh://git@github.com/" "$gp"
eq "the include is in ~/.gitconfig once" 1 "$(count '[includeIf "gitdir:~/Projects/"]' "$H/.gitconfig")"
eq "and points at the file" 1 "$(grep -c $'^\tpath = ~/.gitconfig-projects$' "$H/.gitconfig")"
eq "the global identity is unchanged" "Sarb0z 93070907+Sarb0Z@users.noreply.github.com" "$(gl name) $(gl email)"
eq "the include comes after the user block" '[includeIf "gitdir:~/Projects/"]' "$(grep -n . "$H/.gitconfig" | tail -n 2 | head -n 1 | cut -d: -f2-)"
after=$(tree "$R")
: >"$CALLS"
out=$(run "$B/mac.pub" 2>&1); rc=$?
eq "a second run exits 0" 0 "$rc"
has "a second run has nothing to change" "nothing to change" "$out"
eq "a second run leaves every clone and config as it was" "$after" "$(tree "$R")"
eq "the real git can read the include" "$H/.gitconfig" "$(HOME=$H "$REAL_GIT" config --show-origin --get-all includeif.gitdir:~/Projects/.path | cut -f1 | sed 's/^file://' | head -n 1)"
# Inside ~/Projects the credential helper and the rewrite apply; outside they do not.
eq "inside ~/Projects the https rewrite applies" "git@github.com:" \
  "$(cd "$H/Projects/one" && HOME=$H "$REAL_GIT" config --get-all url.https://github.com/.insteadof | head -n 1)"
eq "outside ~/Projects (the service checkout) it does not" "" \
  "$(cd "$H/apps/svc" && HOME=$H "$REAL_GIT" config --get-all url.https://github.com/.insteadof)"

# --- unit 3: pane scripts and diffview ----------------------------------------------
fresh "$R"
out=$(run "$B/mac.pub" 2>&1)
has "no clone: the links are skipped with a message" "skip:  no colloid-swarm clone in ~/Projects yet" "$out"
eq "no clone: nothing is linked" "" "$(find "$H/.local/bin" -name 'pane-*')"
eq "diffview is at the upstream pin" 4516612fe98ff56ae0415a259ff6361a89419b0a \
  "$(cat "$H/.local/share/nvim/site/pack/colloid/start/diffview.nvim/.git/sha")"
cmp -s "$HERE/colloid-diffview.lua" "$H/.config/nvim/plugin/colloid-diffview.lua" && ok "diffview's keys are installed where nvim has no config" || bad "diffview keys missing"
eq "the diffview folder is owned by the user" 1 "$(grep -c "^git clone $H/.local/share/nvim/site/pack/colloid/start/diffview.nvim USER=openclawops" "$CALLS")"
fresh "$R"
mkdir -p "$H/.config/nvim"
echo '-- my config' >"$H/.config/nvim/init.lua"
out=$(run "$B/mac.pub" 2>&1)
has "an nvim config of its own is named" "note: openclawops has a ~/.config/nvim of its own" "$out"
[[ ! -e $H/.config/nvim/plugin ]] && ok "and gets no file from the script" || bad "plugin file written into the user's nvim config"
eq "its init.lua is untouched" "-- my config" "$(cat "$H/.config/nvim/init.lua")"
fresh "$R"
mkdir -p "$H/Projects/colloid-swarm/.agents/iterm/bin"
printf '#!/bin/sh\n' >"$H/Projects/colloid-swarm/.agents/iterm/bin/pane-a"
printf '#!/bin/sh\n' >"$H/Projects/colloid-swarm/.agents/iterm/bin/pane-b"
chmod +x "$H/Projects/colloid-swarm/.agents/iterm/bin"/pane-*
printf 'mine\n' >"$H/.local/bin/pane-b"
out=$(run "$B/mac.pub" 2>&1); rc=$?
eq "a name that is not the script's link fails the run" 1 "$rc"
has "and is named" "PROBLEM: $H/.local/bin/pane-b exists and is not a link to /home/openclawops/Projects/colloid-swarm/.agents/iterm/bin/pane-b" "$out"
eq "that file is left as it was" mine "$(cat "$H/.local/bin/pane-b")"
eq "the other script is linked to the clone, by its server path" /home/openclawops/Projects/colloid-swarm/.agents/iterm/bin/pane-a \
  "$(readlink "$H/.local/bin/pane-a")"
rm "$H/.local/bin/pane-b"
out=$(run "$B/mac.pub" 2>&1); rc=$?
eq "with the name free the run passes" 0 "$rc"
eq "and links it" /home/openclawops/Projects/colloid-swarm/.agents/iterm/bin/pane-b "$(readlink "$H/.local/bin/pane-b")"
out=$(run "$B/mac.pub" 2>&1)
has "a rerun has nothing to change" "nothing to change" "$out"

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
# A staged file that is not JSON stops the run before anything is written.
for broken in policy.json accounts/$ACCT.json settings.json; do
  fresh "$R"
  cp "$B/$broken" "$T/keep.json"
  printf '{' >"$B/$broken"
  before=$(tree "$R")
  err=$(run "$B/mac.pub" 2>&1); rc=$?
  [[ $rc -eq 1 && $err == *"$broken is not valid JSON"* ]] && ok "a staged $broken that is not JSON stops the run" || bad "broken $broken (rc=$rc): $err"
  eq "and nothing under $R changed for $broken" "$before" "$(tree "$R")"
  [[ ! -e $R/etc/claude-code ]] && ok "and no /etc/claude-code exists for $broken" || bad "/etc/claude-code written for $broken"
  cp "$T/keep.json" "$B/$broken"
done
# The helper runs jq and getent by path.
fresh "$R"
rm "$R/usr/bin/getent"
err=$(run "$B/mac.pub" 2>&1); rc=$?
[[ $rc -eq 1 && $err == *"/usr/bin/jq and /usr/bin/getent must exist"* ]] && ok "a server without /usr/bin/getent is refused" || bad "getent (rc=$rc): $err"
# gh: a problem when missing, a note either way when present.
fresh "$R"
rm "$R/usr/bin/gh"
out=$(run "$B/mac.pub" 2>&1); rc=$?
eq "a missing gh fails the run" 1 "$rc"
has "and is named" "PROBLEM: /usr/bin/gh is missing" "$out"
fresh "$R"
out=$(run "$B/mac.pub" 2>&1); rc=$?
eq "gh present but logged out passes" 0 "$rc"
has "and says the operator logs in" "note: gh is not logged in for openclawops" "$out"
fresh "$R"
touch "$STATE/gh-login"
out=$(run "$B/mac.pub" 2>&1)
has "a logged-in gh is noted" "note: gh is logged in for openclawops" "$out"
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
  # A skill over 5 MB and one that links into a repository are not sent.
  head -c 5300000 /dev/zero >"$T/big.bin"
  mkdir -p "$MACSKILLS/big" "$T/skillrepo"
  mv "$T/big.bin" "$MACSKILLS/big/data.bin"
  "$REAL_GIT" -C "$T/skillrepo" init -q
  ln -s "$T/skillrepo" "$MACSKILLS/linked"
  ln -s ref/notes.md "$MACSKILLS/alpha/notes-link.md"
  export CLAUDE_DEVICE_DIR=$MACDEV GIT_IDENTITIES=$MACREG CLAUDE_SKILLS_DIR=$MACSKILLS
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
  has "apply --check runs the check on the server" "check: 54 change(s) to make; nothing was changed" "$out"
  has "apply sends the Mac's version" "to at least the Mac's $MAC_VERSION" "$out"
  has "apply --check names the clone" "would: clone git@github.com:$slug.git into openclawops' ~/Projects/colloid-swarm" "$out"
  eq "apply --check changes nothing" "$before" "$(tree "$R")"
  eq "apply --check logs in to contabo-hop, then only looks on contabo-dev" \
    "ssh contabo-hop|ssh contabo-dev test" "$(paste -sd'|' "$CALLS")"
  eq "apply sends no macOS file tags, which GNU tar warns about" 0 \
    "$(LC_ALL=C grep -a -c 'LIBARCHIVE\.xattr' "$STATE/sent.tar")"
  sent=$(tar -tf "$STATE/sent.tar" | sed 's#^\./##' | LC_ALL=C sort)
  for f in policy.json "accounts/$ACCT.json" output-style.md git-identities.json skills/alpha/SKILL.md skills/alpha/ref/notes.md \
    managed-settings.json policy-helper.sh server-asks.json claude-statusline.sh CLAUDE.md gitconfig-projects colloid-diffview.lua; do
    has "apply stages $f" "$f" "$sent"
  done
  lacks "apply sends no skill over 5 MB" "skills/big" "$sent"
  lacks "apply sends no skill that links into a repository" "skills/linked" "$sent"
  has "apply names the skill it skipped for size" "apply: skill big is" "$out"
  has "apply names the linked skill it skipped" "apply: skill linked is a link into a repository" "$out"
  eq "apply follows links inside a skill, sending the file" 0 "$(tar -tvf "$STATE/sent.tar" | grep 'notes-link.md' | grep -c '^l')"
  eq "apply sends the registry without key paths" 0 "$(tar -xOf "$STATE/sent.tar" ./git-identities.json | grep -c ssh_keys)"
  eq "apply sends the registry's names, emails and orgs" "2 2" \
    "$(tar -xOf "$STATE/sent.tar" ./git-identities.json | jq -r '"\(.identities | length) \([.identities[] | select(.email and .name and .github_org)] | length)"')"
  eq "apply sends the output style the repository holds" "$(cksum <"$REPO_STYLE")" "$(tar -xOf "$STATE/sent.tar" ./output-style.md | cksum)"
  : >"$CALLS"
  out=$(HOME=$AH SETUP_ROOT=$R TMPDIR=$T/tmpd "$HERE/apply" 2>&1); rc=$?
  eq "apply exits 0" 0 "$rc"
  calls=$(cat "$CALLS")
  has "apply adds the Mac's private key to a throwaway agent" "ssh-add -q $AH/.ssh/id_ed25519" "$calls"
  has "apply clones as openclawops with that agent forwarded" \
    "ssh -A contabo-dev GIT_CONFIG_GLOBAL=/dev/null git clone -q git@github.com:$slug.git ~/Projects/colloid-swarm SSH_AUTH_SOCK=/agent.sock" "$calls"
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

# --- push-product, with real rsync and git and ssh replaced by a local shell ----
# A product folder on a pretend Mac goes to a pretend server home ($SRV). The
# stand-ins above are left off PATH: this script runs git and rsync for real.
PM=$T/pmac
SRV=$T/psrv
mkdir -p "$PM/Projects/Acme/app" "$PM/Projects/Acme/infra/.terraform/providers" "$SRV/Projects" "$T/pbin"
app=$PM/Projects/Acme/app
"$REAL_GIT" -C "$app" init -q -b main
echo one >"$app/README.md"
printf '.env\nnode_modules/\n' >"$app/.gitignore"
"$REAL_GIT" -C "$app" add README.md .gitignore
"$REAL_GIT" -C "$app" -c user.name=t -c user.email=t@t commit -qm one
"$REAL_GIT" -C "$app" branch feature
echo SECRET=1 >"$app/.env"
chmod 644 "$app/.env"
echo wip >"$app/draft.md"
echo 'export class SingletonService {}' >"$app/SingletonService.ts"
"$REAL_GIT" -C "$app" config core.ignorecase true
# A linked worktree parked on a commit that no branch holds.
"$REAL_GIT" -C "$app" worktree add -q --detach .agents/worktrees/lane
echo lane >"$app/.agents/worktrees/lane/lane.md"
"$REAL_GIT" -C "$app/.agents/worktrees/lane" add lane.md
"$REAL_GIT" -C "$app/.agents/worktrees/lane" -c user.name=t -c user.email=t@t commit -qm lane
lane_sha=$("$REAL_GIT" -C "$app/.agents/worktrees/lane" rev-parse HEAD)
mkdir -p "$app/node_modules/dep" "$app/sub/.venv" "$app/sub/.mypy_cache"
touch "$app/node_modules/dep/index.js" "$app/sub/.venv/pyvenv.cfg" "$app/sub/.mypy_cache/x"
touch "$PM/Projects/Acme/notes.md" "$PM/Projects/Acme/.DS_Store" "$PM/Projects/Acme/infra/.terraform/providers/p" "$PM/Projects/Acme/infra/main.tf"
ln -s /var/folders/x/SingletonSocket "$PM/Projects/Acme/SingletonSocket"
"$REAL_GIT" init -q "$PM/Projects/Solo"
# The server's check reads stdin; with $STATE/tamper a branch appears in the
# staging copy first, as a write on the Mac part way through the copy would leave.
printf '#!/usr/bin/env bash\n%s\n' '[[ $1 == contabo-dev ]] || { echo "ssh stand-in: unexpected $*" >&2; exit 3; }
[[ -e $STATE/ssh-down ]] && exit 255
shift; echo "ssh ${1%% *}" >>"$CALLS"
if [[ $1 == "bash -c"* && -e $STATE/tamper ]]; then "$REAL_GIT" -C "$SRV/Projects/.Acme.incoming/app" branch -q stray; fi
cd "$SRV" && eval "$*"' >"$T/pbin/ssh"
chmod +x "$T/pbin/ssh"
push() { env HOME="$PM" SRV="$SRV" PATH="$T/pbin:${PATH#"$T/bin:"}" "$HERE/push-product" "$@" 2>&1; }
dst=$SRV/Projects/Acme
branches() { "$REAL_GIT" -C "$1" for-each-ref --format='%(refname)' | tr '\n' ' ' | sed 's/ $//'; }

out=$(push --check Acme); rc=$?
eq "push-product --check exits 0" 0 "$rc"
has "push-product --check counts the repositories and the commit to pin" "check: 1 repositories; 1 worktree commits to pin" "$out"
has "push-product --check says nothing changed" "check: the figures above are what a run would copy" "$out"
eq "push-product --check writes nothing on the server" "" "$(ls -A "$SRV/Projects")"

mac_before=$(tree "$PM")
: >"$CALLS"
out=$(push Acme); rc=$?
eq "push-product exits 0" 0 "$rc"
has "push-product names where the product landed" "done:  ~/Projects/Acme is on contabo-dev, 1 repositories matching the Mac's" "$out"
eq "a run logs in three times" 3 "$(grep -c '^ssh ' "$CALLS")"
[[ -f $dst/app/.env && -f $dst/app/draft.md && -f $dst/notes.md && -f $dst/infra/main.tf && -f $dst/app/SingletonService.ts ]] &&
  ok "the product arrives with its secret files, uncommitted work, notes and a source file named Singleton*" || bad "push-product left files behind: $(cd "$dst" 2>/dev/null && find . | sort | tr '\n' ' ')"
eq "the repository arrives with its branches, and the parked worktree's commit pinned" \
  "refs/heads/feature refs/heads/main refs/worktree-heads/lane" "$(branches "$dst/app")"
eq "the pin holds the worktree's commit" "$lane_sha" "$("$REAL_GIT" -C "$dst/app" rev-parse refs/worktree-heads/lane)"
eq "the repository arrives with its uncommitted files" "?? SingletonService.ts ?? draft.md" "$("$REAL_GIT" -C "$dst/app" status --short | tr '\n' ' ' | sed 's/ $//')"
eq "a secret file arrives readable by its owner alone" "-rw-------" "$(mode "$dst/app/.env")"
eq "the Mac's case-insensitive git setting is dropped on the server" "" "$("$REAL_GIT" -C "$dst/app" config --local --get core.ignorecase)"
left=$(cd "$dst" && find . \( -name node_modules -o -name .venv -o -name .mypy_cache -o -name .terraform -o -name .DS_Store -o -name SingletonSocket -o -path '*/.agents/worktrees' -o -path '*/.git/worktrees' \) | sort | tr '\n' ' ')
eq "dependencies, caches, providers, worktrees and lock links stay behind" "" "$left"
eq "no staging folder is left once the copy is renamed" "Acme" "$(ls -A "$SRV/Projects")"
eq "the Mac's copy is untouched" "$mac_before" "$(tree "$PM")"

echo changed-on-server >"$dst/notes.md"
out=$(push Acme); rc=$?
[[ $rc -eq 1 && $out == *"already on contabo-dev"* ]] && ok "a product already on the server is refused" || bad "second push (rc=$rc): $out"
eq "and work done there is kept" "changed-on-server" "$(<"$dst/notes.md")"

# A copy that stopped part way, after which the Mac deleted a branch and packed
# its refs: the resumed copy holds the Mac's refs, not the union of both states.
mv "$dst" "$SRV/Projects/.Acme.incoming"
rm "$SRV/Projects/.Acme.incoming/notes.md"
"$REAL_GIT" -C "$app" branch -q -D feature
"$REAL_GIT" -C "$app" pack-refs --all --prune
out=$(push Acme); rc=$?
eq "a copy that stopped part way resumes" 0 "$rc"
has "and says it resumed" "resume: an earlier copy stopped part way" "$out"
[[ -f $dst/notes.md && ! -e $SRV/Projects/.Acme.incoming ]] && ok "the resumed copy is completed and renamed" || bad "resume left: $(ls -A "$SRV/Projects")"
eq "a branch the Mac deleted does not come back" "refs/heads/main refs/worktree-heads/lane" "$(branches "$dst/app")"

# A write on the Mac during the copy: the copy stays in staging, and a rerun
# once it is quiet completes it.
mv "$dst" "$SRV/Projects/.Acme.incoming"
touch "$STATE/tamper"
out=$(push Acme); rc=$?
[[ $rc -eq 1 && $out == *"MISMATCH: app has other refs"* && $out == *"stop the sessions writing in"* ]] &&
  ok "refs that differ from the Mac's stop the rename" || bad "tampered copy (rc=$rc): $out"
[[ -d $SRV/Projects/.Acme.incoming && ! -e $dst ]] && ok "and the copy stays in staging" || bad "tampered copy left: $(ls -A "$SRV/Projects")"
rm "$STATE/tamper"
out=$(push Acme); rc=$?
eq "a rerun once the Mac is quiet completes the copy" 0 "$rc"
eq "without the stray branch" "refs/heads/main refs/worktree-heads/lane" "$(branches "$dst/app")"

# A worktree with uncommitted changes stops the run before anything is sent.
"$REAL_GIT" -C "$app" worktree add -q -b wip .agents/worktrees/dirty
echo edit >>"$app/.agents/worktrees/dirty/README.md"
: >"$CALLS"
out=$(push Acme); rc=$?
[[ $rc -eq 1 && $out == *"hold uncommitted changes"* && $out == *"Acme/app/.agents/worktrees/dirty"* ]] &&
  ok "a worktree with uncommitted changes stops the run and is named" || bad "dirty worktree (rc=$rc): $out"
eq "and nothing reaches the server" "" "$(cat "$CALLS")"

out=$(push Solo); rc=$?
[[ $rc -eq 1 && $out == *"is a repository, not a product folder"* ]] && ok "a repository is refused as a product" || bad "repository as product (rc=$rc): $out"
out=$(push ../etc); rc=$?
eq "a name with a path in it is refused" 2 "$rc"
out=$(push Nope); rc=$?
[[ $rc -eq 1 && $out == *"no folder"* ]] && ok "a missing product folder is named" || bad "missing folder (rc=$rc): $out"
touch "$STATE/ssh-down"
mkdir -p "$PM/Projects/Other"
out=$(push Other); rc=$?
[[ $rc -eq 1 && $out == *"could not log in to contabo-dev"* ]] && ok "a server it cannot reach is named" || bad "ssh down (rc=$rc): $out"
rm "$STATE/ssh-down"

((fails == 0)) && echo "server tests passed" || {
  echo "$fails failed" >&2
  exit 1
}
