"""Proxy URLs, named proxies and the scrub that keeps their passwords out of text.

Two programs load this file by path: `mcp_playwright.py` and the Scrapling
launcher `scrapling-mcp.py`, which runs under `python -I` and so cannot import
from `.agents/`. Nothing here quotes a proxy URL, a line of an env file or a
password in an error: a message names the proxy, its key and its path.
"""

import json
import logging
import os
import re
import stat
import traceback
from pathlib import Path
from typing import NamedTuple
from urllib.parse import quote, unquote, urlsplit

# Playwright and Scrapling both take these four. Chromium cannot authenticate
# to a SOCKS proxy, so credentials on either SOCKS scheme are refused.
SCHEMES = ("http", "https", "socks4", "socks5")
SOCKS_SCHEMES = ("socks4", "socks5")
NAME = re.compile(r"[a-z][a-z0-9-]*")
ENV_KEY = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


class ProxyError(ValueError):
    """A proxy, a configured name or its env file that cannot be used as given."""


def _schemes_text():
    return ", ".join(SCHEMES[:-1]) + ", or " + SCHEMES[-1]


def split_url(raw, source, token=None):
    """Split a proxy URL into the dictionary Playwright and Scrapling take.

    `source` names where the URL came from, such as `$PLAYWRIGHT_PROXY` or
    `proxy 'office'`; errors lead with it and never quote the URL, which
    carries the proxy password. A `{session}` in the URL becomes `token` when
    one is given.
    """
    shape = f"{source} is not a proxy URL of the form scheme://[user:password@]host:port"
    text = raw.strip()
    if token is not None:
        text = text.replace("{session}", token)
    try:
        parts = urlsplit(text)
        port = parts.port
        host = parts.hostname
    except ValueError:
        raise ProxyError(shape) from None
    if parts.scheme not in SCHEMES:
        raise ProxyError(f"{source} must use {_schemes_text()}")
    if not host or port is None or parts.path not in {"", "/"} or parts.query or parts.fragment:
        raise ProxyError(shape)
    if parts.scheme in SOCKS_SCHEMES and (parts.username or parts.password):
        raise ProxyError(f"{source} is {parts.scheme} with credentials, which Chromium cannot send; "
                         "use the vendor's http or https endpoint")
    proxy = {"server": f"{parts.scheme}://{parts.netloc.rpartition('@')[2]}"}
    if parts.username:
        proxy["username"] = unquote(parts.username)
    if parts.password:
        proxy["password"] = unquote(parts.password)
    return proxy


class Named(NamedTuple):
    """A configured proxy: the env file holding its URL and the variable that does."""

    env_file: Path
    key: str


def load_names(config_path):
    """The `scrapling.proxies` map of the config document at `config_path`, name to `Named`.

    A missing file or key means no names. Read from `config.json` alone, never
    through `policy.json`: where a password lives is one operator's choice.
    """
    try:
        document = json.loads(Path(config_path).read_text())
    except FileNotFoundError:
        return {}
    except (OSError, ValueError):
        raise ProxyError(f"cannot read {config_path} as JSON") from None
    scrapling = document.get("scrapling", {}) if isinstance(document, dict) else {}
    proxies = scrapling.get("proxies", {}) if isinstance(scrapling, dict) else None
    if not isinstance(proxies, dict):
        raise ProxyError(f"scrapling.proxies in {config_path} must be an object")
    names = {}
    for name, entry in proxies.items():
        where = f"scrapling.proxies.{name} in {config_path}"
        if not NAME.fullmatch(name):
            raise ProxyError(f"{where}: a proxy name matches [a-z][a-z0-9-]*")
        if not isinstance(entry, dict) or set(entry) != {"env_file", "key"}:
            raise ProxyError(f'{where} must be {{"env_file": <path>, "key": <variable>}}')
        env_file, key = entry["env_file"], entry["key"]
        if not isinstance(env_file, str) or not env_file:
            raise ProxyError(f"{where}: env_file must be a path")
        env_file = os.path.expanduser(env_file)
        if not os.path.isabs(env_file):
            raise ProxyError(f"{where}: env_file must be absolute or start with ~")
        if not isinstance(key, str) or not ENV_KEY.fullmatch(key):
            raise ProxyError(f"{where}: key must be an environment variable name")
        names[name] = Named(Path(env_file), key)
    return names


def _read_line_value(name, named):
    """The value on the `KEY=value` line of `named.env_file`, split at the first `=`.

    No shell evaluation, quoting or `export` handling: the text after the
    first `=` is the value, less its line break.
    """
    label = f"proxy '{name}' (key {named.key} in {named.env_file})"
    try:
        descriptor = os.open(named.env_file, os.O_RDONLY)
    except FileNotFoundError:
        raise ProxyError(f"{label}: the env file does not exist") from None
    except OSError:
        raise ProxyError(f"{label}: the env file cannot be opened") from None
    status = os.fstat(descriptor)
    if not stat.S_ISREG(status.st_mode):
        os.close(descriptor)
        raise ProxyError(f"{label}: the env file is not a regular file")
    if status.st_mode & 0o077:
        os.close(descriptor)
        raise ProxyError(f"{label}: the env file grants group or other access "
                         f"(mode {stat.S_IMODE(status.st_mode):04o}); run chmod 600 {named.env_file}")
    with os.fdopen(descriptor, "rb") as handle:
        try:
            text = handle.read().decode()
        except OSError:
            raise ProxyError(f"{label}: the env file cannot be read") from None
        except UnicodeDecodeError:
            raise ProxyError(f"{label}: the env file is not UTF-8 text") from None
    for line in text.splitlines():
        found, separator, value = line.partition("=")
        if separator and found == named.key:
            if not value:
                raise ProxyError(f"{label}: the value is empty")
            return value
    raise ProxyError(f"{label}: no {named.key}=... line")


def resolve(name, named):
    """The split proxy dictionary for configured `name`, and the strings that must not reach any text.

    The strings are the password raw and percent-encoded and the full URL.
    """
    value = _read_line_value(name, named)
    proxy = split_url(value, f"proxy '{name}' (key {named.key} in {named.env_file})")
    password = proxy.get("password")
    secrets = {value}
    if password:
        secrets |= {password, quote(password, safe=""), quote(password), urlsplit(value).password}
    return proxy, secrets


class Redactor(logging.Filter):
    """Replaces registered secrets with `<proxy NAME>` in text and in log records."""

    def __init__(self):
        super().__init__()
        self._labels = {}

    def add(self, name, secrets):
        for secret in secrets:
            if secret:
                self._labels[secret] = f"<proxy {name}>"

    def scrub(self, text):
        for secret in sorted(self._labels, key=len, reverse=True):
            text = text.replace(secret, self._labels[secret])
        return text

    def filter(self, record):
        if not self._labels:
            return True
        message = record.getMessage()
        scrubbed = self.scrub(message)
        if scrubbed != message:
            record.msg, record.args = scrubbed, ()
        if record.exc_info:
            record.exc_text = "".join(traceback.format_exception(*record.exc_info))
            record.exc_info = None
        if record.exc_text:
            record.exc_text = self.scrub(record.exc_text)
        if record.stack_info:
            record.stack_info = self.scrub(record.stack_info)
        return True
