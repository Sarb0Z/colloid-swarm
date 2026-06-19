#!/usr/bin/env bash
# schedule-audit.sh — install/manage the self-expiring scheduled collector
# across the fleet. Each host runs the collector locally via /etc/cron.d and
# accumulates timestamped snapshots; no credentials are stored on the servers.
#
# Subcommands:
#   install [days=7] [interval_min=20] [window_sec=20]
#   status     show snapshot counts + first/last + expiry per host
#   pull       fetch all snapshots into audit-results/timeseries/<ip>/
#   uninstall  remove cron + /var/lib/srv-audit from every host (our files only)
#
# Env: CREDS, AUDIT_OUTDIR, CONCURRENCY
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-fanout.sh"
COLLECTOR="$HERE/collect-server-audit.sh"
AGENT="$HERE/srv-audit-agent.sh"
OUTDIR="${AUDIT_OUTDIR:-$HERE/../audit-results}"
REMOTE_BASE=/var/lib/srv-audit

usage() { sed -n '2,16p' "$0" >&2; exit 2; }
[ -r "$COLLECTOR" ] || die "collector not found: $COLLECTOR"
[ -r "$AGENT" ]     || die "agent not found: $AGENT"

cmd="${1:-}"; [ $# -gt 0 ] && shift || true

# Build the one-shot install bootstrap (base64-embeds collector + agent so no
# quoting/transfer issues), parameterized by stop epoch / interval / window.
build_payload() {
  local stop="$1" interval="$2" window="$3"
  echo 'set -e'
  echo "mkdir -p $REMOTE_BASE/snapshots; umask 022"
  echo "base64 -d > $REMOTE_BASE/collector.sh <<'B64COLLECTOR'"
  base64 < "$COLLECTOR"
  echo 'B64COLLECTOR'
  echo "base64 -d > $REMOTE_BASE/agent.sh <<'B64AGENT'"
  base64 < "$AGENT"
  echo 'B64AGENT'
  echo "chmod 0755 $REMOTE_BASE/collector.sh $REMOTE_BASE/agent.sh"
  echo "printf '%s\\n' $stop > $REMOTE_BASE/stop_epoch"
  echo "cat > /etc/cron.d/srv-audit <<'CRONEOF'"
  echo "# colloid srv-audit — auto-installed, self-expires at epoch $stop"
  echo "SHELL=/bin/sh"
  echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  echo "*/$interval * * * * root /bin/sh $REMOTE_BASE/agent.sh $window >/dev/null 2>&1"
  echo "CRONEOF"
  echo "chmod 0644 /etc/cron.d/srv-audit"
  # immediate first snapshot, backgrounded so install returns without waiting on the window
  echo "nohup /bin/sh $REMOTE_BASE/agent.sh $window >/dev/null 2>&1 &"
  echo "echo INSTALLED stop=$stop interval=${interval}m window=${window}s"
}

do_install() {
  local days="${1:-7}" interval="${2:-20}" window="${3:-20}" stop
  if   stop=$(date -u -v+"${days}"d +%s 2>/dev/null); then :   # BSD/macOS date
  elif stop=$(date -u -d "+${days} days" +%s 2>/dev/null); then :   # GNU date
  else die "cannot compute stop epoch"; fi

  local payload; payload=$(mktemp)
  build_payload "$stop" "$interval" "$window" > "$payload"
  log "schedule-audit: installing — every ${interval}m for ${days}d (window ${window}s), self-expire epoch $stop"

  install_one() {
    local ip="$1" user="$2" method="$3" secret="$4" out="$OUTDIR/$ip.install"
    remote_exec "$ip" "$user" "$method" "$secret" 90 "bash -s" < "$payload" > "$out" 2>&1
    if grep -q '^INSTALLED' "$out"; then printf 'OK    %s — %s\n' "$ip" "$(grep '^INSTALLED' "$out")" >&2
    else printf 'FAIL  %s — %s\n' "$ip" "$(tail -1 "$out")" >&2; fi
  }
  fanout_init
  for_each_host install_one
  rm -f "$payload"
  log "schedule-audit: install complete across $HOST_COUNT hosts. Check in: scripts/schedule-audit.sh status"
}

do_status() {
  fanout_init
  status_one() {
    local ip="$1" user="$2" method="$3" secret="$4"
    remote_exec "$ip" "$user" "$method" "$secret" 30 "sh -s" >"$OUTDIR/$ip.statline" 2>/dev/null <<'PROBE'
D=/var/lib/srv-audit
n=$(ls -1 "$D/snapshots"/snap-*.json 2>/dev/null | wc -l | tr -d ' ')
f=$(ls -1 "$D/snapshots"/snap-*.json 2>/dev/null | head -1 | sed 's#.*/snap-##;s#\.json##')
l=$(ls -1 "$D/snapshots"/snap-*.json 2>/dev/null | tail -1 | sed 's#.*/snap-##;s#\.json##')
e=no; [ -f "$D/expired" ] && e=yes
c=absent; [ -f /etc/cron.d/srv-audit ] && c=active
printf 'snaps=%s first=%s last=%s cron=%s expired=%s\n' "$n" "${f:-none}" "${l:-none}" "$c" "$e"
PROBE
  }
  for_each_host status_one
  log ""
  log "=== scheduled-collection status ==="
  while IFS= read -r ip; do
    log "  $(printf '%-16s' "$ip") $(cat "$OUTDIR/$ip.statline" 2>/dev/null || echo unreachable)"
  done < <(creds_ips)
}

do_pull() {
  fanout_init
  mkdir -p "$OUTDIR/timeseries"
  pull_one() {
    local ip="$1" user="$2" method="$3" secret="$4" tgz="$OUTDIR/timeseries/$ip.tgz"
    if remote_exec "$ip" "$user" "$method" "$secret" 120 "tar -C /var/lib/srv-audit -czf - snapshots 2>/dev/null" > "$tgz" 2>/dev/null \
       && [ -s "$tgz" ]; then
      rm -rf "$OUTDIR/timeseries/$ip"; mkdir -p "$OUTDIR/timeseries/$ip"
      if tar -xzf "$tgz" -C "$OUTDIR/timeseries/$ip" 2>/dev/null; then
        rm -f "$tgz"
        printf 'OK    %s — %s snapshots\n' "$ip" "$(ls -1 "$OUTDIR/timeseries/$ip/snapshots"/snap-*.json 2>/dev/null | wc -l | tr -d ' ')" >&2
      else printf 'FAIL  %s — extract failed\n' "$ip" >&2; fi
    else printf 'FAIL  %s — pull failed/empty\n' "$ip" >&2; fi
  }
  for_each_host pull_one
  log ""
  log "schedule-audit: pulled to $OUTDIR/timeseries/. Build trend: scripts/build-trend-report.py"
}

do_uninstall() {
  fanout_init
  log "schedule-audit: removing /etc/cron.d/srv-audit and $REMOTE_BASE from every host"
  uninstall_one() {
    local ip="$1" user="$2" method="$3" secret="$4"
    remote_exec "$ip" "$user" "$method" "$secret" 30 \
      "sh -c 'rm -f /etc/cron.d/srv-audit; rm -rf $REMOTE_BASE; echo UNINSTALLED'" \
      > "$OUTDIR/$ip.uninstall" 2>&1
    if grep -q UNINSTALLED "$OUTDIR/$ip.uninstall"; then printf 'OK    %s\n' "$ip" >&2
    else printf 'FAIL  %s — %s\n' "$ip" "$(tail -1 "$OUTDIR/$ip.uninstall")" >&2; fi
  }
  for_each_host uninstall_one
  log "schedule-audit: uninstall complete across $HOST_COUNT hosts."
}

case "$cmd" in
  install)   do_install "$@" ;;
  status)    do_status ;;
  pull)      do_pull ;;
  uninstall) do_uninstall ;;
  *)         usage ;;
esac
