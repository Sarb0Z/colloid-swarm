"""What a runner needs for one command, gathered once."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

from .layout import Layout
from .ledger import Ledger
from .model import Runner
from .plugins import Plugin
from .polite import Http


@dataclass(frozen=True)
class Context:
    layout: Layout
    http: Http
    ledger: Ledger | None  # None in a dry run, which writes nothing
    run: Runner
    say: Callable[[str], None]
    sources: list[Plugin]
    converters: list[Plugin]
