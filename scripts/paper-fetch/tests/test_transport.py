"""The real urllib transport and the client, against a local server."""

from __future__ import annotations

import gzip
import unittest

from helpers import PDF, FakeClock, FakeServer, answer, drop_midway, make_effects, serve

from paperfetch.model import TooLarge, TransportError
from paperfetch.polite import Http, NetworkError, Policy
from paperfetch.transport import urllib_transport

SECOND = 30.0


class TransportTests(unittest.TestCase):
    def fetch(self, server: FakeServer, path: str, max_bytes: int = 1_000_000, method: str = "GET"):
        return urllib_transport(method, server.base + path, {}, None, SECOND, max_bytes)

    def test_returns_status_lowercase_headers_and_body(self) -> None:
        with FakeServer({"/p": serve(200, PDF, Content_Type="application/pdf")}) as server:
            raw = self.fetch(server, "/p")
        self.assertEqual(raw.status, 200)
        self.assertEqual(raw.body, PDF)
        self.assertEqual(raw.headers["content-type"], "application/pdf")

    def test_an_error_status_is_an_answer_not_an_exception(self) -> None:
        with FakeServer({}) as server:
            raw = self.fetch(server, "/absent")
        self.assertEqual((raw.status, raw.body), (404, b"not found"))

    def test_a_redirect_is_returned_for_the_client_to_follow(self) -> None:
        with FakeServer({"/a": serve(302, b"", Location="/b")}) as server:
            raw = self.fetch(server, "/a")
        self.assertEqual((raw.status, raw.headers["location"]), (302, "/b"))

    def test_a_connection_cut_off_mid_body_is_a_transport_error(self) -> None:
        with FakeServer({"/cut": drop_midway}) as server, self.assertRaises(TransportError):
            self.fetch(server, "/cut")

    def test_a_body_over_the_cap_is_too_large(self) -> None:
        with FakeServer({"/big": serve(200, b"x" * 5000)}) as server, self.assertRaises(TooLarge):
            self.fetch(server, "/big", max_bytes=1000)

    def test_a_gzip_body_is_decoded_and_a_bomb_is_refused(self) -> None:
        small = gzip.compress(b"hello paper")
        bomb = gzip.compress(b"\0" * 1_000_000)
        routes = {
            "/gz": serve(200, small, Content_Encoding="gzip"),
            "/bomb": serve(200, bomb, Content_Encoding="gzip"),
        }
        with FakeServer(routes) as server:
            self.assertEqual(self.fetch(server, "/gz").body, b"hello paper")
            with self.assertRaises(TooLarge):
                self.fetch(server, "/bomb", max_bytes=10_000)

    def test_an_unsupported_encoding_is_refused(self) -> None:
        with FakeServer({"/br": serve(200, b"zzz", Content_Encoding="br")}) as server:
            with self.assertRaises(TransportError):
                self.fetch(server, "/br")

    def test_a_refused_connection_is_a_transport_error(self) -> None:
        with self.assertRaises(TransportError):
            urllib_transport("GET", "http://127.0.0.1:9/", {}, None, 2.0, 1000)

    def test_a_file_address_never_reaches_urllib(self) -> None:
        with self.assertRaises(TransportError):
            urllib_transport("GET", "file:///etc/hosts", {}, None, 2.0, 1000)


class ClientAgainstServerTests(unittest.TestCase):
    """The client and the real transport together, with a fake clock."""

    def http(self, server: FakeServer, **options):
        said: list[str] = []
        clock = FakeClock()
        fx = make_effects([], [], clock=clock, transport=urllib_transport)
        policy = Policy(
            delay_ms=options.pop("delay_ms", 0),
            jitter_ms=0,
            max_per_host=options.pop("max_per_host", 25),
            host_intervals_ms={},
            **options,
        )
        return Http(fx, policy, said.append), said

    def test_a_redirect_across_paths_is_followed_and_each_hop_counts(self) -> None:
        routes = {"/old": serve(302, b"", Location="/new"), "/new": serve(200, PDF)}
        with FakeServer(routes) as server:
            http, said = self.http(server)
            response = http.get(server.base + "/old")
            self.assertEqual(server.requests, [("GET", "/old"), ("GET", "/new")])
        self.assertEqual((response.status, response.body), (200, PDF))
        self.assertEqual(response.url, server.base + "/new")
        self.assertEqual(len(said), 3)

    def test_a_429_then_200_from_a_real_server_waits_and_succeeds(self) -> None:
        answers = iter([429, 200])

        def limited(handler) -> None:
            status = next(answers)
            if status == 429:
                answer(handler, 429, b"slow down", Retry_After="2")
            else:
                answer(handler, 200, PDF)

        with FakeServer({"/p": limited}) as server:
            http, _ = self.http(server)
            response = http.get(server.base + "/p")
            self.assertEqual(response.status, 200)
            self.assertEqual(len(server.requests), 2)

    def test_a_connection_cut_mid_body_is_retried_then_reported(self) -> None:
        with FakeServer({"/cut": drop_midway}) as server:
            http, _ = self.http(server)
            with self.assertRaises(NetworkError):
                http.get(server.base + "/cut")
            self.assertEqual(len(server.requests), 4)  # the first try and three retries


if __name__ == "__main__":
    unittest.main()
