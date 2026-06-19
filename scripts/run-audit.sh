#!/usr/bin/env bash
# run-audit.sh — one-shot fan-out of the read-only collector to every host in
# the credentials file, capturing one JSON document per host.
#
# The collector is streamed over SSH stdin (`bash -s`) and never written to the
# remote filesystem, so a run leaves no footprint on the audited servers.
#
# Usage: scripts/run-audit.sh [window_seconds]
# Env:   CREDS, AUDIT_OUTDIR, AUDIT_WINDOW, CONCURRENCY
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-fanout.sh"
COLLECTOR="$HERE/collect-server-audit.sh"
WINDOW="${1:-${AUDIT_WINDOW:-30}}"
OUTDIR="${AUDIT_OUTDIR:-$HERE/../audit-results}"

[ -r "$COLLECTOR" ] || die "collector not found: $COLLECTOR"
fanout_init
log "run-audit: collector→${WINDOW}s window, concurrency=$CONCURRENCY, out=$OUTDIR"

collect_one() {
  local ip="$1" user="$2" method="$3" secret="$4"
  local json="$OUTDIR/$ip.json" err="$OUTDIR/$ip.err" status="$OUTDIR/$ip.status" rc
  remote_exec "$ip" "$user" "$method" "$secret" $((WINDOW + 60)) "bash -s -- $WINDOW" \
    < "$COLLECTOR" > "$json" 2> "$err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'FAIL ssh_rc=%s %s\n' "$rc" "$(tail -1 "$err" 2>/dev/null)" > "$status"
  elif ! jq empty "$json" 2>>"$err"; then
    printf 'FAIL invalid_json\n' > "$status"
  else
    printf 'OK\n' > "$status"
  fi
}

for_each_host collect_one

# --- summary ---------------------------------------------------------------
ok=0; fail=0
log ""
log "=== collection summary ($HOST_COUNT hosts) ==="
while IFS= read -r ip; do
  s=$(cat "$OUTDIR/$ip.status" 2>/dev/null || echo "FAIL no_status")
  case "$s" in OK) ok=$((ok+1)); log "  OK    $ip" ;; *) fail=$((fail+1)); log "  $s   ($ip)" ;; esac
done < <(creds_ips)
log ""
log "run-audit: $ok ok, $fail failed. JSON in $OUTDIR/. Build report: scripts/build-report.py"
[ "$fail" -eq 0 ]
