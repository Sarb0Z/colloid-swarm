"""The saved Signal TLS proxy setting: `<state>/tls-proxy`, one line `HOST:PORT`.

`install.py` writes it (`install.sh --tls-proxy HOST:PORT`) and removes it
(`--tls-proxy none`); signal-cli's agent then gets `--tls-proxy HOST:PORT` before
`daemon`. `phone_link.py` reads it for the daily check of the proxy's certificate.
No file means no proxy.
"""

from __future__ import annotations

import re
from pathlib import Path

FILE = "tls-proxy"
# A host name or an IPv4 address, then a port.
_SHAPE = re.compile(r"([A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?):([0-9]{1,5})")


def parse(text: str) -> tuple:
    """`(host, port)` of `HOST:PORT`; ValueError for anything else."""
    match = _SHAPE.fullmatch(text)
    if not match or not 1 <= int(match.group(2)) <= 65535:
        raise ValueError(f"{text!r} is not HOST:PORT")
    return match.group(1), int(match.group(2))


def read(state: Path):
    """The saved `HOST:PORT`, or None when none is saved. ValueError names a file that holds
    anything else."""
    path = state / FILE
    try:
        text = path.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return None
    try:
        parse(text)
    except ValueError:
        raise ValueError(f"{path} holds {text!r}, not HOST:PORT") from None
    return text
