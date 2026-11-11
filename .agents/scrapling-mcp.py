"""Scrapling's MCP server with its launch surface narrowed.

Claude only: the registry lists `scrapling` for no other host.

Run through uvx with `python -I` (see the `scrapling` entry in mcp.json). `-I`
keeps `.agents/` off `sys.path`, where `mcp.py` would shadow the `mcp` package
Scrapling imports.

Scrapling registers each tool from the bound method, so an override's signature
is the schema the model is offered. Dropping a parameter from the signature
removes it from the schema; a client that still sends it has it ignored.

What the narrowed server cannot do, whatever a call or the environment says:
- name a program to launch (`executable_path`, `SCRAPLING_EXECUTABLE_PATH`,
  `PLAYWRIGHT_NODEJS_PATH`) or pass launch options (`additional_args`);
- attach to a running browser and its cookies (`cdp_url`, `new_context`);
- run an HTTP-only, state-file or session-less request tool;
- fetch a `file://` or other non-web address, or a cloud-metadata host.
"""

import inspect
import ipaddress
import os
from typing import Annotated
from urllib.parse import urlsplit

from pydantic import Field
from scrapling.core.ai import ScraplingMCPServer

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

# Environment variables that name a program to launch (Scrapling's server.py,
# Patchright's driver).
PROGRAM_ENV = ("SCRAPLING_EXECUTABLE_PATH", "PLAYWRIGHT_NODEJS_PATH")

# The cloud-metadata hosts .agents/mcp_playwright.py blocks for Playwright.
METADATA_HOSTS = frozenset(ipaddress.ip_address(host) for host in ("169.254.169.254", "fd00:ec2::254"))


def _refuse_address(url):
    """Raise unless `url` is an http(s) address that is not a cloud-metadata host."""
    parts = urlsplit(url)
    if parts.scheme.lower() not in ("http", "https"):
        raise ValueError(
            f"Refused {url!r}: only http and https addresses are fetched. "
            "To read a local file, use the Read tool; to read a web page, pass its http(s) address."
        )
    host = parts.hostname or ""
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return
    address = getattr(address, "ipv4_mapped", None) or address
    if address in METADATA_HOSTS:
        raise ValueError(
            f"Refused {url!r}: cloud-metadata hosts are not fetched. "
            "Fetch the public page the task names instead."
        )


def _narrowed(parent, dropped=(), replace=None, check_url=False):
    """Build an override of `parent` whose signature omits `dropped`.

    `replace` maps a parameter name to a replacement `inspect.Parameter`. The
    override keeps the parent's docstring and calls the parent with the dropped
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
        return await parent(self, **kwargs)

    override.__name__ = parent.__name__
    override.__qualname__ = parent.__qualname__
    override.__doc__ = parent.__doc__
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
        return server


def main():
    for name in PROGRAM_ENV:
        os.environ.pop(name, None)
    # The same call as `scrapling.cli:mcp` makes for stdio.
    NarrowedScraplingMCPServer().serve(False, "127.0.0.1", 8000)


if __name__ == "__main__":
    main()
