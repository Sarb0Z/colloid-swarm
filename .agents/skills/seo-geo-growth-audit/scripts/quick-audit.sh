#!/usr/bin/env bash
# quick-audit.sh — evidence baseline for the seo-geo-growth-audit skill.
# Usage: quick-audit.sh [REPO_DIR | --no-repo] [BASE_URL] [--sample N] [--max-links N] [--max-children N] [--timeout SECS]
# Static checks run unless --no-repo; live and sampled-page checks run only when BASE_URL is reachable.
# --sample N pages from the sitemap (default 40, 0 disables); --max-links N internal links probed (default 60).
# Exit 0 when the audit ran (findings never change the exit code); 2 on usage errors.
set -u
export LC_ALL=C

REPO_DIR="."
NO_REPO=""
BASE_URL="${BASE_URL:-}"
MAX_CHILDREN=100   # index children to verify; caps runtime on huge sitemap indexes
TIMEOUT=10         # per-request curl timeout in seconds
SAMPLE_N=40        # sitemap pages fetched and analyzed, homepage included
MAX_LINKS=60       # internal links probed for TS-40
MAX_BODY=5242880   # bytes read from any one response body
UA="seo-geo-growth-audit/2.0 (+quick-audit.sh)"
HERE=$(cd "$(dirname "$0")" && pwd)

usage() { sed -n '2,6p' "$0"; exit "${1:-0}"; }
count_arg() { case "${2:-}" in ''|*[!0-9]*) echo "$1 needs a non-negative integer, got '${2:-}'" >&2; usage 2;; esac; }
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage 0 ;;
    --no-repo) NO_REPO=1; shift ;;
    --max-children) MAX_CHILDREN="${2:-100}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-10}"; shift 2 ;;
    --sample) count_arg "$1" "${2:-}"; SAMPLE_N=$2; shift 2 ;;
    --max-links) count_arg "$1" "${2:-}"; MAX_LINKS=$2; shift 2 ;;
    http://*|https://*) BASE_URL="${1%/}"; shift ;;
    -*) echo "unknown flag: $1" >&2; usage 2 ;;
    *) REPO_DIR="$1"; shift ;;
  esac
done
[ -n "$NO_REPO" ] || [ -d "$REPO_DIR" ] || { echo "REPO_DIR not found: $REPO_DIR" >&2; exit 2; }
while [ "$REPO_DIR" != / ] && [ "${REPO_DIR%/}" != "$REPO_DIR" ]; do REPO_DIR=${REPO_DIR%/}; done
WORK=$(mktemp -d "${TMPDIR:-/tmp}/quick-audit.XXXXXX") || { echo "cannot create a temporary directory" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM
PAGES="$WORK/pages"; STOP="$WORK/stop"
mkdir -p "$PAGES"

P=0; F=0; W=0; S=0; FAILED_IDS=""
emit() { # emit STATUS ID detail...
  local st="$1" id="$2"; shift 2
  printf '[%s] %s - %s\n' "$st" "$id" "$*"
  case "$st" in
    PASS) P=$((P+1));; FAIL) F=$((F+1)); FAILED_IDS="$FAILED_IDS $id";;
    WARN) W=$((W+1));; SKIP) S=$((S+1));;
  esac
}
GX=(--exclude-dir=node_modules --exclude-dir=.next --exclude-dir=.git --exclude-dir=dist --exclude-dir=build --exclude-dir=.nuxt --exclude-dir=.svelte-kit --exclude-dir=vendor --exclude-dir=.kimi-code --exclude-dir=.claude --exclude-dir=.cursor --exclude-dir=.github)
# Code-file whitelist for checks that would false-positive on docs/markdown
INC=(--include='*.js' --include='*.jsx' --include='*.ts' --include='*.tsx' --include='*.vue' --include='*.svelte' --include='*.astro' --include='*.html' --include='*.php' --include='*.erb' --include='*.py')
srcgrep() { grep -rE "${GX[@]}" "$@" "$REPO_DIR" 2>/dev/null; }
# Every request: GET or HEAD only, http(s) only (redirects included), the URL passed as --url and taken
# literally (-g), so brackets and braces in a sitemap or link URL never expand into extra requests.
# --compressed: some CDNs send a cached gzip body even when the client never asked for one.
req() { curl -s -g --compressed --proto =http,https --proto-redir =http,https --max-time "$TIMEOUT" -A "$UA" "$@"; }
# body CURL-ARGS... -> at most MAX_BODY bytes: --max-filesize refuses a declared larger body, head -c
# cuts an undeclared one. Returns curl's exit status; a %{stderr} write-out survives the cut.
body() { req --max-filesize "$MAX_BODY" "$@" | head -c "$MAX_BODY"; return "${PIPESTATUS[0]}"; }
# curl prints 000 for a failed request through -w itself, so a failure needs no fallback output
probe()   { { body -w '%{stderr}%{http_code}' --url "$1" >/dev/null; } 2>&1; true; }
probe_head() { local c; c=$(req -o /dev/null -I -w '%{http_code}' --url "$1")
  case "$c" in 405|501) probe "$1";; *) echo "$c";; esac; }
