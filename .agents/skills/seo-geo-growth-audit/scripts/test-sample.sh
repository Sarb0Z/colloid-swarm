#!/usr/bin/env bash
# Firing tests for the sampled-page checks of quick-audit.sh (sample.sh and analyze-pages.py),
# run by test-quick-audit.sh. Every defect lives on its own fixture page; the good fixture holds
# the look-alikes each check must not flag. PYTHON selects the interpreter under test, and the audit
# runs under the bash running this file, so `/bin/bash test-sample.sh` exercises bash 3.2 on macOS.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
audit="$here/quick-audit.sh"
py="${PYTHON:-python3}"
scratch="$(mktemp -d)"
server_pid=""
stop_server() { [ -z "$server_pid" ] || { kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; server_pid=""; }; }
trap 'stop_server; rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

cat >"$scratch/server.py" <<'PY'
import gzip
import http.server
import json
import sys
import threading
import time
from urllib.parse import unquote

MODE, LOG, PEAK = sys.argv[1], sys.argv[2], sys.argv[3]
TEXT = "text/plain; charset=utf-8"
HTML = "text/html; charset=utf-8"
YEAR = time.gmtime().tm_year
LOCK = threading.Lock()
IN_FLIGHT = [0, 0]


def page(title, head="", body="", desc=None, canonical=None):
    desc = desc if desc is not None else title + " description"
    canon = '<link rel="canonical" href="%s">' % canonical if canonical else ""
    return ("<!doctype html><html><head><title>%s</title><meta name=\"description\" content=\"%s\">%s%s</head>"
            "<body><h1>%s</h1>%s</body></html>" % (title, desc, canon, head, title, body)).encode()


def ld(obj):
    return '<script type="application/ld+json">%s</script>' % json.dumps(obj)


def urlset(base, paths):
    locs = "".join("<url><loc>%s</loc></url>" % (p if "://" in p else base + p) for p in paths)
    return ('<?xml version="1.0"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">%s</urlset>' % locs).encode()


MALFORMED = '<a href="https://[link]">a</a><a href="http://[broken">b</a>'
ROBOTS_OK = (TEXT, b"User-agent: *\nAllow: /\n")


