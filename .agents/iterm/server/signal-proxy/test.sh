#!/usr/bin/env bash
# Tests for .agents/iterm/server/signal-proxy: setup-proxy.sh and lego.sh over a
# pretend server folder (SETUP_ROOT), and apply-proxy with ssh replaced by a
# local shell. docker (lego and Compose), systemctl, curl, openssl, ss, ufw,
# iptables-save and ip6tables-save are stand-ins; each logs every call that
# changes state or reaches outside, so a log that stays empty proves none was made.
# Seams: the exact lego command line, the calls a run makes, and the files it
# leaves. Misses Let's Encrypt, the real nginx and Docker, which the plan's
# acceptance 1-7 check on the server after apply.
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
tree() { (cd "$1" && find . | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort); }

PRODUCTION=https://acme-v02.api.letsencrypt.org/directory
STAGING=https://acme-staging-v02.api.letsencrypt.org/directory
LEGO_IMAGE=goacme/lego@sha256:6f1583fc026a455ea46a7a5858c576105bb69c2e2de69db391cab7f14750350c
# The plan's one command line, as docker runs it on the server.
lego_line() { # server
  echo "docker run --rm --name signal-proxy-lego -v /var/lib/lego:/var/lib/lego -v /var/www/html:/var/www/html $LEGO_IMAGE run --accept-tos --path /var/lib/lego --server $1 --domains 62.171.166.213 --http --http.webroot /var/www/html --profile shortlived"
}

# --- stand-ins ----------------------------------------------------------------
# A certificate here is a text file "notAfter=<epoch>" and a serial; openssl reads it.
export STATE=$T/state CALLS=$T/calls
mkdir -p "$T/bin"
stub() { # name body
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$T/bin/$1"
  chmod +x "$T/bin/$1"
}
stub id '[[ $1 == -u ]] && echo 0'
stub openssl 'case "$1 $2" in
  "x509 -checkend") end=$(sed -n "s/^notAfter=//p" "${*: -1}"); (( end - $(date +%s) > $3 )) ;;
  "x509 -enddate") grep "^notAfter=" "${*: -1}" ;;
  "rand -hex") echo 00112233aabbccdd ;;
  *) echo "openssl stand-in: unexpected $*" >&2; exit 3 ;;
esac'
# curl GETs the webroot's file through the host's nginx, unless that is broken.
stub curl 'echo "curl $*" >>"$CALLS"
[[ -e $STATE/webroot-broken ]] && { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
url=${*: -1}
cat "$SETUP_ROOT/var/www/html/.well-known/acme-challenge/${url##*/}"'
for f in iptables-save ip6tables-save; do stub "$f" "echo \"backup: $f\" >>\"\$CALLS\"; echo '*filter'"; done
stub ufw '[[ $* == "status numbered" ]] || { echo "ufw stand-in: unexpected $*" >&2; exit 3; }
echo "backup: ufw $*" >>"$CALLS"; echo "Status: active"'
# nginx holds 80 and 443; docker-proxy holds 8443 while the proxy runs.
stub ss '[[ $1 == -tlnp ]] || { echo "ss stand-in: unexpected $*" >&2; exit 3; }
echo "LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:((\"nginx\",pid=1,fd=6))"
echo "LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:((\"nginx\",pid=1,fd=7))"
[[ -s $STATE/running ]] && echo "LISTEN 0 4096 0.0.0.0:8443 0.0.0.0:* users:((\"docker-proxy\",pid=9,fd=4))"
cat "$STATE/ss-extra" 2>/dev/null; true'
stub systemctl 'unit=${*: -1}
case $1 in
  is-enabled) [[ -e $STATE/$unit-enabled ]] ;;
  is-active) [[ -e $STATE/$unit-active ]] ;;
  enable) echo "systemctl $*" >>"$CALLS"; touch "$STATE/$unit-enabled" "$STATE/$unit-active" ;;
  daemon-reload) echo "systemctl $*" >>"$CALLS" ;;
  *) echo "systemctl stand-in: unexpected $*" >&2; exit 3 ;;
