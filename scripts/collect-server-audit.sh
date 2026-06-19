#!/usr/bin/env bash
# collect-server-audit.sh — read-only server telemetry collector.
#
# Emits one JSON object to stdout describing what a server is running and how
# heavily it is loaded, so over-provisioned or idle hosts can be identified for
# downgrade/deletion. It writes nothing to the server filesystem and mutates no
# state: it reads /proc, runs `ps`/`ss`/`df`/`docker ps`, and samples counters
# over a short window. Safe to run on production mail nodes.
#
# Usage:  bash collect-server-audit.sh [WINDOW_SECONDS]   (default 30)
# Designed to be streamed over SSH:  ssh host 'bash -s -- 30' < collect-server-audit.sh
#
# Output contract: exactly one JSON object on stdout. All human/diagnostic
# noise goes to stderr. Missing tools degrade fields to null/[] with a warning,
# never a hard failure.

set -u
export LC_ALL=C
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

WINDOW="${1:-30}"
case "$WINDOW" in (*[!0-9]*|'') WINDOW=30 ;; esac
[ "$WINDOW" -lt 1 ] 2>/dev/null && WINDOW=1

SCHEMA_VERSION="1.0"
COLLECTOR_VERSION="1.1.0"
WARNINGS=""
warn() { WARNINGS="${WARNINGS}${WARNINGS:+|}$1"; printf 'audit-warn: %s\n' "$1" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- JSON helpers ----------------------------------------------------------
# jstr: escape an arbitrary string into a quoted JSON string (pure bash).
jstr() {
  local s=${1-}
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  # strip any remaining C0 control bytes that would make invalid JSON
  s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')
  printf '"%s"' "$s"
}
# jnum: emit a bare JSON number if the value is a well-formed number, else null.
# Strict regex rejects malformed inputs like "1.2.3" or "+-" that would be
# invalid bare JSON.
jnum() {
  if [[ ${1-} =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then printf '%s' "$1"; else printf 'null'; fi
}

# --- system identity -------------------------------------------------------
HOSTNAME_S=$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null)
FQDN=$(hostname -f 2>/dev/null || printf '%s' "$HOSTNAME_S")
KERNEL=$(uname -r 2>/dev/null)
ARCH=$(uname -m 2>/dev/null)
OS_NAME=""; OS_VERSION=""
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null
  OS_NAME="${PRETTY_NAME:-$NAME}"; OS_VERSION="${VERSION_ID:-}"
fi
VIRT=$(systemd-detect-virt 2>/dev/null || printf 'unknown')
NOW_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
UPTIME_S=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null)
[ -z "${UPTIME_S:-}" ] && UPTIME_S=0
BOOT_UTC=""
if [ "$UPTIME_S" -gt 0 ] 2>/dev/null; then
  BOOT_EPOCH=$(( $(date -u +%s) - UPTIME_S ))
  BOOT_UTC=$(date -u -d "@${BOOT_EPOCH}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')
fi
CPU_MODEL=$(awk -F: '/^model name/{gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
[ -z "${CPU_MODEL:-}" ] && CPU_MODEL=$(awk -F: '/^Model/{gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
CPU_CORES=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || printf '0')

# --- load + cpu since boot -------------------------------------------------
read -r LOAD1 LOAD5 LOAD15 _ < /proc/loadavg 2>/dev/null || { LOAD1=null; LOAD5=null; LOAD15=null; }
# /proc/stat aggregate cpu line: user nice system idle iowait irq softirq steal ...
# printf %.0f (not `print`) so huge jiffy counters are not stringified via
# CONVFMT's %.6g into scientific notation, which would collapse the window delta.
read_cpu_totals() { awk '/^cpu /{idle=$5+$6; total=0; for(i=2;i<=NF;i++) total+=$i; printf "%.0f %.0f", total, idle}' /proc/stat 2>/dev/null; }
read -r CPU_TOTAL_0 CPU_IDLE_0 <<<"$(read_cpu_totals)"
CPU_UTIL_BOOT=$(awk -v t="${CPU_TOTAL_0:-0}" -v i="${CPU_IDLE_0:-0}" 'BEGIN{ if(t>0) printf "%.1f",(t-i)/t*100; else print "null" }')

# --- network counters t0 ---------------------------------------------------
# sum rx/tx bytes across real interfaces (skip lo and virtual veth/docker/br)
read_net_totals() {
  awk -F'[: ]+' '
    NR>2 {
      ifc=$2; rx=$3; tx=$11;
      if (ifc=="lo") next;
      if (ifc ~ /^(veth|docker|br-|virbr|cni|flannel|cali|tun|tap)/) next;
      trx+=rx; ttx+=tx;
    }
    END { printf "%.0f %.0f", trx, ttx }' /proc/net/dev 2>/dev/null
}
read -r NET_RX_0 NET_TX_0 <<<"$(read_net_totals)"

# --- sampling window -------------------------------------------------------
sleep "$WINDOW"

read -r CPU_TOTAL_1 CPU_IDLE_1 <<<"$(read_cpu_totals)"
CPU_UTIL_WIN=$(awk -v t0="${CPU_TOTAL_0:-0}" -v i0="${CPU_IDLE_0:-0}" -v t1="${CPU_TOTAL_1:-0}" -v i1="${CPU_IDLE_1:-0}" \
  'BEGIN{ dt=t1-t0; di=i1-i0; if(dt>0) printf "%.1f",(dt-di)/dt*100; else print "null" }')
read -r NET_RX_1 NET_TX_1 <<<"$(read_net_totals)"
WIN_RX_MBPS=$(awk -v a="${NET_RX_0:-0}" -v b="${NET_RX_1:-0}" -v w="$WINDOW" 'BEGIN{ if(w>0) printf "%.3f",(b-a)*8/w/1e6; else print "null" }')
WIN_TX_MBPS=$(awk -v a="${NET_TX_0:-0}" -v b="${NET_TX_1:-0}" -v w="$WINDOW" 'BEGIN{ if(w>0) printf "%.3f",(b-a)*8/w/1e6; else print "null" }')

# --- network since-boot aggregates -----------------------------------------
NET_RX_GB=$(awk -v b="${NET_RX_1:-0}" 'BEGIN{printf "%.2f", b/1073741824}')
NET_TX_GB=$(awk -v b="${NET_TX_1:-0}" 'BEGIN{printf "%.2f", b/1073741824}')
AVG_RX_MBPS=$(awk -v b="${NET_RX_1:-0}" -v u="${UPTIME_S:-0}" 'BEGIN{ if(u>0) printf "%.3f", b*8/u/1e6; else print "null" }')
AVG_TX_MBPS=$(awk -v b="${NET_TX_1:-0}" -v u="${UPTIME_S:-0}" 'BEGIN{ if(u>0) printf "%.3f", b*8/u/1e6; else print "null" }')

# per-interface array
NET_IFACES=$(awk -F'[: ]+' '
  function jesc(s){ gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/\t/,"\\t",s); gsub(/[\001-\037]/,"",s); return s }
  NR>2 {
    ifc=$2; rx=$3; tx=$11;
    if (ifc=="lo") next;
    if (ifc ~ /^(veth|docker|br-|virbr|cni|flannel|cali|tun|tap)/) next;
    printf "%s{\"name\":\"%s\",\"rx_gb\":%.2f,\"tx_gb\":%.2f}", sep, jesc(ifc), rx/1073741824, tx/1073741824;
    sep=",";
  }' /proc/net/dev 2>/dev/null)

# --- memory ----------------------------------------------------------------
mem_kb() { awk -v k="$1" '$1==k":"{print $2; exit}' /proc/meminfo 2>/dev/null; }
MEM_TOTAL_KB=$(mem_kb MemTotal); MEM_AVAIL_KB=$(mem_kb MemAvailable); MEM_FREE_KB=$(mem_kb MemFree)
BUFFERS_KB=$(mem_kb Buffers); CACHED_KB=$(mem_kb Cached)
SWAP_TOTAL_KB=$(mem_kb SwapTotal); SWAP_FREE_KB=$(mem_kb SwapFree)
: "${MEM_TOTAL_KB:=0}" "${MEM_AVAIL_KB:=0}" "${MEM_FREE_KB:=0}" "${BUFFERS_KB:=0}" "${CACHED_KB:=0}" "${SWAP_TOTAL_KB:=0}" "${SWAP_FREE_KB:=0}"
MEM_TOTAL_MB=$(( MEM_TOTAL_KB / 1024 ))
MEM_AVAIL_MB=$(( MEM_AVAIL_KB / 1024 ))
MEM_USED_MB=$(( (MEM_TOTAL_KB - MEM_AVAIL_KB) / 1024 ))
MEM_FREE_MB=$(( MEM_FREE_KB / 1024 ))
MEM_USED_PCT=$(awk -v t="$MEM_TOTAL_KB" -v a="$MEM_AVAIL_KB" 'BEGIN{ if(t>0) printf "%.1f",(t-a)/t*100; else print "null" }')
SWAP_TOTAL_MB=$(( SWAP_TOTAL_KB / 1024 ))
SWAP_USED_MB=$(( (SWAP_TOTAL_KB - SWAP_FREE_KB) / 1024 ))
SWAP_USED_PCT=$(awk -v t="$SWAP_TOTAL_KB" -v f="$SWAP_FREE_KB" 'BEGIN{ if(t>0) printf "%.1f",(t-f)/t*100; else print "0" }')

# --- disk ------------------------------------------------------------------
DISKS=$(df -P -B1 2>/dev/null | awk '
  function jesc(s){ gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/\t/,"\\t",s); gsub(/[\001-\037]/,"",s); return s }
  NR==1 { next }
  {
    fs=$1; size=$2; used=$3; avail=$4; pct=$5; mnt=$6; for(i=7;i<=NF;i++) mnt=mnt" "$i;
    if (fs ~ /^(tmpfs|devtmpfs|overlay|shm|udev|none)$/) next;
    if (mnt ~ /^\/(dev|proc|sys|run)(\/|$)/) next;
    if (size+0 == 0) next;
    sub(/%/,"",pct);
    printf "%s{\"mount\":\"%s\",\"fs\":\"%s\",\"size_mb\":%d,\"used_mb\":%d,\"avail_mb\":%d,\"used_pct\":%s}",
      sep, jesc(mnt), jesc(fs), size/1048576, used/1048576, avail/1048576, (pct==""?"null":pct);
    sep=",";
  }')

# --- processes (top by RSS and by CPU) -------------------------------------
PROC_AWK='
  function jesc(s){ gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/\t/,"\\t",s); gsub(/[\001-\037]/,"",s); return s }
  {
    pid=$1; user=$2; cpu=$3; mem=$4; rss=$5;
    c=""; for(i=6;i<=NF;i++) c=c (i>6?" ":"") $i;
    printf "%s{\"pid\":%d,\"user\":\"%s\",\"cpu_pct\":%s,\"mem_pct\":%s,\"rss_mb\":%.1f,\"comm\":\"%s\"}",
      sep, pid, jesc(user), (cpu==""?"null":cpu), (mem==""?"null":mem), rss/1024, jesc(c);
    sep=",";
  }'
TOPN=12
if have ps; then
  TOP_RSS=$(ps -eo pid=,user=,pcpu=,pmem=,rss=,comm= --sort=-rss 2>/dev/null | head -n "$TOPN" | awk -v sep="" "$PROC_AWK")
  TOP_CPU=$(ps -eo pid=,user=,pcpu=,pmem=,rss=,comm= --sort=-pcpu 2>/dev/null | head -n "$TOPN" | awk -v sep="" "$PROC_AWK")
  PROC_COUNT=$(ps -e --no-headers 2>/dev/null | wc -l | tr -d ' ')
else
  warn "ps not available"; TOP_RSS=""; TOP_CPU=""; PROC_COUNT=null
fi

# --- listening sockets -----------------------------------------------------
SOCKETS=""
if have ss; then
  SOCKETS=$(ss -H -tulnp 2>/dev/null | awk '
    function jesc(s){ gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/\t/,"\\t",s); gsub(/[\001-\037]/,"",s); return s }
    {
      proto=$1; local=$5; proc="";
      if (match($0, /users:\(\(.*\)\)/)) proc=substr($0, RSTART, RLENGTH);
      key=proto"|"local;
      if (seen[key]++) next;
      printf "%s{\"proto\":\"%s\",\"local\":\"%s\",\"process\":\"%s\"}", sep, jesc(proto), jesc(local), jesc(proc);
      sep=",";
    }')
elif have netstat; then
  SOCKETS=$(netstat -tulnp 2>/dev/null | awk '
    function jesc(s){ gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/\t/,"\\t",s); gsub(/[\001-\037]/,"",s); return s }
    /^(tcp|udp)/ {
      proto=$1; local=$4; proc=$NF;
      key=proto"|"local; if(seen[key]++) next;
      printf "%s{\"proto\":\"%s\",\"local\":\"%s\",\"process\":\"%s\"}", sep, jesc(proto), jesc(local), jesc(proc);
      sep=",";
    }')
else
  warn "no ss/netstat for socket enumeration"
fi

# --- docker containers -----------------------------------------------------
CONTAINERS=""
DOCKER_PRESENT=false
if have docker && timeout 8 docker info >/dev/null 2>&1; then
  DOCKER_PRESENT=true
  CONTAINERS=$(timeout 10 docker ps --no-trunc --format '{{.ID}}\t{{.Image}}\t{{.Names}}\t{{.Status}}' 2>/dev/null | awk -F'\t' '
    function jesc(s){ gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/\t/,"\\t",s); gsub(/[\001-\037]/,"",s); return s }
    {
      id=substr($1,1,12);
      printf "%s{\"id\":\"%s\",\"image\":\"%s\",\"name\":\"%s\",\"status\":\"%s\"}", sep, jesc(id), jesc($2), jesc($3), jesc($4);
      sep=",";
    }')
fi

# --- running services ------------------------------------------------------
SVC_COUNT=null; SVC_SAMPLE=""
if have systemctl; then
  SVC_LIST=$(systemctl list-units --type=service --state=running --no-legend --no-pager 2>/dev/null | awk '{print $1}')
  if [ -n "$SVC_LIST" ]; then
    SVC_COUNT=$(printf '%s\n' "$SVC_LIST" | grep -c . )
    SVC_SAMPLE=$(printf '%s\n' "$SVC_LIST" | head -n 40 | awk '
      function jesc(s){ gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/\t/,"\\t",s); gsub(/[\001-\037]/,"",s); return s }
      { printf "%s\"%s\"", sep, jesc($0); sep="," }')
  else
    SVC_COUNT=0
  fi
fi

# --- role signals ----------------------------------------------------------
# Cheap keyword scan over the evidence we already gathered, to label the host.
ROLE_BLOB=$(printf '%s\n%s\n%s\n%s\n' "$TOP_RSS" "$SOCKETS" "$CONTAINERS" "$SVC_SAMPLE" | tr 'A-Z' 'a-z')
ROLES=""
add_role() { case "$ROLES" in *"\"$1\""*) ;; *) ROLES="${ROLES}${ROLES:+,}\"$1\"" ;; esac; }
case "$ROLE_BLOB" in *kumod*|*kumomta*) add_role kumomta ;; esac
case "$ROLE_BLOB" in *dokku*) add_role dokku ;; esac
case "$ROLE_BLOB" in *librechat*|*"mongo"*) add_role librechat_or_mongo ;; esac
case "$ROLE_BLOB" in *puma*|*rails*|*ruby*) add_role rails ;; esac
case "$ROLE_BLOB" in *node*) add_role nodejs ;; esac
case "$ROLE_BLOB" in *nginx*) add_role nginx ;; esac
case "$ROLE_BLOB" in *postfix*|*dovecot*|*opendkim*) add_role postfix_mail ;; esac
case "$ROLE_BLOB" in *mailpit*) add_role mailpit ;; esac
case "$ROLE_BLOB" in *postgres*) add_role postgres ;; esac
case "$ROLE_BLOB" in *mysql*|*mariadb*) add_role mysql ;; esac
case "$ROLE_BLOB" in *redis*) add_role redis ;; esac
case "$DOCKER_PRESENT" in true) add_role docker ;; esac