def bad(base):
    org = {"@context": "https://schema.org", "@type": "Organization", "name": "Fixture", "url": base + "/",
           "logo": base + "/logo.png", "aggregateRating": {"@type": "AggregateRating", "ratingValue": 5, "reviewCount": 9}}
    pages = {
        "/": page("Fixture home", ld(org), '<a href="/links">links</a>', canonical="/"),
        "/noindex-meta": page("Meta noindex", '<meta name="robots" content="noindex, follow">'),
        "/noindex-header": page("Header noindex"),
        "/private/page": page("Private page"),
        "/js-redirect": page("Script redirect", "<script>var map={\"/old\":\"/new\"};if(map[location.pathname]){location.replace(map[location.pathname]);}</script>"),
        "/title-patch": page("Title patch", "<script>document.title = 'Patched title';</script>"),
        "/script-noindex": page("Script noindex", "<script>var m=document.createElement('meta');m.name='robots';m.content='noindex';document.head.appendChild(m);</script>"),
        "/script-ld": page("Script JSON-LD", "<script>var s=document.createElement('script');s.type='application/ld+json';s.text='{}';document.head.appendChild(s);</script>"),
        "/script-ld-rewrite": page("Script JSON-LD rewrite", "<script>document.querySelectorAll('script[type=\"application/ld+json\"]').forEach(function(e){e.textContent = e.textContent.replace('a', 'b');});</script>"),
        "/bad-ld": page("Broken JSON-LD", '<script type="application/ld+json">{"@type": "Thing",}</script>'),
        "/dates": page("Reversed dates", ld({"@type": "Article", "headline": "x", "datePublished": "2024-05-02", "dateModified": "2024-05-01"})),
        "/future-date": page("Future date", ld({"@type": "Article", "headline": "x", "datePublished": "2999-01-01T00:00:00Z"})),
        "/empty-sameas": page("Empty sameAs", ld({"@type": "Organization", "name": "Fixture", "sameAs": ["", "https://social.test/fixture"]})),
        "/breadcrumb": page("Relative breadcrumb", ld({"@type": "BreadcrumbList", "itemListElement": [{"@type": "ListItem", "position": 1, "name": "Products", "item": "/products"}]})),
        "/relative-image": page("Relative logo", ld({"@type": "Organization", "name": "Fixture", "logo": "/logo.png"})),
        "/main-entity": page("Main entity", ld({"@type": "WebPage", "url": base + "/other-url"}), canonical="/main-entity"),
        "/freshness": page("Best widgets for %d" % (YEAR - 1)),
        "/lorem": page("Lorem page", body="<p>Lorem ipsum dolor sit amet.</p>"),
        "/bracket": page("Bracket page", body="<p>[Hero headline - offer, one line]</p>"),
        "/bracket-word": page("Bracket word page", body="<p>[Insert testimonial here]</p>"),
        "/webfont": page("Webfont loader", '<script src="https://ajax.googleapis.com/ajax/libs/webfont/1.6.26/webfont.js"></script>'),
        "/webfont-inline": page("Webfont inline", "<script>WebFont.load({google: {families: ['Inter']}});</script>"),
        "/font-import": page("Font import", '<style>@import url("https://fonts.googleapis.com/css2?family=Inter");</style>'),
        "/third-party": page("Third-party script", '<noscript><iframe src="https://tags.vendor.test/ns"></iframe></noscript>'
                             '<script src="https://widgets.vendor.test/w.js"></script>'),
        "/placeholder": page("{{ page.title }}", body='<a href="https://example.com/start">start</a>'),
        "/dup-title": page("Fixture home"),
        "/canon-home": page("Canonical home", canonical="/"),
        "/cafe-utf8": page("Café menu"),
        "/links": page("Links", body='<a href="/missing-link">a</a><a href="/old-link">b</a><a href="/private/secret">c</a>'
                       '<a rel="nofollow" href="/nofollow-target">d</a><a href="/moved-new#top">e</a><a href="/busy">f</a>' + MALFORMED),
        "/store": page("Store", body='<footer><a href="https://apps.apple.com/us/app/fixture/id1">us</a>'
                       '<a href="https://apps.apple.com/gb/app/fixture/id1">gb</a></footer>'),
        "/thank-you": page("Thank you"),
        "/q": page("Query page"),
    }
    listed = ["/", "/missing", "/moved", "/maintenance", "/noindex-meta", "/noindex-header", "/private/page", "/q?a=1&amp;b=2",
              "/files/guide.pdf", "file:///etc/passwd"] + [p for p in pages if p not in ("/", "/private/page", "/q", "/thank-you")]
    routes = {p: (HTML, b) for p, b in pages.items()}
    routes.update({
        "/robots.txt": (TEXT, b"User-agent: *\nDisallow: /private/\n"),
        "/sitemap.xml": ("application/xml", ('<?xml version="1.0"?><sitemapindex><sitemap><loc>%s/sitemap-pages.xml</loc></sitemap>'
                                             '<sitemap><loc>%s/sitemap-more.xml.gz</loc></sitemap></sitemapindex>' % (base, base)).encode()),
        "/sitemap-pages.xml": ("application/xml", urlset(base, listed + ["/cafe-latin1"])),
        "/sitemap-more.xml.gz": ("application/gzip", gzip.compress(urlset(base, ["/thank-you"]))),
        "/cafe-latin1": ("text/html", page("Café menu", '<meta charset="iso-8859-1">').decode().encode("latin-1")),
        "/moved": (HTML, b"", 301, {"Location": base + "/moved-new"}),
        "/old-link": (HTML, b"", 301, {"Location": base + "/moved-new"}),
        "/moved-new": (HTML, page("Moved target")),
        "/busy": (TEXT, b"busy\n", 503),
        "/maintenance": (TEXT, b"down for maintenance\n", 503),
    })
    routes["/noindex-header"] = (HTML, pages["/noindex-header"], 200, {"X-Robots-Tag": "noindex"})
    routes["/"] = (HTML, pages["/"], 200, {"x-wf-region": "us-east-1", "cf-ray": "0-TEST"})
    return routes


