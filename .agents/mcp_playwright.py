"""Browser settings and the launch config of the default `playwright` MCP server.

The operator's `browser` section lives in the ignored `.agents/config.json`
only. It names sites whose cookies the operator copies into the browser and a
proxy that carries credentials, so the tracked `policy.json` may not set it.
"""

import json
import re
import secrets
import subprocess
from pathlib import Path
from urllib.parse import unquote, urlsplit

BROWSER_DIR = ".agents/.browser"
CONFIG = f"{BROWSER_DIR}/playwright.json"
PROFILE = f"{BROWSER_DIR}/profile"
TOKEN = f"{BROWSER_DIR}/session-token"

# `None` leaves the value to the browser server, which is what an unconfigured
# checkout runs with. A user agent that disagrees with the real Chrome build is
# easier for a bot wall to detect than no override at all.
DEFAULTS = {
    "chrome_profile": "Default",
    "sync_sites": [],
    "user_agent": None,
    "locale": None,
    "timezone": None,
    "viewport": None,
    "headless": None,
    "proxy": False,
    "proxy_env": "PLAYWRIGHT_PROXY",
    "proxy_bypass": [],
}
CONTEXT_OPTIONS = {"user_agent": "userAgent", "locale": "locale",
                   "timezone": "timezoneId", "viewport": "viewport"}
# Playwright proxies loopback unless the bypass list names a loopback host, so
# a proxied session would send local dev servers to the proxy vendor.
LOOPBACK = ["localhost", "*.localhost", "127.0.0.1", "[::1]"]
# Literal cloud metadata origins refused on direct navigation. Playwright MCP
# documents blocked origins as no security boundary, and they do not apply to
# redirects, so this stops only a typed or linked metadata URL, not a page that
# redirects there. Its `host:*` glob needs a literal ":" in the URL, so IPv4
# takes a bare entry for the default port beside the `:*` one. It cannot express
# a wildcard port for an IPv6 host: those are blocked on the default port only.
# Chromium normalizes ::ffff:169.254.169.254 to the hex form listed here.
METADATA_V4 = "169.254.169.254"
METADATA_V6 = ["[fd00:ec2::254]", "[::ffff:a9fe:a9fe]"]
BLOCKED_ORIGINS = [origin for scheme in ("http", "https")
                   for origin in (f"{scheme}://{METADATA_V4}", f"{scheme}://{METADATA_V4}:*",
                                  *(f"{scheme}://{host}" for host in METADATA_V6))]
ENV_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
TOKEN_SHAPE = re.compile(r"[0-9a-f]{12}")


class SettingsError(Exception):
    """A browser setting or proxy endpoint that cannot be used as given."""


def sync_options(args):
    """`mcp.py sync` flags: the settings file to read and whether to rotate the token."""
    rest = [arg for arg in args if arg != "--new-proxy-session"]
    if rest and (len(rest) != 2 or rest[0] != "--settings"):
        raise SettingsError("usage: mcp.py sync [--settings FILE] [--new-proxy-session]")
    return (Path(rest[1]).resolve() if rest else None), len(rest) != len(args)


def _optional_text(settings, name):
    value = settings[name]
    if value is not None and (not isinstance(value, str) or not value.strip()):
        raise SettingsError(f"browser.{name} must be a non-empty string or null")


def _validate(settings):
    unknown = sorted(set(settings) - set(DEFAULTS))
    if unknown:
        raise SettingsError(f"unknown browser setting(s): {', '.join(unknown)}")
    merged = {**DEFAULTS, **settings}
    profile = merged["chrome_profile"]
    if not isinstance(profile, str) or not profile or "/" in profile or profile in {".", ".."}:
        raise SettingsError("browser.chrome_profile must be a Chrome profile directory name such as Default")
    sites = merged["sync_sites"]
    if not isinstance(sites, list) or not all(isinstance(site, str) for site in sites):
        raise SettingsError("browser.sync_sites must be a list of site names")
    for name in ("user_agent", "locale", "timezone"):
        _optional_text(merged, name)
    viewport = merged["viewport"]
    if viewport is not None and not (
            isinstance(viewport, dict) and set(viewport) == {"width", "height"}
            and all(isinstance(viewport[key], int) and not isinstance(viewport[key], bool)
                    and viewport[key] > 0 for key in viewport)):
        raise SettingsError("browser.viewport must be null or {\"width\": N, \"height\": N}")
    if merged["headless"] is not None and not isinstance(merged["headless"], bool):
        raise SettingsError("browser.headless must be true, false, or null")
    if not isinstance(merged["proxy"], bool):
        raise SettingsError("browser.proxy must be true or false")
    if not isinstance(merged["proxy_env"], str) or not ENV_NAME.fullmatch(merged["proxy_env"]):
        raise SettingsError("browser.proxy_env must be an environment variable name")
    bypass = merged["proxy_bypass"]
    if not isinstance(bypass, list) or not all(
            isinstance(item, str) and item and not re.search(r"[\s,]", item) for item in bypass):
        raise SettingsError("browser.proxy_bypass must be a list of host patterns")
    return merged