esac'
# lego renews as v5.6.0 does: when there is no certificate, at half the life of a
# short-lived one (80 h left), or with --renew-force; $STATE/lego-noop makes it
# write nothing, as when Let's Encrypt refuses.
stub docker 'certs=$SETUP_ROOT/var/lib/lego/certificates
case "$1 $2" in
  "compose version") echo 2.40.3 ;;
  "ps -a") echo "backup: docker ps -a" >>"$CALLS"; echo "CONTAINER ID   IMAGE" ;;
  "network ls") echo "backup: docker network ls" >>"$CALLS"; echo "NETWORK ID     NAME" ;;
  run\ *)
    echo "docker $*" >>"$CALLS"
    [[ -e $STATE/lego-noop ]] && exit 0
    end=$(sed -n "s/^notAfter=//p" "$certs/62.171.166.213.crt" 2>/dev/null)
    if [[ -z $end || $* == *--renew-force* ]] || (( end - $(date +%s) <= 80 * 3600 )); then
      mkdir -p "$certs"
      n=$(( $(cat "$STATE/serial" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$STATE/serial"
      printf "notAfter=%s\nserial=%s\n" $(( $(date +%s) + 160 * 3600 )) "$n" >"$certs/62.171.166.213.crt"
      echo "key $n" >"$certs/62.171.166.213.key"
    fi ;;
  compose\ -p)
    shift 5
    case $1 in
      ps) cat "$STATE/running" 2>/dev/null; true ;;
      up) echo "docker compose $*" >>"$CALLS"; printf "relay\nterminate\n" >"$STATE/running" ;;
      exec) [[ $* == "exec -T terminate nginx -t" && ! -e $STATE/log-nginx-t ]] || echo "docker compose $*" >>"$CALLS" ;;
      *) echo "docker stand-in: unexpected compose $*" >&2; exit 3 ;;
    esac ;;
  *) echo "docker stand-in: unexpected $*" >&2; exit 3 ;;
esac'
export PATH=$T/bin:$PATH

R=$T/root
fresh() {
  rm -rf "$R" "$STATE"
  mkdir -p "$STATE" "$R/root" "$R/etc/systemd/system" "$R/var/www/html"
  echo "the catch-all's page" >"$R/var/www/html/index.html"
  : >"$CALLS"
}
run() { (cd / && SETUP_ROOT=$R bash "$HERE/setup-proxy.sh" "$@"); }
renew() { (cd / && SETUP_ROOT=$R bash "$R/opt/signal-proxy/lego.sh"); }
cert=$R/var/lib/lego/certificates/62.171.166.213.crt
# A certificate from <server> with <hours> left.
cert_left() { # hours server
  mkdir -p "$(dirname "$cert")"
  printf 'notAfter=%s\nserial=old\n' $(($(date +%s) + $1 * 3600)) >"$cert"
  echo "key old" >"${cert%.crt}.key"
  echo "$2" >"$R/var/lib/lego/signal-proxy-server"
}

# --- syntax and pins -------------------------------------------------------------
for f in setup-proxy.sh lego.sh apply-proxy test.sh; do
  bash -n "$HERE/$f" && ok "bash -n $f" || bad "bash -n $f"
done
if command -v shellcheck >/dev/null; then
  shellcheck -S warning "$HERE/setup-proxy.sh" "$HERE/lego.sh" "$HERE/apply-proxy" "$HERE/test.sh" >"$T/shellcheck.out" 2>&1 &&
    ok "shellcheck on the module's scripts" || bad "shellcheck: $(cat "$T/shellcheck.out")"
else
  echo "skip shellcheck (not on PATH)"
fi
read -r relay_sum _ < <(sha256sum "$HERE/relay.conf")
eq "relay.conf is upstream's file at the pinned commit" "$(sed -n 's/^sha256=//p' "$HERE/relay.pin")" "$relay_sum"
eq "the pin names a full commit" 40 "$(sed -n 's/^commit=//p' "$HERE/relay.pin" | tr -d '\n' | wc -c | tr -d ' ')"
eq "compose.yaml publishes 8443 alone, through !override" 'ports: !override|"8443:443"' \
  "$(grep -E 'ports:|"[0-9]+:[0-9]+"' "$HERE/compose.yaml" | sed 's/^ *//; s/^- //' | tr '\n' '|' | sed 's/|$//')"
