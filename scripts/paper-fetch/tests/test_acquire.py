from __future__ import annotations

import unittest

from helpers import PDF

from paperfetch.acquire import judge, looks_like_challenge
from paperfetch.polite import Response

CHALLENGE = b"<html><head><title>Just a moment...</title></head><body>cf-ray 8a1</body></html>"


def answer(status: int, body: bytes) -> Response:
    return Response(status, {}, body, "https://x.example.org/p")


class JudgeTests(unittest.TestCase):
    def test_a_real_pdf_passes(self) -> None:
        self.assertIsNone(judge("pdf", answer(200, PDF)).problem)

    def test_a_challenge_page_where_a_pdf_belongs_is_blocked_not_failed(self) -> None:
        verdict = judge("pdf", answer(200, CHALLENGE))
        self.assertTrue(verdict.blocked)
        self.assertIn("challenge", verdict.problem or "")

    def test_access_statuses_are_blocked_and_other_statuses_are_failed(self) -> None:
        for status in (401, 403, 429):
            with self.subTest(status=status):
                self.assertTrue(judge("pdf", answer(status, b"")).blocked)
        for status in (404, 410, 500):
            with self.subTest(status=status):
                verdict = judge("pdf", answer(status, b""))
                self.assertFalse(verdict.blocked)
                self.assertEqual(verdict.problem, f"HTTP {status}")

    def test_html_that_is_not_a_challenge_is_a_failure_that_shows_what_arrived(self) -> None:
        verdict = judge("pdf", answer(200, b"<html>Sign in to read this article</html>" * 40))
        self.assertFalse(verdict.blocked)
        self.assertIn("not a PDF", verdict.problem or "")

    def test_a_pdf_header_on_a_tiny_body_is_too_small(self) -> None:
        verdict = judge("pdf", answer(200, b"%PDF-1.4\n%%EOF"))
        self.assertIn("too small", verdict.problem or "")

    def test_xml_must_look_like_xml_and_a_challenge_in_html_is_blocked(self) -> None:
        self.assertIsNone(judge("xml", answer(200, b"<?xml version='1.0'?><article>" + b"x" * 2000)).problem)
        self.assertEqual(judge("xml", answer(200, b"plain text " * 200)).problem, "not XML")
        self.assertTrue(judge("html", answer(200, CHALLENGE)).blocked)


class ChallengeTests(unittest.TestCase):
    def test_only_a_short_page_with_a_marker_near_the_top_counts(self) -> None:
        self.assertTrue(looks_like_challenge(CHALLENGE))
        long_article = b"<html><body>" + b"Just a moment of silence. " + b"word " * 40000 + b"</body></html>"
        self.assertFalse(looks_like_challenge(long_article))
        late_marker = b"x" * 5000 + b"Just a moment"
        self.assertFalse(looks_like_challenge(late_marker))


if __name__ == "__main__":
    unittest.main()
