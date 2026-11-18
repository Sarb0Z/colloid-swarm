#!/usr/bin/env bash
# Issue or renew the Signal TLS proxy's certificate for 62.171.166.213, and
# reload the proxy when the certificate changed. signal-proxy-renew.service runs
# it twice a day; setup-proxy.sh runs it for the first certificate.
#
# One lego command line does both: lego v5.6.0's `run` issues when there is no
# certificate and renews at half the life of a short-lived one (80 h of 160 h).
# Let's Encrypt issues at most 5 certificates for one IP in 7 days, so lego is
# not run at all while the certificate is valid for more than 80 h; before it
# is, the webroot is checked to be served at http://62.171.166.213/.
#
# /opt/signal-proxy/acme-server names the ACME directory (Let's Encrypt's, or
# its staging one), as setup-proxy.sh wrote it. A certificate from another
# directory than that one is moved aside, so lego issues a new one.
#
# After each reload it reads the certificate the proxy serves on 127.0.0.1:8443
# and exits 1 when it is not the file's. `lego.sh --served` does only that read;
# setup-proxy.sh runs it at the end of every run.
#
# SIGNAL_PROXY_FORCE=1 renews whatever the time left (lego's --renew-force),
# against staging only. With systemd: `systemctl set-environment
# SIGNAL_PROXY_FORCE=1`, `systemctl start signal-proxy-renew`, then
# `systemctl unset-environment SIGNAL_PROXY_FORCE`.
# SETUP_ROOT puts a folder in front of every path this script reads or writes;
# only the tests set it. The paths given to docker are the server's.
set -euo pipefail

R=${SETUP_ROOT:-}
ip=62.171.166.213
dir=/opt/signal-proxy
store=/var/lib/lego
webroot=/var/www/html
image=goacme/lego@sha256:6f1583fc026a455ea46a7a5858c576105bb69c2e2de69db391cab7f14750350c # v5.6.0
production=https://acme-v02.api.letsencrypt.org/directory
staging=https://acme-staging-v02.api.letsencrypt.org/directory
cert=$R$store/certificates/$ip.crt
key=$R$store/certificates/$ip.key
issued_by=$R$store/signal-proxy-server
compose=(docker compose -p signal-proxy -f "$R$dir/compose.yaml")

die() {
  printf 'lego.sh: %s\n' "$*" >&2
  exit 1
}

# served: true when the proxy on 127.0.0.1:8443 presents the certificate in the
# file. `nginx -s reload` returns before the new workers have it, and a container
# just started needs a moment, so it asks up to 10 times, a second apart.
served() {
  local want got=
  want=$(openssl x509 -noout -fingerprint -sha256 -in "$cert") || {
    printf 'lego.sh: %s is not a certificate openssl reads\n' "${cert#"$R"}" >&2
    return 1
  }
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    got=$(openssl s_client -connect 127.0.0.1:8443 -servername "$ip" </dev/null 2>/dev/null |
      openssl x509 -noout -fingerprint -sha256 2>/dev/null) || got=
    [[ $got == "$want" ]] && return 0
    sleep 1
  done
  printf 'lego.sh: the proxy on 127.0.0.1:8443 serves %s, not the one in %s (%s)\n' \
    "${got:-no certificate}" "${store}/certificates" "$want" >&2
  return 1
}

case ${1-} in
  --served)
    served
    exit
    ;;
esac

server=$(cat "$R$dir/acme-server" 2>/dev/null) || die "no $dir/acme-server; run setup-proxy.sh first"
[[ $server == "$production" || $server == "$staging" ]] || die "$dir/acme-server names $server, neither Let's Encrypt's directory nor its staging one"
force=0
if [[ ${SIGNAL_PROXY_FORCE:-} == 1 ]]; then
  [[ $server == "$staging" ]] || die "SIGNAL_PROXY_FORCE renews against staging only: Let's Encrypt allows 5 certificates for one IP in 7 days"
  force=1
fi

if [[ -f $cert && $(cat "$issued_by" 2>/dev/null) != "$server" ]]; then
  # The running terminate container bind-mounts the certificates folder itself,
  # and a renamed folder stays the mounted one, so the files move and the folder
  # stays where it is.
  aside=$R$store/certificates-$(date +%Y%m%d%H%M%S)
  mkdir "$aside"
  shopt -s dotglob nullglob
  files=("$R$store/certificates"/*)
  shopt -u dotglob nullglob
  mv -- "${files[@]}" "$aside/"
  echo "the certificate is not from $server; its files are moved aside to ${aside#"$R"}"
fi

if ((!force)) && [[ -f $cert ]] && openssl x509 -checkend $((80 * 3600)) -noout -in "$cert" >/dev/null; then
  echo "the certificate is valid for more than 80 h; lego is not run"
  exit 0
fi

# Let's Encrypt fetches the challenge from the host's nginx, whose catch-all
# serves /.well-known/acme-challenge/ from /var/www/html for the bare IP.
name=signal-proxy-check-$(openssl rand -hex 8)
challenges=$R$webroot/.well-known/acme-challenge
mkdir -p "$challenges"
printf '%s\n' "$name" >"$challenges/$name"
got=$(curl -fsS -m 10 "http://$ip/.well-known/acme-challenge/$name" 2>&1) || got="curl failed: $got"
rm -f "$challenges/$name"
[[ $got == "$name" ]] || die "http://$ip/.well-known/acme-challenge/ does not serve $webroot ($got); Let's Encrypt was not asked"

# fingerprint: the chain and the key as one checksum; empty when there is none.
fingerprint() { [[ ! -f $cert ]] || cat "$cert" "$key" | cksum; }
before=$(fingerprint)
extra=()
((!force)) || extra=(--renew-force)
docker run --rm --name signal-proxy-lego -v "$store:$store" -v "$webroot:$webroot" "$image" \
  run --accept-tos --path "$store" --server "$server" --domains "$ip" --http --http.webroot "$webroot" \
  --profile shortlived ${extra[@]+"${extra[@]}"}
printf '%s\n' "$server" >"$issued_by"
after=$(fingerprint)
if [[ $before == "$after" ]]; then
  echo "lego left the certificate as it was"
  exit 0
fi
echo "lego wrote a new certificate: $(openssl x509 -enddate -noout -in "$cert")"

# lego has written the chain and the key by the time it exits, so nginx reads a
# matching pair. A proxy not running yet reads them when it starts.
if "${compose[@]}" ps --status running --services | grep -qx terminate; then
  "${compose[@]}" exec -T terminate nginx -t
  "${compose[@]}" exec -T terminate nginx -s reload
  served || exit 1
  echo "the proxy serves the new certificate"
fi
