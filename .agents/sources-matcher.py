#!/usr/bin/env python3
"""Build every host's sources-capture hook matcher from the MCP registry.

The matcher decides which tool calls reach the provenance ledger, and it has to
say the same thing in three host files. Hand-writing it lets one server's two
reachable forms disagree — `mcp__exa__x` and `mcp__plugin_exa_exa__x` are one
tool needing two alternations — and a research tool the matcher misses produces
sources the ledger never records, silently.

Two rules make that disagreement impossible:

  - A named tool is matched under any server: `mcp__[A-Za-z0-9_-]+__<tool>`.
    One tool reachable as `mcp__exa__x` and `mcp__plugin_exa_exa__x` needs one
    alternation, not two, so the two forms cannot disagree. It also widens
    capture correctly — a page navigation is a source whichever server drove it.
  - A server declaring `"sources": ["*"]` exposes no distinctive tool name, so
    it is named directly, in both its registry and plugin forms.

Host-native web tools are not in the registry and differ per host, so they are
listed here against the file that consumes them.

Usage: sources-matcher.py [--check]
  (none)   rewrite the matcher in each host file
  --check  fail if any host file's matcher differs from the registry
"""

import json
import re
import sys
from pathlib import Path

# The matcher is replaced in place rather than through a parse-and-dump, so the
# hand-maintained formatting around each host file survives. Which value to
# replace is decided by the parser, not by a pattern: a regex reaching from a
# matcher forward to the sources-capture command would, in a group that has lost
# its own `matcher` key, land on the previous group's and silently rewrite it.
TOML_MATCHER = re.compile(r'(matcher = ")([^"]*)("\ncommand = "[^"]*sources-capture\.sh")')

# Each host file, its native web tools, and how its matcher is located.
HOSTS = {
    ".agents/claude/settings.json": (("WebSearch", "WebFetch"), "json"),
    ".agents/codex/hooks.json": ((), "json"),
    ".kimi/config.toml.example": (("WebSearch", "FetchURL"), "toml"),
}

SERVER = "[A-Za-z0-9_-]+"


def render(kind, value):
    """The exact bytes a host file uses to state one matcher."""
    return f'matcher = "{value}"' if kind == "toml" else f'"matcher": {json.dumps(value)}'


def locate(text, kind):
    """The sources-capture group's own matcher value, or None if it states none."""
    if kind == "toml":
        found = TOML_MATCHER.search(text)
        return found.group(2) if found else None
    for groups in (json.loads(text).get("hooks") or {}).values():
        for group in groups:
            commands = " ".join(hook.get("command", "") for hook in group.get("hooks") or [])
            if "sources-capture.sh" in commands:
                return group.get("matcher")     # None when the group states none
    return None


def matcher(registry, native):
    """The full alternation for one host, in a stable order."""
    tools, whole = set(), []
    for name, server in registry.items():
        declared = server.get("sources")
        if not declared:
            continue
        if declared == ["*"]:
            alias = name.replace("-", "_")
            whole.append(f"mcp__({name}|plugin_{alias}_{alias})__.*")
        else:
            tools.update(declared)
    parts = list(native)
    if tools:
        parts.append(f"mcp__{SERVER}__({'|'.join(sorted(tools))})")
    parts.extend(sorted(whole))
    return "|".join(parts)


def main():
    check = "--check" in sys.argv[1:]
    if sys.argv[1:] and not check:
        print("usage: sources-matcher.py [--check]", file=sys.stderr)
        return 2

    repo = Path(__file__).resolve().parent.parent
    try:
        registry = json.loads((repo / ".agents/mcp.json").read_text())["mcpServers"]
    except (OSError, ValueError, KeyError) as error:
        print(f"sources-matcher: cannot read .agents/mcp.json: {error}", file=sys.stderr)
        return 1

    stale = 0
    for rel, (native, kind) in HOSTS.items():
        path = repo / rel
        if not path.exists():
            continue                     # a satellite may not carry every host
        text = path.read_text()
        try:
            current = locate(text, kind)
        except ValueError as error:
            print(f"sources-matcher: {rel} does not parse: {error}", file=sys.stderr)
            stale += 1
            continue
        if current is None:
            # Keep going: one host losing its matcher must not hide the state of
            # the others, which is the whole point of checking all three.
            print(f"sources-matcher: no sources-capture matcher in {rel}", file=sys.stderr)
            stale += 1
            continue
        want = matcher(registry, native)
        if current == want:
            continue
        if check:
            stale += 1
            print(f"sources-matcher: {rel} is stale\n  have: {current}\n  want: {want}",
                  file=sys.stderr)
            continue
        quoted = render(kind, current)
        if text.count(quoted) != 1:
            print(f"sources-matcher: {rel} states that matcher {text.count(quoted)} times; "
                  "refusing to guess which one belongs to sources-capture", file=sys.stderr)
            stale += 1
            continue
        path.write_text(text.replace(quoted, render(kind, want), 1))
        print(f"{rel}: matcher updated")

    if stale:
        print("Run: python3 .agents/sources-matcher.py", file=sys.stderr)
        return 1
    if check:
        print(f"sources matcher: in sync across {len(HOSTS)} host files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
