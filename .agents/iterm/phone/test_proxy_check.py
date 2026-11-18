#!/usr/bin/env python3
"""Tests for proxy_check.py: the daily check of the Signal TLS proxy's certificate.

Seams: `ProxyCheck` with its clock, its certificate reader, its runner and its
sender passed in, over a scratch state folder read back as errors.log; and
`certificate_expiry` against a real TLS listener on 127.0.0.1 with a
certificate made by openssl. Catches a warning that is missed under 48 h, sent
above it, sent twice in a day or again after a restart, a check that runs with
no proxy set, and a reader that does not check the certificate's IP name.
Misses the live proxy and the Mac's trust store, which acceptance 10 and 3
check after apply.
"""

import os
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path
from zoneinfo import ZoneInfo

import log
import proxy_check

NOW = log.epoch_of("2026-11-18T09:00:00Z")
HOUR = 3600
DAY = 24 * HOUR
PKT = ZoneInfo("Asia/Karachi")


class Sender:
    """Stands in for `phone_link.Signal`: records each text, and ends each send with `ending`."""

    def __init__(self):
        self.texts, self.ending = [], ""

    def send(self, text, done):
        self.texts.append(text)
        done(self.ending, None if self.ending else 1)


class Check(unittest.TestCase):
    def setUp(self):
        self.state = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.state)
        log.prepare(self.state)
        self.now = NOW
        self.errors = log.Errors(self.state / "errors.log", clock=lambda: self.now)
        self.signal = Sender()
        self.expiry = NOW + 47 * HOUR
        self.reads = []
        self.deferred = []

    def read(self, host, port):
        self.reads.append((host, port))
        if isinstance(self.expiry, Exception):
            raise self.expiry
        return self.expiry

    def check(self, start=None):
        return proxy_check.ProxyCheck(state=self.state, read_expiry=self.read, start=start or (lambda run: run()),
                                      signal=self.signal, errors=self.errors, zone=PKT, clock=lambda: self.now)

    def lines(self):
        path = self.state / "errors.log"
        return path.read_text(encoding="utf-8").splitlines() if path.exists() else []

    def set_proxy(self, text="62.171.166.213:8443"):
        (self.state / "tls-proxy").write_text(text + "\n", encoding="utf-8")

    def test_under_48_hours_one_errors_line_and_one_alert_a_day(self):
        self.set_proxy()
        check = self.check()
        check.tick()
        self.assertEqual(self.reads, [("62.171.166.213", 8443)])
        self.assertEqual(self.lines(), [
            "2026-11-18T09:00:00Z the TLS proxy 62.171.166.213:8443's certificate expires 2026-11-20T08:00:00Z, "
            "in 47 h; the renewal on the server has not replaced it (journalctl -u signal-proxy-renew)"])
        self.assertEqual(self.signal.texts, [
            "Signal proxy: its certificate expires Fri 20 Nov 13:00, in 47 h. The renewal on the server has not "
            "replaced it: journalctl -u signal-proxy-renew"])
        for minutes in range(1, 24 * 60, 7):
            self.now = NOW + minutes * 60
            check.tick()
        self.assertEqual((len(self.reads), len(self.lines()), len(self.signal.texts)), (1, 1, 1))
        self.now = NOW + DAY
        self.expiry = NOW + DAY + 30 * HOUR
        check.tick()
        self.assertEqual((len(self.reads), len(self.lines()), len(self.signal.texts)), (2, 2, 2))
        self.assertIn("in 30 h", self.signal.texts[-1])

    def test_above_48_hours_nothing_is_written_or_sent(self):
        self.set_proxy()
        self.expiry = NOW + 49 * HOUR
        self.check().tick()
        self.assertEqual((len(self.reads), self.lines(), self.signal.texts), (1, [], []))

    def test_no_proxy_set_no_check(self):
        check = self.check()
        for hours in range(0, 72):
            self.now = NOW + hours * HOUR
            check.tick()
        self.assertEqual((self.reads, self.lines(), self.signal.texts), ([], [], []))

    def test_a_proxy_set_after_the_start_is_checked_within_the_hour(self):
        check = self.check()
        check.tick()
        self.set_proxy()
        self.now = NOW + HOUR
        check.tick()
        self.assertEqual(len(self.reads), 1)
        self.assertEqual(len(self.signal.texts), 1)

    def test_a_restart_within_the_day_does_not_check_again(self):
        self.set_proxy()
        self.check().tick()
        self.now = NOW + 5 * HOUR
        self.check().tick()
        self.assertEqual((len(self.reads), len(self.signal.texts)), (1, 1))
        self.now = NOW + DAY
        self.check().tick()
        self.assertEqual((len(self.reads), len(self.signal.texts)), (2, 2))

    def test_a_certificate_not_read_writes_one_line_and_sends_nothing(self):
        self.set_proxy()
        self.expiry = ssl.SSLCertVerificationError(1, "certificate verify failed: certificate has expired")
        check = self.check()
        check.tick()
        self.now = NOW + HOUR
        check.tick()
        self.assertEqual(len(self.lines()), 1)
        self.assertIn("the TLS proxy 62.171.166.213:8443's certificate was not read: certificate verify "
                      "failed: certificate has expired", self.lines()[0])
        self.assertEqual(self.signal.texts, [])

    def test_an_alert_that_is_not_sent_is_written_too(self):
        self.set_proxy()
        self.signal.ending = "signal-cli's account is not known"
        self.check().tick()
        self.assertEqual(len(self.lines()), 2)
        self.assertIn("the TLS proxy's warning was not sent: signal-cli's account is not known", self.lines()[1])

    def test_a_saved_setting_that_is_not_host_port_is_written_once_a_day(self):
        self.set_proxy("not a proxy")
        check = self.check()
        check.tick()
        self.now = NOW + HOUR
        check.tick()
        self.assertEqual(self.reads, [])
        self.assertEqual(len(self.lines()), 1)
        self.assertIn("holds 'not a proxy', not HOST:PORT", self.lines()[0])

    def test_the_read_runs_off_the_loop_and_one_at_a_time(self):
        self.set_proxy()
        check = self.check(start=self.deferred.append)
        check.tick()
        self.assertEqual(check.next_due(), NOW + 1)
        self.now = NOW + 30
        check.tick()
        self.assertEqual(len(self.deferred), 1)
        self.assertEqual(self.signal.texts, [])
        self.deferred.pop()()
        check.tick()
        self.assertEqual(len(self.signal.texts), 1)
        self.assertEqual(check.next_due(), NOW + DAY)


