#!/usr/bin/env bash
# Put the Signal TLS proxy on contabo-hop (docs/notes/2026-11-18-signal-tls-proxy-plan.md).
# It runs as root on the server; `apply-proxy` on the Mac sends it this folder
# over ssh and runs it.
#
#   1. /opt/signal-proxy: compose.yaml, terminate.conf, upstream's relay.conf
#      (checked against relay.pin's sha256), lego.sh and acme-server.
#   2. signal-proxy-renew.service and .timer in /etc/systemd/system.
#   3. The certificate for 62.171.166.213, by lego.sh, when none is valid for
#      more than 80 h from the ACME directory asked for.
#   4. The two containers (`docker compose -p signal-proxy`); terminate
#      publishes 8443 only. nginx on the host keeps 80 and 443.
#   5. The timer, enabled and started.
#
# Each step reads the current state and changes only what differs, so a second
# run changes nothing. Before the first change of a run, the server's network
# state (iptables-save, ip6tables-save, docker ps -a, docker network ls,
# ss -tlnp, ufw status numbered) is written to /root/backups/signal-proxy-<date>/,
# and a file is copied there before it is replaced. No ufw rule is added: Docker's
# published port bypasses ufw, and `docker compose -p signal-proxy down` closes it.
#
# Usage: setup-proxy.sh [--check] [--staging [--staging-over-production]]
#   --check    print each change a run would make; change nothing, ask no one
#              (no Let's Encrypt, no image pull, no container started)
#   --staging  use Let's Encrypt's staging directory; a run without it moves
#              the proxy to the production directory. Refused while a
#              production certificate is valid for more than 80 h: the way back
#              issues a new one, and Let's Encrypt allows 5 for one IP in 7 days.
#   --staging-over-production  replace that production certificate all the same
# SETUP_ROOT puts a folder in front of every absolute path; only the tests set it.
set -euo pipefail

usage="usage: setup-proxy.sh [--check] [--staging [--staging-over-production]]"
production=https://acme-v02.api.letsencrypt.org/directory
check=0 server=$production over_production=0
for argument in "$@"; do
  case $argument in
    --check) check=1 ;;
    --staging) server=https://acme-staging-v02.api.letsencrypt.org/directory ;;
    --staging-over-production) over_production=1 ;;
    *)
      echo "$usage" >&2
      exit 2
      ;;
  esac
done
if ((over_production)) && [[ $server == "$production" ]]; then
  echo "$usage" >&2
  exit 2
fi
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
R=${SETUP_ROOT:-}
ip=62.171.166.213
dir=$R/opt/signal-proxy
units=$R/etc/systemd/system
cert=$R/var/lib/lego/certificates/$ip.crt
backup=$R/root/backups/signal-proxy-$(date +%Y%m%d)
compose=(docker compose -p signal-proxy -f "$dir/compose.yaml")
changes=0
problems=0

die() {
  printf 'setup-proxy: %s\n' "$*" >&2
  exit 1
}
problem() {
  printf 'PROBLEM: %s\n' "$*" >&2
  problems=$((problems + 1))
}

# The server's network state as it was before this run's first change, once a day.
save_state() {
  [[ -e $backup/ss-tlnp.txt ]] && return 0
  mkdir -p "$backup"
  iptables-save >"$backup/iptables-save.txt"
  ip6tables-save >"$backup/ip6tables-save.txt"
  docker ps -a >"$backup/docker-ps-a.txt"
  docker network ls >"$backup/docker-network-ls.txt"
  ufw status numbered >"$backup/ufw-status-numbered.txt"
  ss -tlnp >"$backup/ss-tlnp.txt"
}

# change <what>: count and print one change; true when it is to be made now.
change() {
  changes=$((changes + 1))
  if ((check)); then
    echo "would: $1"
    return 1
  fi
  echo "do:    $1"
  save_state
}

