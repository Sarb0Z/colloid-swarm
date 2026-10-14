#!/usr/bin/env python3
"""The repository's output style, read one way by every consumer.

Usage:
  output_style.py body <style-path>
  output_style.py drift <style-path> <device-policy-json> <account-style-path>...

`body` prints the style's prose without its YAML frontmatter: the text the
device policy appends to the system prompt, Codex carries as developer
instructions, and `style-inject.sh` hands each subagent, which the host never
sends the output style.

`drift` prints one line per installed copy that says something other than this
repository's style, so a session elsewhere on the machine runs older rules. An
account copy passes when it links to the style or matches it byte for byte;
the device policy passes when its `appendSystemPrompt` equals the body. A copy
that is not installed prints nothing: installing one is the operator's choice.
A copy that cannot be read prints why, on its own line.
"""

import json
import os
import sys


def body(style_path):
    with open(style_path, encoding="utf-8") as handle:
        text = handle.read()
    if text.startswith("---\n"):
        text = text.split("\n---\n", 1)[1]
    return text.strip()


def account_state(copy, style_path):
    """Why one account copy is stale, or empty when it is current or absent."""
    if not os.path.lexists(copy):
        return ""
    if os.path.islink(copy) and not os.path.exists(copy):
        return f"{copy} links to {os.readlink(copy)}, which does not exist"
    if os.path.realpath(copy) == os.path.realpath(style_path):
        return ""
    with open(copy, encoding="utf-8") as installed, open(style_path, encoding="utf-8") as source:
        return "" if installed.read() == source.read() else f"{copy} differs from {style_path}"


def device_state(device_policy, style_path):
    """Why the device policy is stale, or empty when it is current or absent."""
    if not os.path.exists(device_policy):
        return ""
    with open(device_policy, encoding="utf-8") as handle:
        document = json.load(handle)
    appended = document.get("appendSystemPrompt") if isinstance(document, dict) else None
    if not isinstance(appended, str) or not appended.strip():
        return f"{device_policy} appends no output style"
    if appended.strip() != body(style_path):
        return f"{device_policy} appends text that differs from {style_path}"
    return ""


def drift(style_path, device_policy, account_copies):
    # Each copy is judged alone: one that cannot be read is named as such and
    # never hides another copy already found stale.
    checks = [(copy, account_state) for copy in account_copies] + [(device_policy, device_state)]
    stale = []
    for path, state in checks:
        try:
            reason = state(path, style_path)
        except (OSError, ValueError) as error:
            reason = f"{path} could not be read: {error}"
        if reason:
            stale.append(reason)
    return stale


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "body":
        print(body(sys.argv[2]))
        return 0
    if len(sys.argv) >= 4 and sys.argv[1] == "drift":
        for line in drift(sys.argv[2], sys.argv[3], sys.argv[4:]):
            print(line)
        return 0
    raise SystemExit(__doc__.split("\n\n")[1])


if __name__ == "__main__":
    sys.exit(main())
