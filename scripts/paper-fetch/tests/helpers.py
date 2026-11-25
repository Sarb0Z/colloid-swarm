"""Shared fixtures for the paper-fetch tests."""

from __future__ import annotations

import csv
import itertools
import sys
import threading
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

TOOL = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOL))
# A test rewrites a plugin file within one second and at the same size, which
# lets Python reuse stale bytecode keyed by whole-second modification time.
sys.dont_write_bytecode = True

from paperfetch.cli import main
from paperfetch.effects import Effects
from paperfetch.model import RawResponse
from paperfetch.polite import Http, Policy


@dataclass
class Run:
    code: int
    out: list[str]
    err: list[str]


class FakeClock:
    """A clock that moves only when something sleeps."""

    def __init__(self) -> None:
        self.now = 1000.0
        self.sleeps: list[float] = []

    def clock(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds


def reply(status: int = 200, body: bytes = b"", **headers: str) -> RawResponse:
    return RawResponse(status, {name.replace("_", "-"): value for name, value in headers.items()}, body)


class ScriptedTransport:
    """Answers each call from a list; an exception in the list is raised."""

    def __init__(self, clock: FakeClock, script: list[RawResponse | Exception]) -> None:
        self._clock = clock
        self._script = list(script)
        self.calls: list[tuple[str, str, float]] = []  # method, url, clock when sent

    def __call__(self, method, url, headers, body, timeout, max_bytes) -> RawResponse:
        self.calls.append((method, url, self._clock.now))
        if not self._script:
            raise AssertionError(f"unexpected {method} {url}")
        item = self._script.pop(0)
        if isinstance(item, Exception):
            raise item
        return item


def unexpected_transport(method, url, headers, body, timeout, max_bytes) -> RawResponse:
    raise AssertionError(f"unexpected network call: {method} {url}")


def unexpected_runner(argv: list[str]) -> str:
    raise AssertionError(f"unexpected command: {argv}")


def make_stamp() -> Callable[[], str]:
    counter = itertools.count(1)
    return lambda: f"2026-11-25T00:00:{next(counter):02d}+00:00"


def make_effects(
    out: list[str],
    err: list[str],
    environ: dict[str, str] | None = None,
    clock: FakeClock | None = None,
    transport=unexpected_transport,
    run=unexpected_runner,
) -> Effects:
    clock = clock or FakeClock()
    return Effects(
        out=out.append,
        err=err.append,
        environ=environ or {},
        stamp=make_stamp(),
        clock=clock.clock,
        sleep=clock.sleep,
        rng=lambda: 0.5,
        transport=transport,
        run=run,
    )


def make_http(
    clock: FakeClock,
    transport,
    *,
    delay_ms: int = 1000,
    jitter_ms: int = 0,
    max_per_host: int = 25,
    host_intervals_ms: Mapping[str, int] | None = None,
    read_only: bool = False,
) -> tuple[Http, list[str]]:
    said: list[str] = []
    fx = make_effects([], [], clock=clock, transport=transport)
    policy = Policy(
        delay_ms=delay_ms,
        jitter_ms=jitter_ms,
        max_per_host=max_per_host,
        host_intervals_ms=host_intervals_ms or {},
        read_only=read_only,
    )
    return Http(fx, policy, said.append), said


def run_cli(
    argv: list[str],
    plugins: Path,
    environ: dict[str, str] | None = None,
    transport=unexpected_transport,
    run=unexpected_runner,
) -> Run:
    out: list[str] = []
    err: list[str] = []
    fx = make_effects(out, err, environ, transport=transport, run=run)
    return Run(main(argv, fx, plugins), out, err)


def write_manifest(folder: Path, rows: list[dict[str, str]]) -> Path:
    columns = list(rows[0]) if rows else ["key", "doi"]
    path = folder / "manifest.csv"
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    return path


def tree(folder: Path) -> list[str]:
    return sorted(str(path.relative_to(folder)) for path in folder.rglob("*"))


def write_plugin(folder: Path, kind: str, filename: str, body: str) -> Path:
    path = folder / kind / filename
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    return path


Route = Callable[[BaseHTTPRequestHandler], None]


@dataclass
class FakeServer:
    """A real local HTTP server whose routes are plain functions."""

    routes: dict[str, Route]
    requests: list[tuple[str, str]] = field(default_factory=list)

    def __enter__(self) -> FakeServer:
        server = self

        class Handler(BaseHTTPRequestHandler):
            def handle_any(self) -> None:
                path = self.path.split("?", 1)[0]
                server.requests.append((self.command, path))
                route = server.routes.get(path)
                if route is None:
                    answer(self, 404, b"not found")
                else:
                    route(self)

            do_GET = do_HEAD = do_POST = handle_any

            def log_message(self, format: str, *args) -> None:
                pass

        self._httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *exc) -> None:
        self._httpd.shutdown()
        self._httpd.server_close()
        self._thread.join(timeout=5)

    @property
    def base(self) -> str:
        return f"http://127.0.0.1:{self._httpd.server_address[1]}"

    @property
    def host(self) -> str:
        return "127.0.0.1"


def answer(handler: BaseHTTPRequestHandler, status: int, body: bytes = b"", **headers: str) -> None:
    handler.send_response(status)
    handler.send_header("Content-Length", str(len(body)))
    for name, value in headers.items():
        handler.send_header(name.replace("_", "-"), value)
    handler.end_headers()
    if handler.command != "HEAD":
        handler.wfile.write(body)


def serve(status: int, body: bytes = b"", **headers: str) -> Route:
    return lambda handler: answer(handler, status, body, **headers)


def drop_midway(handler: BaseHTTPRequestHandler) -> None:
    """Promise 1000 bytes, send 10, and close."""
    handler.send_response(200)
    handler.send_header("Content-Length", "1000")
    handler.end_headers()
    handler.wfile.write(b"x" * 10)
    handler.wfile.flush()
    handler.close_connection = True


PDF = b"%PDF-1.4\n" + b"fixture paper body\n" * 80
