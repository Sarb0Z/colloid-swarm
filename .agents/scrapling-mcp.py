"""Scrapling's MCP server with its launch surface narrowed.

Run through uvx with `python -I` (see the `scrapling` entry in mcp.json). `-I`
keeps `.agents/` off `sys.path`, where `mcp.py` would shadow the `mcp` package
Scrapling imports.

Scrapling registers each tool from the bound method, so an override's signature
is the schema the model is offered. Dropping a parameter from the signature
removes it from the schema; a client that still sends it has it ignored.

What the narrowed server cannot do, whatever a call or the environment says:
- name a program to launch (`executable_path`, or any `SCRAPLING_`,
  `PLAYWRIGHT_`, `PATCHRIGHT_` or `NODE_` variable) or pass launch options
  (`additional_args`), or preload a library (`DYLD_`, `LD_`);
- attach to a running browser and its cookies (`cdp_url`, `new_context`);
- run an HTTP-only, state-file or session-less request tool;
- fetch a `file://` or other non-web address through `url`, or use a
  cloud-metadata host as its `proxy`;
- without a proxy, reach a cloud-metadata address at all: every browser the
  server opens without one resolves no such address, so a navigation, a
  redirect, an in-page or worker `fetch` and a WebSocket to it each fail with
  `net::ERR_NAME_NOT_RESOLVED`.
Under a proxy the proxy resolves every address, so a redirect from a public
page reaches the metadata service of the proxy's network. A DNS name that
resolves to a metadata address is not covered, with a proxy or without.
"""

import inspect
import ipaddress
import os
import socket
from typing import Annotated
from urllib.parse import unquote, urlsplit

from pydantic import Field
from scrapling.core.ai import ScraplingMCPServer
from scrapling.core.ai import server as server_module

SESSION_ID_PATTERN = r"^[A-Za-z0-9_-]{1,64}$"

DROPPED_LAUNCH_OPTIONS = frozenset({"executable_path", "additional_args", "cdp_url", "new_context"})

# Tools the host deny rules also name; removing them here holds on every host
# and when a hook does not run.
DENIED_TOOLS = (
    "make_request",
    "open_request_session",
    "session_make_request",
    "browser_save_state",
    "browser_load_state",
)

# Variables that choose the browser, the driver's Node or its flags
# (`NODE_OPTIONS --require`), or a library loaded into either. An allowlist
# would also strip the proxy and locale variables a run may need.
SCRUBBED_ENV_PREFIXES = ("NODE_", "PLAYWRIGHT_", "PATCHRIGHT_", "SCRAPLING_", "DYLD_", "LD_")

# The cloud-metadata hosts .agents/mcp_playwright.py blocks for Playwright.
METADATA_HOSTS = frozenset(ipaddress.ip_address(host) for host in ("169.254.169.254", "fd00:ec2::254"))

# Upstream's instructions minus the advice to start with HTTP and use
# `make_request`, which this server does not offer.
INSTRUCTIONS = """1. Close sessions when done. Use `list_sessions` to check sessions and settings. Read needed network data before closing; closing removes access to its history.
2. Use `browser_fetch_once` for standalone fetches; it closes automatically. Use sessions for related requests or follow-up browser actions and network history.
3. Fetch tools use `css_selector` to reduce output. HTML/Markdown/text return all matches; snapshots require one match or no selector for the whole page.
4. Session options persist from opening; fetch options apply per call, with schema defaults.
5. Each browser session uses one page; finish each call before starting the next in that session.
6. Network history capturing omits failed/unfinished requests. Limits: 1000 requests and 20 MiB of saved response bodies; oldest records are removed first. Response bodies over 1 MiB are skipped.
7. For challenges that have a slider with changing speed, don't release the mouse click without checking the page first to see if mouse adjustment needed before releasing. Keep repeating until you are certain."""


