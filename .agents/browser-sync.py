#!/usr/bin/env python3
"""Copy the cookies of the listed sites from a Chrome profile into the
Playwright browser profile, then regenerate the MCP configuration.

Usage: browser-sync.py [--source DIR] [--settings FILE]

The operator runs this, never an agent: it reads the operator's own Chrome
cookie store. `browser.sync_sites` in `.agents/config.json` lists the sites;
`browser.chrome_profile` names the Chrome profile directory. `--source` is a
Chrome user data directory other than the default branded Chrome one, and
`--settings` reads the browser settings from FILE instead of config.json.

Only the cookie store of the Playwright profile is replaced. Its other state
persists, and a rerun replaces the cookies again from the current source.
"""

import ipaddress
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import quote

import mcp_playwright as playwright

CHROME = Path.home() / "Library/Application Support/Google/Chrome"
# Suffixes under which unrelated owners register sites. Listing one would copy
# every site under it. This is a floor, not the Public Suffix List.
PUBLIC_SUFFIXES = {
    "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "com.au", "net.au", "org.au",
    "co.nz", "co.jp", "co.in", "co.za", "com.br", "com.cn", "com.mx", "com.tr",
    "github.io", "gitlab.io", "vercel.app", "netlify.app", "pages.dev",
    "workers.dev", "web.app", "firebaseapp.com", "herokuapp.com", "appspot.com",
    "blogspot.com", "azurewebsites.net", "cloudfront.net", "amazonaws.com",
    "s3.amazonaws.com", "fly.dev", "onrender.com", "ngrok.io", "ngrok-free.app",
}
SIDECARS = ("-journal", "-wal", "-shm")


class SyncError(Exception):
    """A refusal the operator can act on."""


def _exact(host):
    """`localhost` and IP literals match only themselves: `0.0.1` is not a
    parent of `127.0.0.1`, and `localhost` is not a parent of every `*.localhost`."""
    try:
        ipaddress.ip_address(host)
    except ValueError:
        return host == "localhost"
    return True


def normalize_site(entry):
    """`https://www.Bücher.de/path` -> `www.xn--bcher-kva.de`, the form Chrome
    stores; refuses a single-label name and a public suffix."""
    text = re.sub(r"^[a-z][a-z0-9+.-]*://", "", entry.strip().lower())
    host = re.split(r"[/?#]", text, maxsplit=1)[0].rpartition("@")[2]
    host = re.sub(r":\d+$", "", host).strip(".")
    try:
        host = host.encode("idna").decode("ascii")
    except UnicodeError:
        host = ""
    if not host or not re.fullmatch(r"[a-z0-9.-]+", host) or ".." in host:
        raise SyncError(f"browser.sync_sites entry {entry!r} is not a host name")
    if _exact(host):
        return host
    if "." not in host:
        raise SyncError(f"browser.sync_sites entry {entry!r} is a single-label name; list a "
                        "full host name such as example.com (localhost is the one exception)")
    if host.rpartition(".")[2].isdigit():
        raise SyncError(f"browser.sync_sites entry {entry!r} is neither a host name nor an IP address")
    if host in PUBLIC_SUFFIXES:
        raise SyncError(f"browser.sync_sites entry {entry!r} is a public suffix; "
                        "list the site itself, such as example.com")
    return host


def _host_of_site_key(key):
    """The host of a partition key such as `https://example.com`."""
    return re.sub(r"^[a-z][a-z0-9+.-]*://", "", key.lower()).split("/")[0].split(":")[0]


def site_of(host, sites):
    """The listed site a cookie host belongs to, or None.

    `example.com` covers `example.com`, `.example.com`, and `www.example.com`,
    never `notexample.com`. A domain cookie (leading dot) also belongs to a
    listed subdomain it is sent to: `.example.com` to `www.example.com`."""
    domain = host.startswith(".")
    host = host.lower().lstrip(".")
    for site in sites:
        if host == site:
            return site
        if _exact(site) or _exact(host):
            continue
        if host.endswith("." + site) or (domain and "." in host and site.endswith("." + host)):
            return site
    return None


def _kept(host, top_frame_site, sites):
    """A partitioned cookie also needs its top-level site listed. The partition
    key names a registrable site, which covers its subdomains like a domain cookie."""
    if site_of(host or "", sites) is None:
        return False
    return not top_frame_site or site_of("." + _host_of_site_key(top_frame_site), sites) is not None


def profile_locked(directory):
    """True when a live Chrome process holds this user data directory.

    Chrome's SingletonLock is a symlink to `<host>-<pid>`; a dead pid leaves a
    stale link that locks nothing."""
    try:
        target = os.readlink(directory / "SingletonLock")
    except OSError:
        return False
    pid = target.rpartition("-")[2]
    if not pid.isdigit():
        return False
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    return True