fetch()   { body --url "$1"; }
# fetch_doc URL -> DOC_CODE, DOC_TYPE, DOC_BODY, DOC_RC. A single-page app's catch-all
# answers every path 200 with its index page, so a file check needs all three.
fetch_doc() {
  local meta
  body -w '%{stderr}%{http_code} %{content_type}' --url "$1" >"$WORK/doc.body" 2>"$WORK/doc.meta"; DOC_RC=$?
  DOC_BODY=$(cat "$WORK/doc.body"); meta=$(cat "$WORK/doc.meta")
  [ "$DOC_RC" = 0 ] || meta="000 "
  DOC_CODE=${meta%% *}; DOC_TYPE=${meta#* }
}
# head_doc URL [CURL-OPTS...] -> DOC_CODE, DOC_TYPE without the body
head_doc() {
  local out u="$1"; shift
  out=$(req -o /dev/null -I -w '%{http_code} %{content_type}' "$@" --url "$u") || out="000 "
  case "${out%% *}" in 2??) ;; *) out=$({ body -w '%{stderr}%{http_code} %{content_type}' "$@" --url "$u" >/dev/null; } 2>&1) || out="000 ";; esac
  DOC_CODE=${out%% *}; DOC_TYPE=${out#* }
}
# fetch_page ID URL MODE DIR -> DIR/ID.row: url, curl exit, status, redirects, final URL, content type,
# redirect target (tab-separated); DIR/ID.hdr holds the response headers.
#   follow: GET following redirects, body kept in DIR/ID.body   get: GET without following, body kept
#   head: HEAD without following                                probe: HEAD without following, GET if refused
# A 429 writes STOP, so callers issue no further requests.
fetch_page() {
  local id="$1" u="$2" m="$3" d="$4" rc out=/dev/null
  local w='%{stderr}%{http_code}\t%{num_redirects}\t%{url_effective}\t%{content_type}\t%{redirect_url}'
  case "$m" in follow|get) out="$d/$id.body";; esac
  case "$m" in
    follow) body -L --max-redirs 5 -D "$d/$id.hdr" -w "$w" --url "$u" >"$out" 2>"$d/$id.meta";;
    get) body -D "$d/$id.hdr" -w "$w" --url "$u" >"$out" 2>"$d/$id.meta";;
    head) req -I -o /dev/null -D "$d/$id.hdr" -w "$w" --url "$u" 2>"$d/$id.meta";;
    probe) req -I -o /dev/null -D "$d/$id.hdr" -w "$w" --url "$u" 2>"$d/$id.meta"
      case "$(cut -f1 "$d/$id.meta")" in 2??|3??) true;; *) body -D "$d/$id.hdr" -w "$w" --url "$u" >/dev/null 2>"$d/$id.meta";; esac;;
  esac
  rc=$?
  printf '%s\t%s\t%s\n' "$u" "$rc" "$(cat "$d/$id.meta")" >"$d/$id.row"
  [ "$(cut -f1 "$d/$id.meta")" != 429 ] || printf '%s\n' "$u" >"$STOP"
}
row_field() { cut -f"$2" "$1"; }  # row_field ROWFILE N
# sitemap_locs < XML -> page <loc> values, one per line, CDATA unwrapped and XML entities decoded
sitemap_locs() {
  tr -d '\n\r' | sed -e 's/<!\[CDATA\[//g' -e 's/\]\]>//g' \
    | grep -oE '<([A-Za-z0-9]+:)?loc>[^<]+</([A-Za-z0-9]+:)?loc>' | grep -vE '^<(image|video|news|xhtml):' | sed -E 's/<[^>]*>//g' | tr -d ' \t' \
    | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&apos;/'/g" -e "s/&#0*39;/'/g" -e "s/&#[xX]0*27;/'/g" \
      -e 's/&#0*38;/\&/g' -e 's/&#[xX]0*26;/\&/g' -e 's/&amp;/\&/g'
}
html_type() { case "$(printf '%s' "$DOC_TYPE" | tr 'A-Z' 'a-z')" in text/html*|application/xhtml*) return 0;; esac; return 1; }
is_html() { html_type || body_is_html; }  # on the last fetch_doc
body_is_html() { # on the last fetch_doc: the body opens as an HTML document
  local head
  head=$(printf '%s' "${DOC_BODY:0:512}" | sed $'1s/^\xef\xbb\xbf//' | tr -d ' \t\r\n' | tr 'A-Z' 'a-z')
  case "$head" in '<!doctypehtml'*|'<html>'*|'<html'[a-z]*'='*) return 0;; esac
  return 1
}
# live_file PATH ID [STATUS] -> 0 when PATH serves a real file; otherwise emits STATUS (default FAIL) for ID
live_file() {
  local st="${3:-FAIL}"
  fetch_doc "$BASE_URL$1"
  if [ "$DOC_RC" = 63 ]; then emit WARN "$2" "live $1 declares a body over the $((MAX_BODY / 1048576)) MB audit cap - not read"; return 1; fi
  if [ "$DOC_CODE" != 200 ]; then emit "$st" "$2" "live $1 -> $DOC_CODE"; return 1; fi
  if [ -z "$DOC_BODY" ]; then emit "$st" "$2" "live $1 -> 200 with an empty body"; return 1; fi
  if body_is_html; then emit "$st" "$2" "live $1 answers with an HTML page (${DOC_TYPE:-no content-type}) - a catch-all route is serving it, so the file is not deployed"; return 1; fi
  if html_type; then emit WARN "$2" "live $1 serves file content labelled ${DOC_TYPE} - fix the content type; some crawlers reject it"; fi
}
srcfind() { # srcfind FIND-PREDICATES... -> files outside build output, deps, and agent tooling
  find -H "$REPO_DIR" -mindepth 1 \( -name node_modules -o -name .git -o -name .next -o -name dist -o -name build -o -name out -o -name .nuxt \
    -o -name .svelte-kit -o -name vendor -o -name .agents -o -name .claude -o -name .kimi-code -o -name .cursor \) -prune \
    -o -type f \( "$@" \) -print 2>/dev/null
}

