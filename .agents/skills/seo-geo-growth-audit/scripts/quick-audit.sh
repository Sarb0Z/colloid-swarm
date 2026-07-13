#!/usr/bin/env bash
# quick-audit.sh — evidence baseline for the seo-geo-growth-audit skill.
# Usage: quick-audit.sh [REPO_DIR] [BASE_URL] [--max-children N] [--timeout SECS]
# Static checks always run; live checks run only when BASE_URL is reachable.
# Exit 0 when the audit ran (findings never change the exit code); 2 on usage errors.
set -u
LC_ALL=C

REPO_DIR="."
BASE_URL="${BASE_URL:-}"
MAX_CHILDREN=100   # index children to verify; caps runtime on huge sitemap indexes
TIMEOUT=10         # per-request curl timeout in seconds
UA="seo-geo-growth-audit/2.0 (+quick-audit.sh)"

usage() { sed -n '2,5p' "$0"; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage 0 ;;
    --max-children) MAX_CHILDREN="${2:-100}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-10}"; shift 2 ;;
    http://*|https://*) BASE_URL="${1%/}"; shift ;;
    -*) echo "unknown flag: $1" >&2; usage 2 ;;
    *) REPO_DIR="$1"; shift ;;
  esac
done
[ -d "$REPO_DIR" ] || { echo "REPO_DIR not found: $REPO_DIR" >&2; exit 2; }

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
probe()   { curl -sS -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" -A "$UA" "$1" 2>/dev/null || echo 000; }
probe_head() { local c; c=$(curl -sS -o /dev/null -I -w '%{http_code}' --max-time "$TIMEOUT" -A "$UA" "$1" 2>/dev/null || echo 000)
  case "$c" in 405|501) probe "$1";; *) echo "$c";; esac; }
fetch()   { curl -sS --max-time "$TIMEOUT" -A "$UA" "$1" 2>/dev/null; }

echo "## STACK"
FRAMEWORK=unknown; ROUTER=none; PKG="$REPO_DIR/package.json"
if [ -f "$PKG" ]; then
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
CONFIG_FILE=$(ls "$REPO_DIR"/next.config.* "$REPO_DIR"/nuxt.config.* "$REPO_DIR"/astro.config.* "$REPO_DIR"/svelte.config.* "$REPO_DIR"/remix.config.* 2>/dev/null | head -1)
echo "FRAMEWORK=$FRAMEWORK ROUTER=$ROUTER CONFIG=${CONFIG_FILE:-none} REPO=$REPO_DIR BASE_URL=${BASE_URL:-none}"

echo ""
echo "## STATIC"
# TS-21 robots source
if [ -f "$REPO_DIR/public/robots.txt" ] || srcgrep -l --include='robots.*' 'robots|Disallow' >/dev/null; then
  emit PASS TS-21 "robots source found ($(ls "$REPO_DIR/public/robots.txt" 2>/dev/null || srcgrep -l --include='robots.*' 'Disallow|rules' | head -1))"
else emit FAIL TS-21 "no robots.txt file or robots route found"; fi
# TS-01/TS-03 sitemap sources + orphan heuristic
SM_STATIC=$(find "$REPO_DIR/public" -maxdepth 1 -name '*sitemap*.xml' 2>/dev/null | wc -l | tr -d ' ')
SM_ROUTES=$(find "$REPO_DIR" -path '*node_modules*' -prune -o -type f \( -path '*sitemap*route.*' -o -name 'sitemap.*' \) -print 2>/dev/null | grep -vE 'node_modules|\.next|public/' | wc -l | tr -d ' ')
if [ "$SM_STATIC" -gt 0 ] || [ "$SM_ROUTES" -gt 0 ]; then
  emit PASS TS-01 "sitemap sources: $SM_STATIC static file(s), $SM_ROUTES route file(s)"
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
[ -f "$REPO_DIR/public/llms.txt" ] && emit PASS GE-01 "public/llms.txt present ($(wc -l < "$REPO_DIR/public/llms.txt" | tr -d ' ') lines)" \
  || emit WARN GE-01 "no public/llms.txt (may be served by a route; verify live)"
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

echo ""
echo "## LIVE"
if [ -z "$BASE_URL" ]; then
  emit SKIP LIVE "no BASE_URL provided - static checks only"
elif [ "$(probe "$BASE_URL/")" = 000 ]; then
  emit SKIP LIVE "network unreachable for $BASE_URL - static checks only"
