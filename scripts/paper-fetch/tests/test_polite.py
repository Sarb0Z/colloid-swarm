from __future__ import annotations

import unittest

from helpers import FakeClock, ScriptedTransport, make_http, reply

from paperfetch.model import PermanentTransportError, TransportError
from paperfetch.polite import (
    DryRunWrite,
    HostCapReached,
    HostPaused,
    NetworkError,
    RefusedAddress,
    TooManyRedirects,
)

A = "https://a.example.org/paper"
B = "https://b.example.org/paper"


class PacingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.clock = FakeClock()

    def http(self, script, **options):
        transport = ScriptedTransport(self.clock, script)
        http, said = make_http(self.clock, transport, **options)
        return http, transport, said

    def test_two_requests_to_one_host_are_a_base_delay_apart_and_other_hosts_do_not_wait(self) -> None:
        http, transport, _ = self.http([reply(), reply(), reply()], delay_ms=1500)
        http.get(A)
        http.get(A)
        http.get(B)
        first, second, third = (sent for _, _, sent in transport.calls)
        self.assertGreaterEqual(second - first, 1.5)
        self.assertEqual(third, second)  # a different host has its own clock

    def test_a_plugin_interval_raises_the_floor_for_its_host_only(self) -> None:
        http, transport, _ = self.http(
            [reply(), reply(), reply(), reply()], delay_ms=1000, host_intervals_ms={"a.example.org": 3000}
        )
        http.get(A)
        http.get(A)
        http.get(B)
        http.get(B)
        a1, a2, b1, b2 = (sent for _, _, sent in transport.calls)
        self.assertGreaterEqual(a2 - a1, 3.0)
        self.assertGreaterEqual(b2 - b1, 1.0)
        self.assertLess(b2 - b1, 3.0)

    def test_jitter_is_added_to_the_delay(self) -> None:
        http, transport, _ = self.http([reply(), reply()], delay_ms=1000, jitter_ms=1000)
        http.get(A)
        http.get(A)
        (_, _, first), (_, _, second) = transport.calls
        self.assertAlmostEqual(second - first, 1.5)  # the fake rng returns 0.5

    def test_the_request_after_the_cap_stops_the_run_and_names_the_cap(self) -> None:
        http, transport, _ = self.http([reply()] * 25 + [reply()], max_per_host=25, delay_ms=0)
        for _ in range(25):
            http.get(A)
        with self.assertRaises(HostCapReached) as caught:
            http.get(A)
        self.assertIn("25", str(caught.exception))
        self.assertIn("a.example.org", str(caught.exception))
        self.assertEqual(len(transport.calls), 25)
        http.get(B)  # another host still has its whole budget

    def test_every_address_is_printed(self) -> None:
        http, _, said = self.http([reply(), reply()])
        http.get(A)
        http.get(B)
        self.assertEqual(said, [f"  GET {A}", f"  GET {B}"])


class RetryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.clock = FakeClock()

    def http(self, script, **options):
        transport = ScriptedTransport(self.clock, script)
        http, said = make_http(self.clock, transport, delay_ms=0, **options)
        return http, transport, said

    def test_429_waits_the_stated_retry_after_then_succeeds(self) -> None:
        http, transport, _ = self.http([reply(429, retry_after="2"), reply(200, b"ok")])
        response = http.get(A)
        self.assertEqual(response.status, 200)
        self.assertEqual(len(transport.calls), 2)
        self.assertGreaterEqual(transport.calls[1][2] - transport.calls[0][2], 2.0)

    def test_backoff_header_pauses_every_later_request_to_that_host(self) -> None:
        http, transport, _ = self.http([reply(200, backoff="3"), reply(200)])
        http.get(A)
        http.get(A)
        self.assertGreaterEqual(transport.calls[1][2] - transport.calls[0][2], 3.0)

    def test_a_retry_after_longer_than_the_wait_limit_stops_the_run(self) -> None:
        http, transport, _ = self.http([reply(429, retry_after="7200")])
        with self.assertRaises(HostPaused) as caught:
            http.get(A)
        self.assertIn("7200", str(caught.exception))
        self.assertEqual(len(transport.calls), 1)

    def test_a_long_backoff_on_a_good_response_still_delivers_it_and_stops_the_next_request(self) -> None:
        http, transport, _ = self.http([reply(200, b"stored", backoff="7200"), reply(200)])
        response = http.get(A)  # a response already received reaches its caller
        self.assertEqual((response.status, response.body), (200, b"stored"))
        with self.assertRaises(HostPaused) as caught:
            http.get(A)
        self.assertIn("7200", str(caught.exception))
        self.assertEqual(len(transport.calls), 1)

    def test_a_failure_that_will_recur_is_not_retried(self) -> None:
        http, transport, _ = self.http([PermanentTransportError("content encoding 'br' is not supported"), reply(200)])
        with self.assertRaises(NetworkError) as caught:
            http.get(A)
        self.assertIn("'br'", str(caught.exception))
        self.assertEqual(len(transport.calls), 1)

    def test_a_503_is_retried_with_growing_waits_and_then_returned(self) -> None:
        http, transport, _ = self.http([reply(503)] * 4)
        response = http.get(A)
        self.assertEqual(response.status, 503)
        self.assertEqual(len(transport.calls), 4)  # the first try and three retries
        waits = self.clock.sleeps
        self.assertEqual(len(waits), 3)
        self.assertEqual(waits, sorted(waits))
        self.assertGreaterEqual(waits[0], 2.0)

    def test_get_retries_a_network_error(self) -> None:
        http, transport, _ = self.http([TransportError("reset"), reply(200, b"ok")])
        self.assertEqual(http.get(A).status, 200)
        self.assertEqual(len(transport.calls), 2)

    def test_get_gives_up_after_the_retries_and_says_what_failed(self) -> None:
        http, transport, _ = self.http([TransportError("reset")] * 4)
        with self.assertRaises(NetworkError) as caught:
            http.get(A)
        self.assertIn("reset", str(caught.exception))
        self.assertEqual(len(transport.calls), 4)

    def test_a_post_is_not_retried_on_a_network_error(self) -> None:
        http, transport, _ = self.http([TransportError("reset"), reply(200)])
        with self.assertRaises(NetworkError):
            http.request("POST", A, body=b"{}")
        self.assertEqual(len(transport.calls), 1)

    def test_a_post_answered_429_is_retried_because_the_server_did_not_process_it(self) -> None:
        http, transport, _ = self.http([reply(429, retry_after="1"), reply(200)])
        self.assertEqual(http.request("POST", A, body=b"{}").status, 200)
        self.assertEqual(len(transport.calls), 2)

    def test_a_post_answered_503_is_not_retried(self) -> None:
        http, transport, _ = self.http([reply(503), reply(200)])
        self.assertEqual(http.request("POST", A, body=b"{}").status, 503)
        self.assertEqual(len(transport.calls), 1)

    def test_a_caller_may_mark_a_post_idempotent_to_retry_a_network_error(self) -> None:
        http, transport, _ = self.http([TransportError("reset"), reply(200)])
        self.assertEqual(http.request("POST", A, body=b"{}", idempotent=True).status, 200)
        self.assertEqual(len(transport.calls), 2)

    def test_retries_count_against_the_host_cap(self) -> None:
        http, transport, _ = self.http([reply(503)] * 4, max_per_host=2)
        with self.assertRaises(HostCapReached):
            http.get(A)
        self.assertEqual(len(transport.calls), 2)


