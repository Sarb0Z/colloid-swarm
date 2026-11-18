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
# tailscale-archive-keyring.asc, claude-version, managed-settings.json,
# policy-helper.sh, server-asks.json, claude-statusline.sh, CLAUDE.md,
# gitconfig-projects, colloid-diffview.lua, and what `apply` stages from the
# Mac: policy.json, accounts/*.json, output-style.md, git-identities.json
# (names, emails and orgs only) and skills/.
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

# make_parent <path> <owner>: the folder a new file goes in, made when missing,
# owned by the user for the user's files and by root (0755) for the system's.
make_parent() {
  local dir
  dir=$(dirname "$1")
  [[ -d $dir ]] && return 0
  if [[ $2 == "$user:$user" ]]; then
    as_user mkdir -p "$dir"
  else
    mkdir -p "$dir"
    chmod 755 "$dir"
    chown "$2" "$dir"
  fi
}

# put <source> <destination> <mode> <what> [owner]: a file the server keeps as shipped.
put() {
  local owner=${5:-$user:$user}
  if [[ -f $2 ]] && cmp -s "$1" "$2"; then
    return 0
  fi
  if change "$4"; then
    keep "$2"
    make_parent "$2" "$owner"
    cp "$1" "$2"
    chmod "$3" "$2"
    chown "$owner" "$2"
  fi
}

# put_text <content> <destination> <mode> <what> [owner]: the same for text
# worked out in this script.
put_text() {
  local owner=${5:-$user:$user}
  if [[ -f $2 && $(<"$2") == "$1" ]]; then
    return 0
  fi
  if change "$4"; then
    keep "$2"
    make_parent "$2" "$owner"
    printf '%s\n' "$1" >"$2"
    chmod "$3" "$2"
    chown "$owner" "$2"
  fi
}

