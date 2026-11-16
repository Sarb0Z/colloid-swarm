#!/usr/bin/env bash
# Make contabo-hop the development server: TERMINAL-SPEC.md Unit 5, runbook steps
# 1-5. It runs as root on the server; `apply` on the Mac sends it this folder, the
# Mac's public key and the Mac's Claude Code version over ssh, and runs it.
#
# Each step reads the current state and changes only what differs, so a second
# run changes nothing. Before its first change, a file is copied once into
# /root/backups/unit5-<date>/ under its own path. --check prints each change a
# run would make, and changes nothing.
#
# The server is live (mail, web, GitMu), so apt runs with needrestart suspended:
# installing et restarts no running service.
#
# Usage: setup-server.sh [--check] <public key file>
# Beside it: tmux.conf, launchers.bash, settings.json, claude-version.
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
changes=0
problems=0
cfg_changed=0
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 NEEDRESTART_MODE=l

die() {
  echo "setup-server: $*" >&2
  exit 1
}
problem() {
  echo "PROBLEM: $*" >&2
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

as_user() { runuser -u "$user" -- env HOME="$home" "$@"; }
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
older() { [[ $1 != "$2" && $(printf '%s\n' "$1" "$2" | sort -V | head -n 1) == "$1" ]]; }

[[ $(id -u) == 0 ]] || die "run as root: apply logs in to contabo-hop as root"
grep -qx 'VERSION_CODENAME=noble' "$R/etc/os-release" ||
  die "expected Ubuntu 24.04 (noble), the release this script picks ppa:jgmath2000/et for"
[[ -d $home ]] || die "no home folder $home for $user"
for f in tmux.conf launchers.bash settings.json claude-version; do
  [[ -f $here/$f ]] || die "missing $here/$f"
done
pub=$(<"$keyfile")
[[ $pub =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com)\ [A-Za-z0-9+/]+=*(\ [^[:cntrl:]]*)?$ ]] ||
  die "$keyfile is not one public key line"

# The server's tmux is older than the Mac's, so tmux.conf is loaded into a
# throwaway tmux server before anything changes. A plugin not cloned yet is the
# one error that is not the config's.
socket=unit5-check-$$
loaded=$(tmux -L "$socket" -f /dev/null new-session -d -s check \; source-file "$here/tmux.conf" 2>&1) || true
# has-session reports "no server" on stderr when new-session itself failed.
if tmux -L "$socket" has-session 2>/dev/null; then
  tmux -L "$socket" kill-server
fi
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
if ! have_ppa; then
  if change "add ppa:jgmath2000/et (Eternal Terminal for noble)"; then
    keep "$R/etc/apt/sources.list.d"
    add-apt-repository -y ppa:jgmath2000/et
  fi
fi

if ! installed et; then
  if change "install et (etserver runs as the systemd service et); needrestart restarts nothing"; then
    apt-get install -y et
  elif have_ppa; then
    apt-get -s install et | { grep -E '^Inst ' || true; } | sed 's/^/         /'
  else
    echo "         (apt-get -s can list et's packages once the PPA is added)"
  fi
fi

cfg=$R/etc/et.cfg
if [[ -f $cfg ]]; then
  if ! grep -qE '^[[:space:]]*telemetry[[:space:]]*=[[:space:]]*false[[:space:]]*$' "$cfg"; then
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
      cfg_changed=1
    fi
  fi
elif ((check)); then
  change "set telemetry = false in /etc/et.cfg, which the install writes" || true
else
  die "et is installed but $cfg is missing"
fi

# systemctl reports a unit it does not know on stderr; here that only means "not enabled".
if systemctl is-enabled --quiet et 2>/dev/null && systemctl is-active --quiet et; then
  if ((cfg_changed)); then
    if change "restart et to read the new /etc/et.cfg"; then
      systemctl restart et
    fi
  fi
elif change "enable and start the et service (etserver on TCP 2022)"; then
  systemctl enable --now et
fi

firewall=$(ufw status)
if ! grep -qE '^2022/tcp[[:space:]]+LIMIT' <<<"$firewall"; then
  if change "ufw limit 2022/tcp, rate-limited as 22 is"; then
    keep "$R/etc/ufw/user.rules"
    keep "$R/etc/ufw/user6.rules"
    mkdir -p "$backup"
    if [[ ! -e $backup/ufw-status.txt ]]; then
      ufw status numbered >"$backup/ufw-status.txt"
    fi
    ufw limit 2022/tcp
  fi
fi

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

for account in "${accounts[@]}"; do
  folder=$home/.claude-$account
  if [[ ! -d $folder ]]; then
    if change "make ~/.claude-$account for the $account account"; then
      mkdir -m 700 "$folder"
      own "$folder"
    fi
  fi
  put "$here/settings.json" "$folder/settings.json" 600 \
    "write ~/.claude-$account/settings.json, the Mac's privacy settings"
done

# The install is shared by every login of openclawops, and DISABLE_AUTOUPDATER
# keeps it where it is, so it is brought up to the Mac's version here.
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
