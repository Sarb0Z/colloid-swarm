"""The push runner.

Without `--apply` it runs each sink's `plan` through a read-only client, so a dry
run cannot write. With `--apply` it calls `push` and records the ids the sink
returns. A push outcome is its own stage in the ledger: a failure here never
changes a paper's fetch state, so it never causes a second download.
"""

from __future__ import annotations

import json
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

from .context import Context
from .ledger import FETCH, PUSH, Row, latest, read_rows
from .model import Paper
from .plugins import Plugin
from .polite import RunStopped

PUSHABLE_FETCH_STATES = ("fetched", "converted", "needs-text")


@dataclass(frozen=True)
class PushOptions:
    only: frozenset[str] | None
    force: bool
    apply: bool


@dataclass
class PushReport:
    counts: Counter[str] = field(default_factory=Counter)
    stopped: str | None = None


def skip_reason(fetch: Row | None, push: Row | None, force: bool) -> str | None:
    """Why a paper is not pushed, or None when it is. The transition table's push column."""
    if fetch is None or fetch.state not in PUSHABLE_FETCH_STATES:
        return f"fetch state is {fetch.state if fetch else 'pending'}, so there is nothing to push"
    if push is not None and push.state == "pushed" and not force:
        return "already pushed"
    return None


def run_push(papers: list[Paper], sink: Plugin, ctx: Context, options: PushOptions) -> PushReport:
    report = PushReport()
    states = latest(read_rows(ctx.layout.ledger))
    for paper in papers:
        if options.only is not None and paper.key not in options.only:
            continue
        reason = skip_reason(states.get((paper.key, FETCH)), states.get((paper.key, PUSH)), options.force)
        if reason is not None:
            ctx.say(f"= skip    {paper.key} ({reason})")
            report.counts["skipped"] += 1
            continue
        try:
            outcome = _apply(paper, sink, ctx) if options.apply else _plan(paper, sink, ctx)
        except RunStopped as error:
            report.stopped = str(error)
            ctx.say(f"! stopped: {error}")
            break
        report.counts[outcome] += 1
    return report


def _plan(paper: Paper, sink: Plugin, ctx: Context) -> str:
    folder = ctx.layout.paper_dir(paper.key)
    try:
        lines = sink.module.plan(paper, folder, ctx.http)
    except RunStopped:
        raise
    except Exception as error:  # a plugin boundary: reported here, and the next paper is planned
        ctx.say(f"! plan failed for {paper.key}: {error}")
        return "failed"
    for line in lines:
        ctx.say(f"~ {paper.key}: {line}")
    return "planned"


def _apply(paper: Paper, sink: Plugin, ctx: Context) -> str:
    assert ctx.ledger is not None
    folder = ctx.layout.paper_dir(paper.key)
    before = _listing(folder)
    try:
        ids = sink.module.push(paper, folder, ctx.http)
    except RunStopped:
        raise
    except Exception as error:  # a plugin boundary: recorded, and the next paper is pushed
        return _fail(paper, sink, ctx, f"sink {sink.name} raised {error!r}")
    changed = sorted(set(_listing(folder)) ^ set(before))
    if changed:
        return _fail(paper, sink, ctx, f"sink {sink.name} wrote in the paper folder: {', '.join(changed)}")
    if not isinstance(ids, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in ids.items()):
        return _fail(paper, sink, ctx, f"sink {sink.name} returned {ids!r}, not a dict of strings")
    ctx.ledger.append(
        key=paper.key, doi=paper.doi, stage=PUSH, state="pushed", source=sink.name,
        external_ids=json.dumps(ids, sort_keys=True),
    )
    ctx.say(f"+ pushed   {paper.key}  ({sink.name}: {json.dumps(ids, sort_keys=True)})")
    return "pushed"


def _fail(paper: Paper, sink: Plugin, ctx: Context, detail: str) -> str:
    assert ctx.ledger is not None
    ctx.ledger.append(key=paper.key, doi=paper.doi, stage=PUSH, state="failed", source=sink.name, detail=detail)
    ctx.say(f"! failed   {paper.key}: {detail}")
    return "failed"


def _listing(folder: Path) -> list[str]:
    return sorted(path.name for path in folder.iterdir()) if folder.is_dir() else []