eq "both containers run the pinned nginx" 2 "$(grep -c 'image: nginx:stable-alpine@sha256:901e593c95dc85f5a729f5765516321366ef4ac401821431d408897e95287d0a$' "$HERE/compose.yaml")"
has "terminate reads lego's chain" "ssl_certificate       /certs/62.171.166.213.crt;" "$(cat "$HERE/terminate.conf")"
has "terminate reads lego's key" "ssl_certificate_key   /certs/62.171.166.213.key;" "$(cat "$HERE/terminate.conf")"
has "terminate passes on to the relay's port" "server relay:4433;" "$(cat "$HERE/terminate.conf")"
lacks "terminate needs no certbot" "certbot" "$(grep -v '^ *#' "$HERE/terminate.conf")"
lacks "terminate includes no other file (options-ssl-nginx.conf)" "include" "$(grep -v '^ *#' "$HERE/terminate.conf")"

# --- --check changes nothing and asks no one --------------------------------------
fresh
before=$(tree "$R")
out=$(run --check 2>&1); rc=$?
eq "check exits 0" 0 "$rc"
for line in "write /opt/signal-proxy/compose.yaml" "write /opt/signal-proxy/terminate.conf" "write /opt/signal-proxy/relay.conf" \
  "write /opt/signal-proxy/lego.sh" "write /opt/signal-proxy/acme-server: $PRODUCTION" \
  "write /etc/systemd/system/signal-proxy-renew.service" "write /etc/systemd/system/signal-proxy-renew.timer" \
  "systemctl daemon-reload" "issue the certificate for 62.171.166.213 from $PRODUCTION with lego.sh (there is none)" \
  "start the proxy's containers (terminate publishes 8443)" "enable and start signal-proxy-renew.timer"; do
  has "check lists: $line" "would: $line" "$out"
done
has "check counts every change" "check: 11 change(s) to make; nothing was changed" "$out"
eq "check leaves the server unchanged" "$before" "$(tree "$R")"
eq "check makes no outside or changing call (no lego, curl, pull, up, backup)" "" "$(cat "$CALLS")"

# --- --staging first: a run makes every change -------------------------------------
out=$(run --staging 2>&1); rc=$?
eq "staging run exits 0" 0 "$rc"
calls=$(cat "$CALLS")
eq "the lego command line, against staging" "$(lego_line "$STAGING")" "$(grep '^docker run' <<<"$calls")"
has "the webroot is checked before lego runs" "curl -fsS -m 10 http://62.171.166.213/.well-known/acme-challenge/signal-proxy-check-00112233aabbccdd" \
  "$(grep -B100 '^docker run' <<<"$calls")"
[[ ! -e $R/var/www/html/.well-known/acme-challenge/signal-proxy-check-00112233aabbccdd ]] &&
  ok "the webroot check removes its file" || bad "the webroot check left its file"
eq "the catch-all's own file stays" "the catch-all's page" "$(cat "$R/var/www/html/index.html")"
eq "the backup comes first" "backup: iptables-save" "$(head -n 1 "$CALLS")"
for f in iptables-save ip6tables-save docker-ps-a docker-network-ls ufw-status-numbered ss-tlnp; do
  [[ -s $R/root/backups/signal-proxy-$(date +%Y%m%d)/$f.txt ]] && ok "backup holds $f" || bad "backup lacks $f"
done
has "the containers start after the certificate is there" "docker compose up -d" "$(sed -n '/^docker run/,$p' "$CALLS")"
has "the timer is enabled" "systemctl enable --now signal-proxy-renew.timer" "$calls"
lacks "no ufw rule is added" "ufw allow" "$calls"
eq "acme-server names staging" "$STAGING" "$(cat "$R/opt/signal-proxy/acme-server")"
eq "lego.sh is executable" "-rwxr-xr-x" "$(ls -l "$R/opt/signal-proxy/lego.sh" | cut -c1-10)"
for f in compose.yaml terminate.conf relay.conf lego.sh; do
  cmp -s "$HERE/$f" "$R/opt/signal-proxy/$f" && ok "/opt/signal-proxy/$f is the module's" || bad "/opt/signal-proxy/$f differs"