@unittest.skipUnless(shutil.which("openssl"), "openssl makes the test certificate")
class Expiry(unittest.TestCase):
    """`certificate_expiry` against a TLS listener on 127.0.0.1."""

    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.folder)

    def serve(self, address):
        cert, key = self.folder / f"{address}.crt", self.folder / f"{address}.key"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
                        "-days", "2", "-subj", f"/CN={address}", "-addext", f"subjectAltName=IP:{address}",
                        "-keyout", str(key), "-out", str(cert)], check=True, capture_output=True)
        server = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        server.load_cert_chain(cert, key)
        listener = socket.create_server(("127.0.0.1", 0))
        self.addCleanup(listener.close)

        def answer():
            connection, _ = listener.accept()
            try:
                with server.wrap_socket(connection, server_side=True) as tls:
                    tls.recv(1)
            except (ssl.SSLError, OSError):
                connection.close()
        threading.Thread(target=answer, daemon=True).start()
        trusted = ssl.create_default_context(cafile=str(cert))
        return listener.getsockname()[1], trusted, cert

    def test_reads_the_not_after_of_a_certificate_for_the_ip(self):
        port, trusted, cert = self.serve("127.0.0.1")
        enddate = subprocess.run(["openssl", "x509", "-enddate", "-noout", "-in", str(cert)], check=True,
                                 capture_output=True, text=True).stdout.strip()
        expected = ssl.cert_time_to_seconds(enddate.removeprefix("notAfter="))
        self.assertEqual(proxy_check.certificate_expiry("127.0.0.1", port, trusted), expected)

    def test_a_certificate_for_another_ip_is_refused(self):
        port, trusted, _cert = self.serve("10.9.8.7")
        with self.assertRaises(ssl.SSLCertVerificationError):
            proxy_check.certificate_expiry("127.0.0.1", port, trusted)


if __name__ == "__main__":
    unittest.main()