# keep <path>: copy a file into the backup before its first change.
keep() {
  local dest=$backup${1#"$R"}
  if [[ -e $1 && ! -e $dest ]]; then
    mkdir -p "$(dirname "$dest")"
    cp -a "$1" "$dest"
  fi
}

# put <source> <destination> <mode>: a file the server keeps as shipped, owned by
# root. True when it changed (under --check: would change).
put() {
  if [[ -f $2 ]] && cmp -s "$1" "$2"; then
    return 1
  fi
  if change "write ${2#"$R"}"; then
    keep "$2"
    mkdir -p "$(dirname "$2")"
    cp "$1" "$2"
    chmod "$3" "$2"
  fi
  return 0
}

# ── Before anything changes ──────────────────────────────────────────────────
[[ $(id -u) == 0 ]] || die "run as root: apply-proxy logs in to contabo-hop as root"
for f in compose.yaml terminate.conf relay.conf relay.pin lego.sh signal-proxy-renew.service signal-proxy-renew.timer; do
  [[ -f $here/$f ]] || die "missing $here/$f"
done
pinned=$(sed -n 's/^sha256=//p' "$here/relay.pin")
read -r actual _ < <(sha256sum "$here/relay.conf")
[[ $actual == "$pinned" ]] || die "relay.conf's sha256 is $actual, not relay.pin's $pinned; nothing was changed"
# ports: !override needs Compose 2.24.4 or later.
version=$(docker compose version --short) || die "docker compose is not installed"
[[ $(printf '%s\n' 2.24.4 "${version#v}" | sort -V | head -n 1) == 2.24.4 ]] || die "docker compose $version is older than 2.24.4, which compose.yaml's !override needs"
listening=$(ss -tlnp)
grep -E '[:.]80[[:space:]].*"nginx"' <<<"$listening" >/dev/null ||
  die "nginx does not hold port 80 here; lego's challenge is served by it, so nothing was changed"
holder=$(grep -E '[:.]8443[[:space:]]' <<<"$listening" | grep -v '"docker-proxy"' || true)
[[ -z $holder ]] || die "port 8443 is held by another program: $holder"
issued_by=$(cat "$R/var/lib/lego/signal-proxy-server" 2>/dev/null || true)
if [[ $server != "$production" && $issued_by == "$production" ]] && ((!over_production)) &&
  [[ -f $cert ]] && openssl x509 -checkend $((80 * 3600)) -noout -in "$cert" >/dev/null; then
  die "the production certificate here is valid for more than 80 h; --staging would replace it, and the way back issues a new one (Let's Encrypt allows 5 for one IP in 7 days). Add --staging-over-production to replace it all the same; nothing was changed"
fi

# ── 1. The module's files ─────────────────────────────────────────────────────
config_changed=0
for f in compose.yaml terminate.conf relay.conf; do
  if put "$here/$f" "$dir/$f" 644; then config_changed=1; fi
done
put "$here/lego.sh" "$dir/lego.sh" 755 || true
if [[ $(cat "$dir/acme-server" 2>/dev/null) != "$server" ]]; then
  if change "write /opt/signal-proxy/acme-server: $server"; then
    keep "$dir/acme-server"
    printf '%s\n' "$server" >"$dir/acme-server"
    chmod 644 "$dir/acme-server"
  fi
fi

# ── 2. The renew service and its timer ───────────────────────────────────────
units_changed=0
for f in signal-proxy-renew.service signal-proxy-renew.timer; do
  if put "$here/$f" "$units/$f" 644; then units_changed=1; fi
done
if ((units_changed)) && change "systemctl daemon-reload, to read the renew units"; then
  systemctl daemon-reload
fi

# ── 3. The certificate ───────────────────────────────────────────────────────
if [[ ! -f $cert ]]; then
  why="there is none"
elif [[ $issued_by != "$server" ]]; then
  why="the one there is not from $server"
elif ! openssl x509 -checkend $((80 * 3600)) -noout -in "$cert" >/dev/null; then
  why="the one there is valid for 80 h or less"
else
  why=
fi
if [[ -n $why ]] && change "issue the certificate for $ip from $server with lego.sh ($why)"; then
  bash "$dir/lego.sh"
fi

# ── 4. The proxy's containers ────────────────────────────────────────────────
running=
if [[ -f $dir/compose.yaml ]]; then
  services=$("${compose[@]}" ps --status running --services) || die "docker compose ps failed; the containers were left as they are"
  running=$(printf '%s' "$services" | LC_ALL=C sort | tr '\n' ' ')
fi
if ((config_changed)) && [[ -n $running ]]; then
  if change "recreate the proxy's containers, to read the new configuration"; then
    "${compose[@]}" up -d --force-recreate
  fi
elif [[ $running != "relay terminate " ]]; then
  if change "start the proxy's containers (terminate publishes 8443)"; then
    "${compose[@]}" up -d
  fi
fi

# ── 5. The timer ─────────────────────────────────────────────────────────────
if ! { systemctl is-enabled --quiet signal-proxy-renew.timer 2>/dev/null && systemctl is-active --quiet signal-proxy-renew.timer; }; then
  if change "enable and start signal-proxy-renew.timer (lego.sh twice a day)"; then
    systemctl enable --now signal-proxy-renew.timer
  fi
fi

# ── Result ───────────────────────────────────────────────────────────────────
if ((check)); then
  echo "check: $changes change(s) to make; nothing was changed"
else
  if ((changes == 0)); then
    echo "nothing to change"
  fi
  "${compose[@]}" exec -T terminate nginx -t >/dev/null 2>&1 || problem "nginx -t fails in the terminate container"
  bash "$dir/lego.sh" --served ||
    problem "the proxy on 8443 does not serve /var/lib/lego/certificates/$ip.crt (lego.sh's line above names both); recreate it: docker compose -p signal-proxy -f /opt/signal-proxy/compose.yaml up -d --force-recreate terminate"
  grep -E '[:.]8443[[:space:]].*"docker-proxy"' <<<"$(ss -tlnp)" >/dev/null || problem "docker-proxy does not hold port 8443"
  grep -E '[:.]443[[:space:]].*"nginx"' <<<"$(ss -tlnp)" >/dev/null || problem "nginx no longer holds port 443"
  if [[ -d $backup ]]; then
    echo "backups: ${backup#"$R"}"
  fi
fi
if ((problems)); then
  exit 1
fi