# Serving-platform fingerprints (references/technical-seo.md, serving platforms): NAME<tab>header regex.
# The generator meta joins the headers as a `generator:` line; cf-ray alone only says "behind Cloudflare".
PLATFORM_PRINTS='Vercel	^(x-vercel-id:|server: *vercel)
Netlify	^(x-nf-request-id:|server: *netlify)
Webflow	^(x-wf-page-id:|x-wf-region:|generator: *webflow)
Shopify	^powered-by: *shopify
Wix	^(x-wix-request-id:|generator: *wix)
WordPress.com	^(host-header: *wordpress\.com|generator: *wordpress\.com)
Squarespace	^server: *squarespace
Framer	^(server: *framer|generator: *framer)
Render	^x-render-origin-server:
Fly.io	^(fly-request-id:|server: *fly/)
Railway	^server: *railway
GitHub Pages	^(x-github-request-id:|server: *github\.com)
WordPress	^generator: *wordpress
nginx	^server: *nginx
Apache	^server: *apache'
# platform_of HEADERS BODY -> PLATFORM name (or unknown) and PLATFORM_EVIDENCE
platform_of() {
  local lines gen name re hit
  gen=$(head -c 65536 "$2" | tr -d '\n\r' | grep -oiE "<meta[^>]+name=[\"']?generator[\"' ][^>]*>" | head -1 \
    | sed -nE "s/.*content=[\"']([^\"']+)[\"'].*/\\1/p")
  lines=$(tr -d '\r' <"$1"; [ -z "$gen" ] || printf 'generator: %s\n' "$gen")
  PLATFORM=unknown; PLATFORM_EVIDENCE=""
  while IFS='	' read -r name re; do
    hit=$(grep -iE -m1 "$re" <<<"$lines") || continue
    PLATFORM=$name; PLATFORM_EVIDENCE=${hit:0:80}; break
  done <<<"$PLATFORM_PRINTS"
  grep -qi '^cf-ray:' <<<"$lines" && PLATFORM_EVIDENCE="${PLATFORM_EVIDENCE:+$PLATFORM_EVIDENCE; }behind Cloudflare"
  : "${PLATFORM_EVIDENCE:=no fingerprint}"
}

echo "## STACK"
FRAMEWORK=unknown; ROUTER=none; PKG="$REPO_DIR/package.json"
if [ -n "$NO_REPO" ]; then FRAMEWORK=n/a; ROUTER=n/a
elif [ -f "$PKG" ]; then
  for f in next nuxt @sveltejs/kit astro @remix-run gatsby vite; do
    grep -q "\"$f" "$PKG" && { FRAMEWORK="$f"; break; }
  done
  [ "$FRAMEWORK" = unknown ] && FRAMEWORK=node
else
  [ -f "$REPO_DIR/Gemfile" ] && FRAMEWORK=ruby
  [ -f "$REPO_DIR/pyproject.toml" ] || [ -f "$REPO_DIR/requirements.txt" ] && FRAMEWORK=python
  [ -f "$REPO_DIR/composer.json" ] && FRAMEWORK=php
  [ -f "$REPO_DIR/go.mod" ] && FRAMEWORK=go
fi
if [ "$FRAMEWORK" = next ]; then
  { [ -d "$REPO_DIR/app" ] || [ -d "$REPO_DIR/src/app" ]; } && ROUTER=app
  { [ -d "$REPO_DIR/pages" ] || [ -d "$REPO_DIR/src/pages" ]; } && ROUTER="${ROUTER:+$ROUTER+}pages"
