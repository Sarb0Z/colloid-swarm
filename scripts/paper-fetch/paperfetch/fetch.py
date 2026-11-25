"""The fetch runner.

For each paper: use a file saved by hand, else the inbox, else ask each source for
addresses and download the first good one; save it atomically; convert it. Every
outcome is one ledger row. A run that must stop (a host cap, a long server pause)
leaves the papers it did not reach exactly as they were.
"""

from __future__ import annotations

import hashlib
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

from .acquire import Downloaded, download_first_good, judge
from .context import Context
from .convert import convert_saved
from .layout import CHECKER_NAMES, write_atomic
from .ledger import FETCH, Row, latest, read_rows, tool_hashes
from .model import KINDS, Candidate, Paper
from .polite import Response, RunStopped

SKIP, CONVERT, FULL = "skip", "convert", "full"
INBOX_TEXT_SUFFIXES = (".md", ".txt")


@dataclass(frozen=True)
class FetchOptions:
    only: frozenset[str] | None
    limit: int  # papers that may reach a source this run; 0 means no limit
    force: bool


@dataclass
class Report:
    counts: Counter[str] = field(default_factory=Counter)
    attempted: int = 0
    stopped: str | None = None


def decide(current: Row | None, force: bool) -> str:
    """The transition table: what `fetch` does with a paper in its current state."""
    if current is None or current.state in ("awaiting-inbox", "blocked", "failed"):
        return FULL
    if current.state == "fetched":
        return FULL if force else CONVERT
    return FULL if force else SKIP  # converted, needs-text


def run_fetch(papers: list[Paper], ctx: Context, options: FetchOptions) -> Report:
    report = Report()
    rows = read_rows(ctx.layout.ledger)
    states = latest(rows)
    for paper in papers:
        if options.only is not None and paper.key not in options.only:
            continue
        try:
            outcome = _handle(paper, ctx, rows, states.get((paper.key, FETCH)), options, report)
        except RunStopped as error:
            report.stopped = str(error)
            ctx.say(f"! stopped: {error}")
            break
        if outcome == "over-limit":
            ctx.say(f"  limit of {options.limit} reached; run again for the rest")
            break
        report.counts[outcome] += 1
    return report


def _handle(
    paper: Paper, ctx: Context, rows: list[Row], current: Row | None, options: FetchOptions, report: Report
) -> str:
    hand = find_hand(paper.key, ctx, rows)
    if hand is not None:
        return _record_hand(paper, hand, current, ctx)
    action = decide(current, options.force)
    if action == SKIP:
        ctx.say(f"= skip    {paper.key} ({current.state if current else 'pending'})")
        return "skipped"
    if action == CONVERT:
        return _convert_existing(paper, ctx)
    if options.limit and report.attempted >= options.limit:
        return "over-limit"
    report.attempted += 1
    return _full_attempt(paper, ctx)


def find_hand(key: str, ctx: Context, rows: list[Row]) -> Path | None:
    """A checker file in the paper's folder that this tool did not write."""
    ours = tool_hashes(rows, key)
    for name in CHECKER_NAMES:
        path = ctx.layout.paper_dir(key) / name
        if path.is_file() and _sha256(path.read_bytes()) not in ours:
            return path
    return None


def _record_hand(paper: Paper, path: Path, current: Row | None, ctx: Context) -> str:
    assert ctx.ledger is not None
    data = path.read_bytes()
    digest = _sha256(data)
    if current is not None and current.source == "hand" and current.sha256 == digest:
        ctx.say(f"= skip    {paper.key} (hand-supplied {path.name})")
        return "skipped"
    ctx.ledger.append(
        key=paper.key,
        doi=paper.doi,
        stage=FETCH,
        state="converted",
        source="hand",
        sha256=digest,
        size=len(data),
        detail=f"{path.name} was saved by hand and is left as it is",
    )
    ctx.say(f"= hand    {paper.key} ({path.name} left as it is)")
    return "hand"


def _full_attempt(paper: Paper, ctx: Context) -> str:
    for inbox in ctx.layout.inbox_paths(paper):
        if inbox.is_file():
            return _from_inbox(paper, inbox, ctx)
    candidates, notes = locate(paper, ctx)
    if not candidates:
        if notes:
            return _fail(paper, ctx, "failed", "; ".join(notes))
        expected = ", ".join(str(p.relative_to(ctx.layout.root)) for p in ctx.layout.inbox_paths(paper))
        return _fail(paper, ctx, "awaiting-inbox", f"no source offered a file; expected {expected}")
    attempt = download_first_good(candidates, ctx.http, ctx.say)
    if attempt.downloaded is None:
        state = "blocked" if attempt.blocked else "failed"
        return _fail(paper, ctx, state, "; ".join(attempt.problems + notes))
    return _save_and_convert(paper, attempt.downloaded, ctx)


