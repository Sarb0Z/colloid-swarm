#!/usr/bin/env python3
"""Decide which subagents carry no genome.

Usage: genome-exempt.py <config-path>    # {"subagent_type": "..."} on stdin

Prints `yes` when the type is exempt and `no` otherwise. A read-only utility
type is exempt: a genome on a search that cannot write is noise.

An unreadable payload prints `no`, so the injector stamps. The default is not
the guard's "fail open" reasoning inverted by accident — a stamp on a cell that
did not need one costs a few hundred tokens, and a missing stamp costs the
treatment the layer exists to apply.
"""

import json
import sys

EXEMPT = ["explore", "plan", "claude-code-guide", "statusline-setup", "learning-reporter"]
TYPE_ALIASES = {"explorer": "explore"}


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    # config.py owns the policy.json/config.json layering; read through it so
    # a tracked exemption list is honoured the same as an operator's.
    settings = {}
    if len(sys.argv) > 1:
        import importlib.util
        import os
        spec = importlib.util.spec_from_file_location(
            "colloid_config", os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        settings = module.load(sys.argv[1])

    # Coerce: a non-string type must stamp rather than crash.
    kind = payload.get("subagent_type")
    kind = (kind if isinstance(kind, str) else "").strip().lower()
    kind = TYPE_ALIASES.get(kind, kind)

    exempt = set(settings.get("swarm", {}).get("exempt_subagent_types", EXEMPT))
    print("yes" if kind in exempt else "no")
    return 0


if __name__ == "__main__":
    sys.exit(main())
