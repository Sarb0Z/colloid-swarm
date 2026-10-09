"""Sampled-page checks for quick-audit.sh. Reads pages already fetched; makes no requests.

Usage: analyze-pages.py MANIFEST BASE_URL CURRENT_YEAR ROBOTS_PATH OUT_DIR PLATFORM

MANIFEST is tab-separated, one fetched URL per row, the homepage first: url, curl exit, status,
redirect count, final URL, content type, body path (empty for a HEAD-only file), headers path,
redirect target, 1 when the sitemap lists the URL, and the bot-wall evidence sample.sh found (empty
when the response is not blocked). Pages were fetched without following redirects; only a page that
answered 200 itself is analyzed. ROBOTS_PATH may be empty.

Prints one "STATUS<tab>ID<tab>detail" line per check and defect class. Writes OUT_DIR/links.txt
(internal followed links on the audited host or its www/apex pair that robots.txt lets Googlebot
crawl) and OUT_DIR/stores.txt ("own<tab>URL" for an app the site presents as its own: an app meta
tag or a store link in the header, nav, or footer; "content<tab>URL" for any other store link).
Python 3.8+, standard library only.
"""

import codecs
import datetime
import ipaddress
import json
import os
import re
import sys
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit

EXAMPLES = 5
HTML_TYPES = ("text/html", "application/xhtml+xml")
UTILITY_SEGMENTS = {
    "thank-you", "thanks", "checkout", "cart", "order-confirmation", "search", "login", "signin",
    "sign-in", "account", "404", "401", "500",
}
UTILITY_TITLES = {
    "thank you", "thank you!", "thanks", "thanks!", "checkout", "cart", "your cart", "shopping cart",
    "order confirmation", "search", "search results", "login", "log in", "sign in", "page not found",
    "not found", "404", "404 not found", "error",
}
MAIN_TYPES = {"WebPage", "Article", "BlogPosting", "NewsArticle", "Product"}
ORG_TYPES = {
    "Organization", "Corporation", "NGO", "EducationalOrganization", "CollegeOrUniversity", "School",
    "MedicalOrganization", "Hospital", "Dentist", "Physician", "Pharmacy", "DiagnosticLab", "VeterinaryCare",
    "MedicalClinic", "MedicalBusiness", "Optician", "NewsMediaOrganization", "OnlineBusiness", "OnlineStore",
    "SportsOrganization", "Airline", "LocalBusiness", "Restaurant", "FoodEstablishment", "Bakery", "BarOrPub",
    "Brewery", "CafeOrCoffeeShop", "FastFoodRestaurant", "IceCreamShop", "Winery", "Store", "AutoPartsStore",
    "BikeStore", "BookStore", "ClothingStore", "ComputerStore", "ConvenienceStore", "DepartmentStore",
    "ElectronicsStore", "Florist", "FurnitureStore", "GardenStore", "GroceryStore", "HardwareStore",
    "HobbyShop", "HomeGoodsStore", "JewelryStore", "LiquorStore", "MobilePhoneStore", "MusicStore",
    "OfficeEquipmentStore", "OutletStore", "PawnShop", "PetStore", "ShoeStore", "SportingGoodsStore",
    "TireShop", "ToyStore", "WholesaleStore", "LegalService", "Attorney", "Notary", "AccountingService",
    "FinancialService", "BankOrCreditUnion", "InsuranceAgency", "RealEstateAgent",
    "HomeAndConstructionBusiness", "Electrician", "GeneralContractor", "HVACBusiness", "HousePainter",
    "Locksmith", "MovingCompany", "Plumber", "RoofingContractor", "ProfessionalService",
    "AutomotiveBusiness", "AutoDealer", "AutoRepair", "AutoBodyShop", "AutoRental", "AutoWash",
    "HealthAndBeautyBusiness", "BeautySalon", "DaySpa", "HairSalon", "HealthClub", "NailSalon",
    "TattooParlor", "LodgingBusiness", "Hotel", "Motel", "Hostel", "Resort", "BedAndBreakfast", "Campground",
    "ChildCare", "DryCleaningOrLaundry", "EmploymentAgency", "EntertainmentBusiness", "TravelAgency",
    "SelfStorage", "SportsActivityLocation", "EmergencyService", "RecyclingCenter", "ShoppingCenter",
}
# Hosts a hosted builder serves its own runtime from; the site owner cannot move them (PF-21).
PLATFORM_HOSTS = {
    "Webflow": ("website-files.com", "webflow.com", "webflow.io", "d3e54v103j8qbb.cloudfront.net"),
    "Shopify": ("shopify.com", "shopifycdn.com", "shopifycdn.net", "myshopify.com", "shopifysvc.com"),
    "Squarespace": ("squarespace.com", "sqspcdn.com", "squarespace-cdn.com"),
    "Wix": ("parastorage.com", "wixstatic.com", "wix.com", "wixapps.net"),
    "Framer": ("framer.com", "framerusercontent.com", "framer.app", "framer.website"),
    "WordPress.com": ("wp.com", "wordpress.com"),
}
# Second-level suffixes under which a registrable domain takes three labels.
MULTI_SUFFIXES = {
    "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "co.jp", "ne.jp", "or.jp", "com.au",
    "net.au", "org.au", "edu.au", "gov.au", "co.nz", "org.nz", "com.br", "com.mx", "co.in", "co.za",
    "com.sg", "com.hk", "com.tr", "com.cn", "co.kr", "com.tw", "com.ar", "co.il", "com.my", "com.ph",
    "com.pk", "github.io", "vercel.app", "netlify.app", "pages.dev", "herokuapp.com", "up.railway.app",
    "fly.dev", "onrender.com", "web.app", "firebaseapp.com", "myshopify.com", "webflow.io", "framer.app",
}
FONT_HOSTS = re.compile(
    r"@import\s+(?:url\()?\s*[\"']?(?:https?:)?//(?:fonts\.googleapis\.com|fonts\.bunny\.net|use\.typekit\.net"
    r"|p\.typekit\.net|fast\.fonts\.net|fonts\.cdnfonts\.com|cloud\.typography\.com|use\.fontawesome\.com)", re.I)
