"""Download a candidate and decide whether what came back is the file asked for.

A server that blocks a client rarely says so. It answers 200 with a short page
that reads "Just a moment", or serves a login page where the PDF should be. A
body is accepted only when it has the shape of the kind the source promised.
"""

from __future__ import annotations

import re
from collections.abc import Callable
from dataclasses import dataclass
from urllib.parse import urlsplit

from .model import Candidate, TooLarge
from .polite import Http, PoliteError, Response, RunStopped

BLOCK_STATUSES = (401, 403, 429)
# Smaller than this is not a paper, whatever its first bytes say.
MIN_BYTES = 1024
# An interstitial carries its marker near the top and is small as a whole; a
# long page that happens to quote one of these phrases is a real page.
CHALLENGE_SCAN_BYTES = 4096
CHALLENGE_MAX_BYTES = 100_000
# These mirror the patterns in research-mcp's `src/core/challenge.ts`, which
# came from live boards. Keep the two lists alike when either changes.
CHALLENGE_PATTERNS = tuple(
    re.compile(pattern, re.IGNORECASE)
    for pattern in (
        r"just a moment",
        r"performing security verification",
        r"checking your browser before",
        r"verify you are (a |not a )?human",
        r"enable javascript and cookies to continue",
        r"attention required.*cloudflare",
        r"\bcf-ray\b",
        r"please complete the security check",
        r"\bddos protection by\b",
    )
)


@dataclass(frozen=True)
class Verdict:
    problem: str | None  # None means the body is acceptable
    blocked: bool = False  # the host refused us, as opposed to the file being wrong


GOOD = Verdict(None)


@dataclass(frozen=True)
class Downloaded:
    candidate: Candidate
    response: Response


@dataclass(frozen=True)
class Attempt:
    downloaded: Downloaded | None
    problems: list[str]
    blocked: bool


def looks_like_challenge(body: bytes) -> bool:
    if len(body) > CHALLENGE_MAX_BYTES:
        return False
    head = body[:CHALLENGE_SCAN_BYTES].decode("utf-8", errors="replace")
    return any(pattern.search(head) for pattern in CHALLENGE_PATTERNS)


def judge(kind: str, response: Response) -> Verdict:
    if response.status in BLOCK_STATUSES:
        return Verdict(f"HTTP {response.status}", blocked=True)
    if response.status != 200:
        return Verdict(f"HTTP {response.status}")
    body = response.body
    if kind == "pdf" and not body.startswith(b"%PDF-"):
        if looks_like_challenge(body):
            return Verdict("a challenge page, not a PDF", blocked=True)
        return Verdict(f"not a PDF: it starts with {body[:12]!r}")
    if kind != "pdf" and looks_like_challenge(body):
        return Verdict("a challenge page", blocked=True)
    if len(body) < MIN_BYTES:
        return Verdict(f"{len(body)} bytes is too small to be a paper")
    if kind == "xml" and not body.lstrip().startswith(b"<"):
        return Verdict("not XML")
    return GOOD


def download_first_good(
    candidates: list[Candidate], http: Http, say: Callable[[str], None]
) -> Attempt:
    problems: list[str] = []
    blocked = False
    for candidate in candidates:
        host = urlsplit(candidate.url).hostname or candidate.url
        try:
            response = http.get(candidate.url)
        except RunStopped:
            raise
        except (PoliteError, TooLarge) as error:
            problems.append(f"{candidate.source} {host}: {error}")
            say(f"  ! {candidate.source}: {error}")
            continue
        verdict = judge(candidate.kind, response)
        if verdict.problem is None:
            return Attempt(Downloaded(candidate, response), problems, blocked)
        blocked = blocked or verdict.blocked
        problems.append(f"{candidate.source} {host}: {verdict.problem}")
        say(f"  ! {candidate.source}: {verdict.problem}")
    return Attempt(None, problems, blocked)