def locate(paper: Paper, ctx: Context) -> tuple[list[Candidate], list[str]]:
    found: list[Candidate] = []
    notes: list[str] = []
    seen: set[str] = set()
    for plugin in ctx.sources:
        try:
            offered = plugin.module.locate(paper, ctx.http)
        except RunStopped:
            raise
        except Exception as error:  # a plugin boundary: reported here, and the next source runs
            note = f"source {plugin.name} raised {error!r}"
            ctx.say(f"  ! {note}")
            notes.append(note)
            continue
        for item in offered or []:
            if not isinstance(item, Candidate) or item.kind not in KINDS:
                notes.append(f"source {plugin.name} returned {item!r}, not a Candidate of kind {KINDS}")
            elif item.url not in seen:
                seen.add(item.url)
                found.append(item)
    return found, notes


def _from_inbox(paper: Paper, path: Path, ctx: Context) -> str:
    assert ctx.ledger is not None
    suffix = path.suffix.lower()
    data = path.read_bytes()
    if suffix == ".pdf":
        verdict = judge("pdf", Response(200, {}, data, str(path)))
        if verdict.problem is not None:
            return _fail(paper, ctx, "failed", f"inbox file {path} left in place: {verdict.problem}")
        saved = _save_original(paper, ctx, "pdf", data, "inbox", str(path))
        return convert_saved(paper, saved, "pdf", ctx)
    if suffix in INBOX_TEXT_SUFFIXES:
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError as error:
            return _fail(paper, ctx, "failed", f"inbox file {path} left in place: not UTF-8 ({error})")
        if not text.strip():
            return _fail(paper, ctx, "failed", f"inbox file {path} left in place: it is empty")
        write_atomic(ctx.layout.fulltext(paper.key), data)
        ctx.ledger.append(
            key=paper.key, doi=paper.doi, stage=FETCH, state="converted", source="inbox",
            url=str(path), sha256=_sha256(data), size=len(data),
        )
        ctx.say(f"+ converted {paper.key}  (text copied from the inbox)")
        return "converted"
    return _fail(paper, ctx, "failed", f"inbox file {path} left in place: only .pdf, .md and .txt are read")


def _save_and_convert(paper: Paper, downloaded: Downloaded, ctx: Context) -> str:
    candidate = downloaded.candidate
    saved = _save_original(
        paper, ctx, candidate.kind, downloaded.response.body, candidate.source, candidate.url
    )
    return convert_saved(paper, saved, candidate.kind, ctx)


def _save_original(
    paper: Paper, ctx: Context, kind: str, data: bytes, source: str, url: str
) -> Path:
    assert ctx.ledger is not None
    path = ctx.layout.original(paper.key, kind)
    write_atomic(path, data)
    for other in ctx.layout.originals(paper.key):
        if other != path:
            other.unlink()  # an earlier copy of another kind; this run wrote it
    ctx.ledger.append(
        key=paper.key, doi=paper.doi, stage=FETCH, state="fetched", source=source,
        url=url, sha256=_sha256(data), size=len(data),
    )
    ctx.say(f"+ fetched  {paper.key}  ({len(data)} bytes, {source})")
    return path


def _convert_existing(paper: Paper, ctx: Context) -> str:
    originals = ctx.layout.originals(paper.key)
    if not originals:  # the ledger says fetched but the file is gone
        return _full_attempt(paper, ctx)
    return convert_saved(paper, originals[0], originals[0].suffix.lstrip("."), ctx)


def _fail(paper: Paper, ctx: Context, state: str, detail: str) -> str:
    assert ctx.ledger is not None
    ctx.ledger.append(key=paper.key, doi=paper.doi, stage=FETCH, state=state, detail=detail)
    ctx.say(f"! {state:<9} {paper.key}: {detail}")
    return state


def preview(papers: list[Paper], ctx: Context, options: FetchOptions) -> None:
    """A dry run: ask each source, print what it offers, write nothing."""
    states = latest(read_rows(ctx.layout.ledger))
    for paper in papers:
        if options.only is not None and paper.key not in options.only:
            continue
        current = states.get((paper.key, FETCH))
        action = decide(current, options.force)
        ctx.say(f"{paper.key}: {current.state if current else 'pending'} -> {action}")
        if action != FULL:
            continue
        for inbox in ctx.layout.inbox_paths(paper):
            if inbox.is_file():
                ctx.say(f"  inbox file present: {inbox}")
        candidates, notes = locate(paper, ctx)
        for candidate in candidates:
            ctx.say(f"  candidate {candidate.kind:<4} {candidate.source}: {candidate.url}")
        if not candidates:
            ctx.say("  no source offered a file" + (f" ({'; '.join(notes)})" if notes else ""))


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()