FRAMEWORK_PAYLOADS = ("self.__next_f", "__NEXT_DATA__", "__NUXT__", "window.__remixContext", "__sveltekit")
STORE_LINK = re.compile(r"https?://(apps|itunes)\.apple\.com/|https?://play\.google\.com/store/apps")
CLASSIC_TYPES = {"", "text/javascript", "application/javascript", "application/ecmascript", "text/ecmascript"}
YEAR = r"((?:19|20)\d\d)"
# A year reads as a freshness stamp only beside these cues; "(2019)", "in 2023", "since 2010" do not.
FRESHNESS = [re.compile(p, re.I) for p in (
    r"\bupdated:?\s+(?:[a-z]+\.?\s+)?" + YEAR + r"\b", r"\bfor\s+" + YEAR + r"\b", r"\b" + YEAR + r"\s+guide\b",
    r"\bbest\b[^|.!?]{0,60}?\b" + YEAR + r"\b", r"\btop\b[^|.!?]{0,60}?\b" + YEAR + r"\b",
)]
FRESHNESS_YEARS = 3       # a stale stamp is a recent past year; an older one is history, not freshness
NOT_FRESHNESS = re.compile(r"\b(since|founded|established|est\.?|tax|taxes|fiscal|fy|reports?|annual)\b", re.I)
# A template slot: "[Hero headline — offer, one line]" (a dash then a lower-case descriptor) or a bracket
# naming itself a placeholder. Editorial notes ("[Update: ...]", "[PDF - 2 MB]") carry neither cue.
PLACEHOLDER = re.compile(r"\[[A-Z][^\]]{1,60}?(?:\s?—\s?|\s-\s)[a-z][^\]]*\]")
PLACEHOLDER_WORDS = re.compile(r"\[[^\]]*\b(?:placeholder|todo|tbd|insert)\b[^\]]*\]", re.I)
PLACEHOLDER_HOSTS = re.compile(r"(?<![\w-])example\.com\b|yourdomain|yourservice|yoursite", re.I)
DATE = re.compile(r"(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d+))?)?\s*(Z|[+-]\d{2}(?::?\d{2})?)?)?$", re.I)