def _read(path, label):
    try:
        document = json.loads(path.read_text())
    except FileNotFoundError:
        return {}
    except (OSError, ValueError):
        raise SettingsError(f"cannot read {label} as JSON") from None
    return document if isinstance(document, dict) else {}


def read_config(source):
    """The operator's config document, empty when the file is absent."""
    return _read(source, str(source))


def load_settings(repo, path=None):
    """The validated browser settings: `path`, else `.agents/config.json`, over DEFAULTS."""
    if "browser" in _read(repo / ".agents/policy.json", ".agents/policy.json"):
        raise SettingsError("browser settings belong in the ignored .agents/config.json, "
                            "not the tracked .agents/policy.json")
    source = path or repo / ".agents/config.json"
    section = read_config(source).get("browser", {})
    if not isinstance(section, dict):
        raise SettingsError(f"browser in {source} must be an object")
    return _validate(section)


def _proxy_url(raw, token, env_name):
    """Split a proxy URL into Playwright's fields. Errors never quote the URL:
    it carries the proxy password."""
    shape = f"${env_name} is not a proxy URL of the form scheme://[user:password@]host:port"
    try:
        parts = urlsplit(raw.strip().replace("{session}", token or ""))
        port = parts.port
        host = parts.hostname
    except ValueError:
        raise SettingsError(shape) from None
    if parts.scheme not in {"http", "https", "socks5"}:
        raise SettingsError(f"${env_name} must use http, https, or socks5")
    if not host or port is None or parts.path not in {"", "/"} or parts.query or parts.fragment:
        raise SettingsError(shape)
    if parts.scheme == "socks5" and (parts.username or parts.password):
        raise SettingsError(f"${env_name} is socks5 with credentials, which Chromium cannot send; "
                            "use the vendor's http or https endpoint")
    proxy = {"server": f"{parts.scheme}://{parts.netloc.rpartition('@')[2]}"}
    if parts.username:
        proxy["username"] = unquote(parts.username)
    if parts.password:
        proxy["password"] = unquote(parts.password)
    return proxy


def _proxy(repo, settings, environ, rotate):
    """Playwright's proxy option and the session token it used, if any.

    The `{session}` token is stored and reused, so every generation presents
    the proxy vendor with one sticky identity until the operator rotates it.
    """
    env_name = settings["proxy_env"]
    raw = environ.get(env_name, "")
    if not raw.strip():
        raise SettingsError(f"browser.proxy is true but ${env_name} is not set")
    token = None
    if "{session}" in raw:
        stored = ""
        if not rotate:
            try:
                stored = (repo / TOKEN).read_text().strip()
            except OSError:
                stored = ""
        token = stored if TOKEN_SHAPE.fullmatch(stored) else secrets.token_hex(6)
    proxy = _proxy_url(raw, token, env_name)
    bypass = LOOPBACK + [item for item in settings["proxy_bypass"] if item not in LOOPBACK]
    proxy["bypass"] = ",".join(bypass)
    return proxy, token


def render(repo, settings, environ, rotate=False):
    """The server's config document and the proxy session token to store."""
    launch = {"channel": "chrome"}
    if settings["headless"] is not None:
        launch["headless"] = settings["headless"]
    browser = {"browserName": "chromium", "launchOptions": launch}
    profile = repo / PROFILE
    if (profile / "Default/Cookies").is_file():
        # Branded Chrome encrypts cookies with the login Keychain key, and
        # Playwright's default mock keychain cannot decrypt the synced ones.
        # playwright-session.py starts each server on its own copy of this
        # directory: one profile admits one browser, and sessions run in parallel.
        browser["userDataDir"] = str(profile)
        launch["ignoreDefaultArgs"] = ["--use-mock-keychain"]
    else:
        browser["isolated"] = True
    context = {key: settings[name] for name, key in CONTEXT_OPTIONS.items()
               if settings[name] is not None}
    if context:
        browser["contextOptions"] = context
    token = None
    if settings["proxy"]:
        launch["proxy"], token = _proxy(repo, settings, environ, rotate)
    return {"browser": browser, "network": {"blockedOrigins": BLOCKED_ORIGINS}, "webmcp": False}, token


def prepare_dir(repo, target):
    """Create the browser directory so Git ignores it, and refuse a target Git
    would still track: the directory holds session cookies and proxy credentials."""
    directory = repo / BROWSER_DIR
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory.chmod(0o700)
    marker = directory / ".gitignore"
    if not marker.is_file() or marker.read_text() != "*\n":
        marker.write_text("*\n")
    try:
        inside = subprocess.run(["git", "-C", str(repo), "rev-parse", "--is-inside-work-tree"],
                                capture_output=True, text=True)
    except FileNotFoundError:
        return
    if inside.returncode or inside.stdout.strip() != "true":
        return
    ignored = subprocess.run(["git", "-C", str(repo), "check-ignore", "-q", "--", str(target)],
                             capture_output=True)
    if ignored.returncode:
        raise SettingsError(f"refusing to write {target.relative_to(repo)}: Git does not ignore it; "
                            f"untrack it and keep {BROWSER_DIR}/ in .gitignore")