def _fsync(path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def filtered_copy(source, target, sites):
    """Write the listed sites' rows of the cookie store `source` to `target`.

    The unfiltered store is read into memory only: the file that reaches disk
    is written by VACUUM INTO after the unlisted rows are gone, so no free page
    of it carries another site's cookie. Returns (kept rows per site, total)."""
    memory = sqlite3.connect(":memory:")
    temp = None
    try:
        try:
            origin = sqlite3.connect(f"file:{quote(str(source))}?mode=ro", uri=True, timeout=1,
                                     isolation_level=None)
            try:
                # Python's backup retries a busy source forever, so take the
                # read lock first, where the timeout applies, and hold it.
                origin.execute("BEGIN")
                origin.execute("SELECT count(*) FROM sqlite_master").fetchone()
                origin.backup(memory)
            finally:
                origin.close()
        except sqlite3.OperationalError as error:
            if "locked" in str(error) or "busy" in str(error):
                raise SyncError("Chrome holds its cookie store open; quit Chrome, then rerun") from None
            raise SyncError(f"cannot read {source} as a Chrome cookie store") from None
        except sqlite3.DatabaseError:
            raise SyncError(f"cannot read {source} as a Chrome cookie store") from None
        columns = {row[1] for row in memory.execute("PRAGMA table_info(cookies)")}
        if "host_key" not in columns:
            raise SyncError(f"{source} has no Chrome cookies table")
        partition = "top_frame_site_key" if "top_frame_site_key" in columns else "''"
        memory.create_function("kept", 2, lambda host, top: _kept(host, top, sites), deterministic=True)
        total = memory.execute("SELECT count(*) FROM cookies").fetchone()[0]
        memory.execute(f"DELETE FROM cookies WHERE NOT kept(host_key, {partition})")
        memory.commit()
        counts = dict.fromkeys(sites, 0)
        for (host,) in memory.execute("SELECT host_key FROM cookies"):
            counts[site_of(host, sites)] += 1
        descriptor, name = tempfile.mkstemp(dir=target.parent, prefix=".Cookies-", suffix=".tmp")
        os.close(descriptor)
        temp = Path(name)
        memory.execute("VACUUM INTO ?", (str(temp),))
        temp.chmod(0o600)
        _fsync(temp)
        for suffix in SIDECARS:
            Path(f"{target}{suffix}").unlink(missing_ok=True)
        temp.replace(target)
        temp = None
        _fsync(target.parent)
        return counts, total
    finally:
        memory.close()
        if temp is not None:
            for path in (temp, *(Path(f"{temp}{suffix}") for suffix in SIDECARS)):
                path.unlink(missing_ok=True)


def sync(repo, source, settings_path):
    """Copy the listed cookies into the Playwright profile. Returns printable lines.

    `source` is None for the default Chrome directory. A given source must hold
    its own store: a symlink out of it, or into the default Chrome directory,
    would read the user's cookies under a synthetic-looking path."""
    settings = playwright.load_settings(repo, settings_path)
    sites = list(dict.fromkeys(normalize_site(entry) for entry in settings["sync_sites"]))
    if not sites:
        raise SyncError("browser.sync_sites is empty; list the sites to copy in .agents/config.json")
    if source is None:
        source = CHROME
    else:
        resolved = (source / settings["chrome_profile"] / "Cookies").resolve()
        if not resolved.is_relative_to(source.resolve()) or resolved.is_relative_to(CHROME):
            raise SyncError("the cookie store under --source resolves outside it or into the "
                            "default Chrome directory; omit --source to read that directory")
    store = source / settings["chrome_profile"] / "Cookies"
    if not store.is_file():
        raise SyncError(f"no Chrome cookie store at {store}")
    if profile_locked(source):
        raise SyncError("Chrome is running on the source profile; quit Chrome, then rerun")
    profile = repo / playwright.PROFILE
    if profile_locked(profile):
        raise SyncError("a browser is running on the synced profile, which agent sessions copy "
                        "and never open; close that browser, then rerun")
    target = profile / "Default/Cookies"
    playwright.prepare_dir(repo, target)
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    for directory in (profile, target.parent):
        directory.chmod(0o700)
    counts, total = filtered_copy(store, target, sites)
    lines = [f"Copied {sum(counts.values())} of {total} cookies into {playwright.PROFILE}."]
    lines += [f"  {site}: {count}" for site, count in counts.items() if count]
    empty = [site for site, count in counts.items() if not count]
    if empty:
        lines.append("No cookies for: " + ", ".join(empty))
    return lines


def _arguments(argv):
    options = {"--source": None, "--settings": None}
    while argv:
        flag, *argv = argv
        name, _, value = flag.partition("=")
        if name not in options or not (value or argv):
            raise SyncError("usage: browser-sync.py [--source DIR] [--settings FILE]")
        if not value:
            value, *argv = argv
        options[name] = Path(value).expanduser().resolve()
    return options["--source"], options["--settings"]


def main(argv, platform=sys.platform):
    repo = Path(__file__).resolve().parent.parent
    try:
        if platform != "darwin":
            raise SyncError("syncing needs macOS: the copied cookies are sealed with the macOS Keychain key")
        source, settings_path = _arguments(argv)
        lines = sync(repo, source, settings_path)
    except (SyncError, playwright.SettingsError) as error:
        print(f"browser-sync: {error}", file=sys.stderr)
        return 1
    print("\n".join(lines))
    regenerate = [sys.executable, str(repo / ".agents/mcp.py"), "sync"]
    if settings_path:
        regenerate += ["--settings", str(settings_path)]
    if subprocess.run(regenerate).returncode:
        print("browser-sync: the cookies are synced, but mcp.py sync failed; fix it and rerun mcp.py",
              file=sys.stderr)
        return 1
    print("Restart the agent session so the playwright server loads the synced profile.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
