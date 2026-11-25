"""The types a plugin receives and the errors a plugin may raise."""

from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import dataclass

KINDS = ("pdf", "xml", "html")

# Runs a command and returns its standard output. The entry point wires the real
# one; a converter calls it instead of importing `subprocess`.
Runner = Callable[[list[str]], str]


@dataclass(frozen=True)
class Paper:
    """One manifest row: its key, its DOI and every column the manifest holds."""

    key: str
    doi: str
    row: dict[str, str]


@dataclass(frozen=True)
class Candidate:
    """An address a source offers for a paper, and what the address should serve."""

    url: str
    kind: str
    source: str
    license: str | None = None


class NoText(Exception):
    """A converter found no text layer in the file."""


class WrongPaper(Exception):
    """The file is not the paper the manifest names. The message says why."""


@dataclass(frozen=True)
class RawResponse:
    status: int
    headers: dict[str, str]  # names in lower case
    body: bytes


class TransportError(Exception):
    """The connection failed: refused, reset, timed out, or cut off mid-body."""


class TooLarge(TransportError):
    """The body is larger than the cap."""


# method, url, headers, body, timeout seconds, body-size cap -> a raw response.
Transport = Callable[[str, str, Mapping[str, str], bytes | None, float, int], RawResponse]
