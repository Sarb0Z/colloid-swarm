#!/usr/bin/env python3
"""Decide which subagents need a genome, and whether a dispatch carries one.

Usage: genome-guard.py <config-path>             # payload on stdin
       genome-guard.py <config-path> --exempt

The default reads {"prompt", "subagent_type"} and prints `allow`, `missing`, or
`double`. `--exempt` reads {"subagent_type"} alone and prints `yes` or `no`,
which is what the SubagentStart injector needs — it has a type but no prompt.

One module owns the exemption list, because two answers to "does this cell need
a personality" is one too many. A read-only utility type carries none: a genome
on a search that cannot write is noise. An unreadable payload prints `allow`,
because a guard must never block on its own blindness.
"""

import json
import sys

# genome.sh emits this as the first line of a stamp.
SENTINEL = "⊰ COLLOID GENOME · THE "
EXEMPT = ["explore", "plan", "claude-code-guide", "statusline-setup", "learning-reporter"]


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    settings = {}
    if len(sys.argv) > 1:
        try:
            with open(sys.argv[1], encoding="utf-8") as source:
                settings = json.load(source)
        except (OSError, ValueError):
            settings = {}
    if not isinstance(settings, dict):
        settings = {}

    # Coerce: a non-string prompt or type must fail open rather than crash.
    prompt = payload.get("prompt")
    prompt = prompt if isinstance(prompt, str) else ""
    kind = payload.get("subagent_type")
    kind = (kind if isinstance(kind, str) else "").strip().lower()

    exempt = set(settings.get("swarm", {}).get("exempt_subagent_types", EXEMPT))
    if "--exempt" in sys.argv[2:]:
        print("yes" if kind in exempt else "no")
        return 0
    if kind in exempt or not prompt.strip():
        print("allow")
        return 0
    stamps = sum(1 for line in prompt.splitlines() if line.startswith(SENTINEL))
    print("missing" if stamps == 0 else "double" if stamps > 1 else "allow")
    return 0


if __name__ == "__main__":
    sys.exit(main())