def good(base):
    org = {"@context": "https://schema.org", "@graph": [
        {"@type": "Organization", "@id": base + "/#org", "name": "Fixture shop", "url": base + "/", "logo": base + "/logo.png",
         "sameAs": ["https://social.test/fixture"]},
        {"@type": "WebPage", "url": base, "name": "Fixture shop"}]}
    payload = "self.__next_f.push([1,\"\\u003cscript type=\\\"application/ld+json\\\"\\u003e{}\\u003c/script\\u003e\"]);document.title='x'"
    rated = {"@type": "AggregateRating", "ratingValue": 4, "reviewCount": 3}
    products = [{"@type": "Product", "name": n, "url": base + "/item/" + n} for n in ("one", "two", "three")]
    pages = {
        "/blog/one": page("Post one"), "/blog/two": page("Post two"), "/blog/three": page("Post three"), "/blog/four": page("Post four"),
        "/": page("Fixture shop", ld(org) + '<script src="https://cdn.shopify.com/s/theme.js"></script>', '<a href="/links-good">links</a>', canonical="/"),
        "/next-page": page("Next page", "<script>%s</script>" % payload + ld({"@type": "WebPage", "url": base + "/next-page/"}), canonical="/next-page"),
        "/event": page("Spring event", ld({"@type": "Event", "name": "Spring event", "startDate": "2999-04-01",
                                            "offers": {"@type": "Offer", "price": "1", "priceValidUntil": "2999-03-01"}})),
        "/about": page("Best service since 2010", desc="Serving customers since 2010; founded 2009."),
        "/tax": page("Filing taxes for %d" % (YEAR - 1), desc="What changed for the %d tax year." % (YEAR - 1)),
        "/history": page("Our story in %d (%d edition)" % (YEAR - 2, YEAR - 1), '<meta name="page-config" content="{{ settings }}">',
                         "<p>[Update: new rates]</p><p>[Editor note - …]</p><p>[PDF - 2 MB]</p>",
                         desc="Best tools for %d, kept as an archive." % (YEAR - 10)),
        "/code-sample": page("Code sample", body="<pre>{{ x }}</pre><code>https://example.com/api</code><code><a href=\"https://example.com/doc\">doc</a></code>"),
        "/email": page("Contact", body='<a href="/cdn-cgi/l/email-protection" class="__cf_email__" data-cfemail="00">[email&#160;protected]</a> [email protected]'),
        "/directory": page("Directory listing", ld({"@context": "https://schema.org", "@graph": [
            {"@type": "LocalBusiness", "name": "Listed plumber", "url": base + "/directory/listed-plumber", "aggregateRating": rated},
            {"@type": "LocalBusiness", "name": "Other business", "url": "https://other-business.test/", "aggregateRating": rated}]})),
        "/category": page("Category", ld(products)),
        "/stamp": page("Stamped article", ld({"@type": "Article", "headline": "x", "url": base + "/stamp", "datePublished": "2025-01-01T10:00:00.123456789Z",
                                               "dateModified": "2025-01-02T10:00:00.5+02:00"}), canonical="/stamp"),
        "/scripts": page("Scripts page", '<script type="module" src="https://cdn.vendor.test/m.js"></script><script async src="https://tags.vendor.test/t.js"></script>'
                         '<link rel="stylesheet" media="print" href="https://cdn.vendor.test/print.css">'),
        "/image-preview": page("Image preview", '<meta name="robots" content="index, follow, max-image-preview:none">'),
        "/links-good": page("Links", body='<a href="/login">login</a><a href="/about">about</a><a href="/c{a,b}">braces</a>'
                            '<a href="https://apps.apple.com/us/app/one/id2">one</a><a href="https://apps.apple.com/gb/app/two/id3">two</a>'
                            + MALFORMED + '<footer><a href="https://play.google.com/store/apps/details?id=test.fixture">app</a></footer>'),
        "/r[1-3]": page("Bracketed path"),
        "/it's-here": page("Apostrophe path"),
        "/scoped-header": page("Scoped header"),
    }
    routes = {p: (HTML, b) for p, b in pages.items()}
    routes.update({
        "/robots.txt": ROBOTS_OK,
        "/sitemap.xml": ("application/xml", urlset(base, [p for p in pages if p not in ("/links-good-x", "/it's-here")] + ["/latin", "/it&#39;s-here"])),
        "/latin": ("text/html", page("Résumé tips", '<meta charset="iso-8859-1">').decode().encode("latin-1")),
        "/login": (HTML, b"", 302, {"Location": "/signin"}),
        "/signin": (HTML, page("Sign in")),
        "/c{a,b}": (HTML, page("Braces")),
        "/.well-known/assetlinks.json": ("application/json", b"[]"),
    })
    # Some CDNs gzip a cached page whether or not the client asked for it.
    routes["/"] = (HTML, gzip.compress(pages["/"]), 200, {"powered-by": "Shopify", "Content-Encoding": "gzip"})
    routes["/scoped-header"] = (HTML, pages["/scoped-header"], 200, {"X-Robots-Tag": "otherbot: noindex"})
    return routes