# pin_clone <folder> <url> <commit> <what>: a git checkout at one commit, as the user.
pin_clone() {
  if [[ -d $1/.git && $(as_user git -C "$1" rev-parse HEAD) == "$3" ]]; then
    return 0
  fi
  if change "check out $4"; then
    as_user mkdir -p "$(dirname "$1")"
    if [[ ! -d $1/.git ]]; then
      as_user git clone -q "$2" "$1"
    fi
    as_user git -C "$1" -c advice.detachedHead=false checkout -q "$3"
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
for f in tmux.conf launchers.bash settings.json claude-version github-known-hosts tailscale-archive-keyring.asc \
  managed-settings.json policy-helper.sh policy.json server-asks.json claude-statusline.sh CLAUDE.md output-style.md \
  gitconfig-projects git-identities.json colloid-diffview.lua; do
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
  pin_clone "$home/.tmux/plugins/$name" "https://github.com/tmux-plugins/$name.git" "$pin" \
    "$name at ${pin:0:12} in $user's ~/.tmux/plugins"
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

# A settings.json Claude Code has written to since keeps its own keys. The
# shipped env keys are forced (they are privacy settings); every other shipped key
# is a default, used only where the file has none, so a model picked on the server
# stays. Each event's hook entry carrying a shipped command is replaced in place,
# and added when absent, so a rerun adds no second copy.
merge_settings='. as $cur | $ship[0] as $s
  | (($s | del(.env, .hooks)) * $cur)
  | .env = (($cur.env // {}) + $s.env)
  | .hooks = reduce ($s.hooks | keys[]) as $ev (($cur.hooks // {});
      ($s.hooks[$ev] | map(.hooks[].command)) as $cmds
      | $s.hooks[$ev] as $mine
      | (.[$ev] // []) as $arr
      | ($arr | map(any(.hooks[]?; .command as $c | any($cmds[]; . == $c)))) as $own
      | if ($own | any) then
          .[$ev] = ([range(0; $arr | length)] | map(
            if $own[.] then (if . == ($own | index(true)) then $mine[] else empty end) else $arr[.] end))
        else .[$ev] = $arr + $mine end)'
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
    put "$here/settings.json" "$settings" 600 "write ~/.claude-$account/settings.json, the Mac's settings"
  else
    merged=$(jq -S --slurpfile ship "$here/settings.json" "$merge_settings" "$settings")
    if [[ $merged != "$(jq -S . "$settings")" ]]; then
      if change "merge the Mac's settings into ~/.claude-$account/settings.json, keeping its other keys"; then
        keep "$settings"
        printf '%s\n' "$merged" >"$settings"
      fi
    fi
  fi
  put "$here/output-style.md" "$folder/output-styles/colloid.md" 644 "install the colloid output style in ~/.claude-$account"
  put "$here/CLAUDE.md" "$folder/CLAUDE.md" 644 "write ~/.claude-$account/CLAUDE.md, the server's instructions"
  if [[ -d $here/skills ]]; then
    for skill in "$here"/skills/*/; do
      [[ -d $skill ]] || continue
      name=$(basename "$skill")
      dest=$folder/skills/$name
      if [[ -d $dest ]] && diff -rq "$skill" "$dest" >/dev/null; then
        continue
      fi
      if change "install the $name skill in ~/.claude-$account/skills"; then
        keep "$dest"
        make_parent "$dest" "$user:$user"
        rm -rf "$dest"
        cp -R "${skill%/}" "$dest"
        chown -R "$user:$user" "$dest"
      fi
    done
  fi
done

put "$here/claude-statusline.sh" "$home/.local/bin/claude-statusline.sh" 755 "install the status line script in $user's ~/.local/bin"

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

# Clones under ~/Projects reach GitHub over https with the operator's gh login
# (which the operator makes with `gh auth login --with-token`); the services'
# clones under ~/apps keep their own transport, as only ~/Projects reads the file.
put "$here/gitconfig-projects" "$home/.gitconfig-projects" 644 "write $user's ~/.gitconfig-projects, gh as the credential helper for GitHub"
gc=$home/.gitconfig
include_head='[includeIf "gitdir:~/Projects/"]'
if ! grep -qxF -- "$include_head" "$gc" 2>/dev/null; then
  if change "include ~/.gitconfig-projects for clones under ~/Projects in $user's ~/.gitconfig"; then
    keep "$gc"
    if [[ -s $gc && -n $(tail -c 1 "$gc") ]]; then
      echo >>"$gc"
    fi
    printf '%s\n\tpath = ~/.gitconfig-projects\n' "$include_head" >>"$gc"
    own "$gc"
  fi
fi

# Each clone authors as the identity the Mac's registry gives its origin's owner;
# an owner the registry does not list keeps the global identity, and a local
# identity that differs is named, not changed.
owner_of() {
  sed -E 's#^(ssh://|https?://)?([^@/]+@)?github\.com[:/]+##; s#/.*##' <<<"$1"
}
for gitdir in "$home"/Projects/*/.git "$home"/Projects/*/*/.git; do
  [[ -e $gitdir ]] || continue
  clone=$(dirname "$gitdir")
  url=$(as_user git -C "$clone" remote get-url origin 2>/dev/null || true)
  [[ $url == *github.com* ]] || continue
  owner=$(owner_of "$url")
  want=$(jq -r --arg o "$owner" '.identities[] | select(any(.github_org[]; ascii_downcase == ($o | ascii_downcase))) | [.name, .email] | @tsv' "$here/git-identities.json" | head -n 1)
  [[ -n $want ]] || continue
  IFS=$'\t' read -r want_name want_email <<<"$want"
  todo=()
  for key in name email; do
    wanted=$want_name
    [[ $key == email ]] && wanted=$want_email
    have=$(as_user git -C "$clone" config --local --get "user.$key" || true)
    if [[ -z $have ]]; then
      todo+=("$key")
    elif [[ $have != "$wanted" ]]; then
      echo "note: ${clone#"$R"} keeps its own local user.$key; the registry's differs for owner $owner" >&2
    fi
  done
  if ((${#todo[@]})); then
    if change "set the local git identity of ${clone#"$R"} (${todo[*]}) from the Mac's registry for owner $owner"; then
      for key in "${todo[@]}"; do
        wanted=$want_name
        [[ $key == email ]] && wanted=$want_email
        as_user git -C "$clone" config --local "user.$key" "$wanted"
      done
    fi
  fi
done

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

# ── The iTerm2 panes' side of the server: pane-* scripts and diffview ──────────
# The scripts come from the colloid-swarm clone `apply` makes after this script
# runs, so the first apply finds no clone and the second links them. A name in
# ~/.local/bin that is not this script's own link is named and left alone.
clone=$home/Projects/colloid-swarm
if [[ -d $clone/.agents/iterm/bin ]]; then
  for script in "$clone"/.agents/iterm/bin/*; do
    [[ -f $script ]] || continue
    link=$home/.local/bin/$(basename "$script")
    target=${script#"$R"}
    if [[ $(readlink "$link" 2>/dev/null) == "$target" ]]; then
      continue
    elif [[ -e $link || -L $link ]]; then
      problem "$link exists and is not a link to $target; left alone"
    elif change "link $(basename "$script") from the colloid-swarm clone into $user's ~/.local/bin"; then
      as_user mkdir -p "$home/.local/bin"
      as_user ln -s "$target" "$link"
    fi
  done
else
  echo "skip:  no colloid-swarm clone in ~/Projects yet, so no pane-* links; apply again once it exists"
fi

# diffview, the Mac's pin (nvim's lazy-lock.json), loaded from nvim's own pack folder.
pin_clone "$home/.local/share/nvim/site/pack/colloid/start/diffview.nvim" \
  https://github.com/dlyongemallo/diffview-plus.nvim.git 2a2d89a07f5d5d3cef7f542b99c3e28050ca205c \
  "diffview at 2a2d89a07f5d in $user's nvim packages"
nvdv=$home/.config/nvim/plugin/colloid-diffview.lua
if [[ -f $nvdv ]] && cmp -s "$here/colloid-diffview.lua" "$nvdv"; then
  :
elif [[ -e $home/.config/nvim ]]; then
  echo "note: $user has a ~/.config/nvim of its own, so the Mac's diffview keys are not installed; copy colloid-diffview.lua by hand if wanted" >&2
else
  put "$here/colloid-diffview.lua" "$nvdv" 644 "write $user's ~/.config/nvim/plugin/colloid-diffview.lua, the Mac's diffview keys"
fi

# ── Claude Code's managed policy on the server ────────────────────────────────
# The Mac's device policy and per-account payloads, with the asks that hold only
# on the server added to each, reach Claude Code through the policy helper
# /etc/claude-code/managed-settings.json names. All of it is root's: the user
# whose sessions it governs cannot edit it.
cc=$R/etc/claude-code
server_asks=$(jq -c . "$here/server-asks.json")
with_server_asks() {
  jq --argjson asks "$server_asks" '.managedSettings.permissions.ask = (((.managedSettings.permissions.ask // []) + $asks) | unique)' "$1"
}
put "$here/managed-settings.json" "$cc/managed-settings.json" 644 "write /etc/claude-code/managed-settings.json, naming the policy helper" root:root
put "$here/policy-helper.sh" "$cc/policy-helper.sh" 755 "install /etc/claude-code/policy-helper.sh" root:root
put_text "$(with_server_asks "$here/policy.json")" "$cc/policy.json" 644 "write /etc/claude-code/policy.json, the Mac's policy with the server's own asks" root:root
payloads=("$here"/accounts/*.json)
for payload in "${payloads[@]}"; do
  [[ -f $payload ]] || continue
  put_text "$(with_server_asks "$payload")" "$cc/accounts/$(basename "$payload")" 644 \
    "write the policy payload of one limited account in /etc/claude-code/accounts, with the server's own asks" root:root
done

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
