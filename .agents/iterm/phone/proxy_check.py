"""The daily check of the Signal TLS proxy's certificate (plan
`docs/notes/2026-11-18-signal-tls-proxy-plan.md`, acceptance 10).

While a proxy is set (`tls_proxy.py`), the link reads the certificate the proxy
presents, over TLS checked against this Mac's trust store, once a day. When
less than 48 h are left, it writes one line to errors.log and sends one alert
to Note to Self, while signal-cli still reaches Signal through the proxy. A
certificate that cannot be read (the proxy down, or a certificate that no
longer verifies) gets one errors.log line, and no alert, which could not go
out. `<state>/proxy-checked` holds the time of the last check, so a restart
does not check, or alert, again that day. With no proxy set, the setting is
looked at again every hour and nothing else is done.

The read runs off the service's loop (`start`), so a slow proxy holds no hook.
"""

from __future__ import annotations

import socket
import ssl
from datetime import datetime
from pathlib import Path

import log
import tls_proxy

WARN_SECONDS = 48 * 3600
DAY_SECONDS = 24 * 3600
# How often the setting is looked at while no proxy is set.
UNSET_SECONDS = 3600
# The loop's wake-up while a read runs.
POLL_SECONDS = 1
READ_TIMEOUT_SECONDS = 10
STAMP = "proxy-checked"


def certificate_expiry(host: str, port: int, context: ssl.SSLContext) -> float:
    """The notAfter, in epoch seconds, of the certificate `host:port` presents, verified by
    `context` for the name `host` (an IP address is checked as one)."""
    with socket.create_connection((host, port), timeout=READ_TIMEOUT_SECONDS) as raw:
        with context.wrap_socket(raw, server_hostname=host) as tls:
            return ssl.cert_time_to_seconds(tls.getpeercert()["notAfter"])


class ProxyCheck:
    """`tick()` and `next_due()` beside the link's. `read_expiry(host, port)` returns the
    certificate's notAfter or raises OSError (ssl.SSLError among them) or ValueError;
    `start(run)` runs `run` off the loop; `signal.send(text, done)` sends to Note to Self."""

    def __init__(self, *, state: Path, read_expiry, start, signal, errors, zone, clock):
        self.state, self.read_expiry, self.start, self.signal = state, read_expiry, start, signal
        self.errors, self.zone, self.clock = errors, zone, clock
        self.running = None  # the proxy being read, while a read runs
        self.result = None  # (notAfter, None) or (None, error), set by the read when it ends
        self.next_at = self._last_check() + DAY_SECONDS

    def _last_check(self) -> float:
        try:
            return float((self.state / STAMP).read_text(encoding="utf-8"))
        except FileNotFoundError:
            return float("-inf")
        except ValueError:
            self.errors.write(f"{self.state / STAMP} is not a time; the proxy's certificate is checked now")
            return float("-inf")

    def tick(self) -> None:
        self._begin(self.clock())
        if self.running is not None and self.result is not None:
            self._handle(self.running, *self.result, self.clock())
            self.running, self.result = None, None

    def _begin(self, now: float) -> None:
        """Start the day's read when it is due and none runs."""
        if self.running is not None or now < self.next_at:
            return
        try:
            proxy = tls_proxy.read(self.state)
        except ValueError as error:
            self.errors.write(f"the TLS proxy's certificate is not checked: {error}")
            self._checked(now)
            return
        if proxy is None:
            self.next_at = now + UNSET_SECONDS
            return
        self._checked(now)
        self.running = proxy
        host, port = tls_proxy.parse(proxy)
        self.start(lambda: self._read(host, port))

    def _checked(self, now: float) -> None:
        self.next_at = now + DAY_SECONDS
        (self.state / STAMP).write_text(f"{now}\n", encoding="utf-8")

    def _read(self, host: str, port: int) -> None:
        try:
            self.result = (self.read_expiry(host, port), None)
        except (OSError, ValueError) as error:
            self.result = (None, error)

    def _handle(self, proxy: str, expiry, error, now: float) -> None:
        if error is not None:
            self.errors.write(f"the TLS proxy {proxy}'s certificate was not read: {error}")
            return
        left = expiry - now
        if left >= WARN_SECONDS:
            return
        hours = int(left // 3600)
        self.errors.write(f"the TLS proxy {proxy}'s certificate expires {log.iso(expiry)}, in {hours} h; "
                          "the renewal on the server has not replaced it (journalctl -u signal-proxy-renew)")
        when = datetime.fromtimestamp(expiry, self.zone).strftime("%a %d %b %H:%M")
        text = (f"Signal proxy: its certificate expires {when}, in {hours} h. The renewal on the server has not "
                "replaced it: journalctl -u signal-proxy-renew")

        def sent(failure: str, _stamp) -> None:
            if failure:
                self.errors.write(f"the TLS proxy's warning was not sent: {failure}")
        self.signal.send(text, sent)

    def next_due(self) -> float:
        return self.clock() + POLL_SECONDS if self.running is not None else self.next_at