def numbered(base, walled):
    routes = {"/robots.txt": ROBOTS_OK, "/": (HTML, page("Home", body='<a href="/p1">p1</a>'))}
    routes["/sitemap.xml"] = ("application/xml", urlset(base, ["/p%d" % i for i in range(1, 13)]))
    for i in range(1, 13):
        routes["/p%d" % i] = walled.get(i) or (HTML, page("Page %d" % i))
    return routes


def hosts(base):
    other = base.replace("127.0.0.1", "localhost")
    return {
        "/robots.txt": (TEXT, ("User-agent: *\nAllow: /\nSitemap: %s/sm/pages.xml\nSitemap: %s/sm/other.xml\n" % (base, other)).encode()),
        "/sm/pages.xml": ("application/xml", urlset(base, ["/", "/alpha", "/beta"])),
        "/": (HTML, page("Home", body='<a href="/alpha">a</a><a href="%s/elsewhere">x</a>' % other, canonical=other + "/")),
        "/alpha": (HTML, page("Alpha")), "/beta": (HTML, page("Beta")),
    }


def blocked(base):
    wall = b"<!doctype html><html><head><title>Just a moment...</title></head><body></body></html>"
    return {"*": (HTML, wall, 403, {"cf-mitigated": "challenge"})}


def truncated(base):
    oversize = {"Content-Length": "6000000"}
    return {
        "/": (HTML, page("Home", body='<a href="/walled">w</a>')),
        "/walled": (TEXT, b"no\n", 403),
        "/robots.txt": ROBOTS_OK,
        "/sitemap.xml": ("application/xml", urlset(base, ["/slow", "/huge"])),
        "/huge": (HTML, page("Huge"), 200, oversize),
        "/llms.txt": (TEXT, b"# App\n", 200, oversize),
    }


MODES = {
    "sample-bad": bad, "sample-good": good, "sample-blocked": blocked, "sample-truncated": truncated, "sample-hosts": hosts,
    "sample-429": lambda base: numbered(base, {5: (TEXT, b"slow down\n", 429)}),
    "sample-mixed": lambda base: numbered(base, {i: (TEXT, b"no\n", 403) for i in range(1, 5)}),
}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.counted(True)

    def do_HEAD(self):
        self.counted(False)

    def counted(self, send_body):
        with LOCK:
            IN_FLIGHT[0] += 1
            IN_FLIGHT[1] = max(IN_FLIGHT)
            with open(LOG, "a") as log:
                log.write("%s %s %s\n" % (self.command, self.path, self.headers.get("Host", "")))
            with open(PEAK, "w") as peak:
                peak.write(str(IN_FLIGHT[1]))
        try:
            self.reply(send_body)
        finally:
            with LOCK:
                IN_FLIGHT[0] -= 1

    def reply(self, send_body):
        base = "http://%s:%d" % self.server.server_address
        path = unquote(self.path.split("?")[0])
        if MODE == "sample-truncated" and path == "/slow":
            return self.stall(send_body)
        if MODE == "sample-good" and send_body and not path.endswith((".txt", ".xml", ".json")):
            time.sleep(0.1)
        if path == "/files/guide.pdf":
            route = ("application/pdf", b"%PDF-1.4", 200) if not send_body else (TEXT, b"downloaded", 500)
        elif path == "/q" and self.path != "/q?a=1&b=2":
            route = (TEXT, b"not found\n", 404)
        else:
            routes = MODES[MODE](base)
            route = routes.get(path) or routes.get("*") or (TEXT, b"not found\n", 404)
        ctype, body = route[0], route[1]
        status = route[2] if len(route) > 2 else 200
        extra = route[3] if len(route) > 3 else {}
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        if "Content-Length" not in extra:
            self.send_header("Content-Length", str(len(body)))
        for name, value in extra.items():
            self.send_header(name, value)
        self.end_headers()
        if send_body:
            self.wfile.write(body)
        if "Content-Length" in extra:
            self.close_connection = True

    def stall(self, send_body):
        self.send_response(200)
        self.send_header("Content-Type", HTML)
        self.send_header("Content-Length", "100000")
        self.end_headers()
        if send_body:
            self.wfile.write(b'<!doctype html><html><head><title>Slow</title><script type="application/ld+json">{"@type": "Art')
            self.wfile.flush()
            time.sleep(8)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY

unset BASE_URL
empty_repo="$scratch/empty-repo"
mkdir -p "$empty_repo"
real_curl="$(command -v curl)"
shim="$scratch/shim"; mkdir -p "$shim"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/curl.log"\nexec "%s" "$@"\n' "$scratch" "$real_curl" >"$shim/curl"
chmod +x "$shim/curl"

serve() {  # <mode> -> starts the fixture server, logging every request; audit_live then runs against it
  stop_server
  : >"$scratch/port"; : >"$scratch/requests"; : >"$scratch/curl.log"; echo 0 >"$scratch/peak"
  "$py" -I "$scratch/server.py" "$1" "$scratch/requests" "$scratch/peak" >"$scratch/port" &
  server_pid=$!
  for _ in $(seq 50); do [ -s "$scratch/port" ] && break; sleep 0.1; done
  [ -s "$scratch/port" ] || fail "test server for '$1' did not start"
  base="http://127.0.0.1:$(cat "$scratch/port")"
}
audit_live() { PATH="$shim:$PATH" "$BASH" "$audit" "$empty_repo" "$base" --timeout 3 "$@"; }
section() { sed -n '/^## SAMPLE$/,/^## SUMMARY$/p' <<<"$1"; }
hits() { grep -c -F -x -- "$1" "$scratch/requests" || true; }
has() { [[ "$1" == *"$2"* ]] || fail "$3: expected '$2' in:"$'\n'"$1"; }
lacks() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in:"$'\n'"$1"; }
year=$(date -u +%Y)

