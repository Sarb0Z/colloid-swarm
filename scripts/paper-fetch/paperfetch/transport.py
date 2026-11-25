"""The real network transport, built on `urllib`.

It follows no redirect: the client follows each hop itself so every hop is
counted and printed. It reads at most `max_bytes`, and it decodes a gzip body
because an archive can serve one although the request asked for none.
"""

from __future__ import annotations

import http.client
import urllib.error
import urllib.request
import zlib
from collections.abc import Mapping
from email.message import Message
from typing import IO
from urllib.parse import urlsplit

from .model import RawResponse, TooLarge, TransportError


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def urllib_transport(
    method: str,
    url: str,
    headers: Mapping[str, str],
    body: bytes | None,
    timeout: float,
    max_bytes: int,
) -> RawResponse:
    if urlsplit(url).scheme not in ("http", "https"):
        raise TransportError(f"{url}: only http and https addresses are allowed")
    request = urllib.request.Request(url, data=body, headers=dict(headers), method=method)
    has_body = method != "HEAD"
    try:
        try:
            with _OPENER.open(request, timeout=timeout) as response:
                return _read(response.status, response.headers, response, max_bytes, has_body)
        except urllib.error.HTTPError as error:
            with error:  # an HTTP error status is still an answer
                return _read(error.code, error.headers, error, max_bytes, has_body)
    except (urllib.error.URLError, http.client.HTTPException, OSError, zlib.error) as error:
        raise TransportError(str(error)) from error


def _read(
    status: int, headers: Message, stream: IO[bytes], max_bytes: int, has_body: bool
) -> RawResponse:
    data = stream.read(max_bytes + 1)
    if len(data) > max_bytes:
        raise TooLarge(f"the body is over {max_bytes} bytes")
    lowered = {name.lower(): value for name, value in headers.items()}
    _check_complete(lowered.get("content-length"), data, has_body)
    encoding = lowered.get("content-encoding", "").strip().lower()
    if encoding == "gzip":
        data = _gunzip(data, max_bytes)
    elif encoding not in ("", "identity"):
        raise TransportError(f"content encoding {encoding!r} is not supported")
    return RawResponse(status, lowered, data)


def _check_complete(declared: str | None, data: bytes, has_body: bool) -> None:
    """Refuse a body shorter than the server promised.

    `read(amount)` on a response of known length returns what arrived and says
    nothing when the connection closed early, so a cut-off download would
    otherwise look whole. A PDF cut after its first bytes still starts `%PDF-`.
    """
    if has_body and declared is not None and declared.strip().isdigit():
        if len(data) != int(declared):
            raise TransportError(f"the body was cut off: {len(data)} of {declared.strip()} bytes arrived")


def _gunzip(data: bytes, max_bytes: int) -> bytes:
    decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
    text = decoder.decompress(data, max_bytes + 1)
    if len(text) > max_bytes or decoder.unconsumed_tail:
        raise TooLarge(f"the decoded body is over {max_bytes} bytes")
    return text
