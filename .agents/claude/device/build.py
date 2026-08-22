#!/usr/bin/env python3
"""Build the device policy payload from the repository's own sources.

The payload is generated, never checked in, so the device tier cannot drift
from the rule list the repository tests. `permissions.ask` comes from
`.agents/claude/settings.json`, which `test-guard-publish.py` already holds to
the guard's plain forms in both directions.

Usage: build.py <output-directory>
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SETTINGS = os.path.join(HERE, "..", "settings.json")
PROSE = os.path.join(HERE, "counter-pressure.md")

# The only keys Claude Code accepts from a policy helper's stdout.
ENVELOPE_KEYS = {"managedSettings", "claudeMd", "appendSystemPrompt"}


def payload():
    with open(PROSE, encoding="utf-8") as handle:
        prose = handle.read().strip()
    with open(SETTINGS, encoding="utf-8") as handle:
        ask = json.load(handle)["permissions"]["ask"]
    if not prose:
        raise SystemExit("build: counter-pressure.md is empty")
    if "Artifact" not in ask:
        raise SystemExit("build: settings.json permissions.ask does not gate Artifact")
    return {"appendSystemPrompt": prose,
            "managedSettings": {"permissions": {"ask": ask}}}


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: build.py <output-directory>")
    target = sys.argv[1]
    document = payload()
    assert set(document) <= ENVELOPE_KEYS
    os.makedirs(target, exist_ok=True)
    with open(os.path.join(target, "policy.json"), "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2)
        handle.write("\n")
    print(f"build: {len(document['appendSystemPrompt'])} chars appended, "
          f"{len(document['managedSettings']['permissions']['ask'])} ask rules")


if __name__ == "__main__":
    main()