done
for f in signal-proxy-renew.service signal-proxy-renew.timer; do
  cmp -s "$HERE/$f" "$R/etc/systemd/system/$f" && ok "$f is installed" || bad "$f is not installed"
done
has "the run says where the backup is" "backups: /root/backups/signal-proxy-" "$out"

# --- a second run changes nothing ---------------------------------------------------
: >"$CALLS"
after=$(tree "$R")
out=$(run --staging 2>&1); rc=$?
eq "second run exits 0" 0 "$rc"
has "second run: nothing to change" "nothing to change" "$out"
eq "second run makes no changing call" "" "$(cat "$CALLS")"
eq "second run leaves the server as it was" "$after" "$(tree "$R")"
out=$(run --staging --check 2>&1)
has "check after a run reports no change" "check: 0 change(s) to make; nothing was changed" "$out"

# --- the issue guard and the reload, as the renew service runs lego.sh ---------------
: >"$CALLS"
cert_left 100 "$STAGING"
out=$(renew 2>&1); rc=$?
eq "100 h left: exits 0" 0 "$rc"
has "100 h left: lego is not run" "valid for more than 80 h; lego is not run" "$out"
eq "100 h left: no call at all" "" "$(cat "$CALLS")"

cert_left 50 "$STAGING"
touch "$STATE/log-nginx-t"
out=$(renew 2>&1); rc=$?
eq "50 h left: exits 0" 0 "$rc"
eq "50 h left: lego runs, then nginx -t, then the reload" \
  "curl|$(lego_line "$STAGING")|docker compose exec -T terminate nginx -t|docker compose exec -T terminate nginx -s reload|" \
  "$(sed 's/^curl .*/curl/' "$CALLS" | tr '\n' '|')"
has "50 h left: names the new notAfter" "lego wrote a new certificate: notAfter=" "$out"

: >"$CALLS"
cert_left 50 "$STAGING"
touch "$STATE/lego-noop"
out=$(renew 2>&1); rc=$?
eq "a renewal that leaves the certificate: exits 0" 0 "$rc"
lacks "a renewal that leaves the certificate: no reload" "nginx" "$(cat "$CALLS")"
has "a renewal that leaves the certificate: says so" "lego left the certificate as it was" "$out"
rm "$STATE/lego-noop"

: >"$CALLS"
touch "$STATE/webroot-broken"
out=$(renew 2>&1); rc=$?
eq "a webroot that is not served: exits 1" 1 "$rc"
has "a webroot that is not served: says so" "does not serve /var/www/html" "$out"
lacks "a webroot that is not served: Let's Encrypt is not asked" "docker run" "$(cat "$CALLS")"
rm "$STATE/webroot-broken"

: >"$CALLS"
cert_left 100 "$STAGING"
out=$(SIGNAL_PROXY_FORCE=1 renew 2>&1); rc=$?
eq "a forced renewal against staging: exits 0" 0 "$rc"
eq "a forced renewal adds --renew-force alone" "$(lego_line "$STAGING") --renew-force" "$(grep '^docker run' "$CALLS")"

# --- then production: the staging certificate is put aside ---------------------------
: >"$CALLS"
out=$(run 2>&1); rc=$?
eq "production run exits 0" 0 "$rc"
has "production run: names why it issues" "issue the certificate for 62.171.166.213 from $PRODUCTION with lego.sh (the one there is not from $PRODUCTION)" "$out"
eq "the lego command line, against production" "$(lego_line "$PRODUCTION")" "$(grep '^docker run' "$CALLS")"
compgen -G "$R/var/lib/lego/certificates-*/62.171.166.213.crt" >/dev/null && ok "the staging certificate is kept aside" || bad "the staging certificate is gone"
eq "the certificate is from production now" "$PRODUCTION" "$(cat "$R/var/lib/lego/signal-proxy-server")"
lacks "production run: the running proxy is not recreated" "up -d" "$(cat "$CALLS")"
has "production run: the running proxy reloads the new certificate" "docker compose exec -T terminate nginx -s reload" "$(cat "$CALLS")"
: >"$CALLS"
out=$(SIGNAL_PROXY_FORCE=1 renew 2>&1); rc=$?
eq "a forced renewal against production: refused" 1 "$rc"
eq "a forced renewal against production: no call" "" "$(cat "$CALLS")"

