#!/usr/bin/env python3
"""Fetch the papers a manifest lists and push them to a catalogue.

Usage:
    python3 -I scripts/paper-fetch/papers.py status  --manifest M --root P
    python3 -I scripts/paper-fetch/papers.py sources [--plugins DIR]
    python3 -I scripts/paper-fetch/papers.py fetch   --manifest M --root P [options]
    python3 -I scripts/paper-fetch/papers.py push    --manifest M --root P --sink NAME [--apply]

`scripts/paper-fetch/README.md` explains the options and the plugin contracts.
This file wires the real clock, network and commands into the package.
"""

from __future__ import annotations

import os
import sys
from datetime import UTC, datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
# `python3 -I` puts neither this folder nor the working directory on the path, so
# the package folder is named here by the file's own location.
sys.path.insert(0, str(HERE))

from paperfetch.cli import main  # noqa: E402
from paperfetch.effects import Effects  # noqa: E402


def real_effects() -> Effects:
    return Effects(
        out=print,
        err=lambda text: print(text, file=sys.stderr),
        environ=dict(os.environ),
        stamp=lambda: datetime.now(UTC).isoformat(timespec="seconds"),
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], real_effects(), HERE / "plugins"))
