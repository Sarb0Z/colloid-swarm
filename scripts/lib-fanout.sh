#!/usr/bin/env bash
# lib-fanout.sh — shared SSH fan-out machinery for the audit tooling.
# Sourced by run-audit.sh (one-shot collection) and schedule-audit.sh
# (install/pull/status/uninstall of the scheduled collector).
#
# Caller contract: set CREDS / OUTDIR / CONCURRENCY (or accept defaults),
# then call fanout_init once. Credentials file is tab-separated:
#   <ip>\t<user>\t<method>\t<secret>   method=key|password
# key      -> secret is a local private-key path
# password -> secret is the login password (used via exported SSHPASS + sshpass -e)

: "${CREDS:=$HOME/.config/contabo-audit/hosts.tsv}"
: "${CONCURRENCY:=8}"
HOST_COUNT=0

die() { printf '%s: %s\n' "${0##*/}" "$1" >&2; exit 1; }
log() { printf '%s\n' "$1" >&2; }

fanout_init() {
  [ -r "$CREDS" ] || die "credentials file not found: $CREDS"
  command -v jq >/dev/null 2>&1 || die "jq is required"
  [ -n "${OUTDIR:-}" ] || die "OUTDIR must be set before fanout_init"

  local perms
  perms=$(stat -f '%Lp' "$CREDS" 2>/dev/null || stat -c '%a' "$CREDS" 2>/dev/null)
  case "$perms" in ''|*[!0-7]*) die "cannot read permissions of $CREDS" ;; esac
  [ $(( 8#$perms & 077 )) -eq 0 ] || die "credentials file $CREDS is group/other-accessible ($perms); chmod 600 it"

  if awk -F'\t' '$1!~/^[[:space:]]*#/ && $3=="password"{f=1} END{exit f?0:1}' "$CREDS"; then
    command -v sshpass >/dev/null 2>&1 || die "sshpass required for password-auth hosts (brew install hudochenkov/sshpass/sshpass)"
  fi

  mkdir -p "$OUTDIR"
  KNOWN_HOSTS="$OUTDIR/.audit_known_hosts"   # per-run TOFU; never touches ~/.ssh/known_hosts
  : > "$KNOWN_HOSTS"
  SSH_COMMON=(-o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3
              -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS"
              -o LogLevel=ERROR -o NumberOfPasswordPrompts=1)

  if command -v timeout >/dev/null 2>&1; then CAP_BIN=timeout
  elif command -v gtimeout >/dev/null 2>&1; then CAP_BIN=gtimeout
  else CAP_BIN=""; fi
}

# capped SECONDS cmd...  — hard wall-clock cap; honors the caller's redirections.
capped() {
  local secs="$1"; shift
  if [ -n "$CAP_BIN" ]; then "$CAP_BIN" -k 5 "$secs" "$@"; return $?; fi
  "$@" & local p=$!
  # watchdog: on timeout TERM the job AND its children (sshpass forks ssh), then KILL.
  ( sleep "$secs"; kill -TERM "$p" 2>/dev/null; pkill -P "$p" 2>/dev/null; sleep 3; kill -KILL "$p" 2>/dev/null ) & local w=$!
  wait "$p" 2>/dev/null; local rc=$?
  # normal completion: reap the watchdog subshell and its still-sleeping child.
  kill -TERM "$w" 2>/dev/null; pkill -P "$w" 2>/dev/null; wait "$w" 2>/dev/null
  return "$rc"
}

# remote_exec ip user method secret budget remote_cmd...
# Runs remote_cmd on the host under the cap. Caller supplies stdin/stdout/stderr
# redirections, which flow through to ssh.
remote_exec() {
  local ip="$1" user="$2" method="$3" secret="$4" budget="$5"; shift 5
  if [ "$method" = key ]; then
    capped "$budget" ssh -i "$secret" -o BatchMode=yes -o PreferredAuthentications=publickey -o IdentitiesOnly=yes \
      "${SSH_COMMON[@]}" "$user@$ip" "$@"
  else
    # export (not assignment-prefix) so SSHPASS survives through capped()/timeout to sshpass.
    # Each invocation runs inside a per-host background subshell, so this never leaks across hosts.
    export SSHPASS="$secret"
    capped "$budget" sshpass -e ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no \
      "${SSH_COMMON[@]}" "$user@$ip" "$@"
    local rc=$?; unset SSHPASS; return "$rc"
  fi
}

# for_each_host callback_fn — run callback(ip,user,method,secret) per host,
# concurrently, throttled to $CONCURRENCY. Sets HOST_COUNT.
for_each_host() {
  local cb="$1" n=0
  while IFS=$'\t' read -r ip user method secret; do
    ip="${ip%$'\r'}"; secret="${secret%$'\r'}"   # tolerate CRLF creds files
    case "$ip" in ''|\#*) continue ;; esac
    [ -n "$user" ] && [ -n "$method" ] && [ -n "$secret" ] || { log "skip malformed line for '$ip'"; continue; }
    "$cb" "$ip" "$user" "$method" "$secret" &
    n=$((n+1))
    while [ "$(jobs -rp | wc -l)" -ge "$CONCURRENCY" ]; do wait -n 2>/dev/null || sleep 0.2; done
  done < "$CREDS"
  wait
  HOST_COUNT=$n
}

# each_host_status — iterate creds (serially) yielding "ip" lines for summaries.
creds_ips() { awk -F'\t' '$1!~/^[[:space:]]*#/ && NF>=4 {print $1}' "$CREDS"; }