class Page(HTMLParser):
    """The parts of one HTML document the checks read."""

    EXCLUDED = {"code", "pre", "script", "style", "template"}
    HEAD_TAGS = {"html", "head", "title", "meta", "link", "script", "style", "base", "noscript", "template"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.title = None
        self.metas = []          # (name or property, content)
        self.canonical = None
        self.base = None
        self.scripts = []        # dicts: attrs, text, head
        self.styles = []         # inline <style> text
        self.sheets = []         # (href, media) of head <link rel=stylesheet>
        self.anchors = []        # (href, rel, inside header/nav/footer)
        self.attr_values = []    # href/src/content values outside code, pre, template
        self.text = []
        self.in_head = True
        self.depth = dict.fromkeys(("code", "pre", "template", "svg", "title", "noscript", "header", "nav", "footer"), 0)
        self.current = None      # the open <script> or <style>
        self.title_parts = None

    def excluded(self):
        return any(self.depth[t] for t in ("code", "pre", "template"))

    def handle_starttag(self, tag, attrs):
        a = {k.lower(): (v if v is not None else "") for k, v in attrs}
        # With scripting on, <noscript> in the head is raw text, so nothing inside it closes the head.
        if tag == "body" or (self.in_head and tag not in self.HEAD_TAGS and not self.depth["noscript"]):
            self.in_head = False
        if tag in self.depth:
            self.depth[tag] += 1
        if tag == "title" and self.title is None and not self.depth["svg"]:
            self.title_parts = []
        if not self.excluded():
            for k in ("href", "src", "content"):
                if a.get(k):
                    self.attr_values.append(a[k])
        if tag == "meta":
            key = (a.get("name") or a.get("property") or "").lower()
            if key:
                self.metas.append((key, a.get("content", "")))
        elif tag == "link":
            rels = a.get("rel", "").lower().split()
            if "canonical" in rels and self.canonical is None:
                self.canonical = a.get("href", "").strip()
            if "stylesheet" in rels and "alternate" not in rels and self.in_head:
                self.sheets.append((a.get("href", "").strip(), a.get("media", "").lower()))
        elif tag == "base" and self.base is None and a.get("href"):
            self.base = a["href"].strip()
        elif tag == "a" and a.get("href") and not self.excluded():
            chrome = any(self.depth[t] for t in ("header", "nav", "footer"))
            self.anchors.append((a["href"].strip(), a.get("rel", "").lower(), chrome))
        elif tag == "script":
            self.current = {"attrs": a, "text": [], "head": self.in_head}
            self.scripts.append(self.current)
        elif tag == "style":
            self.current = {"text": []}
            self.styles.append(self.current)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag in self.depth:
            self.depth[tag] -= 1
        if tag in ("script", "style"):
            self.current = None

    def handle_endtag(self, tag):
        if tag == "head":
            self.in_head = False
        if tag in self.depth and self.depth[tag]:
            self.depth[tag] -= 1
        if tag == "title" and self.title_parts is not None:
            self.title = " ".join("".join(self.title_parts).split())
            self.title_parts = None
        if tag in ("script", "style"):
            self.current = None

    def handle_data(self, data):
        if self.current is not None:
            self.current["text"].append(data)
        elif self.title_parts is not None:
            self.title_parts.append(data)
        elif not self.excluded() and not self.depth["svg"]:
            self.text.append(data)

    def meta(self, *keys):
        return [c for k, c in self.metas if k in keys]


def decode(raw, content_type):
    """Decode a body the way a browser picks its charset: header, then meta, then UTF-8."""
    m = re.search(r"charset=[\"']?([\w.:-]+)", content_type or "", re.I)
    if not m:
        m = re.search(rb"<meta[^>]+charset=[\"']?([\w.:-]+)", raw[:4096], re.I)
    name = (m.group(1) if m else "utf-8")
    name = name.decode("ascii", "replace") if isinstance(name, bytes) else name
    if name.lower() in ("iso-8859-1", "latin1", "latin-1", "us-ascii", "ascii"):
        name = "cp1252"
    try:
        codecs.lookup(name)
    except LookupError:
        name = "utf-8"
    return raw.decode(name, "replace")


def last_headers(path):
    """Header lines of the final response in a curl -D file, lower-cased names."""
    with open(path, "rb") as f:
        blocks = re.split(rb"\r?\n\r?\n", f.read().strip())
    lines = blocks[-1].decode("latin-1").splitlines()[1:] if blocks else []
    return [(k.strip().lower(), v.strip()) for k, _, v in (ln.partition(":") for ln in lines) if _]


def x_robots_noindex(headers):
    """X-Robots-Tag noindex/none that applies to Google: unscoped, `googlebot:`, or `*:`."""
    known = {"unavailable_after", "max-snippet", "max-image-preview", "max-video-preview"}
    for name, value in headers:
        if name != "x-robots-tag":
            continue
        scope = None
        for part in value.split(","):
            part = part.strip().lower()
            head, sep, rest = part.partition(":")
            if sep and head.strip() not in known:
                scope, part = head.strip(), rest.strip()
            if part in ("noindex", "none") and scope in (None, "googlebot", "*"):
                return True
    return False


def meta_noindex(contents):
    """A robots/googlebot meta that says noindex or none, read as comma-separated directives."""
    return any(t.strip().lower() in ("noindex", "none") for c in contents for t in c.split(","))


class Robots:
    """Googlebot's view of robots.txt: a group naming googlebot beats `*`; longest match wins, allow on ties."""

    def __init__(self, text):
        groups, cur, last_ua = [], None, False
        for line in text.splitlines():
            key, sep, val = line.split("#", 1)[0].partition(":")
            key, val = key.strip().lower(), val.strip()
            if not sep:
                continue
            if key == "user-agent":
                if not last_ua:
                    cur = {"agents": set(), "rules": []}
                    groups.append(cur)
                cur["agents"].add(val.lower())
                last_ua = True
            elif key in ("allow", "disallow"):
                last_ua = False
                if cur is not None and val:
                    cur["rules"].append((key == "allow", val))
        named = [g for g in groups if "googlebot" in g["agents"]]
        chosen = named or [g for g in groups if "*" in g["agents"]]
        self.rules = [(allow, len(p), self._regex(p)) for g in chosen for allow, p in g["rules"]]

    @staticmethod
    def _regex(pattern):
        end = pattern.endswith("$")
        body = re.escape(pattern[:-1] if end else pattern).replace(r"\*", ".*")
        return re.compile(body + ("$" if end else ""))

    def allowed(self, url):
        parts = urlsplit(url)
        path = (parts.path or "/") + ("?" + parts.query if parts.query else "")
        best = None
        for allow, length, rx in self.rules:
            if rx.match(path) and (best is None or length > best[0] or (length == best[0] and allow)):
                best = (length, allow)
        return best is None or best[1]


def host_of(url):
    try:
        return (urlsplit(url).hostname or "").lower()
    except ValueError:
        return ""


def registrable(host):
    labels = host.split(".")
    if re.fullmatch(r"[\d.]+|\[.*\]", host) or len(labels) < 3:
        return host
    take = 3 if ".".join(labels[-2:]) in MULTI_SUFFIXES else 2
    return ".".join(labels[-take:])


def strip_www(host):
    return host[4:] if host.startswith("www.") else host


def url_key(url):
    """Comparable form of a URL for "is this the same page": host without www, no trailing slash or fragment."""
    p = urlsplit(url)
    path = p.path.rstrip("/")
    return "%s://%s%s%s" % (p.scheme.lower(), strip_www((p.netloc or "").lower()), path, "?" + p.query if p.query else "")


def parse_date(value):
    """ISO 8601 -> (date-only?, date or aware datetime); None when unparseable."""
    if not isinstance(value, str):
        return None
    m = DATE.match(value.strip())
    if not m:
        return None
    y, mo, d, hh, mi, ss, frac, tz = m.groups()
    try:
        if hh is None:
            return True, datetime.date(int(y), int(mo), int(d))
        offset = datetime.timezone.utc
        if tz and tz.upper() != "Z":
            digits = tz[1:].replace(":", "")
            delta = datetime.timedelta(hours=int(digits[:2]), minutes=int(digits[2:4] or 0))
            offset = datetime.timezone(delta if tz[0] == "+" else -delta)
        micro = int((frac or "0")[:6].ljust(6, "0"))
        return False, datetime.datetime(int(y), int(mo), int(d), int(hh), int(mi), int(ss or 0), micro, offset)
    except ValueError:
        return None


def day_of(parsed):
    return parsed[1] if parsed[0] else parsed[1].date()


def types_of(node):
    t = node.get("@type")
    return set(t if isinstance(t, list) else [t]) if t else set()


def walk(obj):
    """Every JSON object inside obj, depth first."""
    if isinstance(obj, dict):
        yield obj
        for v in obj.values():
            yield from walk(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from walk(v)


def top_nodes(doc):
    for item in doc if isinstance(doc, list) else [doc]:
        if isinstance(item, dict):
            yield item
            for g in item.get("@graph", []) if isinstance(item.get("@graph"), list) else []:
                if isinstance(g, dict):
                    yield g


def url_value(v):
    if isinstance(v, dict):
        v = v.get("@id") or v.get("url") or v.get("contentUrl")
    return v.strip() if isinstance(v, str) else None


def is_absolute(u):
    return bool(re.match(r"(?i)https?://|//|data:", u))


class Findings:
    """Collects (status, id, class) -> examples; one output line per class."""

    def __init__(self):
        self.items = {}
        self.order = []
        self.ran = []

    def ran_check(self, cid):
        if cid not in self.ran:
            self.ran.append(cid)

    def add(self, status, cid, label, example):
        key = (status, cid, label)
        if key not in self.items:
            self.items[key] = []
            self.order.append(key)
        if example not in self.items[key]:
            self.items[key].append(example)

    def lines(self, passes):
        out = []
        for status, cid, label in self.order:
            ex = self.items[(status, cid, label)]
            more = ", ..." if len(ex) > EXAMPLES else ""
            out.append((status, cid, "%d %s: %s%s" % (len(ex), label, ", ".join(ex[:EXAMPLES]), more)))
        flagged = {cid for _, cid, _ in self.order}
        for cid in self.ran:
            if cid not in flagged and cid in passes:
                out.append(("PASS", cid, passes[cid]))
        return out


class Audit:
    def __init__(self, rows, base_url, year, robots, platform, now):
        self.rows, self.base_url, self.year, self.robots, self.platform = rows, base_url, year, robots, platform
        self.now = now
        self.owned_note = ""
        self.f = Findings()
        self.pages = []          # (row, Page, parsed JSON-LD docs) for pages that answered 200 with HTML
        self.home = None
        self.canonical_host = ""
        self.link_hosts = set()  # BASE_URL's host and its www/apex pair: the only hosts links are probed on
        self.home_org_keys = set()
        self.links, self.stores, self.script_hosts = set(), {}, {}
        self.notes = {"transfer": [], "blocked": [], "status": 0, "head": 0, "not_html": 0}

    def resolve(self, row, base, ref):
        """ref resolved against base; None, recorded under TS-36, when no URL parser would accept it."""
        try:
            url = urljoin(base, ref)
            parts = urlsplit(url)
            parts.port  # reading it raises ValueError for a port that is not a number
            host = parts.netloc.rpartition("@")[2]
            if host.startswith("["):
                ipaddress.IPv6Address(host[1:host.find("]")])
            return url
        except ValueError:
            self.f.add("WARN", "TS-36", "malformed URL value(s) in href, src, canonical, or JSON-LD", "%s (%s)" % (row["url"], ref[:80]))
            return None

    # ---- loading -------------------------------------------------------------------------------
    def load(self):
        for row in self.rows:
            url, code = row["url"], row["code"]
            if row["exit"] != "0":
                self.notes["transfer"].append("%s (curl exit %s)" % (url, row["exit"]))
            elif row["walled"]:
                self.notes["blocked"].append("%s (%s)" % (url, row["walled"]))
            elif not row["body"]:
                self.notes["head"] += 1
            elif code != "200" or row["redirects"] not in ("", "0"):
                self.notes["status"] += 1
            elif not row["type"].lower().startswith(HTML_TYPES):
                self.notes["not_html"] += 1
            else:
                with open(row["body"], "rb") as fh:
                    html = decode(fh.read(), row["type"])
                page = Page()
                page.feed(html)
                page.close()
                self.pages.append((row, page, self.json_ld(row, page)))
        first = self.rows[0] if self.rows else None
        self.home = next((p for p in self.pages if p[0] is first), None)
        home_url = first["url"] if first else self.base_url + "/"
        home_canon = ""
        if self.home and self.home[1].canonical:
            home_canon = self.resolve(first, home_url, self.home[1].canonical) or ""
        self.canonical_host = host_of(home_canon) or host_of(home_url) or host_of(self.base_url)
        self.home_keys = {url_key(u) for u in (home_url, home_canon, self.base_url + "/") if u}
        base_host = urlsplit(self.base_url).netloc.lower()
        self.link_hosts = {base_host, strip_www(base_host), "www." + strip_www(base_host)}
        for doc in (self.home[2] if self.home else []):
            for node in walk(doc):
                if types_of(node) & ORG_TYPES:
                    for key in ("@id", "url"):
                        ident = url_value(node.get(key))
                        target = self.resolve(first, home_url, ident) if ident else None
                        if target:
                            self.home_org_keys.add(url_key(target))

    def json_ld(self, row, page):
        docs = []
        for s in page.scripts:
            if s["attrs"].get("type", "").strip().lower() != "application/ld+json":
                continue
            raw = "".join(s["text"]).strip()
            if not raw:
                continue
            self.f.ran_check("SD-10")
            try:
                docs.append(json.loads(raw, strict=False))
            except ValueError as e:
                self.f.add("FAIL", "SD-10", "JSON-LD block(s) that do not parse", "%s (%s)" % (row["url"], e.msg))
        return docs

    def canonical_of(self, row, page):
        return (self.resolve(row, row["url"], page.canonical) if page.canonical else None) or row["url"]

    # ---- checks --------------------------------------------------------------------------------
    def check_index(self):
        """TS-22: sitemapped URLs answer 200 directly, are indexable, crawlable, and not utility pages."""
        for row in (r for r in self.rows if r["listed"]):
            url, code = row["url"], row["code"]
            if row["exit"] != "0" or row["walled"] or (row["body"] == "" and code in ("405", "501")):
                continue
            self.f.ran_check("TS-22")
            if code in ("404", "410") or code.startswith("5"):
                self.f.add("FAIL", "TS-22", "sitemapped URL(s) answer 404/410/5xx", "%s (%s)" % (url, code))
            elif code.startswith("3"):
                self.f.add("FAIL", "TS-22", "sitemapped URL(s) redirect - list the final URL", "%s -> %s" % (url, row["location"] or "no Location"))
            if self.robots and not self.robots.allowed(url):
                self.f.add("FAIL", "TS-22", "sitemapped URL(s) disallowed for Googlebot by robots.txt", url)
        for row, page, _ in self.pages:
            if not row["listed"]:
                continue
            by_script = any(self.script_kind(s) == "robots" and "noindex" in self.script_text(s) for s in page.scripts)
            if meta_noindex(page.meta("robots", "googlebot")) or x_robots_noindex(last_headers(row["headers"])):
                self.f.add("FAIL", "TS-22", "sitemapped page(s) carry noindex", row["url"])
            elif by_script:
                self.f.add("FAIL", "TS-22", "sitemapped page(s) carry noindex", row["url"] + " (set by script)")
            segs = {s.lower() for s in urlsplit(row["url"]).path.split("/") if s}
            title = (page.title or "").strip().lower()
            if segs & UTILITY_SEGMENTS or title in UTILITY_TITLES or re.split(r"\s+[|\-–—·:]\s+", title)[0] in UTILITY_TITLES:
                self.f.add("WARN", "TS-22", "utility page(s) in the sitemap", row["url"])

    def check_titles(self):
        """TS-32 home-folding titles and canonicals; TS-13 titles shared across sampled pages."""
        seen, groups = set(), {}
        home_title = self.home[1].title if self.home else None
        for row, page, _ in self.pages:
            key = url_key(row["url"])
            if key in seen:
                continue
            seen.add(key)
            if page.title:
                groups.setdefault(page.title.lower(), []).append(row["url"])
            if self.home is None or key in self.home_keys:
                continue
            self.f.ran_check("TS-32")
            if home_title and page.title == home_title:
                self.f.add("WARN", "TS-32", "page(s) reuse the homepage title", row["url"])
            if page.canonical and url_key(self.canonical_of(row, page)) in self.home_keys:
                self.f.add("WARN", "TS-32", "page(s) canonicalize to the homepage", row["url"])
        if len(seen) > 1:
            self.f.ran_check("TS-13")
        for title, urls in groups.items():
            if len(urls) > 1:
                self.f.add("WARN", "TS-13", "title(s) shared by 2+ sampled pages", '"%s" (%d pages: %s)' % (title[:60], len(urls), ", ".join(urls[:3])))

    def check_structured(self):
        """SD-07 URL hygiene, SD-12 empty values and self-serving ratings, SD-13 publication dates."""
        for row, page, docs in self.pages:
            if not docs:
                continue
            for cid in ("SD-07", "SD-12", "SD-13"):
                self.f.ran_check(cid)
            canon = self.canonical_of(row, page)
            self.main_entity(row, docs, canon)
            for doc in docs:
                for node in walk(doc):
                    self.node_urls(row, node)
                    self.node_values(row, node)
                    self.node_dates(row, node, self.now)

    def main_entity(self, row, docs, canon):
        """SD-07: the page's main entity names the canonical. A node that names the page through
        mainEntityOfPage is the main entity; otherwise only a lone WebPage/*Page/Article/Product is."""
        named, candidates = [], []
        for node in (n for doc in docs for n in top_nodes(doc)):
            if not url_value(node.get("url")):
                continue
            mop = url_value(node.get("mainEntityOfPage"))
            target = self.resolve(row, canon, mop) if mop else None
            types = types_of(node)
            if target and url_key(target) == url_key(canon):
                named.append(node)
            elif types & MAIN_TYPES or any(t.endswith("Page") for t in types if isinstance(t, str)):
                candidates.append(node)
        for node in named or (candidates if len(candidates) == 1 else []):
            url = url_value(node["url"])
            target = self.resolve(row, canon, url)
            if target and target.rstrip("/") != canon.rstrip("/"):
                self.f.add("WARN", "SD-07", "main entity url(s) differ from the page canonical (practice)", "%s (%s vs %s)" % (row["url"], url, canon))

    def node_urls(self, row, node):
        if "BreadcrumbList" in types_of(node) and isinstance(node.get("itemListElement"), list):
            for el in node["itemListElement"]:
                item = url_value(el.get("item")) if isinstance(el, dict) else None
                target = self.resolve(row, "https:", item) if item else None
                if target and (not is_absolute(item) or host_of(target) != self.canonical_host):
                    self.f.add("WARN", "SD-07", "breadcrumb item(s) relative or off the canonical host %s (practice)" % self.canonical_host, "%s (%s)" % (row["url"], item))
        for key in ("image", "logo"):
            for v in node.get(key) if isinstance(node.get(key), list) else [node.get(key)]:
                u = v if isinstance(v, str) else None
                if u and u.strip() and not is_absolute(u.strip()):
                    self.f.add("WARN", "SD-07", "relative image/logo URL(s) in JSON-LD (practice)", "%s (%s: %s)" % (row["url"], key, u.strip()))

    def node_values(self, row, node):
        for key in ("name", "url", "image", "sameAs"):
            v = node.get(key)
            for item in v if isinstance(v, list) else [v]:
                if isinstance(item, str) and not item.strip():
                    self.f.add("WARN", "SD-12", "empty JSON-LD value(s)", "%s (%s)" % (row["url"], key))
        types = types_of(node)
        if not (types & ORG_TYPES) or not (node.get("aggregateRating") or node.get("review")):
            return
        ident = url_value(node.get("url")) or url_value(node.get("@id"))
        target = self.resolve(row, row["url"], ident) if ident else None
        if target and self.is_site_itself(target):
            self.f.add("WARN", "SD-12", "self-rated Organization/LocalBusiness - ineligible when the entity controls the reviews about itself (heuristic ownership match)", "%s (%s)" % (row["url"], "/".join(sorted(t for t in types if isinstance(t, str)))))

    def is_site_itself(self, url):
        """The rated entity is the site: its url/@id is the site root or the homepage Organization's."""
        parts = urlsplit(url)
        root = parts.netloc.lower() in self.link_hosts and parts.path in ("", "/") and not parts.query
        return root or url_key(url) in self.home_org_keys

    def node_dates(self, row, node, now):
        parsed = {}
        for key in ("datePublished", "dateModified", "uploadDate"):
            if key not in node:
                continue
            p = parse_date(node[key])
            if p is None:
                self.f.add("WARN", "SD-13", "unparseable publication date(s)", "%s (%s: %s)" % (row["url"], key, str(node[key])[:40]))
                continue
            parsed[key] = p
            future = day_of(p) > (now + datetime.timedelta(days=1)).date() if p[0] else p[1] > now + datetime.timedelta(days=1)
            if future:
                self.f.add("WARN", "SD-13", "publication date(s) in the future", "%s (%s: %s)" % (row["url"], key, node[key]))
        pub, mod = parsed.get("datePublished"), parsed.get("dateModified")
        if pub and mod:
            earlier = day_of(mod) < day_of(pub) if pub[0] or mod[0] else mod[1] < pub[1]
            if earlier:
                self.f.add("FAIL", "SD-13", "dateModified earlier than datePublished", "%s (%s < %s)" % (row["url"], node["dateModified"], node["datePublished"]))

    @staticmethod
    def script_text(s):
        return "".join(s["text"])

    def script_kind(self, s):
        """What an inline classic script patches for crawlers that render, or None."""
        if s["attrs"].get("src") or s["attrs"].get("type", "").strip().lower() not in CLASSIC_TYPES | {"module"}:
            return None
        js = self.script_text(s)
        if any(marker in js for marker in FRAMEWORK_PAYLOADS):
            return None
        redirect = re.search(r"\b(?:window\.|document\.)?location(?:\.href)?\s*=(?!=)|\blocation\.(?:replace|assign)\s*\(", js)
        mapped = re.search(r"pathname|[\"']/[^\"'\s]*[\"']\s*:\s*[\"'](?:/|https?://)", js)
        if redirect and mapped:
            return "redirect"
        if re.search(r"[\"']robots[\"']|name=[\\\"']*robots", js) and re.search(r"createElement\(\s*[\"']meta|setAttribute\(|\.content\s*=", js):
            return "robots"
        if re.search(r"\bdocument\.title\s*=(?!=)", js):
            return "title"
        if "ld+json" in js and re.search(r"createElement\(\s*[\"']script|innerHTML|insertAdjacentHTML|textContent\s*=(?!=)|\.text\s*=(?!=)", js):
            return "json-ld"
        return None

    def check_scripts(self):
        """TS-39: redirects, robots, titles, and JSON-LD applied only by inline script."""
        labels = {"redirect": "redirect map or path redirect", "robots": "robots meta", "title": "document.title",
                  "json-ld": "JSON-LD injection or rewrite"}
        for row, page, _ in self.pages:
            self.f.ran_check("TS-39")
            for s in page.scripts:
                kind = self.script_kind(s)
                if kind:
                    self.f.add("WARN", "TS-39", "page(s) with a %s applied by script: reaches only crawlers that render (TS-39)" % labels[kind], row["url"])

    def check_copy(self):
        """TS-19 stale freshness years, LC-39 placeholder copy, TS-36 template leftovers."""
        for row, page, _ in self.pages:
            for cid in ("TS-19", "LC-39", "TS-36"):
                self.f.ran_check(cid)
            title = page.title or ""
            social = [c for k, c in page.metas if k.startswith(("og:", "twitter:"))]
            head_copy = [title] + page.meta("description") + social
            stale = next((f for f in [title] + page.meta("description") if self.stale_year(f)), None)
            if stale:
                self.f.add("WARN", "TS-19", "page(s) carry a past year as freshness in the title or description", '%s ("%s")' % (row["url"], stale[:80]))
            text = " ".join(" ".join(page.text).split())
            if re.search(r"\blorem ipsum\b", text, re.I):
                self.f.add("WARN", "LC-39", "page(s) show lorem ipsum", row["url"])
            for field in head_copy + [text]:
                m = PLACEHOLDER.search(field) or PLACEHOLDER_WORDS.search(field)
                if m:
                    self.f.add("WARN", "LC-39", "page(s) show bracket placeholder copy", "%s (%s)" % (row["url"], m.group(0)[:60]))
                    break
            for v in page.attr_values:
                if PLACEHOLDER_HOSTS.search(v):
                    self.f.add("WARN", "TS-36", "page(s) link or load template placeholder hosts", "%s (%s)" % (row["url"], v[:80]))
                    break
            if any("{{" in v or "}}" in v for v in head_copy):
                self.f.add("WARN", "TS-36", "page(s) with unrendered {{ }} template tags in title/meta", row["url"])

    def stale_year(self, text):
        for rx in FRESHNESS:
            for m in rx.finditer(text):
                year = int(m.group(1))
                around = text[max(0, m.start(1) - 30):m.start(1)] + " " + text[m.end(1):m.end(1) + 20]
                if self.year - FRESHNESS_YEARS <= year < self.year and not NOT_FRESHNESS.search(around):
                    return year
        return None

    def check_head(self):
        """PF-10 blocking font loaders; PF-21 render-blocking third-party head resources; AA-29 script hosts."""
        owned = PLATFORM_HOSTS.get(self.platform, ())
        blocking, platform_hits = {}, set()
        for row, page, _ in self.pages:
            for cid in ("PF-10", "PF-21", "AA-29"):
                self.f.ran_check(cid)
            site = registrable(host_of(row["url"]))
            for s in page.scripts:
                a = s["attrs"]
                kind = a.get("type", "").strip().lower()
                src = (self.resolve(row, row["url"], a["src"]) or "") if a.get("src") else ""
                sync = kind in CLASSIC_TYPES and "async" not in a and "defer" not in a
                host = host_of(src) if src.lower().startswith(("http:", "https:")) else ""
                if host and registrable(host) != site:
                    self.script_hosts.setdefault(host, set()).add(row["url"])
                if s["head"] and sync and src and re.search(r"(webfont\.js|webfontloader)", urlsplit(src).path, re.I):
                    self.f.add("WARN", "PF-10", "page(s) load a font loader synchronously in the head", "%s (%s)" % (row["url"], src[:80]))
                if s["head"] and not a.get("src") and kind in CLASSIC_TYPES and "WebFont.load(" in self.script_text(s):
                    self.f.add("WARN", "PF-10", "page(s) call WebFont.load inline in the head", row["url"])
                if s["head"] and sync and host and registrable(host) != site:
                    self.blocking(blocking, platform_hits, owned, host, row["url"])
            for st in page.styles:
                if FONT_HOSTS.search("".join(st["text"])):
                    self.f.add("WARN", "PF-10", "page(s) @import a font host in an inline style", row["url"])
            for href, media in page.sheets:
                host = host_of(self.resolve(row, row["url"], href) or "")
                if host and registrable(host) != site and media != "print":
                    self.blocking(blocking, platform_hits, owned, host, row["url"])
        owned_note = " (platform-owned, not counted: %s)" % ", ".join(sorted(platform_hits)) if platform_hits else ""
        for host in sorted(blocking, key=lambda h: (-len(blocking[h]), h)):
            self.f.add("WARN", "PF-21", "third-party host(s) render-blocking in the head" + owned_note, "%s (%d page%s)" % (host, len(blocking[host]), "" if len(blocking[host]) == 1 else "s"))
        self.owned_note = owned_note

    @staticmethod
    def blocking(blocking, platform_hits, owned, host, url):
        if any(host == h or host.endswith("." + h) for h in owned):
            platform_hits.add(host)
        else:
            blocking.setdefault(host, set()).add(url)

    def collect_links(self):
        """links.txt: followed links on BASE_URL's host pair that Googlebot may crawl; stores: app store links."""
        for row, page, _ in self.pages:
            base = (self.resolve(row, row["url"], page.base) if page.base else None) or row["url"]
            for key, prefix in (("apple-itunes-app", "https://apps.apple.com/app/id"), ("google-play-app", "https://play.google.com/store/apps/details?id=")):
                for content in page.meta(key):
                    m = re.search(r"app-id=([\w.]+)", content)
                    if m:
                        self.stores[prefix + m.group(1)] = "own"
            for href, rel, chrome in page.anchors:
                url = self.resolve(row, base, href)
                if url is None:
                    continue
                url = url.split("#", 1)[0]
                low = url.lower()
                if STORE_LINK.match(low) and self.stores.get(url) != "own":
                    self.stores[url] = "own" if chrome else "content"
                parts = urlsplit(url)
                if not low.startswith(("http://", "https://")) or "nofollow" in rel.split():
                    continue
                if parts.netloc.lower() not in self.link_hosts or "/cdn-cgi/" in parts.path:
                    continue
                if self.robots and not self.robots.allowed(url):
                    continue
                self.links.add(url)
            for v in page.attr_values:
                if STORE_LINK.match(v.strip().lower()):
                    self.stores.setdefault(v.strip(), "content")

    def summary(self):
        out = []
        fams = {(urlsplit(r["url"]).path.strip("/").split("/") or [""])[0] for r, _, _ in self.pages}
        n = self.notes
        if n["transfer"]:
            out.append(("WARN", "SAMPLE", "%d page(s) not fully fetched (timeout, size cap, or transfer error) - not analyzed: %s" % (len(n["transfer"]), ", ".join(n["transfer"][:EXAMPLES]))))
        if n["blocked"]:
            out.append(("WARN", "SAMPLE", "%d page(s) blocked to the audit client - not analyzed: %s" % (len(n["blocked"]), ", ".join(n["blocked"][:EXAMPLES]))))
        if not self.pages:
            out.insert(0, ("SKIP", "SAMPLE", "no sampled page answered 200 with HTML - page checks not run"))
            return out
        extra = []
        if len(self.rows) == 1:
            extra.append("homepage only: no usable sitemap URLs; its links still feed TS-40")
        if n["status"]:
            extra.append("%d URL(s) that redirected or failed not analyzed" % n["status"])
        if n["head"]:
            extra.append("%d sitemapped file(s) checked by HEAD only" % n["head"])
        if n["not_html"]:
            extra.append("%d non-HTML response(s) skipped" % n["not_html"])
        anchor = "sampled %d page(s) across %d URL famil%s%s" % (len(self.pages), len(fams), "y" if len(fams) == 1 else "ies", " (%s)" % "; ".join(extra) if extra else "")
        out.insert(0, ("PASS", "SAMPLE", anchor))
        return out

    def run(self):
        self.load()
        self.check_index()
        self.check_titles()
        self.check_structured()
        self.check_scripts()
        self.check_copy()
        self.check_head()
        self.collect_links()
        hosts = sorted(self.script_hosts)
        passes = {
            "TS-22": "sampled sitemap URLs answer 200 directly, indexable and crawlable",
            "TS-32": "sampled pages carry their own titles and canonicals",
            "TS-13": "no title shared across sampled pages",
            "SD-10": "every JSON-LD block on the sampled pages parses",
            "SD-07": "JSON-LD entity, breadcrumb, and image URLs match the canonical host",
            "SD-12": "no empty JSON-LD values or self-rated organizations",
            "SD-13": "JSON-LD publication dates parse, are ordered, and are not in the future",
            "TS-39": "no redirects, robots, titles, or JSON-LD applied by inline script",
            "TS-19": "no past-year freshness stamps in titles or descriptions",
            "LC-39": "no lorem ipsum or bracket placeholder copy",
            "TS-36": "no template placeholder hosts, unrendered tags, or malformed URLs",
            "PF-10": "no synchronous font loader or font-host @import",
            "PF-21": "no render-blocking third-party head resources" + self.owned_note,
            "AA-29": "third-party script hosts (%d): %s" % (len(hosts), ", ".join(hosts) or "none"),
        }
        return self.summary() + self.f.lines(passes)


def read_manifest(path):
    names = ("url", "exit", "code", "redirects", "final", "type", "body", "headers", "location", "listed", "walled")
    rows = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            cells = (line.rstrip("\n").split("\t") + [""] * len(names))[:len(names)]
            row = dict(zip(names, cells))
            row["listed"] = row["listed"] == "1"
            rows.append(row)
    return rows


def main():
    if len(sys.argv) != 7:
        sys.exit("usage: analyze-pages.py MANIFEST BASE_URL CURRENT_YEAR ROBOTS_PATH OUT_DIR PLATFORM")
    manifest, base_url, year, robots_path, out_dir, platform = sys.argv[1:]
    robots = None
    if robots_path:
        with open(robots_path, encoding="utf-8", errors="replace") as fh:
            robots = Robots(fh.read().lstrip("\ufeff"))
    now = datetime.datetime.now(datetime.timezone.utc)
    audit = Audit(read_manifest(manifest), base_url.rstrip("/"), int(year), robots, platform, now)
    for status, cid, detail in audit.run():
        print("%s\t%s\t%s" % (status, cid, " ".join(detail.split())))
    with open(os.path.join(out_dir, "links.txt"), "w", encoding="utf-8") as fh:
        fh.writelines(u + "\n" for u in sorted(audit.links))
    with open(os.path.join(out_dir, "stores.txt"), "w", encoding="utf-8") as fh:
        fh.writelines("%s\t%s\n" % (kind, u) for u, kind in sorted(audit.stores.items()))


if __name__ == "__main__":
    main()