serve sample-bad; out="$(audit_live --sample 60)"; s="$(section "$out")"
has "$s" "[PASS] SAMPLE - sampled" "the sample runs past malformed URLs"
[ "$(hits "GET /moved-new 127.0.0.1:$(cat "$scratch/port")")" = 0 ] || fail "a sampled redirect is not followed"
has "$s" "[WARN] SAMPLE - 1 page(s) blocked to the audit client - not analyzed: $base/maintenance (503)" "a 503 page is blocked, not a TS-22 failure"
lacks "$s" "etc/passwd" "a file:// loc leaves no TS-22 row"
lacks "$(cat "$scratch/curl.log")" "file:" "a file:// loc is never handed to curl"
lacks "$s" "q?a=1" "an entity-encoded query loc resolves once decoded"
lacks "$s" "guide.pdf" "a PDF loc is checked by HEAD, never downloaded"
lacks "$s" "nofollow-target" "a nofollow link is not probed"
lacks "$s" "private/secret" "a robots-disallowed link is not probed"
has "$out" "PLATFORM=Webflow (x-wf-region: us-east-1; behind Cloudflare)" "a builder fingerprint behind a proxy"
has "$s" "[FAIL] TS-22 - 1 sitemapped URL(s) answer 404/410/5xx: $base/missing (404)" "a 404 loc"
has "$s" "[FAIL] TS-22 - 1 sitemapped URL(s) redirect - list the final URL: $base/moved -> $base/moved-new" "a redirected loc"
has "$s" "[FAIL] TS-22 - 3 sitemapped page(s) carry noindex: $base/noindex-meta, $base/noindex-header, $base/script-noindex (set by script)" "noindex by meta, header, and script"
has "$s" "[FAIL] TS-22 - 1 sitemapped URL(s) disallowed for Googlebot by robots.txt: $base/private/page" "a robots-disallowed loc"
has "$s" "[WARN] TS-22 - 1 utility page(s) in the sitemap: $base/thank-you" "a utility page from the gzip child"
has "$s" "[WARN] TS-22 - 1 sitemap URL(s) on other hosts or non-http(s) schemes" "a file:// loc is dropped"
has "$s" "(2 URL(s) that redirected or failed not analyzed; 1 sitemapped file(s) checked by HEAD only)" "redirects and the PDF are not analyzed"
has "$s" "[WARN] TS-39 - 1 page(s) with a redirect map or path redirect applied by script" "a script redirect map"
has "$s" "[WARN] TS-39 - 1 page(s) with a document.title applied by script" "a script title patch"
has "$s" "[WARN] TS-39 - 1 page(s) with a robots meta applied by script" "a script robots meta"
has "$s" "[WARN] TS-39 - 2 page(s) with a JSON-LD injection or rewrite applied by script: reaches only crawlers that render (TS-39): $base/script-ld, $base/script-ld-rewrite" "script-injected JSON-LD"
has "$s" "[FAIL] SD-10 - 1 JSON-LD block(s) that do not parse: $base/bad-ld" "unparseable JSON-LD"
has "$s" "[FAIL] SD-13 - 1 dateModified earlier than datePublished: $base/dates" "reversed dates"
has "$s" "[WARN] SD-13 - 1 publication date(s) in the future: $base/future-date" "a future date"
has "$s" "[WARN] SD-12 - 1 empty JSON-LD value(s): $base/empty-sameas (sameAs)" "an empty sameAs"
has "$s" "[WARN] SD-12 - 1 self-rated Organization/LocalBusiness" "a self-rated organization"
has "$s" "[WARN] SD-07 - 1 breadcrumb item(s) relative" "a relative breadcrumb item"
has "$s" "[WARN] SD-07 - 1 relative image/logo URL(s) in JSON-LD (practice): $base/relative-image (logo: /logo.png)" "a relative logo"
has "$s" "[WARN] SD-07 - 1 main entity url(s) differ from the page canonical (practice): $base/main-entity" "a main entity off its canonical"
has "$s" "[WARN] TS-19 - 1 page(s) carry a past year as freshness in the title or description: $base/freshness (\"Best widgets for $((year - 1))\")" "a last-year freshness title"
has "$s" "[WARN] LC-39 - 1 page(s) show lorem ipsum: $base/lorem" "lorem ipsum"
has "$s" "[WARN] LC-39 - 2 page(s) show bracket placeholder copy: $base/bracket ([Hero headline - offer, one line]), $base/bracket-word ([Insert testimonial here])" "bracket placeholders"
has "$s" "[WARN] TS-36 - 1 page(s) link or load template placeholder hosts: $base/placeholder" "an example.com link"
has "$s" "[WARN] TS-36 - 1 page(s) with unrendered {{ }} template tags in title/meta: $base/placeholder" "an unrendered template tag"
has "$s" "[WARN] TS-36 - 2 malformed URL value(s) in href, src, canonical, or JSON-LD: $base/links (https://[link]), $base/links (http://[broken)" "malformed hrefs"
has "$s" "[WARN] PF-10 - 1 page(s) load a font loader synchronously in the head: $base/webfont" "a sync webfont loader"
has "$s" "[WARN] PF-10 - 1 page(s) call WebFont.load inline in the head: $base/webfont-inline" "an inline WebFont.load"
has "$s" "[WARN] PF-10 - 1 page(s) @import a font host in an inline style: $base/font-import" "a font-host @import"
has "$s" "[WARN] PF-21 - 2 third-party host(s) render-blocking in the head: ajax.googleapis.com (1 page), widgets.vendor.test (1 page)" "sync third-party head scripts"
has "$s" "[PASS] AA-29 - third-party script hosts (2): ajax.googleapis.com, widgets.vendor.test" "script host inventory"
has "$s" "[WARN] TS-32 - 1 page(s) reuse the homepage title: $base/dup-title" "a page reusing the homepage title"
has "$s" "[WARN] TS-32 - 1 page(s) canonicalize to the homepage: $base/canon-home" "a page canonicalized to the homepage"
has "$s" '[WARN] TS-13 - 2 title(s) shared by 2+ sampled pages: "fixture home" (2 pages' "a shared title"
has "$s" "\"café menu\" (2 pages: $base/cafe-utf8, $base/cafe-latin1)" "a Latin-1 page decodes by its meta charset"
has "$s" "[SKIP] TS-40 - 1 link(s) not checked: 1 blocked to the audit client" "a 503 link is blocked, not broken"
has "$s" "[FAIL] TS-40 - 1 internal link(s) answer 404/410/5xx: $base/missing-link (404)" "a broken internal link"
has "$s" "[WARN] TS-40 - 1 internal link(s) redirect - link the final URL directly: $base/old-link -> $base/moved-new (301)" "a redirected internal link"
has "$s" "[WARN] TS-37 - /.well-known/apple-app-site-association absent (404) while the site links its own App Store app" "a footer App Store link without an association file"
has "$s" "[WARN] TS-37 - one App Store app opens different storefronts: id1 (gb us)" "one app id under two country codes"
ok "the bad fixture fires every sampled-page check once, on its own page"

