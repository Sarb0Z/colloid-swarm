"""Turn a saved file into the `fulltext.md` the project's quote checker reads."""

from __future__ import annotations

import hashlib
from pathlib import Path

from .context import Context
from .ledger import FETCH
from .layout import write_atomic
from .model import NoText, Paper, WrongPaper
from .plugins import Plugin


def pick_converter(converters: list[Plugin], kind: str) -> Plugin | None:
    for plugin in converters:  # already in name order
        if kind in plugin.module.ACCEPTS:
            return plugin
    return None


def convert_saved(paper: Paper, original: Path, kind: str, ctx: Context) -> str:
    """Convert one saved file, record the outcome, and return its state name."""
    assert ctx.ledger is not None
    converter = pick_converter(ctx.converters, kind)
    if converter is None:
        ctx.say(f"  . no converter accepts {kind}; {paper.key} stays fetched")
        return "fetched"
    try:
        text = converter.module.convert(original, ctx.run)
    except NoText as error:
        return _record(paper, ctx, "needs-text", converter.name, str(error) or "no text layer")
    except WrongPaper as error:
        original.unlink(missing_ok=True)  # the copy this run saved; an inbox file is untouched
        return _record(paper, ctx, "failed", converter.name, f"identity: {error}")
    except Exception as error:  # a plugin boundary: reported here, and the run goes on
        return _record(paper, ctx, "failed", converter.name, f"converter {converter.name} raised {error!r}")
    if not isinstance(text, str) or not text.strip():
        return _record(paper, ctx, "needs-text", converter.name, "the converter returned no text")
    data = text.encode("utf-8")
    write_atomic(ctx.layout.fulltext(paper.key), data)
    ctx.ledger.append(
        key=paper.key,
        doi=paper.doi,
        stage=FETCH,
        state="converted",
        source=converter.name,
        sha256=hashlib.sha256(data).hexdigest(),
        size=len(data),
    )
    ctx.say(f"+ converted {paper.key}  ({len(data)} bytes of text, {converter.name})")
    return "converted"


def _record(paper: Paper, ctx: Context, state: str, source: str, detail: str) -> str:
    assert ctx.ledger is not None
    ctx.ledger.append(key=paper.key, doi=paper.doi, stage=FETCH, state=state, source=source, detail=detail)
    ctx.say(f"! {state:<9} {paper.key}: {detail}")
    return state