fi
CONFIG_FILE=""
[ -n "$NO_REPO" ] || CONFIG_FILE=$(ls "$REPO_DIR"/next.config.* "$REPO_DIR"/nuxt.config.* "$REPO_DIR"/astro.config.* "$REPO_DIR"/svelte.config.* "$REPO_DIR"/remix.config.* 2>/dev/null | head -1)
echo "FRAMEWORK=$FRAMEWORK ROUTER=$ROUTER CONFIG=${CONFIG_FILE:-none} REPO=$([ -n "$NO_REPO" ] && echo n/a || printf '%s' "$REPO_DIR") BASE_URL=${BASE_URL:-none}"
# One homepage fetch serves the platform fingerprint, the live head checks, and the sample.
HOME_CODE=000
if [ -n "$BASE_URL" ]; then
  fetch_page 0 "$BASE_URL/" follow "$PAGES"
  HOME_CODE=$(row_field "$PAGES/0.row" 3)
  if [ "$HOME_CODE" != 000 ]; then platform_of "$PAGES/0.hdr" "$PAGES/0.body"; echo "PLATFORM=$PLATFORM ($PLATFORM_EVIDENCE)"; fi
fi

echo ""
echo "## STATIC"
if [ -n "$NO_REPO" ]; then emit SKIP STATIC "--no-repo: repository checks not run"; else
# Static files ship from a public/ or static/ directory; a copy anywhere else is
# invisible to the build. A repository with neither serves its root as is.
PUB=""; for d in public static; do [ -d "$REPO_DIR/$d" ] && { PUB="$d"; break; }; done
rel() { awk -v r="$REPO_DIR/" '{ if (index($0, r) == 1) $0 = substr($0, length(r) + 1); print }'; }
shipped() { awk '{ p = "/" $0 } index(p, "/public/") || index(p, "/static/")'; }
unshipped() { awk '{ p = "/" $0 } !index(p, "/public/") && !index(p, "/static/")'; }
# TS-21 robots source
ROBOTS_SHIPPED=$(srcfind -name robots.txt | rel | shipped | head -1)
ROUTE_EXT='\.(js|jsx|ts|tsx|mjs|cjs|php|rb|py)$'
ROBOTS_ROUTE=$(srcfind -name 'robots.*' ! -name '*.txt' | rel | grep -E "(^|/)robots$ROUTE_EXT" | head -1)
ROBOTS_STRAY=$(srcfind -name robots.txt | rel | unshipped | head -1)
if [ -n "$ROBOTS_SHIPPED" ]; then emit PASS TS-21 "robots source found ($ROBOTS_SHIPPED)"
elif [ -n "$ROBOTS_ROUTE" ]; then emit PASS TS-21 "robots route found ($ROBOTS_ROUTE)"
elif [ -n "$ROBOTS_STRAY" ] && [ -n "$PUB" ]; then
  emit WARN TS-21 "$ROBOTS_STRAY is not under $PUB/, the directory the build ships - the live site likely lacks it; verify live"
elif [ -n "$ROBOTS_STRAY" ]; then emit PASS TS-21 "robots source found ($ROBOTS_STRAY)"
else emit FAIL TS-21 "no robots.txt file or robots route found"; fi
# TS-01/TS-03 sitemap sources + orphan heuristic
SM_STATIC=$(srcfind -name '*sitemap*.xml' | rel | shipped | wc -l | tr -d ' ')
SM_ROUTES=$(srcfind -path '*sitemap*route.*' -o -name 'sitemap.*' ! -name '*.xml' | rel \
  | grep -E "((^|/)sitemap(\.xml)?|sitemap[^/]*/route)$ROUTE_EXT" | grep -cvE '\.(test|spec)\.' || true)
SM_STRAY=$(srcfind -name '*sitemap*.xml' | rel | unshipped | head -3 | tr '\n' ' ')
if [ "$SM_STATIC" -gt 0 ] || [ "$SM_ROUTES" -gt 0 ]; then
  emit PASS TS-01 "sitemap sources: $SM_STATIC static file(s), $SM_ROUTES route file(s)"
elif [ -n "$SM_STRAY" ] && [ -n "$PUB" ]; then
  emit WARN TS-01 "sitemap XML not under $PUB/, the directory the build ships: ${SM_STRAY% } - the live site likely lacks it; verify live"
elif [ -n "$SM_STRAY" ]; then emit PASS TS-01 "sitemap file(s) at the served root: ${SM_STRAY% }"
else emit FAIL TS-01 "no sitemap files or routes found"; fi
if [ "$FRAMEWORK" = next ] && [ -n "${CONFIG_FILE:-}" ] && [ "$SM_ROUTES" -gt 1 ]; then
  ORPHANS=""
  for rt in $(find "$REPO_DIR" -type f -path '*sitemap*route.*' 2>/dev/null | grep -vE 'node_modules|\.next'); do
    seg=$(basename "$(dirname "$rt")")
    grep -q "$seg" "$CONFIG_FILE" || srcgrep -l --include='*route*' "$seg-sitemap|sitemaps/$seg" | grep -qv "$rt" || ORPHANS="$ORPHANS $seg"
  done
  [ -n "$ORPHANS" ] && emit WARN TS-03 "sitemap routes possibly unrouted/orphaned:$ORPHANS (verify against index + rewrites)" \
                    || emit PASS TS-03 "no orphan sitemap routes detected"
