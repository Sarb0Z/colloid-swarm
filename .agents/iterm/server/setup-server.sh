#!/usr/bin/env bash
# Make contabo-hop the development server: TERMINAL-SPEC.md Unit 5, runbook steps
# 1-5, and the development tools beside them; and the Mac's Tailscale exit node
# for the phone link (docs/notes/2026-11-17-phone-link-spec.md, Setup). It runs
# as root on the server; `apply` on the Mac sends it this folder, the
# Mac's public key and the Mac's Claude Code version over ssh, and runs it.
#
# Each step reads the current state and changes only what differs, so a second
# run changes nothing. Before its first change, a file is copied once into
# /root/backups/unit5-<date>/ under its own path. --check prints each change a
# run would make, and changes nothing.
#
# The server is live (web, Docker, GitMu):
# - apt runs with needrestart suspended, so an install restarts no service;
# - the install stops before it would upgrade or remove an installed package;
# - apt's output goes to a log in the backup folder, not to the ssh connection,
#   so a dropped connection cannot kill dpkg in the middle of configuring.
#
# Usage: setup-server.sh [--check] <public key file>
# Beside it: tmux.conf, launchers.bash, settings.json, github-known-hosts,
# tailscale-archive-keyring.asc, claude-version.
# SETUP_ROOT puts a folder in front of every absolute path; only the tests set it.
set -euo pipefail

check=0
if [[ ${1:-} == --check ]]; then
  check=1
  shift
