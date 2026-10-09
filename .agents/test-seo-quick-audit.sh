#!/usr/bin/env bash
# Firing tests for the seo-geo-growth-audit quick-audit.sh file checks. A
# single-page app's catch-all answers every path 200 with its index page, so a
# robots.txt, sitemap, or llms.txt check that reads only the status passes a
# site that serves none of them.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
audit="$repo/.agents/skills/seo-geo-growth-audit/scripts/quick-audit.sh"
scratch="$(mktemp -d)"
server_pid=""
stop_server() { [ -z "$server_pid" ] || { kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; server_pid=""; }; }
trap 'stop_server; rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

cat >"$scratch/server.py" <<'PY'
import http.server
import sys

MODE = sys.argv[1]
INDEX = ("text/html; charset=utf-8", b"<!doctype html>\n<html><head><title>App</title></head><body></body></html>\n")
URLSET = b'<?xml version="1.0"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">%s</urlset>'
TEXT = "text/plain; charset=utf-8"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.reply(send_body=True)

    def do_HEAD(self):
        self.reply(send_body=False)

    def reply(self, send_body):
        base = "http://%s:%d" % self.server.server_address
        routes = {}
        if MODE == "good":
            routes = {
                "/robots.txt": (TEXT, b"User-agent: *\nAllow: /\nSitemap: " + base.encode() + b"/sitemap.xml\n"),
                "/sitemap.xml": ("application/xml", URLSET % (b"<url><loc>%s/</loc></url><url><loc>%s/faq</loc></url>" % (base.encode(), base.encode()))),
                "/llms.txt": (TEXT, b"# App\n"),
            }
        elif MODE == "empty":
            routes = {"/robots.txt": (TEXT, b""), "/sitemap.xml": ("application/xml", URLSET % b"")}
        elif MODE == "badchild":
            index = b'<?xml version="1.0"?><sitemapindex><sitemap><loc>%s/sitemap-pages.xml</loc></sitemap></sitemapindex>' % base.encode()
            routes = {"/sitemap.xml": ("application/xml", index)}
        elif MODE == "quirks":
            prefixed = (
                b'<?xml version="1.0"?><sm:urlset xmlns:sm="http://www.sitemaps.org/schemas/sitemap/0.9">'
                b"<sm:url><sm:loc><![CDATA[%s/a]]></sm:loc></sm:url><sm:url><sm:loc>\n %s/b \n</sm:loc></sm:url></sm:urlset>"
            ) % (base.encode(), base.encode())
            routes = {
                "/robots.txt": ("TEXT/HTML", b"<!-- c --><div>spa</div>"),
                "/sitemap.xml": ("text/xml", prefixed),
                "/llms.txt": ("text/markdown", b"# App\n<html-like> text\n"),
            }
        path = self.path.split("?")[0]
        if path in routes:
            status, (ctype, body) = 200, routes[path]
        elif MODE == "spa" or (MODE == "badchild" and path.endswith(".xml")):
            status, (ctype, body) = 200, INDEX
        else:
            status, ctype, body = 404, TEXT, b"not found\n"
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if send_body:
            self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY

# A BASE_URL in the caller's environment would point the static fixtures at a real site.
unset BASE_URL
empty_repo="$scratch/empty-repo"
mkdir -p "$empty_repo"

# serve runs in this shell, not in $(...), so the EXIT trap can stop the server.
serve() {  # <mode> -> starts the test server; audit_live then runs against it
  stop_server
  : >"$scratch/port"
  python3 -I "$scratch/server.py" "$1" >"$scratch/port" &
  server_pid=$!
  for _ in $(seq 50); do [ -s "$scratch/port" ] && break; sleep 0.1; done
  [ -s "$scratch/port" ] || fail "test server for '$1' did not start"
}
audit_live() { "$audit" "$empty_repo" "http://127.0.0.1:$(cat "$scratch/port")" --timeout 3; }
has() { [[ "$1" == *"$2"* ]] || fail "$3: expected '$2' in:"$'\n'"$1"; }
lacks() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in:"$'\n'"$1"; }

serve spa; out="$(audit_live)"
has "$out" "[FAIL] TS-21 - live /robots.txt answers with an HTML page" "catch-all robots.txt"
has "$out" "[FAIL] TS-01 - live /sitemap.xml answers with an HTML page" "catch-all sitemap"
has "$out" "[FAIL] GE-01 - live /llms.txt answers with an HTML page" "catch-all llms.txt"
has "$out" "[SKIP] GE-03" "catch-all llms-full.txt"
ok "a catch-all that answers every file path with its index page fails robots, sitemap, and llms.txt"