serve sample-good
out="$(audit_live --sample 6)"
has "$(section "$out")" "[PASS] SAMPLE - sampled 6 page(s) across 4 URL families" "three per family first: the fourth post waits for round-robin"
out="$(audit_live)"; s="$(section "$out")"
port="$(cat "$scratch/port")"
[ "$(hits "GET /r[1-3] 127.0.0.1:$port")" = 1 ] || fail "a bracketed loc is one request: $(grep -F '/r' "$scratch/requests")"
braced="HEAD /c{a,b} 127.0.0.1:$port"   # bash 3.2 brace-expands this inside a nested "$(... "...")"
n=$(hits "$braced"); [ "$n" = 1 ] || fail "a braced link is one request, saw $n"
[ "$(hits "GET /it's-here 127.0.0.1:$port")" = 1 ] || fail "an apostrophe loc decodes from &#39;: $(grep -F 'here' "$scratch/requests")"
has "$out" "PLATFORM=Shopify (powered-by: Shopify)" "platform from response headers"
has "$out" "[PASS] TS-13 - homepage <title> (12 chars): Fixture shop" "a gzip body the client never asked for is decoded"
has "$s" "[PASS] SAMPLE - sampled 22 page(s) across 19 URL families" "positive anchor; the fourth post is filled in round-robin"
has "$s" "[PASS] PF-21 - no render-blocking third-party head resources (platform-owned, not counted: cdn.shopify.com)" "a platform-owned host is not a finding"
has "$s" "[PASS] AA-29 - third-party script hosts (3): cdn.shopify.com, cdn.vendor.test, tags.vendor.test" "module and async scripts are inventoried"
has "$s" "1 auth redirect(s) (expected)" "a link to a login redirect"
has "$s" "[PASS] TS-37 - /.well-known/assetlinks.json answers 200 application/json without a redirect" "a footer Play link with its association file"
[ "$(hits "GET /.well-known/apple-app-site-association 127.0.0.1:$port")" = 0 ] || fail "App Store links in page content do not trigger an association fetch"
[ "$(cat "$scratch/peak")" -le 4 ] || fail "at most 4 requests in flight, saw $(cat "$scratch/peak")"
has "$s" "[WARN] TS-36 - 2 malformed URL value(s) in href, src, canonical, or JSON-LD: $base/links-good" "malformed hrefs do not stop the sample"
rest="$(grep -v '^\[WARN\] TS-36 - 2 malformed URL value' <<<"$s")"
for st in FAIL WARN SKIP; do lacks "$rest" "[$st]" "the good fixture"; done
ok "the good fixture's look-alikes raise nothing; URLs go out literally, 4 at a time, decoded"

serve sample-hosts; out="$(audit_live)"; s="$(section "$out")"
has "$s" "[WARN] SAMPLE - /sitemap.xml gave no usable URLs - sampling from the Sitemap: lines of robots.txt" "robots.txt sitemap fallback"
has "$s" "[WARN] SAMPLE - 1 sitemap file(s) on another host or scheme - not fetched" "an off-host robots.txt sitemap"
has "$s" "[PASS] SAMPLE - sampled 3 page(s) across 3 URL families" "pages from the robots.txt sitemap"
lacks "$(cat "$scratch/requests")" " localhost:" "nothing is requested from the canonical's other host"
ok "a missing /sitemap.xml falls back to robots.txt; links and sitemaps stay on the audited host"

serve sample-blocked; out="$(audit_live)"; s="$(section "$out")"
has "$s" "[SKIP] SAMPLE - blocked to the audit client (homepage: 403, cf-mitigated, challenge title)" "a bot wall on the homepage"
[ "$(grep -c '^\[' <<<"$s")" = 1 ] || fail "a bot wall yields exactly one sample line:"$'\n'"$s"
serve sample-mixed; out="$(audit_live)"; s="$(section "$out")"
has "$s" "[SKIP] SAMPLE - blocked to the audit client (4 of the first 8 pages answered with a bot wall)" "half the first pages walled"
[ "$(grep -c '^\[' <<<"$s")" = 1 ] || fail "a half-walled sample yields exactly one sample line:"$'\n'"$s"
serve sample-429; out="$(audit_live)"; s="$(section "$out")"
has "$s" "[WARN] SAMPLE - rate limited (429) at $base/p5 - stopped issuing requests" "a 429 stops the sample"
has "$s" "[SKIP] TS-40 - 1 internal links not probed - the site rate-limited the audit (429)" "a 429 stops the link probes"
for i in 8 9 10 11 12; do lacks "$(cat "$scratch/requests")" "GET /p$i " "no page is requested after a 429"; done
ok "a site that walls off the audit client or rate-limits it yields a SKIP or WARN, and requests stop"

serve sample-truncated; out="$(audit_live)"; s="$(section "$out")"
has "$s" "[WARN] SAMPLE - 2 page(s) not fully fetched (timeout, size cap, or transfer error) - not analyzed: $base/slow (curl exit 28), $base/huge (curl exit 63)" "a stalled page and one over the size cap"
has "$out" "[WARN] GE-01 - live /llms.txt declares a body over the 5 MB audit cap - not read" "a file over the size cap"
lacks "$s" "SD-10" "a truncated JSON-LD block is not a parse failure"
lacks "$s" "[PASS] TS-22" "no TS-22 pass when every sitemapped URL failed to transfer"
has "$s" "[SKIP] TS-40 - 1 link(s) not checked: 1 blocked to the audit client" "a walled link"
lacks "$s" "[PASS] TS-40" "no TS-40 pass when no link was verified"
ok "a page that stalls mid-body or declares more than 5 MB is a transfer error, not a finding"

serve sample-good
nopy="$scratch/nopy-bin"; mkdir -p "$nopy"
ln -s "$BASH" "$nopy/bash"
for t in env curl sed awk grep tr head tail cat cut mktemp rm mkdir mv wc sort od gzip date dirname find ls basename seq; do
  ln -s "$(command -v "$t")" "$nopy/$t"
done
out="$(env -u PYTHON PATH="$nopy" "$BASH" "$audit" "$empty_repo" "$base" --timeout 3)" || fail "audit without python3 exited $?"
has "$(section "$out")" "[SKIP] SAMPLE - python3 >= 3.8 unavailable" "no python3 on PATH"
printf '#!/bin/sh\n[ "$1" = -c ] && exec "%s" "$@"\na=$1 b=$2; shift 3; exec "%s" "$a" "$b" "%s/missing.tsv" "$@"\n' \
  "$(command -v "$py")" "$(command -v "$py")" "$scratch" >"$scratch/crashpy"
chmod +x "$scratch/crashpy"
out="$(PYTHON="$scratch/crashpy" audit_live)"; s="$(section "$out")"
has "$s" "[SKIP] SAMPLE - page analyzer failed: FileNotFoundError" "an analyzer that crashes"
lacks "$s" "[PASS]" "a crashed analyzer reports no pass"
ok "a missing interpreter or a crashed analyzer is a SKIP with its reason"

out="$(audit_live --sample 0)"
has "$(section "$out")" "[SKIP] SAMPLE - --sample 0" "--sample 0 disables the section"
code=0; "$BASH" "$audit" --sample abc >/dev/null 2>&1 || code=$?
[ "$code" = 2 ] || fail "non-numeric --sample exited $code, expected 2"
code=0; "$BASH" "$audit" --max-links -1 >/dev/null 2>&1 || code=$?
[ "$code" = 2 ] || fail "negative --max-links exited $code, expected 2"
mkdir -p "$scratch/pkg-repo"; printf '{"dependencies":{"next":"15"}}\n' >"$scratch/pkg-repo/package.json"
out="$(cd "$scratch/pkg-repo" && "$BASH" "$audit" --no-repo)"
has "$out" "FRAMEWORK=n/a" "--no-repo skips the fingerprint"
has "$out" "[SKIP] STATIC - --no-repo" "--no-repo skips static checks"
lacks "$out" "TS-21" "--no-repo runs no static check"
stop_server
ok "--sample 0 and --no-repo skip their sections; a malformed count is a usage error"