# --- a changed config recreates the containers -------------------------------------
: >"$CALLS"
echo "# an older terminate.conf" >"$R/opt/signal-proxy/terminate.conf"
out=$(run 2>&1); rc=$?
eq "changed config: exits 0" 0 "$rc"
eq "changed config: one recreate, nothing else changing" "docker compose up -d --force-recreate|" "$(grep -v '^docker compose exec -T terminate nginx -t$' "$CALLS" | tr '\n' '|')"
[[ -f $R/root/backups/signal-proxy-$(date +%Y%m%d)/opt/signal-proxy/terminate.conf ]] && ok "changed config: the old file is backed up" || bad "changed config: no backup of the old file"

# --- refusals change nothing ---------------------------------------------------------
fresh
cp -R "$HERE" "$T/module"
echo "# tampered" >>"$T/module/relay.conf"
before=$(tree "$R")
out=$( (cd / && SETUP_ROOT=$R bash "$T/module/setup-proxy.sh") 2>&1); rc=$?
eq "a relay.conf that is not the pinned one: exits 1" 1 "$rc"
has "a relay.conf that is not the pinned one: says so" "not relay.pin's" "$out"
eq "a relay.conf that is not the pinned one: nothing changed" "$before" "$(tree "$R")$(cat "$CALLS")"

echo 'LISTEN 0 4096 0.0.0.0:8443 0.0.0.0:* users:(("sshd",pid=5,fd=3))' >"$STATE/ss-extra"
out=$(run 2>&1); rc=$?
eq "8443 held by another program: exits 1" 1 "$rc"
has "8443 held by another program: names it" "port 8443 is held by another program" "$out"
eq "8443 held by another program: nothing changed" "$before" "$(tree "$R")$(cat "$CALLS")"
rm "$STATE/ss-extra"

out=$(run --bogus 2>&1); rc=$?
eq "an unknown option: usage, exit 2" "2 usage: setup-proxy.sh [--check] [--staging]" "$rc $out"

# --- apply-proxy end to end, ssh replaced by a local shell ------------------------------
fresh
stub ssh '[[ $1 == contabo-hop ]] || { echo "ssh stand-in: unexpected host $1" >&2; exit 3; }
echo "ssh $1" >>"$CALLS"; exec bash -c "$2"'
before=$(tree "$R")
out=$(SETUP_ROOT=$R bash "$HERE/apply-proxy" --check 2>&1); rc=$?
eq "apply-proxy --check exits 0" 0 "$rc"
has "apply-proxy --check runs the check there" "check: 11 change(s) to make; nothing was changed" "$out"
eq "apply-proxy --check: one ssh login, nothing else" "ssh contabo-hop" "$(cat "$CALLS")"
eq "apply-proxy --check leaves the server unchanged" "$before" "$(tree "$R")"
out=$(SETUP_ROOT=$R bash "$HERE/apply-proxy" --staging 2>&1); rc=$?
eq "apply-proxy --staging exits 0" 0 "$rc"
eq "apply-proxy --staging issues from staging" "$(lego_line "$STAGING")" "$(grep '^docker run' "$CALLS")"
out=$(SETUP_ROOT=$R bash "$HERE/apply-proxy" --staging 2>&1); rc=$?
has "a second apply-proxy changes nothing" "nothing to change" "$out"
out=$(bash "$HERE/apply-proxy" --bogus 2>&1); rc=$?
eq "apply-proxy: an unknown option" "2 usage: apply-proxy [--check] [--staging]" "$rc $out"

((fails == 0)) && echo "signal-proxy tests passed" || {
  echo "$fails failed" >&2
  exit 1
}