else
  HOST=${BASE_URL#*://}
  # TS-23 canonical host
  [ "${BASE_URL#https://}" != "$BASE_URL" ] && emit PASS TS-23 "HTTPS base" || emit FAIL TS-23 "BASE_URL is not HTTPS"
  HTTP_RED=$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" -A "$UA" "http://$HOST/" 2>/dev/null || echo 000)
  case "$HTTP_RED" in 301|308) emit PASS TS-23 "http -> https redirects ($HTTP_RED)";; 000) emit WARN TS-23 "http variant unreachable";; *) emit WARN TS-23 "http variant returned $HTTP_RED (expect 301/308)";; esac
  case "$HOST" in www.*) ALT="${HOST#www.}";; *) ALT="www.$HOST";; esac
  ALT_CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" -A "$UA" "https://$ALT/" 2>/dev/null || echo 000)
  case "$ALT_CODE" in 301|308) emit PASS TS-23 "www/apex variant redirects ($ALT_CODE)";; 200) emit FAIL TS-23 "both $HOST and $ALT serve 200 - duplicate host";; 000) emit WARN TS-23 "alt host $ALT unreachable (may be unconfigured DNS)";; *) emit WARN TS-23 "alt host $ALT returned $ALT_CODE";; esac
  # robots live + GE-04 AI crawler policy
  ROBOTS=$(fetch "$BASE_URL/robots.txt")
  if [ -n "$ROBOTS" ]; then
    emit PASS TS-21 "live robots.txt ($(printf '%s' "$ROBOTS" | grep -c 'Sitemap:') Sitemap directive(s))"
    AIRPT=""
    for t in GPTBot ClaudeBot anthropic-ai PerplexityBot Google-Extended CCBot; do
      v=$(printf '%s\n' "$ROBOTS" | awk -v ua="$t" 'BEGIN{f=0;done=0}
        tolower($0) ~ "^user-agent:[ \t]*"tolower(ua) {f=1;next}
        f && tolower($0) ~ /^user-agent:/ {exit}
        f && tolower($0) ~ /^disallow:[ \t]*\/[ \t]*$/ {print "explicit-block";done=1;exit}
        f && tolower($0) ~ /^(allow|disallow):/ {print "explicit-allow";done=1;exit}
        END{if(!done) print f ? "mentioned" : "unspecified"}')
      AIRPT="$AIRPT $t=$v"
    done
    case "$AIRPT" in
      *unspecified*) emit WARN GE-04 "AI crawler policy:$AIRPT (unspecified = default, not a decision)";;
      *) emit PASS GE-04 "AI crawler policy fully explicit:$AIRPT";;
    esac
  else emit FAIL TS-21 "no live /robots.txt"; fi
  # TS-01/TS-02 sitemap index + children resolve
  SM=$(fetch "$BASE_URL/sitemap.xml")
  if [ -z "$SM" ]; then emit FAIL TS-01 "live /sitemap.xml missing or empty"
  else
    LOCS=$(printf '%s' "$SM" | tr -d '\n\r' | grep -oE '<loc>[^<]+</loc>' | sed -e 's/<loc>//' -e 's|</loc>||')
    NLOC=$(printf '%s\n' "$LOCS" | grep -c . || true)
    if printf '%s' "$SM" | grep -q '<sitemapindex'; then
      emit PASS TS-01 "live sitemap index with $NLOC children"
      BAD=0; CHECKED=0
      for u in $LOCS; do
        [ "$CHECKED" -ge "$MAX_CHILDREN" ] && break
        CHECKED=$((CHECKED+1))
        c=$(probe_head "$u"); [ "$c" = 200 ] || { BAD=$((BAD+1)); emit FAIL TS-02 "index child $u -> $c"; }
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
  LLMS_CODE=$(probe "$BASE_URL/llms.txt")
  [ "$LLMS_CODE" = 200 ] && emit PASS GE-01 "live /llms.txt (200)" || emit FAIL GE-01 "/llms.txt -> $LLMS_CODE"
  [ "$(probe "$BASE_URL/llms-full.txt")" = 200 ] && emit PASS GE-03 "/llms-full.txt present (optional)" || emit SKIP GE-03 "/llms-full.txt absent (optional)"
  # Homepage head signals
  HP=$(fetch "$BASE_URL/" | tr -d '\n\r')
  TITLE=$(printf '%s' "$HP" | grep -oE '<title[^>]*>[^<]*' | head -1 | sed 's/<title[^>]*>//')
  [ -n "$TITLE" ] && emit PASS TS-13 "homepage <title> (${#TITLE} chars): ${TITLE:0:80}" || emit FAIL TS-13 "homepage missing <title>"
  printf '%s' "$HP" | grep -q 'name="description"' && emit PASS TS-13 "meta description present" || emit FAIL TS-13 "homepage missing meta description"
  printf '%s' "$HP" | grep -q 'rel="canonical"' && emit PASS TS-14 "homepage canonical present" || emit WARN TS-14 "homepage canonical missing"
  printf '%s' "$HP" | grep -q 'property="og:image"' && emit PASS TS-17 "og:image present" || emit WARN TS-17 "homepage og:image missing"
  printf '%s' "$HP" | grep -q 'name="twitter:card"' && emit PASS TS-18 "twitter:card present" || emit WARN TS-18 "twitter:card missing"
  NLD=$(printf '%s' "$HP" | grep -o 'application/ld+json' | wc -l | tr -d ' ')
  [ "$NLD" -gt 0 ] && emit PASS SD-01 "homepage renders $NLD JSON-LD block(s)" || emit WARN SD-01 "no JSON-LD in homepage HTML"
  printf '%s' "$HP" | grep -q 'rel="llms"' && emit PASS GE-02 "rel=llms discovery link present" || emit WARN GE-02 "no rel=llms link in head"
  # TS-27 soft-404
  NF=$(probe "$BASE_URL/definitely-missing-page-$$-audit")
  [ "$NF" = 404 ] && emit PASS TS-27 "garbage URL returns 404" || emit FAIL TS-27 "garbage URL returns $NF (soft-404 if 200)"
fi

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