def _scrub_environment(environ):
    """Remove from `environ` every variable named by `SCRUBBED_ENV_PREFIXES`."""
    for name in [name for name in environ if name.startswith(SCRUBBED_ENV_PREFIXES)]:
        del environ[name]


def _host_address(host):
    """The address Chromium connects to for `host`, or None when it is a name.

    `host` is `urlsplit`'s lowercased hostname. Chromium percent-decodes it,
    maps full-width characters (IDNA), drops one trailing dot, and reads a
    numeric last label as IPv4 in every form `inet_aton` accepts: decimal, hex,
    octal and fewer than four parts.
    """
    host = unquote(host)
    if not host.isascii():
        try:
            host = host.encode("idna").decode("ascii")
        except UnicodeError:
            return None
    host = host.lower().removesuffix(".")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        try:
            address = ipaddress.IPv4Address(socket.inet_aton(host))
        except OSError:
            return None
    return getattr(address, "ipv4_mapped", None) or address


def _refuse_metadata(value, host):
    address = _host_address(host or "")
    if address in METADATA_HOSTS:
        raise ValueError(
            f"Refused {value!r}: cloud-metadata hosts are not fetched. "
            "Fetch the public page the task names instead."
        )


def _refuse_backslash(value):
    if "\\" in value:
        raise ValueError(
            f"Refused {value!r}: a backslash in an address is read differently by the browser. "
            "Write the address with forward slashes."
        )


def _refuse_address(url):
    """Raise unless `url` is an http(s) address that is not a cloud-metadata host."""
    _refuse_backslash(url)
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https"):
        raise ValueError(
            f"Refused {url!r}: only http and https addresses are fetched. "
            "To read a local file, use the Read tool; to read a web page, pass its http(s) address."
        )
    # Chromium reads `http:169.254.169.254/` and its one- and three-slash forms
    # as that host, where urlsplit sees no host at all.
    if not parts.hostname:
        raise ValueError(f"Refused {url!r}: the address names no host. Write it as http(s)://host/path.")
    _refuse_metadata(url, parts.hostname)


def _refuse_proxy(proxy):
    """Raise when `proxy`, a URL or a dictionary with `server`, names a cloud-metadata host."""
    server = proxy.get("server") if isinstance(proxy, dict) else proxy
    if not isinstance(server, str):
        return
    _refuse_backslash(server)
    # Playwright reads a server without a scheme as http.
    parts = urlsplit(server if "://" in server else f"http://{server}")
    _refuse_metadata(server, parts.hostname)


def _host_resolver_switch(addresses):
    """Chromium's `--host-resolver-rules` switch under which none of `addresses` resolves.

    Chromium matches a rule against the host of the canonical URL: IPv6
    without brackets (a bracketed entry matches nothing), and an IPv4 address
    spelled as IPv4-mapped IPv6 as its own hex form, so each IPv4 address
    gets a second entry. Numeric spellings of IPv4 canonicalize to dotted
    decimal before the match. Python's `compressed` writes the mapped form
    dotted, which Chromium does not match, so the hex is spelled out.
    """
    hosts = []
    for address in sorted(addresses, key=lambda address: (address.version, int(address))):
        hosts.append(address.compressed)
        if address.version == 4:
            hosts.append(f"::ffff:{int(address) >> 16:x}:{int(address) & 0xFFFF:x}")
    return "--host-resolver-rules=" + ", ".join(f"MAP {host} ~NOTFOUND" for host in hosts)


def _session_resolving_none_of(session_class, addresses):
    """A subclass of `session_class` whose browser, launched without a proxy, resolves none of `addresses`.

    The switch travels in Scrapling's `extra_flags` session option, which no
    tool exposes. Under a proxy it is left out: the proxy resolves every host,
    so it would not apply, and under socks5 patchright's driver passes its own
    `--host-resolver-rules`, which a second switch would collide with.
    """
    switch = _host_resolver_switch(addresses)

    class SessionResolvingNoneOf(session_class):
        __slots__ = ()

        def __init__(self, **kwargs):
            if not kwargs.get("proxy"):
                kwargs["extra_flags"] = [switch]
            super().__init__(**kwargs)

    return SessionResolvingNoneOf