class RedirectTests(unittest.TestCase):
    def setUp(self) -> None:
        self.clock = FakeClock()

    def http(self, script, **options):
        transport = ScriptedTransport(self.clock, script)
        http, said = make_http(self.clock, transport, delay_ms=0, **options)
        return http, transport, said

    def test_each_hop_is_followed_printed_and_counted_against_its_own_host(self) -> None:
        http, transport, said = self.http(
            [reply(302, location=B), reply(302, location="/final"), reply(200, b"done")], max_per_host=1
        )
        with self.assertRaises(HostCapReached):  # A once, B once, then B again exceeds a cap of 1
            http.get(A)
        self.assertEqual([url for _, url, _ in transport.calls], [A, B])
        self.assertIn(f"  -> redirected to {B}", said)

    def test_a_redirect_chain_returns_the_final_address_and_body(self) -> None:
        http, _, said = self.http([reply(301, location=B), reply(200, b"paper")])
        response = http.get(A)
        self.assertEqual((response.status, response.body, response.url), (200, b"paper", B))
        self.assertEqual(said, [f"  GET {A}", f"  -> redirected to {B}", f"  GET {B}"])

    def test_a_relative_location_resolves_against_the_current_address(self) -> None:
        http, transport, _ = self.http([reply(302, location="/other"), reply(200)])
        http.get(A)
        self.assertEqual(transport.calls[1][1], "https://a.example.org/other")

    def test_a_redirect_to_a_file_address_is_refused(self) -> None:
        http, transport, _ = self.http([reply(302, location="file:///etc/hosts")])
        with self.assertRaises(RefusedAddress):
            http.get(A)
        self.assertEqual(len(transport.calls), 1)

    def test_a_loop_of_redirects_ends(self) -> None:
        http, _, _ = self.http([reply(302, location=A)] * 10)
        with self.assertRaises(TooManyRedirects):
            http.get(A)

    def test_a_post_redirect_is_returned_not_followed(self) -> None:
        http, transport, _ = self.http([reply(302, location=B)])
        self.assertEqual(http.request("POST", A, body=b"{}").status, 302)
        self.assertEqual(len(transport.calls), 1)


class RefusalTests(unittest.TestCase):
    def setUp(self) -> None:
        self.clock = FakeClock()

    def test_only_http_and_https_addresses_are_allowed(self) -> None:
        transport = ScriptedTransport(self.clock, [])
        http, _ = make_http(self.clock, transport)
        for address in ("file:///etc/hosts", "ftp://x.example.org/a", "gopher://x/a", "no-scheme", "http://[bad"):
            with self.subTest(address=address), self.assertRaises(RefusedAddress):
                http.get(address)
        self.assertEqual(transport.calls, [])

    def test_a_read_only_client_refuses_a_write_before_it_reaches_the_network(self) -> None:
        transport = ScriptedTransport(self.clock, [reply(200), reply(200)])
        http, _ = make_http(self.clock, transport, read_only=True)
        for method in ("POST", "PUT", "PATCH", "DELETE"):
            with self.subTest(method=method), self.assertRaises(DryRunWrite):
                http.request(method, A, body=b"x")
        self.assertEqual(transport.calls, [])
        self.assertEqual(http.get(A).status, 200)
        self.assertEqual(http.request("HEAD", A).status, 200)


if __name__ == "__main__":
    unittest.main()
