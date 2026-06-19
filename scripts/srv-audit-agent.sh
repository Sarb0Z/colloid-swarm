#!/bin/sh
# srv-audit-agent.sh — on-server wrapper for scheduled telemetry capture.
# Installed under /var/lib/srv-audit and run by /etc/cron.d/srv-audit.
# Each run: self-expire if past the stop date, else write ONE timestamped
# snapshot from the collector. Atomic writes; bounded snapshot count.
set -u

BASE="${SRV_AUDIT_BASE:-/var/lib/srv-audit}"
SNAPS="$BASE/snapshots"
COLLECTOR="$BASE/collector.sh"
STOP_FILE="$BASE/stop_epoch"
WINDOW="${1:-20}"
MAX_SNAPS=1000   # defensive cap in case the stop check ever fails to fire

now=$(date +%s 2>/dev/null) || now=0

# Self-expire: past the stop epoch -> remove our cron entry and stop collecting.
if [ -f "$STOP_FILE" ]; then
  stop=$(cat "$STOP_FILE" 2>/dev/null)
  case "$stop" in ''|*[!0-9]*) stop=0 ;; esac
  if [ "$stop" -gt 0 ] && [ "$now" -ge "$stop" ]; then
    rm -f /etc/cron.d/srv-audit
    : > "$BASE/expired"
    exit 0
  fi
fi

[ -r "$COLLECTOR" ] || exit 0
mkdir -p "$SNAPS" 2>/dev/null

ts=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null)
tmp="$SNAPS/.snap-$ts.tmp"
# Write to a temp file then rename, so a concurrent pull never sees a partial snapshot.
if bash "$COLLECTOR" "$WINDOW" > "$tmp" 2>/dev/null; then
  mv -f "$tmp" "$SNAPS/snap-$ts.json"
else
  rm -f "$tmp"
fi

# Defensive prune: keep only the newest MAX_SNAPS snapshots.
count=$(ls -1 "$SNAPS"/snap-*.json 2>/dev/null | wc -l)
if [ "$count" -gt "$MAX_SNAPS" ]; then
  ls -1t "$SNAPS"/snap-*.json 2>/dev/null | tail -n +$((MAX_SNAPS + 1)) | xargs rm -f 2>/dev/null
fi