# The one seam into upstream for the rule: `browser_open` and
# `browser_fetch_once` look this module global up on every call to build their
# browser session. Fail at import when either stops doing so, rather than
# serve browsers without the rule.
for _tool in (ScraplingMCPServer.browser_open, ScraplingMCPServer.browser_fetch_once):
    if "AsyncStealthySession" not in _tool.__code__.co_names:
        raise RuntimeError(
            f"Scrapling's {_tool.__name__} no longer builds its session from AsyncStealthySession; "
            "recheck the launcher's resolver rule seam"
        )
server_module.AsyncStealthySession = _session_resolving_none_of(server_module.AsyncStealthySession, METADATA_HOSTS)


def _narrowed(parent, dropped=(), replace=None, check_url=False, doc=None):
    """Build an override of `parent` whose signature omits `dropped`.

    `replace` maps a parameter name to a replacement `inspect.Parameter`. The
    override keeps the parent's docstring unless `doc` is given, refuses a
    metadata `proxy` when it takes one, and calls the parent with the dropped
    parameters unset.
    """
    signature = inspect.signature(parent)
    replace = replace or {}
    # `self` is left out of the published signature: Scrapling wraps the bound
    # method with functools.wraps, which copies this attribute as the schema
    # source and would otherwise offer `self` as a required argument.
    parameters = [
        replace.get(name, parameter)
        for name, parameter in signature.parameters.items()
        if name not in dropped and name != "self"
    ]
    annotations = {parameter.name: parameter.annotation for parameter in parameters}
    annotations["return"] = signature.return_annotation

    async def override(self, **kwargs):
        if check_url:
            _refuse_address(kwargs["url"])
        _refuse_proxy(kwargs.get("proxy"))
        return await parent(self, **kwargs)

    override.__name__ = parent.__name__
    override.__qualname__ = parent.__qualname__
    override.__doc__ = doc or parent.__doc__
    override.__annotations__ = annotations
    override.__signature__ = signature.replace(parameters=parameters)
    return override


_SESSION_ID = inspect.Parameter(
    "session_id",
    inspect.Parameter.POSITIONAL_OR_KEYWORD,
    annotation=Annotated[
        str,
        Field(
            description="Browser session ID: 1 to 64 letters, digits, '-' or '_'.",
            pattern=SESSION_ID_PATTERN,
        ),
    ],
)


class NarrowedScraplingMCPServer(ScraplingMCPServer):
    browser_open = _narrowed(
        ScraplingMCPServer.browser_open,
        dropped=DROPPED_LAUNCH_OPTIONS,
        replace={"session_id": _SESSION_ID},
        doc=ScraplingMCPServer.browser_open.__doc__.replace("local or remote browser session", "local browser session"),
    )
    browser_fetch_once = _narrowed(
        ScraplingMCPServer.browser_fetch_once, dropped=DROPPED_LAUNCH_OPTIONS, check_url=True
    )
    browser_fetch = _narrowed(ScraplingMCPServer.browser_fetch, check_url=True)

    def _resolve_executable_path(self, executable_path):
        return None

    def _build_server(self, host, port):
        server = super()._build_server(host, port)
        for name in DENIED_TOOLS:
            server.remove_tool(name)
        # MCPServer exposes its instructions read-only; the low-level server
        # sends this attribute in the initialize reply, which the launcher's
        # firing test reads back.
        server._lowlevel_server.instructions = INSTRUCTIONS
        return server


def main():
    _scrub_environment(os.environ)
    # The same call as `scrapling.cli:mcp` makes for stdio.
    NarrowedScraplingMCPServer().serve(False, "127.0.0.1", 8000)


if __name__ == "__main__":
    main()