serve good; out="$(audit_live)"
has "$out" "[PASS] TS-21 - live robots.txt (1 Sitemap directive(s))" "real robots.txt"
has "$out" "[PASS] TS-01 - live urlset sitemap with 2 URLs" "real sitemap"
has "$out" "[PASS] GE-01 - live /llms.txt (200" "real llms.txt"
has "$out" "[PASS] TS-27" "real 404"
ok "real files pass and a missing page answers 404"

serve empty; out="$(audit_live)"
has "$out" "[FAIL] TS-01 - live /sitemap.xml lists no <loc> entries" "empty sitemap"
has "$out" "[FAIL] TS-21 - live /robots.txt -> 200 with an empty body" "empty robots.txt"
has "$out" "[FAIL] GE-01 - live /llms.txt -> 404" "missing llms.txt"
ok "an empty sitemap, an empty robots.txt, and a missing llms.txt fail"

serve badchild; out="$(audit_live)"
has "$out" "[PASS] TS-01 - live sitemap index with 1 children" "sitemap index"
has "$out" "[FAIL] TS-02 - index child http://127.0.0.1:$(cat "$scratch/port")/sitemap-pages.xml answers with an HTML page" "catch-all index child"
has "$out" "[FAIL] TS-21 - live /robots.txt -> 404" "missing robots.txt"
ok "a sitemap index child answered by the catch-all fails"

serve quirks; out="$(audit_live)"
has "$out" "[FAIL] TS-21 - live /robots.txt answers with an HTML page (TEXT/HTML)" "upper-case HTML content type"
has "$out" "[PASS] TS-01 - live urlset sitemap with 2 URLs" "prefixed sitemap with CDATA and padded locs"
has "$out" "[PASS] GE-01 - live /llms.txt (200, text/markdown)" "markdown llms.txt holding an angle-bracket line"
ok "content types match case-insensitively, prefixed sitemaps parse, and only a leading HTML document counts as HTML"
stop_server

fixture() {  # <name> <files...> -> fixture repo path holding those files
  local d="$scratch/$1"; shift
  mkdir -p "$d"
  for f in "$@"; do mkdir -p "$d/$(dirname "$f")"; printf 'User-agent: *\nDisallow:\n' >"$d/$f"; done
  printf '%s' "$d"
}

out="$("$audit" "$(fixture stray public/favicon.ico robots.txt sitemap.xml)")"
has "$out" "[WARN] TS-21 - robots.txt is not under public/" "robots.txt outside public/"
has "$out" "[WARN] TS-01 - sitemap XML not under public/, the directory the build ships: sitemap.xml -" "sitemap outside public/"
ok "robots.txt and sitemap.xml beside a public/ directory warn that the build does not ship them"

out="$("$audit" "$(fixture shipped public/robots.txt public/sitemap.xml)")"
has "$out" "[PASS] TS-21 - robots source found (public/robots.txt)" "robots.txt in public/"
has "$out" "[PASS] TS-01 - sitemap sources: 1 static file(s), 0 route file(s)" "sitemap in public/"
ok "files in public/ pass"

out="$("$audit" "$(fixture monorepo public/favicon.ico apps/web/public/robots.txt apps/web/public/sitemap.xml)")"
has "$out" "[PASS] TS-21 - robots source found (apps/web/public/robots.txt)" "robots.txt in a nested public/"
has "$out" "[PASS] TS-01 - sitemap sources: 1 static file(s)" "sitemap in a nested public/"
ok "files in an app's own public/ pass in a monorepo"

out="$("$audit" "$(fixture routed app/robots.ts app/sitemap.ts)")"
has "$out" "[PASS] TS-21 - robots route found (app/robots.ts)" "robots route"
has "$out" "[PASS] TS-01 - sitemap sources: 0 static file(s), 1 route file(s)" "sitemap route"
ok "framework routes pass"

out="$("$audit" "$(fixture build app/robots.ts app/sitemap.ts)")"
has "$out" "[PASS] TS-21 - robots route found" "repo directory named build"
has "$out" "[PASS] TS-01 - sitemap sources: 0 static file(s), 1 route file(s)" "repo directory named build"
ok "a repository whose own directory is named like build output is still searched"

root="$(fixture rootserved robots.txt sitemap.xml)"
for arg in "$root" "$root/" "$root//"; do
  out="$("$audit" "$arg")"
  has "$out" "[PASS] TS-21 - robots source found (robots.txt)" "root-served robots.txt via '$arg'"
  has "$out" "[PASS] TS-01 - sitemap file(s) at the served root: sitemap.xml" "root-served sitemap via '$arg'"
  lacks "$(grep "^\[" <<<"$out")" "$root" "absolute path in a finding via '$arg'"
done
ok "with no public directory, files at the root pass, with or without a trailing slash"