fi
if (($# != 1)); then
  echo "usage: setup-server.sh [--check] <public key file>" >&2
  exit 2
fi
keyfile=$1
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
R=${SETUP_ROOT:-}
user=openclawops
home=$R/home/$user
backup=$R/root/backups/unit5-$(date +%Y%m%d)
accounts=(work personal family guest)
plugins=(
  tmux-resurrect:e87d7d592cac97fa38c12395ebec042c154a1844   # v4.0.0
  tmux-continuum:46e0e0023476018ddb4cc0d44783eede27e5a8ec   # v3.1.0
)
tools=(ripgrep fd-find neovim)
git_name=Sarb0z
git_email=93070907+Sarb0Z@users.noreply.github.com
changes=0
problems=0
cfg_changed=0
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 NEEDRESTART_MODE=l

die() {
  printf 'setup-server: %s\n' "$*" >&2
  exit 1
}
problem() {
  printf 'PROBLEM: %s\n' "$*" >&2
  problems=$((problems + 1))
}

# change <what>: count and print one change; true when it is to be made now.
change() {
  changes=$((changes + 1))
  if ((check)); then
    echo "would: $1"
    return 1
  fi
  echo "do:    $1"
}

# keep <path>: copy a file or folder into the backup before its first change.
keep() {
  local dest=$backup${1#"$R"}
  if [[ -e $1 && ! -e $dest ]]; then
    mkdir -p "$(dirname "$dest")"
    cp -a "$1" "$dest"
  fi
}

# logged <log name> <command...>: run with its output in the backup folder.
logged() {
  local log=$backup/$1.log
  shift
  mkdir -p "$backup"
  if ! "$@" >"$log" 2>&1; then
    tail -n 20 "$log" >&2
    die "$* failed; its full output is in ${log#"$R"}"
  fi
}

# runuser -u keeps root's environment, so the user's own names are set here.
as_user() {
  runuser -u "$user" -- env -u XDG_RUNTIME_DIR HOME="$home" USER="$user" LOGNAME="$user" "$@"
}
own() { chown "$user:$user" "$@"; }

# put <source> <destination> <mode> <what>: a file the server keeps as shipped.
put() {
  if [[ -f $2 ]] && cmp -s "$1" "$2"; then
    return 0
  fi
  if change "$4"; then
    keep "$2"
    cp "$1" "$2"
    chmod "$3" "$2"
    own "$2"
  fi
}

# A package dpkg does not know is reported on stderr; here that only means "absent".
installed() { [[ $(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null) == ii* ]]; }
have_ppa() { grep -rqF 'jgmath2000/et' "$R/etc/apt/sources.list.d"; }
# candidate <package>: apt has a version of it to install.
candidate() {
  local found
  found=$(apt-cache policy "$1" | awk '/Candidate:/ { print $2 }')
  [[ -n $found && $found != "(none)" ]]
}
older() { [[ $1 != "$2" && $(printf '%s\n' "$1" "$2" | sort -V | head -n 1) == "$1" ]]; }

# refuse_upgrades <package...>: show what apt would install, and stop (a problem
# under --check) when it would upgrade or remove an installed package.
refuse_upgrades() {
  local simulated touched
  simulated=$(apt-get -s install "$@" 2>&1) || die "apt cannot install $*: $simulated"
  grep -E '^Inst ' <<<"$simulated" | sed 's/^/         /' || true
  # "Inst name [installed version] (new version)" is an upgrade.
  touched=$(grep -E '^(Inst [^ ]+ \[|Remv )' <<<"$simulated" || true)
  [[ -n $touched ]] || return 0
  if ((check)); then
    problem "installing $* would upgrade or remove installed packages: $touched"
  else
    die "installing $* would upgrade or remove installed packages, so nothing is installed: $touched"
  fi
}

# install_held <log name> <package> [apt option...]: install a package whose
# postinst may start its service: et's does, and tailscale's does on a reinstall
# of a unit that was enabled. A policy-rc.d answering 101 stops that start, as
# Debian's deb-systemd-invoke reads it, so the first start is this script's,
# after the service's settings are written.
gate=$R/usr/sbin/policy-rc.d
install_held() {
  [[ ! -e $gate ]] || die "$gate already exists; this script will not replace it"
  trap 'rm -f "$gate"' EXIT
  printf '#!/bin/sh\nexit 101\n' >"$gate"
  chmod 755 "$gate"
  logged "$1" apt-get install -y "${@:3}" "$2"
  rm -f "$gate"
  trap - EXIT
  grep -E '^Setting up ' "$backup/$1.log" | sed 's/^/         /' || true
}

# service_up <unit> <settings changed: 0 or 1> <settings file> <what it runs>:
# start an enabled-and-running unit again only when its settings changed, and
# enable and start any other. systemctl reports a unit it does not know on
# stderr; here that only means "not enabled".
service_up() {
  if systemctl is-enabled --quiet "$1" 2>/dev/null && systemctl is-active --quiet "$1"; then
    if (($2)); then
      if change "restart $1 to read the new $3"; then
        systemctl restart "$1"
      fi
    fi
  elif change "enable and start the $1 service ($4)"; then
    systemctl enable --now "$1"
  fi
}

# ufw_allow <port/protocol> <why>: open a port once, the firewall backed up first.
# allow, not limit: ufw's limit rules count every port in one list per address,
# so a client retrying once a second would lock the Mac out of 22.
ufw_allow() {
  if grep -qE "^$1[[:space:]]+ALLOW" <<<"$(ufw status)"; then
    return 0
  fi
  if change "ufw allow $1 ($2)"; then
    keep "$R/etc/ufw/user.rules"
    keep "$R/etc/ufw/user6.rules"
    mkdir -p "$backup"
    if [[ ! -e $backup/ufw-status.txt ]]; then
      ufw status numbered >"$backup/ufw-status.txt"
    fi
    ufw allow "$1"
  fi
}

[[ $(id -u) == 0 ]] || die "run as root: apply logs in to contabo-hop as root"
grep -qx 'VERSION_CODENAME=noble' "$R/etc/os-release" ||
  die "expected Ubuntu 24.04 (noble), the release this script picks ppa:jgmath2000/et for"
[[ -d $home ]] || die "no home folder $home for $user"
command -v jq >/dev/null || die "jq is needed to merge settings.json"
for f in tmux.conf launchers.bash settings.json claude-version github-known-hosts tailscale-archive-keyring.asc; do
  [[ -f $here/$f ]] || die "missing $here/$f"
done
pub=$(<"$keyfile")
[[ $pub =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com)\ [A-Za-z0-9+/]+=*(\ [^[:cntrl:]]*)?$ ]] ||
  die "$keyfile is not one public key line"
# git and claude run as openclawops, which cannot read root's /root.
cd "$home"

# The server's tmux is older than the Mac's, so tmux.conf is loaded into a
# throwaway tmux server, on a socket in a scratch folder, before anything
# changes. A plugin not cloned yet is the one error that is not the config's.
scratch=$(mktemp -d "${TMPDIR:-/tmp}/unit5-check.XXXXXX")
loaded=$(tmux -S "$scratch/check" -f /dev/null new-session -d -s check \; source-file "$here/tmux.conf" 2>&1) || true
# has-session reports "no server" on stderr when new-session itself failed.
if tmux -S "$scratch/check" has-session 2>/dev/null; then
  tmux -S "$scratch/check" kill-server
fi
rm -rf "$scratch"
rejected=$(grep -vE "^'[^']*/\.tmux/plugins/tmux-(resurrect|continuum)/[a-z]+\.tmux' returned 127$" <<<"$loaded" || true)
[[ -z $rejected ]] || die "$(tmux -V) rejects tmux.conf: $rejected"

# ── 2. The Mac's key for openclawops ─────────────────────────────────────────
ak=$home/.ssh/authorized_keys
if ! [[ -f $ak ]] || ! grep -qxF -- "$pub" "$ak"; then
  if change "add the Mac's key to $user's ~/.ssh/authorized_keys"; then
    keep "$ak"
    mkdir -p "$home/.ssh"
    if [[ -s $ak && -n $(tail -c 1 "$ak") ]]; then
      echo >>"$ak"
    fi
    printf '%s\n' "$pub" >>"$ak"
    chmod 700 "$home/.ssh"
    chmod 600 "$ak"
    own "$home/.ssh" "$ak"
  fi
fi

# ── 3. Eternal Terminal: package, telemetry off, service, firewall ───────────
if ! installed et; then
  if ! have_ppa; then
    if change "add ppa:jgmath2000/et (Eternal Terminal for noble)"; then
      keep "$R/etc/apt/sources.list.d"
      logged add-apt-repository add-apt-repository -y ppa:jgmath2000/et
    fi
  elif ! candidate et; then
    if change "apt-get update: ppa:jgmath2000/et is listed but apt has no et to install"; then
      logged apt-get-update apt-get update
    fi
  fi
  if have_ppa && candidate et; then
    refuse_upgrades et
  elif ((check)); then
    echo "         (apt-get -s can list et's packages once the PPA is added)"
  fi
  # The package's postinst would start et while /etc/et.cfg still says telemetry = true.
  if change "install et (etserver runs as the systemd service et); needrestart restarts nothing"; then
    install_held apt-get-install et
  fi
fi

cfg=$R/etc/et.cfg
if [[ -f $cfg ]]; then
  if ! grep -qE '^[[:space:]]*telemetry[[:space:]]*=[[:space:]]*false[[:space:]]*$' "$cfg"; then
    cfg_changed=1
    if change "set telemetry = false in /etc/et.cfg"; then
      keep "$cfg"
      if grep -qE '^[[:space:]]*telemetry[[:space:]]*=' "$cfg"; then
        awk '/^[[:space:]]*telemetry[[:space:]]*=/ { print "telemetry = false"; next } { print }' "$cfg" >"$cfg.unit5"
      elif grep -qx '\[Debug\]' "$cfg"; then
        awk '{ print } $0 == "[Debug]" { print "telemetry = false" }' "$cfg" >"$cfg.unit5"
      else
        { cat "$cfg"; printf '\n[Debug]\ntelemetry = false\n'; } >"$cfg.unit5"
      fi
      cat "$cfg.unit5" >"$cfg"
      rm "$cfg.unit5"
    fi
  fi
elif ((check)); then
  change "set telemetry = false in /etc/et.cfg, which the install writes" || true
else
  die "et is installed but $cfg is missing"
fi

service_up et "$cfg_changed" /etc/et.cfg "etserver on TCP 2022"

ufw_allow 2022/tcp "Eternal Terminal"

# ── 4. tmux for openclawops ──────────────────────────────────────────────────
put "$here/tmux.conf" "$home/.tmux.conf" 644 "write $user's ~/.tmux.conf"
for entry in "${plugins[@]}"; do
  name=${entry%%:*}
  pin=${entry#*:}
  dir=$home/.tmux/plugins/$name
  if [[ -d $dir/.git && $(as_user git -C "$dir" rev-parse HEAD) == "$pin" ]]; then
    continue
  fi
  if change "check out $name at ${pin:0:12} in $user's ~/.tmux/plugins"; then
    as_user mkdir -p "$home/.tmux/plugins"
    if [[ ! -d $dir/.git ]]; then
      as_user git clone -q "https://github.com/tmux-plugins/$name.git" "$dir"
    fi
    as_user git -C "$dir" -c advice.detachedHead=false checkout -q "$pin"
  fi
done

# ── 5. Claude Code: four account launchers and folders ───────────────────────
rc=$home/.bashrc
begin=$(head -n 1 "$here/launchers.bash")
end=$(tail -n 1 "$here/launchers.bash")
block=$(<"$here/launchers.bash")
current=
if [[ -f $rc ]]; then
  if grep -qxF -- "$begin" "$rc" && ! grep -qxF -- "$end" "$rc"; then
    die "$rc has the launcher block's first line but not its last; mend it by hand, then run again"
  fi
  current=$(awk -v b="$begin" -v e="$end" '$0 == b { on = 1 } on { print } $0 == e { on = 0 }' "$rc")
fi
if [[ $current != "$block" ]]; then
  if change "write the account launchers into $user's ~/.bashrc"; then
    if [[ ! -f $rc ]]; then
      cp "$here/launchers.bash" "$rc"
      own "$rc"
    else
      keep "$rc"
      if [[ -n $current ]]; then
        awk -v b="$begin" -v e="$end" -v f="$here/launchers.bash" '
          $0 == b { while ((getline line < f) > 0) print line; skip = 1; next }
          skip && $0 == e { skip = 0; next }
          !skip { print }' "$rc" >"$rc.unit5"
      else
        { cat "$rc"; echo; cat "$here/launchers.bash"; } >"$rc.unit5"
      fi
      cat "$rc.unit5" >"$rc"
      rm "$rc.unit5"
    fi
  fi
fi

# A settings.json Claude Code has written to since keeps its own keys: only the
# shipped env keys are merged in.
for account in "${accounts[@]}"; do
  folder=$home/.claude-$account
  if [[ ! -d $folder ]]; then
    if change "make ~/.claude-$account for the $account account"; then
      mkdir -m 700 "$folder"
      own "$folder"
    fi
  fi
  settings=$folder/settings.json
  if [[ ! -f $settings ]]; then
    put "$here/settings.json" "$settings" 600 "write ~/.claude-$account/settings.json, the Mac's privacy settings"
    continue
  fi
  merged=$(jq -S --slurpfile ship "$here/settings.json" '.env = ((.env // {}) + $ship[0].env)' "$settings")
  if [[ $merged != "$(jq -S . "$settings")" ]]; then
    if change "merge the Mac's privacy settings into ~/.claude-$account/settings.json, keeping its other keys"; then
      keep "$settings"
      printf '%s\n' "$merged" >"$settings"
    fi
  fi
done

# The install is shared by every login of openclawops, and DISABLE_AUTOUPDATER
# keeps it where it is, so this script brings it up to the Mac's version.
claude=$home/.local/bin/claude
want=$(<"$here/claude-version")
if [[ ! -x $claude ]]; then
  problem "no Claude Code at $claude for $user"
else
  have=$(as_user env CLAUDE_CONFIG_DIR="$home/.claude-work" "$claude" --version | awk '{ print $1 }')
  if older "$have" "$want"; then
    if change "update Claude Code from $have to at least the Mac's $want, for every login of $user"; then
      as_user env CLAUDE_CONFIG_DIR="$home/.claude-work" "$claude" update
      have=$(as_user env CLAUDE_CONFIG_DIR="$home/.claude-work" "$claude" --version | awk '{ print $1 }')
      if older "$have" "$want"; then
        problem "claude update left $have, older than the Mac's $want"
      fi
    fi
  fi
fi

# A login shell (each tmux window, each et or ssh login) runs only the first of
# ~/.bash_profile, ~/.bash_login and ~/.profile that exists, and only Ubuntu's
# ~/.profile reads ~/.bashrc and puts ~/.local/bin on PATH. Claude Code makes an
# empty ~/.bash_profile wherever none exists, which hides both, so a missing or
# empty one becomes a loader of ~/.profile. One with lines of its own is the
# user's: it is named when it reads neither file, and left alone.
login=$home/.bash_profile
if [[ ! -f $login ]] || ! grep -q '[^[:space:]]' "$login"; then
  if change "make $user's ~/.bash_profile load ~/.profile, so a login shell has the launchers"; then
    keep "$login"
    printf '%s\n' '# bash reads this file instead of ~/.profile at login, so it loads ~/.profile' \
      '[ -f ~/.profile ] && . ~/.profile' >"$login"
    own "$login"
  fi
elif ! grep -qE '(\.|source)[[:space:]]+[^#]*\.(profile|bashrc)' "$login"; then
  problem "$login runs before ~/.profile and reads neither ~/.profile nor ~/.bashrc, so a login shell gets no launchers; make it read ~/.profile, then run again"
fi

# ── 6. Development: tools, git identity, GitHub's host key, ~/Projects ─────────
# Clones and pushes use the Mac's key, forwarded by et while the Mac is attached
# (the Dev server profile's --forward-ssh-agent), so no GitHub login is stored here.
missing=()
for package in "${tools[@]}"; do
  installed "$package" || missing+=("$package")
done
if ((${#missing[@]})); then
  refuse_upgrades "${missing[@]}"
  if change "install ${missing[*]}; needrestart restarts nothing"; then
    logged apt-get-install-tools apt-get install -y "${missing[@]}"
  fi
fi

# Ubuntu names fd's command fdfind, as another package owns /usr/bin/fd.
fd=$home/.local/bin/fd
if [[ $(readlink "$fd" 2>/dev/null) != /usr/bin/fdfind ]]; then
  if [[ -e $fd || -L $fd ]]; then
    problem "$fd exists and is not a link to /usr/bin/fdfind; left alone"
  elif change "link fd to fdfind in $user's ~/.local/bin"; then
    as_user mkdir -p "$home/.local/bin"
    as_user ln -s /usr/bin/fdfind "$fd"
  fi
fi

if [[ $(as_user git config --global --get user.name || true) != "$git_name" ||
  $(as_user git config --global --get user.email || true) != "$git_email" ]]; then
  if change "set $user's git identity to $git_name <$git_email>"; then
    keep "$home/.gitconfig"
    as_user git config --global user.name "$git_name"
    as_user git config --global user.email "$git_email"
  fi
fi

# GitHub's key from api.github.com/meta, so the first clone asks nothing.
kh=$home/.ssh/known_hosts
github_key=$(<"$here/github-known-hosts")
if ! [[ -f $kh ]] || ! ssh-keygen -F github.com -f "$kh" 2>/dev/null | grep -qF -- "${github_key#github.com }"; then
  if change "add GitHub's published host key to $user's ~/.ssh/known_hosts"; then
    keep "$kh"
    if [[ -s $kh && -n $(tail -c 1 "$kh") ]]; then
      echo >>"$kh"
    fi
    printf '%s\n' "$github_key" >>"$kh"
    chmod 600 "$kh"
    own "$kh"
  fi
fi

if [[ ! -d $home/Projects ]]; then
  if change "make $user's ~/Projects"; then
    as_user mkdir "$home/Projects"
  fi
fi

# ── 7. Tailscale, the Mac's exit node for the phone link ───────────────────────
# The Mac's own network blocks Signal's hosts, so the Mac reaches Signal through
# this server. This step installs and prepares; the operator signs in with
# `tailscale up --advertise-exit-node` and approves the exit node. The package
# comes from Tailscale's apt repository, signed by the key shipped beside this
# script (fingerprint 2596A99EAAB33821893C0A79458CA832957F5868).
ts_key=$R/usr/share/keyrings/tailscale-archive-keyring.asc
ts_list=$R/etc/apt/sources.list.d/tailscale.list
ts_source="deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.asc] https://pkgs.tailscale.com/stable/ubuntu noble main"
if ! cmp -s "$here/tailscale-archive-keyring.asc" "$ts_key"; then
  if change "install Tailscale's apt signing key in /usr/share/keyrings"; then
    keep "$ts_key"
    mkdir -p "$(dirname "$ts_key")"
    cp "$here/tailscale-archive-keyring.asc" "$ts_key"
    chmod 644 "$ts_key"
  fi
fi
if [[ $(cat "$ts_list" 2>/dev/null) != "$ts_source" ]]; then
  if change "list Tailscale's apt repository in /etc/apt/sources.list.d/tailscale.list"; then
    keep "$R/etc/apt/sources.list.d"
    printf '%s\n' "$ts_source" >"$ts_list"
  fi
fi
if ! installed tailscale; then
  if ! candidate tailscale; then
    if change "apt-get update, to fetch Tailscale's package list"; then
      logged apt-get-update-tailscale apt-get update
    fi
  fi
  # The package Recommends tailscale-archive-keyring, whose own copy of the key
  # this list would not read, so it is left out. debt: tailscale-key-rotation
  if candidate tailscale; then
    refuse_upgrades --no-install-recommends tailscale
  elif ((check)); then
    echo "         (apt-get -s can list tailscale's packages once its repository is fetched)"
  fi
  if change "install tailscale (tailscaled runs as the systemd service tailscaled); needrestart restarts nothing"; then
    install_held apt-get-install-tailscale tailscale --no-install-recommends
  fi
fi

# --no-logs-no-support stops tailscaled uploading its logs to Tailscale, in line
# with the telemetry opt-outs on the Mac. The package ships FLAGS=""; any other
# FLAGS line is the operator's, named rather than rewritten, and tailscaled is
# then not started by this script.
tsd=$R/etc/default/tailscaled
ts_changed=0
ts_flags_ok=1
if [[ -f $tsd ]]; then
  flags=$(grep -E '^[[:space:]]*FLAGS=' "$tsd" || true)
  if [[ $flags != *--no-logs-no-support* ]]; then
    if [[ -n $flags && $flags != 'FLAGS=""' ]]; then
      ts_flags_ok=0
      problem "/etc/default/tailscaled has $flags; add --no-logs-no-support to it by hand, then run again"
    else
      ts_changed=1
      if change "set FLAGS=\"--no-logs-no-support\" in /etc/default/tailscaled, so tailscaled uploads no logs"; then
        keep "$tsd"
        if [[ -n $flags ]]; then
          awk '$0 == "FLAGS=\"\"" { print "FLAGS=\"--no-logs-no-support\""; next } { print }' "$tsd" >"$tsd.phone"
        else
          { cat "$tsd"; echo 'FLAGS="--no-logs-no-support"'; } >"$tsd.phone"
        fi
        cat "$tsd.phone" >"$tsd"
        rm "$tsd.phone"
      fi
    fi
  fi
elif ((check)); then
  change "set FLAGS=\"--no-logs-no-support\" in /etc/default/tailscaled, which the install writes" || true
else
  die "tailscale is installed but $tsd is missing"
fi
if ((ts_flags_ok)); then
  service_up tailscaled "$ts_changed" /etc/default/tailscaled "Tailscale, signed in by the operator"
fi

# An exit node forwards the Mac's packets. Docker turned IPv4 forwarding on, but
# only until a reboot; IPv6 forwarding is off. The server's IPv6 address never
# expires and its default route is netplan's (proto static, 2026-11-18), so
# forwarding drops no route that router advertisements gave it. Forwarding is
# safe only while ufw drops forwarded packets by default, for IPv4 and IPv6, so
# that is required first. The values before the change go to the backup folder,
# which the rollback in the phone link spec's Setup restores.
fwd=$R/etc/sysctl.d/99-tailscale.conf
fwd_text=$'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1'
v4=$R/proc/sys/net/ipv4/ip_forward
v6=$R/proc/sys/net/ipv6/conf/all/forwarding
if [[ $(cat "$fwd" 2>/dev/null) != "$fwd_text" || $(<"$v4") != 1 || $(<"$v6") != 1 ]]; then
  if ! grep -qx 'DEFAULT_FORWARD_POLICY="DROP"' "$R/etc/default/ufw" || ! grep -qx 'IPV6=yes' "$R/etc/default/ufw"; then
    problem "/etc/default/ufw must hold DEFAULT_FORWARD_POLICY=\"DROP\" and IPV6=yes before this server forwards packets; forwarding is left as it is"
  elif change "write /etc/sysctl.d/99-tailscale.conf (IPv4 and IPv6 forwarding, kept across reboots) and load it"; then
    keep "$fwd"
    mkdir -p "$backup"
    if [[ ! -e $backup/forwarding-before.txt ]]; then
      printf 'net.ipv4.ip_forward = %s\nnet.ipv6.conf.all.forwarding = %s\n' "$(<"$v4")" "$(<"$v6")" >"$backup/forwarding-before.txt"
    fi
    printf '%s\n' "$fwd_text" >"$fwd"
    logged sysctl sysctl -p "${fwd#"$R"}"
  fi
fi

# Without it the Mac still connects, through Tailscale's relays, more slowly.
ufw_allow 41641/udp "Tailscale direct connections"

# ── Result ───────────────────────────────────────────────────────────────────
if ((check)); then
  echo "check: $changes change(s) to make; nothing was changed"
else
  if ((changes == 0)); then
    echo "nothing to change"
  fi
  if ! grep -qE '[:.]2022[[:space:]]' <<<"$(ss -tln)"; then
    problem "nothing listens on TCP 2022"
  fi
  if [[ -d $backup ]]; then
    echo "backups: ${backup#"$R"}"
  fi
fi
if ((problems)); then
  exit 1
fi
