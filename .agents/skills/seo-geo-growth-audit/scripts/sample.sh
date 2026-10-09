# shellcheck shell=bash
# sample.sh — sampled-page checks, sourced by quick-audit.sh after its LIVE section.
# Shares quick-audit.sh's emit, fetch_page, row_field, sitemap_locs, the DOC_* helpers, and its
# BASE_URL, SAMPLE_N, MAX_LINKS, MAX_BODY, WORK, PAGES, STOP, HERE, ROBOTS, SM, LOCS, PLATFORM.
# Bounds: SAMPLE_N pages, MAX_LINKS link probes, 4 requests at a time, MAX_BODY per body, http(s) on
# the audited host and its www/apex pair only, no redirect followed. A blocked, timed-out, truncated,
# or crashed step is a SKIP or WARN with its reason, never a FAIL. Page analysis is analyze-pages.py,
# which has no network.
PYTHON="${PYTHON:-python3}"
SITEMAP_CAP=10   # sitemap files fetched to build the pool, nested indexes included

# fetch_wave LIST DIR: fetch every "ID<tab>URL<tab>MODE" line of LIST, 4 at a time, until STOP exists
fetch_wave() {
  local id u m rest n=0
  while IFS='	' read -r id u m rest; do
    [ ! -e "$STOP" ] || break
    fetch_page "$id" "$u" "$m" "$2" </dev/null &
    n=$((n + 1)); [ $((n % 4)) -ne 0 ] || wait
  done <"$1"
  wait
}

sample_hosts() { # -> SITE_HOST (host[:port] of BASE_URL, lower case) and SITE_ALT, its www/apex pair
  SITE_HOST=$(printf '%s' "${BASE_URL#*://}" | sed 's|[/?#].*||' | tr 'A-Z' 'a-z')
  case "$SITE_HOST" in www.*) SITE_ALT=${SITE_HOST#www.};; *) SITE_ALT=www.$SITE_HOST;; esac
}

# on_site COUNTFILE < URLS -> the http(s) URLs on SITE_HOST or SITE_ALT; how many others there were goes to COUNTFILE
on_site() {
  awk -v a="$SITE_HOST" -v b="$SITE_ALT" -v cnt="$1" '
    { l = tolower($0) }
    l ~ /^https?:\/\/[^\/?#@]+([\/?#]|$)/ { h = l; sub(/^https?:\/\//, "", h); sub(/[\/?#].*/, "", h); if (h == a || h == b) { print; next } }
    { other++ }
    END { print other + 0 > cnt }'
}

# page_blocked ROWFILE -> the evidence, when the response is a bot wall. This is the one definition of
# "blocked" for the sample: pages, link probes, and association files all ask it before any status rule.
page_blocked() {
  local b="${1%.row}" ev=""
  case "$(row_field "$1" 3)" in 401|403|429|503) ev=$(row_field "$1" 3);; esac
  [ ! -f "$b.hdr" ] || ! grep -qi '^cf-mitigated:' "$b.hdr" || ev="${ev:+$ev, }cf-mitigated"
  [ ! -f "$b.body" ] || ! head -c 65536 "$b.body" | tr -d '\n\r' \
    | grep -qiE '<title[^>]*>[^<]*(just a moment|attention required|access denied)' || ev="${ev:+$ev, }challenge title"
  [ -n "$ev" ] && printf '%s\n' "$ev"
}

# with_wall ROWFILE -> the row with the page_blocked evidence appended as its last column
with_wall() { printf '%s\t%s\n' "$(cat "$1")" "$(page_blocked "$1")"; }