else emit SKIP TS-03 "orphan heuristic: needs Next.js config + multiple sitemap routes"; fi
# GE-01 llms.txt static
LLMS="$REPO_DIR/${PUB:+$PUB/}llms.txt"
[ -f "$LLMS" ] && emit PASS GE-01 "${PUB:+$PUB/}llms.txt present ($(wc -l < "$LLMS" | tr -d ' ') lines)" \
  || emit WARN GE-01 "no ${PUB:+$PUB/}llms.txt (may be served by a route; verify live)"
# TS-13 dynamic metadata coverage
if [ "$FRAMEWORK" = next ]; then
  GM=$(srcgrep -l --include='*.jsx' --include='*.tsx' --include='*.js' --include='*.ts' 'generateMetadata' | wc -l | tr -d ' ')
  DYN=$(find "$REPO_DIR" -type d -name '*\[*' 2>/dev/null | grep -vE 'node_modules|\.next' | wc -l | tr -d ' ')
  [ "$GM" -gt 0 ] && emit PASS TS-13 "generateMetadata in $GM file(s) vs $DYN dynamic route dir(s)" \
    || emit FAIL TS-13 "no generateMetadata found ($DYN dynamic route dirs exist)"
else
  srcgrep -ql 'og:title|meta name="description"' && emit PASS TS-13 "meta tags found (generic check)" || emit WARN TS-13 "no obvious meta tags (generic check)"
fi
# TS-14 canonicals
CAN=$(srcgrep -l 'canonical' --include='*.jsx' --include='*.tsx' --include='*.js' --include='*.ts' --include='*.html' | wc -l | tr -d ' ')
[ "$CAN" -gt 0 ] && emit PASS TS-14 "canonical referenced in $CAN file(s)" || emit FAIL TS-14 "no canonical URL handling found"
# SD-01 JSON-LD presence, SD-09 invalid strategy attr, SD-04 hardcoded ratings
LD=$(srcgrep -l "${INC[@]}" 'application/ld\+json' | wc -l | tr -d ' ')
[ "$LD" -gt 0 ] && emit PASS SD-01 "JSON-LD injected in $LD file(s)" || emit WARN SD-01 "no JSON-LD found"
BADLD=$(srcgrep -n '<script[^>]*strategy=' --include='*.jsx' --include='*.tsx' | grep -v 'Script' | wc -l | tr -d ' ')
[ "$BADLD" -gt 0 ] && emit FAIL SD-09 "native <script> tags carrying a framework strategy= attr: $BADLD (invalid HTML)" \
  || emit PASS SD-09 "no native script tags with framework-only attrs"
