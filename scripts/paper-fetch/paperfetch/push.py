"""The push runner.

Without `--apply` it runs each sink's `plan` through a read-only client, so a dry
run cannot write. With `--apply` it calls `push` and records the ids the sink
returns. A push outcome is its own stage in the ledger: a failure here never
changes a paper's fetch state, so it never causes a second download.

Once a sink's `push` returns, the remote write has happened. The tool then
records `pushed` even when the sink broke a rule (it wrote in the paper folder or
returned an id that is not a string), with a warning, because recording `failed`
would send the next run to write the same thing again.
"""

from __future__ import annotations

import json
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

from .context import Context
from .ledger import FETCH, PUSH, Row, latest, read_rows
from .manifest import select
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
    for paper in select(papers, options.only):
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
        except Exception as error:  # one paper's unexpected failure is reported; the next paper still runs
            outcome = _unexpected(paper, sink, ctx, error, options.apply)
        report.counts[outcome] += 1
    return report


def _plan(paper: Paper, sink: Plugin, ctx: Context) -> str:
    folder = ctx.layout.paper_dir(paper.key)
    try:
        lines = list(sink.module.plan(paper, folder, ctx.http))
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
    before = _snapshot(folder)
    try:
        ids = sink.module.push(paper, folder, ctx.http)
    except RunStopped:
        raise
    except Exception as error:  # a plugin boundary: recorded, and the next paper is pushed
        return _fail(paper, sink, ctx, f"sink {sink.name} raised {error!r}")
    if not isinstance(ids, dict):
        return _fail(paper, sink, ctx, f"sink {sink.name} returned {ids!r}, not a dict of ids")
    warnings = []
    if any(not isinstance(key, str) or not isinstance(value, str) for key, value in ids.items()):
        warnings.append("ids were not all strings and were stored as text")
    after = _snapshot(folder)
    changed = sorted(name for name in set(after) | set(before) if after.get(name) != before.get(name))
    if changed:
        warnings.append(f"sink wrote in the paper folder: {', '.join(changed)}")
    stored = {str(key): str(value) for key, value in ids.items()}
    ctx.ledger.append(
        key=paper.key, doi=paper.doi, stage=PUSH, state="pushed", source=sink.name,
        external_ids=json.dumps(stored, sort_keys=True), detail="WARNING: " + "; ".join(warnings) if warnings else "",
    )
    ctx.say(f"+ pushed   {paper.key}  ({sink.name}: {json.dumps(stored, sort_keys=True)})")
    for warning in warnings:
        ctx.say(f"! warning  {paper.key}: {warning}")
    return "pushed"


def _unexpected(paper: Paper, sink: Plugin, ctx: Context, error: Exception, apply: bool) -> str:
    detail = f"unexpected {type(error).__name__}: {error}"
    if apply:
        return _fail(paper, sink, ctx, detail)
    ctx.say(f"! plan failed for {paper.key}: {detail}")
    return "failed"


def _fail(paper: Paper, sink: Plugin, ctx: Context, detail: str) -> str:
    assert ctx.ledger is not None
    ctx.ledger.append(key=paper.key, doi=paper.doi, stage=PUSH, state="failed", source=sink.name, detail=detail)
    ctx.say(f"! failed   {paper.key}: {detail}")
    return "failed"


def _snapshot(folder: Path) -> dict[str, tuple[int, int]]:
    """Each file's name with its size and modification time, so a rewrite shows."""
    if not folder.is_dir():
        return {}
    return {path.name: (path.stat().st_size, path.stat().st_mtime_ns) for path in folder.iterdir()}