# sitemap_read ID URL -> page locs appended to SD/locs, nested sitemap locs to SD/sm-next
sitemap_read() {
  local id="$1" u="$2" rc code gz
  rc=$(row_field "$SD/$id.row" 2); code=$(row_field "$SD/$id.row" 3)
  if [ "$rc" != 0 ] || [ "$code" != 200 ]; then
    emit WARN SAMPLE "sitemap $u unreadable (status $code, curl exit $rc) - its URLs are not sampled"; return
  fi
  if [ "$(head -c 2 "$SD/$id.body" | od -An -tx1 | tr -d ' \n')" = 1f8b ]; then
    gzip -dc <"$SD/$id.body" | head -c "$MAX_BODY" >"$SD/$id.xml"; gz=${PIPESTATUS[0]}
    if [ "$gz" != 0 ] && [ "$(wc -c <"$SD/$id.xml")" -lt "$MAX_BODY" ]; then
      emit WARN SAMPLE "sitemap $u does not decompress (gzip exit $gz) - its URLs are not sampled"; return
    fi
  else mv "$SD/$id.body" "$SD/$id.xml"; fi
  DOC_BODY=$(head -c 512 "$SD/$id.xml")
  if body_is_html; then emit WARN SAMPLE "sitemap $u answers with an HTML page - its URLs are not sampled"; return; fi
  if grep -qE '<([A-Za-z0-9]+:)?sitemapindex' "$SD/$id.xml"; then sitemap_locs <"$SD/$id.xml" >>"$SD/sm-next"
  else sitemap_locs <"$SD/$id.xml" >>"$SD/locs"; fi
}

# Callers redirect a file into the functions that emit, never a pipe: bash 3.2 runs the last stage of a
# pipeline in a subshell, which would drop the PASS/FAIL/WARN/SKIP counters.
# sample_sitemaps < SITEMAP_URLS -> SD/locs gains the page locs of up to SITEMAP_CAP on-site sitemaps,
# taken in order and expanding nested indexes; sitemaps on other hosts are counted, never fetched
sample_sitemaps() {
  local left=$SITEMAP_CAP level=0 off=0 id u rest
  on_site "$SD/sm-off" >"$SD/sm-next"; off=$(cat "$SD/sm-off")
  while [ -s "$SD/sm-next" ] && [ "$left" -gt 0 ] && [ ! -e "$STOP" ]; do
    level=$((level + 1))
    head -n "$left" "$SD/sm-next" | awk -v l="$level" '{ print "s" l "-" NR "\t" $0 "\tget" }' >"$SD/sm-list"
    left=$((left - $(grep -c . "$SD/sm-list"))); : >"$SD/sm-next"
    fetch_wave "$SD/sm-list" "$SD"
    while IFS='	' read -r id u rest; do [ ! -f "$SD/$id.row" ] || sitemap_read "$id" "$u"; done <"$SD/sm-list"
    on_site "$SD/sm-off" <"$SD/sm-next" >"$SD/sm-kept"; mv "$SD/sm-kept" "$SD/sm-next"; off=$((off + $(cat "$SD/sm-off")))
  done
  [ "$off" -eq 0 ] || emit WARN SAMPLE "$off sitemap file(s) on another host or scheme - not fetched, their URLs are not sampled"
}

# robots_sitemaps -> the on-site Sitemap: URLs of the live robots.txt other than /sitemap.xml itself
robots_sitemaps() {
  printf '%s\n' "${ROBOTS:-}" | tr -d '\r' | awk -v skip="$BASE_URL/sitemap.xml" '
    tolower($0) ~ /^[ \t]*sitemap[ \t]*:/ { v = $0; sub(/^[^:]*:[ \t]*/, "", v); sub(/[ \t]+$/, "", v); if (v != "" && v != skip) print v }'
}

