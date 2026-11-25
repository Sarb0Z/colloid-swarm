"""The outside world a command touches, passed in so a test can replace it."""

from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import dataclass


@dataclass(frozen=True)
class Effects:
    out: Callable[[str], None]
    err: Callable[[str], None]
    environ: Mapping[str, str]
    stamp: Callable[[], str]