HARDRATE=$(srcgrep -n "${INC[@]}" 'ratingValue["'\'': ]+["'\'']?[0-9]' | wc -l | tr -d ' ')
[ "$HARDRATE" -gt 0 ] && emit WARN SD-04 "$HARDRATE literal ratingValue assignment(s) - trace each to real review data" \
  || emit PASS SD-04 "no hardcoded ratingValue literals"
# PF-04 image component adoption
if [ "$FRAMEWORK" = next ]; then
  NI=$(srcgrep -l 'next/image' | wc -l | tr -d ' '); RAW=$(srcgrep -l '<img[ >]' --include='*.jsx' --include='*.tsx' | wc -l | tr -d ' ')
  [ "$NI" -ge "$RAW" ] && emit PASS PF-04 "next/image in $NI file(s) vs raw <img> in $RAW" || emit WARN PF-04 "raw <img> ($RAW files) outweighs next/image ($NI)"
else
  NOLAZY=$(srcgrep -n '<img' --include='*.html' --include='*.jsx' --include='*.vue' | grep -cv 'loading=' || true)
  emit WARN PF-04 "generic check: $NOLAZY <img> line(s) without loading= (review manually)"
fi
# AA vendor + AA-07 instrumentation depth + PF-17 web-vitals + dormant code
VENDOR=$(srcgrep -l "${INC[@]}" 'googletagmanager|gtag\(|dataLayer|plausible|posthog|fathom|matomo|umami|segment|clarity\.ms' | head -5)
EVENTS=$(srcgrep -n "${INC[@]}" "dataLayer\.push|gtag\('event'|\.track\(" | grep -v 'gtm.start' | wc -l | tr -d ' ')
if [ -n "$VENDOR" ]; then
  emit PASS AA-01 "analytics vendor code present ($(echo "$VENDOR" | head -1))"
  [ "$EVENTS" -gt 0 ] && emit PASS AA-07 "$EVENTS custom event push(es) found" \
    || emit FAIL AA-07 "analytics theater: vendor present but ZERO custom events pushed"
else emit WARN AA-01 "no analytics vendor found in source"; fi
grep -q '"web-vitals"' "$PKG" 2>/dev/null && emit PASS PF-17 "web-vitals dependency present" \
  || emit WARN PF-17 "no web-vitals dependency - real-user CWV likely unmeasured"
DORMANT=$(srcgrep -n "${INC[@]}" '^[[:space:]]*//.*(dataLayer|web-vitals|onLCP|onCLS|onINP|PerfLog|analytics)' | wc -l | tr -d ' ')
[ "$DORMANT" -gt 3 ] && emit WARN PF-17 "$DORMANT commented-out instrumentation line(s) - dormant code is not measurement"
# AA-10 UTM handling
srcgrep -ql "${INC[@]}" 'utm_' && emit PASS AA-10 "UTM handling present" || emit WARN AA-10 "no UTM parameter handling found"
# LC-14 write-endpoint protection sweep
WRITE_ROUTES=$(srcgrep -l --include='route.*' --include='*.js' --include='*.ts' 'POST' | grep -iE 'contact|lead|comment|subscribe|delete' | head -20)
if [ -n "$WRITE_ROUTES" ]; then
  UNPROT=""
  for r in $WRITE_ROUTES; do
    grep -qiE 'recaptcha|turnstile|hcaptcha|rate.?limit|captcha' "$r" || UNPROT="$UNPROT $(basename "$(dirname "$r")")"
  done
  [ -n "$UNPROT" ] && emit WARN LC-14 "write endpoints without captcha/rate-limit tokens:$UNPROT" \
    || emit PASS LC-14 "all detected write endpoints reference protection"
else emit SKIP LC-14 "no lead/comment/contact write routes detected"; fi
# PS-01/PS-09 PSEO signals
GSP=$(srcgrep -l 'generateStaticParams' | wc -l | tr -d ' ')
emit PASS PS-09 "generateStaticParams in $GSP file(s) (0 is fine if no PSEO layer)"
MW=$(ls "$REPO_DIR"/middleware.* "$REPO_DIR"/src/middleware.* 2>/dev/null | head -1)
[ -n "$MW" ] && grep -qE 'redirect' "$MW" && emit WARN PS-01 "middleware performs redirects ($MW) - verify no kill-switch is silently disabling shipped surfaces"
fi

echo ""
echo "## LIVE"
if [ -z "$BASE_URL" ]; then
  emit SKIP LIVE "no BASE_URL provided - static checks only"
elif [ "$HOME_CODE" = 000 ]; then
  emit SKIP LIVE "network unreachable for $BASE_URL - static checks only"
else
  HOST=${BASE_URL#*://}
  # TS-23 canonical host
  [ "${BASE_URL#https://}" != "$BASE_URL" ] && emit PASS TS-23 "HTTPS base" || emit FAIL TS-23 "BASE_URL is not HTTPS"
  HTTP_RED=$(probe "http://$HOST/")
  case "$HTTP_RED" in 301|308) emit PASS TS-23 "http -> https redirects ($HTTP_RED)";; 000) emit WARN TS-23 "http variant unreachable";; *) emit WARN TS-23 "http variant returned $HTTP_RED (expect 301/308)";; esac
  case "$HOST" in www.*) ALT="${HOST#www.}";; *) ALT="www.$HOST";; esac
  ALT_CODE=$(probe "https://$ALT/")
  case "$ALT_CODE" in 301|308) emit PASS TS-23 "www/apex variant redirects ($ALT_CODE)";; 200) emit FAIL TS-23 "both $HOST and $ALT serve 200 - duplicate host";; 000) emit WARN TS-23 "alt host $ALT unreachable (may be unconfigured DNS)";; *) emit WARN TS-23 "alt host $ALT returned $ALT_CODE";; esac
  # robots live + GE-04 AI crawler policy
  if live_file /robots.txt TS-21; then
    ROBOTS=$DOC_BODY
    emit PASS TS-21 "live robots.txt ($(printf '%s' "$ROBOTS" | grep -c 'Sitemap:') Sitemap directive(s))"
    # robots_verdict TOKEN -> explicit-block | explicit-allow | wildcard-block | unspecified, read as a
    # crawler reads robots.txt: a group naming the token beats `*`; stacked User-agent lines share one group.
    robots_verdict() {
      printf '%s\n' "$ROBOTS" | tr -d '\r' | sed $'1s/^\xef\xbb\xbf//' | awk -v ua="$1" '
        BEGIN { ua = tolower(ua) }
        { line = $0; sub(/#.*/, "", line); low = tolower(line) }
        low ~ /^[ \t]*user-agent[ \t]*:/ {
          v = low; sub(/^[ \t]*user-agent[ \t]*:/, "", v); gsub(/[ \t]/, "", v)
          if (!in_ua) { cur_named = 0; cur_wild = 0 }
          in_ua = 1
          if (v == ua) { cur_named = 1; named = 1 }
          if (v == "*") { cur_wild = 1; wild = 1 }
          next
        }
        low ~ /^[ \t]*(allow|disallow)[ \t]*:/ {
          in_ua = 0
          key = low; sub(/[ \t]*:.*/, "", key); gsub(/[ \t]/, "", key)
          val = low; sub(/^[^:]*:/, "", val); gsub(/[ \t]/, "", val)
          if (val == "/*") val = "/"
          if (val == "/" && cur_named) { if (key == "disallow") nblock = 1; else nallow = 1 }
          if (val == "/" && cur_wild) { if (key == "disallow") wblock = 1; else wallow = 1 }
          next
        }
        END {
          if (named) print ((nblock && !nallow) ? "explicit-block" : "explicit-allow")
          else if (wild && wblock && !wallow) print "wildcard-block"
          else print "unspecified"
        }'
    }
    # Robots-honouring training and search-index tokens (references/geo.md, crawler classes).
    # A group naming the token beats `*`; stacked User-agent lines share one group.
    AIRPT=""
    for t in GPTBot OAI-SearchBot ClaudeBot Claude-SearchBot PerplexityBot Google-Extended Applebot Applebot-Extended \
             Meta-ExternalAgent Meta-WebIndexer Amazonbot Amzn-SearchBot MistralAI-Training MistralAI-Index DuckAssistBot CCBot; do
      v=$(robots_verdict "$t")
      AIRPT="$AIRPT $t=$v"
    done
    [ "$(robots_verdict '*')" = explicit-block ] && emit WARN TS-21 "the * group disallows / - Googlebot and every crawler without its own group are blocked; right only for a private surface"
    SIGNAL=$(printf '%s\n' "$ROBOTS" | tr -d '\r' | grep -iE '^[[:space:]]*content-signal[[:space:]]*:' | head -1 | sed -E 's/^[[:space:]]*//')
    case "$AIRPT" in
      *unspecified*) emit WARN GE-04 "AI crawler policy:$AIRPT${SIGNAL:+ | $SIGNAL} (unspecified = default, not a decision)";;
      *) emit PASS GE-04 "AI crawler policy fully explicit:$AIRPT${SIGNAL:+ | $SIGNAL}";;
    esac
  fi
  # TS-01/TS-02 sitemap index + children resolve
  if live_file /sitemap.xml TS-01; then
    SM=$DOC_BODY
    LOCS=$(printf '%s' "$SM" | sitemap_locs)
    NLOC=$(printf '%s\n' "$LOCS" | grep -c . || true)
    if ! grep -qE '<([A-Za-z0-9]+:)?(sitemapindex|urlset)' <<<"$SM"; then
      emit FAIL TS-01 "live /sitemap.xml holds neither <urlset> nor <sitemapindex>"
    elif [ "$NLOC" -eq 0 ]; then
      emit FAIL TS-01 "live /sitemap.xml lists no <loc> entries"
    elif grep -qE '<([A-Za-z0-9]+:)?sitemapindex' <<<"$SM"; then
      emit PASS TS-01 "live sitemap index with $NLOC children"
      BAD=0; CHECKED=0
      for u in $LOCS; do
        [ "$CHECKED" -ge "$MAX_CHILDREN" ] && break
        CHECKED=$((CHECKED+1))
        head_doc "$u"
        if [ "$DOC_CODE" != 200 ]; then BAD=$((BAD+1)); emit FAIL TS-02 "index child $u -> $DOC_CODE"
        elif html_type; then BAD=$((BAD+1)); emit FAIL TS-02 "index child $u answers with an HTML page - a catch-all route is serving it"; fi
      done
      [ "$BAD" -eq 0 ] && emit PASS TS-02 "all $CHECKED index children resolve 200"
      FIRST=$(printf '%s\n' "$LOCS" | head -1)
      SAMPLE=$(fetch "$FIRST" | tr -d '\n\r' | grep -oE '<loc>[^<]+</loc>' | sed -e 's/<loc>//' -e 's|</loc>||' | head -3)
      SBAD=0
      for u in $SAMPLE; do c=$(probe_head "$u"); [ "$c" = 200 ] || SBAD=$((SBAD+1)); done
      [ -n "$SAMPLE" ] && { [ "$SBAD" -eq 0 ] && emit PASS TS-05 "3-URL sample from $(basename "$FIRST") resolves" || emit WARN TS-05 "$SBAD of sampled URLs non-200"; }
    else
      emit PASS TS-01 "live urlset sitemap with $NLOC URLs (no index)"
    fi
  fi
  # GE-01/GE-03 llms.txt live
  # llms.txt is optional (Google Search ignores it), so its absence warns rather than fails
  LLMS_OK=""
  live_file /llms.txt GE-01 WARN && { LLMS_OK=1; emit PASS GE-01 "live /llms.txt (200, ${DOC_TYPE:-no content-type})"; }
  fetch_doc "$BASE_URL/llms-full.txt"
  [ "$DOC_CODE" = 200 ] && [ -n "$DOC_BODY" ] && ! is_html && emit PASS GE-03 "/llms-full.txt present (optional)" \
    || emit SKIP GE-03 "/llms-full.txt absent (optional)"
  # Homepage head signals
  # The STACK fetch followed redirects; every head check below reads the page it ended on, which is
  # not the homepage when the probe hit an error, a login, or a bot challenge.
  if [ "$(row_field "$PAGES/0.row" 2)" = 0 ]; then
    HP_END="$HOME_CODE $(row_field "$PAGES/0.row" 5)"; HP=$(tr -d '\n\r' <"$PAGES/0.body")
  else HP_END="000 $BASE_URL/"; HP=""; fi
  if [ "${HP_END%% *}" != 200 ]; then emit WARN TS-13 "homepage probe ended at ${HP_END#* } with ${HP_END%% *} - the head checks below read that response"
  else HP_PATH=${HP_END#* }; HP_PATH=${HP_PATH#*://}; case "$HP_PATH" in */*) HP_PATH=/${HP_PATH#*/};; *) HP_PATH=/;; esac
    case "$HP_PATH" in *login*|*signin*|*sign-in*|/auth|/auth/*|*challenge*) emit WARN TS-13 "homepage probe ended at ${HP_END#* } - the head checks below read that page, not the homepage";; esac; fi
  TITLE=$(printf '%s' "$HP" | grep -oE '<title[^>]*>[^<]*' | head -1 | sed 's/<title[^>]*>//')
  [ -n "$TITLE" ] && emit PASS TS-13 "homepage <title> (${#TITLE} chars): ${TITLE:0:80}" || emit FAIL TS-13 "homepage missing <title>"
  grep -q 'name="description"' <<<"$HP" && emit PASS TS-13 "meta description present" || emit FAIL TS-13 "homepage missing meta description"
  grep -q 'rel="canonical"' <<<"$HP" && emit PASS TS-14 "homepage canonical present" || emit WARN TS-14 "homepage canonical missing"
  OG=$(printf '%s' "$HP" | grep -oiE "<meta[^>]+(property|name)=[\"']og:image[\"'][^>]*>" | head -1 \
    | sed -nE "s/.*content=[\"']([^\"']+)[\"'].*/\\1/p" | sed 's/&amp;/\&/g')
  if [ -z "$OG" ]; then emit WARN TS-17 "homepage og:image missing"
  else
    case "$OG" in
      //*) OG="${BASE_URL%%://*}:$OG";;
      /*) OG="$BASE_URL$OG";;
      http://*|https://*) ;;
      *) OG="$BASE_URL/$OG";;
    esac
    head_doc "$OG" -L
    case "$DOC_CODE $(printf '%s' "$DOC_TYPE" | tr 'A-Z' 'a-z')" in
      "200 image/"*) emit PASS TS-17 "og:image resolves ($OG -> $DOC_TYPE)";;
      *) emit FAIL TS-17 "og:image $OG -> $DOC_CODE ${DOC_TYPE:-no content-type} - link previews get no image";;
    esac
  fi
  grep -q 'name="twitter:card"' <<<"$HP" && emit PASS TS-18 "twitter:card present" || emit WARN TS-18 "twitter:card missing"
  NLD=$(printf '%s' "$HP" | grep -o 'application/ld+json' | wc -l | tr -d ' ')
  [ "$NLD" -gt 0 ] && emit PASS SD-01 "homepage renders $NLD JSON-LD block(s)" || emit WARN SD-01 "no JSON-LD in homepage HTML"
  if [ -z "$LLMS_OK" ]; then emit SKIP GE-02 "no llms.txt to point at"
  else
    DESC_TAG=$(printf '%s' "$HP" | grep -oiE '<link[^>]+>' | grep -i 'describedby' | grep -i 'llms\.txt' | head -1)
    DESC_HDR=$(tr -d '\r' <"$PAGES/0.hdr" | grep -i '^link:' | grep -i 'describedby' | grep -i 'llms\.txt' | head -1)
    if [ -n "$DESC_TAG$DESC_HDR" ]; then emit PASS GE-02 "rel=describedby points at llms.txt (${DESC_TAG:+link element}${DESC_TAG:+${DESC_HDR:+ and }}${DESC_HDR:+Link header})"
    else emit WARN GE-02 "llms.txt live but no rel=describedby link or Link header points at it"; fi
  fi
  # TS-27 soft-404
  NF=$(probe "$BASE_URL/definitely-missing-page-$$-audit")
  [ "$NF" = 404 ] && emit PASS TS-27 "garbage URL returns 404" || emit FAIL TS-27 "garbage URL returns $NF (soft-404 if 200)"
fi

. "$HERE/sample.sh"
echo ""
echo "## SAMPLE"
if [ "$SAMPLE_N" -eq 0 ]; then emit SKIP SAMPLE "--sample 0: sampled-page checks not run"
elif [ -z "$BASE_URL" ] || [ "$HOME_CODE" = 000 ]; then emit SKIP SAMPLE "needs a reachable BASE_URL"
else sample_section; fi

echo ""
echo "## SUMMARY"
echo "PASS=$P FAIL=$F WARN=$W SKIP=$S"
if [ -n "$FAILED_IDS" ]; then
  echo "Failed checks:$FAILED_IDS"
  echo "NEXT: load the reference file for each failed prefix:"
  for pfx in TS SD PS PF CS AA LC GE; do
    case "$FAILED_IDS" in *" $pfx-"*)
      case "$pfx" in
        TS) echo "  $pfx-* -> references/technical-seo.md";;
        SD) echo "  $pfx-* -> references/structured-data.md";;
        PS) echo "  $pfx-* -> references/pseo.md";;
        PF) echo "  $pfx-* -> references/performance.md";;
        CS) echo "  $pfx-* -> references/content-systems.md";;
        AA) echo "  $pfx-* -> references/analytics-attribution.md";;
        LC) echo "  $pfx-* -> references/leads-conversion.md";;
        GE) echo "  $pfx-* -> references/geo.md";;
      esac;;
    esac
  done
fi
exit 0