# --- assemble JSON ---------------------------------------------------------
cat <<JSON
{
  "schema_version": $(jstr "$SCHEMA_VERSION"),
  "collector_version": $(jstr "$COLLECTOR_VERSION"),
  "collected_at_utc": $(jstr "$NOW_UTC"),
  "collection_window_seconds": $(jnum "$WINDOW"),
  "system": {
    "hostname": $(jstr "$HOSTNAME_S"),
    "fqdn": $(jstr "$FQDN"),
    "os": $(jstr "$OS_NAME"),
    "os_version": $(jstr "$OS_VERSION"),
    "kernel": $(jstr "$KERNEL"),
    "arch": $(jstr "$ARCH"),
    "virt": $(jstr "$VIRT"),
    "uptime_seconds": $(jnum "$UPTIME_S"),
    "boot_time_utc": $(jstr "$BOOT_UTC"),
    "cpu_model": $(jstr "$CPU_MODEL"),
    "cpu_cores": $(jnum "$CPU_CORES")
  },
  "load": {
    "avg_1m": $(jnum "$LOAD1"),
    "avg_5m": $(jnum "$LOAD5"),
    "avg_15m": $(jnum "$LOAD15"),
    "cpu_util_pct_window": $(jnum "$CPU_UTIL_WIN"),
    "cpu_util_pct_since_boot": $(jnum "$CPU_UTIL_BOOT"),
    "process_count": $(jnum "$PROC_COUNT")
  },
  "memory": {
    "total_mb": $(jnum "$MEM_TOTAL_MB"),
    "used_mb": $(jnum "$MEM_USED_MB"),
    "available_mb": $(jnum "$MEM_AVAIL_MB"),
    "free_mb": $(jnum "$MEM_FREE_MB"),
    "used_pct": $(jnum "$MEM_USED_PCT"),
    "swap_total_mb": $(jnum "$SWAP_TOTAL_MB"),
    "swap_used_mb": $(jnum "$SWAP_USED_MB"),
    "swap_used_pct": $(jnum "$SWAP_USED_PCT")
  },
  "disk": [${DISKS}],
  "network": {
    "uptime_seconds": $(jnum "$UPTIME_S"),
    "total_rx_gb": $(jnum "$NET_RX_GB"),
    "total_tx_gb": $(jnum "$NET_TX_GB"),
    "avg_rx_mbps_since_boot": $(jnum "$AVG_RX_MBPS"),
    "avg_tx_mbps_since_boot": $(jnum "$AVG_TX_MBPS"),
    "window_rx_mbps": $(jnum "$WIN_RX_MBPS"),
    "window_tx_mbps": $(jnum "$WIN_TX_MBPS"),
    "interfaces": [${NET_IFACES}]
  },
  "top_processes_by_rss": [${TOP_RSS}],
  "top_processes_by_cpu": [${TOP_CPU}],
  "listening_sockets": [${SOCKETS}],
  "docker_present": ${DOCKER_PRESENT},
  "containers": [${CONTAINERS}],
  "running_services_count": $(jnum "$SVC_COUNT"),
  "running_services_sample": [${SVC_SAMPLE}],
  "role_signals": [${ROLES}],
  "warnings": $(jstr "$WARNINGS")
}
JSON