# sample_pool < LOCS -> SD/pool: "ID<tab>URL<tab>MODE<tab>1", SAMPLE_N entries counting the homepage
# (ID 0, fetched by STACK): up to 3 per first path segment in sitemap order, then round-robin across
# segments. SD/home-listed says whether the sitemap lists the page the homepage landed on. Files that
# are not pages get a HEAD request only.
sample_pool() {
  on_site "$SD/offsite" | awk -v n="$SAMPLE_N" -v home="$HOME_URL" -v hfile="$SD/home-listed" '
    function key(u) { u = tolower(u); sub(/#.*/, "", u); sub(/\/+$/, "", u); return u }
    function seg(u) { sub(/^[^:]*:\/\/[^\/?#]*/, "", u); sub(/[?#].*/, "", u); sub(/^\/+/, "", u); sub(/\/.*/, "", u); return u }
    function take(u,   p) { p = tolower(u); sub(/[?#].*/, "", p)
      print taken++ "\t" u "\t" ((p ~ /\.(pdf|jpe?g|png|gif|webp|avif|svg|mp4|webm|mov|mp3|zip|gz|xml|docx?|xlsx?|pptx?|csv)$/) ? "head" : "get") "\t1" }
    seen[$0]++ { next }
    key($0) == key(home) { listed = 1; next }
    { s = seg($0); if (!(s in cnt)) order[++ns] = s; at[s, ++cnt[s]] = $0; all[++na] = $0; rank[na] = cnt[s] }
    END {
      taken = 1
      for (i = 1; i <= na && taken < n; i++) if (rank[i] <= 3) take(all[i])
      for (r = 4; taken < n; r++) {
        more = 0
        for (j = 1; j <= ns && taken < n; j++) if (r <= cnt[order[j]]) { take(at[order[j], r]); more = 1 }
        if (!more) break
      }
      print listed + 0 > hfile
    }' >"$SD/pool"
}

# sample_fetch -> pages fetched into PAGES; returns 1 after emitting a SKIP when the site walls off the audit
sample_fetch() {
  local i n=0 b=0
  head -n 7 "$SD/pool" >"$SD/wave1"; tail -n +8 "$SD/pool" >"$SD/wave2"
  fetch_wave "$SD/wave1" "$PAGES"
  for i in 0 1 2 3 4 5 6 7; do
    [ -f "$PAGES/$i.body" ] || continue
    n=$((n + 1)); ! page_blocked "$PAGES/$i.row" >/dev/null || b=$((b + 1))
  done
  if [ "$n" -gt 1 ] && [ $((b * 2)) -ge "$n" ]; then
    emit SKIP SAMPLE "blocked to the audit client ($b of the first $n pages answered with a bot wall)"; return 1
  fi
  fetch_wave "$SD/wave2" "$PAGES"
  [ ! -e "$STOP" ] || emit WARN SAMPLE "rate limited (429) at $(head -1 "$STOP") - stopped issuing requests; results cover the pages fetched before it"
}

# sample_manifest -> SD/manifest, one row per fetched page (columns documented in analyze-pages.py).
# The homepage row is the page the STACK fetch landed on, when that page is on the audited host.
sample_manifest() {
  local id flag b
  { printf '0\t%s\n' "$(cat "$SD/home-listed")"; cut -f1,4 "$SD/pool"; } | while IFS='	' read -r id flag; do
    [ -f "$PAGES/$id.row" ] || continue
    b="$PAGES/$id.body"; [ -f "$b" ] || b=""
    with_wall "$PAGES/$id.row" | awk -F'\t' -v OFS='\t' -v b="$b" -v h="$PAGES/$id.hdr" -v f="$flag" -v home="$HOME_URL" -v id="$id" '
      id == 0 && home != "" { $1 = home; $4 = 0; $7 = "" }
      { print $1, $2, $3, $4, $5, $6, b, h, $7, f, $8 }'
  done >"$SD/manifest"
}

# sample_links -> TS-40: probe the internal links the analyzer collected, without following redirects
sample_links() {
  local LD="$WORK/links" total id rest st lid detail
  total=$(grep -c . "$SD/links.txt")
  if [ -e "$STOP" ]; then emit SKIP TS-40 "$total internal links not probed - the site rate-limited the audit (429)"; return; fi
  if [ "$total" -eq 0 ]; then emit SKIP TS-40 "no internal links on the sampled pages"; return; fi
  if [ "$MAX_LINKS" -eq 0 ]; then emit SKIP TS-40 "--max-links 0: $total internal links not probed"; return; fi
  mkdir -p "$LD"
  sort -u "$SD/links.txt" | head -n "$MAX_LINKS" | awk '{ print "l" NR "\t" $0 "\tprobe" }' >"$LD/list"
  fetch_wave "$LD/list" "$LD"
  while IFS='	' read -r id rest; do [ ! -f "$LD/$id.row" ] || with_wall "$LD/$id.row"; done <"$LD/list" >"$LD/rows"
  awk -F'\t' -v found="$total" '
    function ex(a, n,   s, i) { for (i = 1; i <= n && i <= 5; i++) s = s (i > 1 ? ", " : "") a[i]; return s (n > 5 ? ", ..." : "") }
    $8 != "" { blk++; next }
    $3 ~ /^2/ { ok++; next }
    $3 ~ /^3/ { p = tolower($7); sub(/^[a-z]+:\/\/[^\/]*/, "", p); sub(/[?#].*/, "", p)
                if (p ~ /(^|\/)(login|log-in|signin|sign-in|auth|oauth|sso)(\/|$)/) { auth++; next }
                red[++nr] = $1 " -> " ($7 == "" ? "no Location" : $7) " (" $3 ")"; next }
    $3 ~ /^(404|410|5[0-9][0-9])$/ { bad[++nb] = $1 " (" $3 ")"; next }
    { oth[++no] = $1 " (" ($3 == "000" || $3 == "" ? "no response, curl exit " $2 : $3) ")" }
    END {
      sum = NR " of " found " internal links probed; " auth + 0 " auth redirect(s) (expected)"
      if (nb) printf "FAIL\tTS-40\t%d internal link(s) answer 404/410/5xx: %s [%s]\n", nb, ex(bad, nb), sum
      if (nr) printf "WARN\tTS-40\t%d internal link(s) redirect - link the final URL directly: %s [%s]\n", nr, ex(red, nr), sum
      if (blk + no) printf "SKIP\tTS-40\t%d link(s) not checked: %d blocked to the audit client%s%s\n", blk + no, blk, (no ? "; " : ""), ex(oth, no)
      if (!nb && !nr && ok + auth > 0) printf "PASS\tTS-40\t%s; %d answer 2xx directly\n", sum, ok
    }' "$LD/rows" >"$LD/findings"
  while IFS='	' read -r st lid detail; do emit "$st" "$lid" "$detail"; done <"$LD/findings"
}

# store_file PATH LABEL -> TS-37 verdict for one app-association file on the site's final origin
store_file() {
  local id="${1##*/}" code rc ev
  if [ -e "$STOP" ]; then emit SKIP TS-37 "$1 not checked - the site rate-limited the audit (429)"; return; fi
  fetch_page "$id" "$ORIGIN$1" get "$SD"
  rc=$(row_field "$SD/$id.row" 2); code=$(row_field "$SD/$id.row" 3)
  DOC_TYPE=$(row_field "$SD/$id.row" 6); DOC_BODY=$(head -c 512 "$SD/$id.body")
  if ev=$(page_blocked "$SD/$id.row"); then emit SKIP TS-37 "$1 not checked - blocked to the audit client ($ev)"; return; fi
  if [ "$rc" != 0 ]; then emit SKIP TS-37 "$1 not checked (status $code, curl exit $rc)"; return; fi
  case "$code" in
    3??) emit FAIL TS-37 "$1 redirects ($code -> $(row_field "$SD/$id.row" 7)) - the OS fetches it without following redirects";;
    404|410) emit WARN TS-37 "$1 absent ($code) while the site links its own $2 app - needed only if the app opens links to this domain";;
    200) if body_is_html; then emit WARN TS-37 "$1 answers with an HTML page (a catch-all), so it is absent - needed only if the app opens links to this domain"
         elif [ "$(printf '%s' "$DOC_TYPE" | tr 'A-Z' 'a-z' | sed 's/;.*//; s/ //g')" != application/json ]; then emit WARN TS-37 "$1 answers 200 as ${DOC_TYPE:-no content-type} - serve application/json"
         else emit PASS TS-37 "$1 answers 200 application/json without a redirect"; fi;;
    *) emit FAIL TS-37 "$1 answers $code - the OS treats the association as missing";;
  esac
}

# sample_stores -> TS-37: association files when the site links its own app (an app meta tag, or a store
# link in the header, nav, or footer), and storefront agreement per App Store app id
sample_stores() {
  local split ORIGIN
  [ -s "$SD/stores.txt" ] || return 0
  ORIGIN=$(row_field "$PAGES/0.row" 5 | sed -E 's|^([A-Za-z]+://[^/?#]+).*|\1|')
  [ -n "$(printf '%s\n' "$ORIGIN" | on_site "$SD/origin-offsite")" ] || ORIGIN=$(printf '%s' "$BASE_URL" | sed -E 's|^([A-Za-z]+://[^/?#]+).*|\1|')
  ! grep -qiE '^own	https?://(apps|itunes)\.apple\.com/' "$SD/stores.txt" || store_file /.well-known/apple-app-site-association "App Store"
  ! grep -qiE '^own	https?://play\.google\.com/' "$SD/stores.txt" || store_file /.well-known/assetlinks.json "Google Play"
  split=$(cut -f2 "$SD/stores.txt" | tr 'A-Z' 'a-z' | awk '
    match($0, /^https?:\/\/(apps|itunes)\.apple\.com\/[a-z][a-z]\//) && match($0, /\/id[0-9]+/) {
      id = substr($0, RSTART + 1, RLENGTH - 1); u = $0; sub(/^https?:\/\/[^\/]+\//, "", u); cc = substr(u, 1, 2)
      if (!((id, cc) in seen)) { seen[id, cc] = 1; ccs[id] = ccs[id] (ccs[id] == "" ? "" : " ") cc; n[id]++ }
    }
    END { for (id in n) if (n[id] > 1) printf "%s (%s)\n", id, ccs[id] }' | sort | awk '{ printf "%s%s", (NR > 1 ? ", " : ""), $0 }')
  [ -z "$split" ] || emit WARN TS-37 "one App Store app opens different storefronts: $split - every store link should agree on the target market"
}

sample_section() {
  local SD="$WORK/sample" ev robots="" st id detail final HOME_URL=""
  mkdir -p "$SD"
  if ! "$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then
    emit SKIP SAMPLE "python3 >= 3.8 unavailable (PYTHON=$PYTHON) - sampled-page checks not run"; return
  fi
  if ev=$(page_blocked "$PAGES/0.row"); then emit SKIP SAMPLE "blocked to the audit client (homepage: $ev)"; return; fi
  sample_hosts
  final=$(row_field "$PAGES/0.row" 5)
  [ -z "$(printf '%s\n' "$final" | on_site "$SD/home-off")" ] || HOME_URL=$final
  : >"$SD/locs"
  if [ -n "${SM:-}" ] && [ -n "${LOCS:-}" ]; then
    if grep -qE '<([A-Za-z0-9]+:)?sitemapindex' <<<"$SM"; then
      printf '%s\n' "$LOCS" | head -n "$SITEMAP_CAP" >"$SD/sm-in"; sample_sitemaps <"$SD/sm-in"
    else printf '%s\n' "$LOCS" >"$SD/locs"; fi
  fi
  if [ -z "$(on_site "$SD/x" <"$SD/locs")" ] && [ -n "$(robots_sitemaps)" ]; then
    emit WARN SAMPLE "/sitemap.xml gave no usable URLs - sampling from the Sitemap: lines of robots.txt"
    robots_sitemaps | head -n "$SITEMAP_CAP" >"$SD/sm-in"; sample_sitemaps <"$SD/sm-in"
  fi
  sample_pool <"$SD/locs"
  [ "$(cat "$SD/offsite")" -eq 0 ] || emit WARN TS-22 "$(cat "$SD/offsite") sitemap URL(s) on other hosts or non-http(s) schemes - a sitemap lists only URLs on its own host"
  sample_fetch || return 0
  sample_manifest
  if [ -n "${ROBOTS:-}" ]; then printf '%s\n' "$ROBOTS" >"$SD/robots.txt"; robots="$SD/robots.txt"; fi
  if ! "$PYTHON" -I "$HERE/analyze-pages.py" "$SD/manifest" "$BASE_URL" "$(date -u +%Y)" "$robots" "$SD" "${PLATFORM:-unknown}" \
      >"$SD/findings" 2>"$SD/analyzer.err"; then
    emit SKIP SAMPLE "page analyzer failed: $(grep . "$SD/analyzer.err" | tail -1)"; return
  fi
  while IFS='	' read -r st id detail; do emit "$st" "$id" "$detail"; done <"$SD/findings"
  sample_links
  sample_stores
}
