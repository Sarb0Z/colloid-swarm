"""The polite HTTP client every plugin shares.

A plugin never opens a connection. It asks this client, which paces requests to
each host, counts them against a per-host cap, honours `Retry-After` and
`Backoff`, follows redirects one hop at a time and prints every address it
reads. A run that must stop raises `RunStopped`; the runner turns that into exit
code 3.
"""

from __future__ import annotations

from collections import Counter
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from urllib.parse import urljoin, urlsplit

from .effects import Effects
from .model import RawResponse, TooLarge, TransportError

SAFE_METHODS = ("GET", "HEAD")
REDIRECT_STATUSES = (301, 302, 303, 307, 308)
RETRY_STATUSES = (500, 502, 503, 504)
ALLOWED_SCHEMES = ("http", "https")

RETRIES = 3
BACKOFF_BASE_S = 2.0
MAX_WAIT_S = 120.0
TIMEOUT_S = 30.0
MAX_BYTES = 64 * 1024 * 1024
MAX_REDIRECTS = 5
USER_AGENT = "paper-fetch/0.1 (research retrieval; honest client)"


class PoliteError(Exception):
    """Base for what this client refuses or gives up on."""


class RunStopped(PoliteError):
    """The whole run must stop; the message says why and how to resume."""


class HostCapReached(RunStopped):
    pass


class HostPaused(RunStopped):
    pass


class NetworkError(PoliteError):
    """A request failed after every retry its method allows."""


class RefusedAddress(PoliteError):
    """An address with a scheme other than http or https."""


class DryRunWrite(PoliteError):
    """A write was attempted through a read-only client."""


class TooManyRedirects(PoliteError):
    pass


@dataclass(frozen=True)
class Response:
    status: int
    headers: dict[str, str]
    body: bytes
    url: str  # the address that answered, after any redirects


@dataclass(frozen=True)
class Policy:
    delay_ms: int
    jitter_ms: int
    max_per_host: int
    host_intervals_ms: Mapping[str, int]
    read_only: bool = False
    retries: int = RETRIES
    backoff_base_s: float = BACKOFF_BASE_S
    max_wait_s: float = MAX_WAIT_S
    timeout_s: float = TIMEOUT_S
    max_bytes: int = MAX_BYTES
    max_redirects: int = MAX_REDIRECTS
    user_agent: str = USER_AGENT


class Http:
    def __init__(self, fx: Effects, policy: Policy, say: Callable[[str], None]) -> None:
        self._fx = fx
        self._policy = policy
        self._say = say
        self._counts: Counter[str] = Counter()
        self._next_ok: dict[str, float] = {}
        self._paused_until: dict[str, float] = {}

    def get(self, url: str, headers: Mapping[str, str] | None = None) -> Response:
        return self.request("GET", url, headers)

    def request(
        self,
        method: str,
        url: str,
        headers: Mapping[str, str] | None = None,
        body: bytes | None = None,
        idempotent: bool | None = None,
    ) -> Response:
        """Send one request and follow redirects.

        `idempotent` says a network error may be retried. It defaults to true for
        GET and HEAD and false for anything else, since a write that reached the
        server before the connection dropped would otherwise repeat.
        """
        method = method.upper()
        if self._policy.read_only and method not in SAFE_METHODS:
            raise DryRunWrite(f"{method} {url}: refused, this client is read-only")
        retry_errors = method in SAFE_METHODS if idempotent is None else idempotent
        sent = {"User-Agent": self._policy.user_agent, "Accept-Encoding": "identity", **(headers or {})}
        for _ in range(self._policy.max_redirects + 1):
            raw = self._send(method, url, sent, body, retry_errors)
            location = raw.headers.get("location")
            if raw.status in REDIRECT_STATUSES and location and method in SAFE_METHODS:
                url = urljoin(url, location)
                self._say(f"  -> redirected to {url}")
                continue
            return Response(raw.status, raw.headers, raw.body, url)
        raise TooManyRedirects(f"{url}: more than {self._policy.max_redirects} redirects")

    def _send(
        self, method: str, url: str, headers: Mapping[str, str], body: bytes | None, retry_errors: bool
    ) -> RawResponse:
        attempt = 0
        while True:
            host = self._admit(url)
            self._say(f"  {method} {url}")
            try:
                raw = self._fx.transport(
                    method, url, headers, body, self._policy.timeout_s, self._policy.max_bytes
                )
            except TooLarge:
                raise
            except TransportError as error:
                if retry_errors and attempt < self._policy.retries:
                    self._fx.sleep(self._backoff(host, attempt, None))
                    attempt += 1
                    continue
                raise NetworkError(f"{method} {url}: {error}") from error
            self._note_pause(host, raw)
            if self._retryable(raw.status, retry_errors) and attempt < self._policy.retries:
                self._fx.sleep(self._backoff(host, attempt, raw.headers.get("retry-after")))
                attempt += 1
                continue
            return raw

    @staticmethod
    def _retryable(status: int, retry_errors: bool) -> bool:
        # A 429 means the server refused the request unprocessed, so any method
        # may repeat it. A 5xx may have run the request first.
        return status == 429 or (retry_errors and status in RETRY_STATUSES)

    def _admit(self, url: str) -> str:
        """Check the address, then wait until this host may be asked again."""
        parts = urlsplit(url)
        if parts.scheme not in ALLOWED_SCHEMES or not parts.hostname:
            raise RefusedAddress(f"{url}: only http and https addresses are allowed")
        host = parts.hostname.lower()
        cap = self._policy.max_per_host
        if self._counts[host] >= cap:
            raise HostCapReached(
                f"{host}: {cap} requests made this run, the per-host cap; rerun to continue"
            )
        ready = max(self._next_ok.get(host, 0.0), self._paused_until.get(host, 0.0))
        now = self._fx.clock()
        if ready > now:
            self._fx.sleep(ready - now)
        self._counts[host] += 1
        interval_ms = max(self._policy.delay_ms, self._policy.host_intervals_ms.get(host, 0))
        pause = (interval_ms + self._fx.rng() * self._policy.jitter_ms) / 1000
        self._next_ok[host] = self._fx.clock() + pause
        return host

    def _note_pause(self, host: str, raw: RawResponse) -> None:
        seconds = _seconds(raw.headers.get("backoff"))
        if seconds:
            self._check_wait(host, seconds)
            self._paused_until[host] = self._fx.clock() + seconds

    def _backoff(self, host: str, attempt: int, retry_after: str | None) -> float:
        seconds = _seconds(retry_after)
        if seconds is not None:
            self._check_wait(host, seconds)
            return float(seconds)
        base = self._policy.backoff_base_s
        return min(self._policy.max_wait_s, base * 2**attempt + self._fx.rng() * base)

    def _check_wait(self, host: str, seconds: int) -> None:
        if seconds > self._policy.max_wait_s:
            raise HostPaused(
                f"{host}: asked for a {seconds} s pause, longer than the "
                f"{self._policy.max_wait_s:.0f} s this tool waits; rerun later"
            )


def _seconds(value: str | None) -> int | None:
    """Whole seconds from a Retry-After or Backoff value; None when it is not a number."""
    if value is None or not value.strip().isdigit():
        return None
    return int(value.strip())
