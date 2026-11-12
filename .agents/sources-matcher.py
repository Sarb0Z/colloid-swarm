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

The `untrusted-content.sh` hook, which adds a note beside web-page and outside
service results, has a second matcher kind. It names every server with a
non-empty `sources`, whole-server in both forms, because any tool of such a
server can return page text. Host-native web tools are added in front. Claude
registers it for PostToolUse and PostToolUseFailure, Codex for PostToolUse, and
Kimi not at all: it has no post-tool context channel.

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

# JSON hosts are rewritten through the parsed structure, which dumps back to the
# files' exact bytes. Kimi's TOML has no parser in the standard library of every
# supported Python, so its matcher is replaced as text; the pattern spans the
# hook's own event, matcher and command lines, so it cannot reach another hook.
TOML_HOOK = re.compile(r'event = "([^"]*)"\nmatcher = "([^"]*)"(\ncommand = "[^"]*sources-capture\.sh")')

# Each host file, the policy whose groups carry the matcher, the host's native
# web tools, how the file is parsed, the events the policy registers on there
# (one group each), and which matcher kind it takes.
CAPTURE, UNTRUSTED = "sources-capture.sh", "untrusted-content.sh"
HOSTS = (
    (".agents/claude/settings.json", CAPTURE, ("WebSearch", "WebFetch"), "json", ("PostToolUse",)),
    (".agents/codex/hooks.json", CAPTURE, (), "json", ("PostToolUse",)),
    (".kimi/config.toml.example", CAPTURE, ("WebSearch", "FetchURL"), "toml", ("PostToolUse",)),
    (".agents/claude/settings.json", UNTRUSTED, ("WebFetch", "WebSearch"), "json",
     ("PostToolUse", "PostToolUseFailure")),
    (".agents/codex/hooks.json", UNTRUSTED, (), "json", ("PostToolUse",)),
)

SERVER = "[A-Za-z0-9_-]+"


def json_groups(data, policy):
    """(event, group) for every hook group running `policy`."""
    found = []
    for event, groups in (data.get("hooks") or {}).items():
        for group in groups:
            commands = " ".join(hook.get("command", "") for hook in group.get("hooks") or [])
            if policy in commands:
                found.append((event, group))
    return found


def registration_errors(events, wanted):
    """Why the events carrying the policy are not exactly `wanted`, one group each."""
    problems = []
    for event in wanted:
        count = events.count(event)
        if count != 1:
            problems.append(f"{count} groups on {event}, expected 1")
    problems.extend(f"unexpected group on {event}" for event in sorted(set(events) - set(wanted)))
    return problems


def whole_server(name):
    return f"mcp__({name}|plugin_{name}_{name})__.*"


def matcher(registry, native):
    """The sources-capture alternation for one host, in a stable order."""
    tools, whole = set(), []
    for name, server in registry.items():
        declared = server.get("sources")
        if not declared:
            continue
        if declared == ["*"]:
            whole.append(whole_server(name))
        else:
            tools.update(declared)
    parts = list(native)
    if tools:
        parts.append(f"mcp__{SERVER}__({'|'.join(sorted(tools))})")
    parts.extend(sorted(whole))
    return anchored(parts)


def anchored(parts):
    """Claude tests a regex matcher unanchored, so a matcher states its own ends."""
    return f"^({'|'.join(parts)})$"


def untrusted_matcher(registry, native):
    """The untrusted-content alternation: every `sources` server, whole."""
    names = sorted(name for name, server in registry.items() if server.get("sources"))
    return anchored([*native, *(whole_server(name) for name in names)])


BUILDERS = {CAPTURE: matcher, UNTRUSTED: untrusted_matcher}


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
    for rel, policy, native, kind, events in HOSTS:
        path = repo / rel
        if not path.exists():
            continue                     # a satellite may not carry every host
        text = path.read_text()
        try:
            if kind == "json":
                data = json.loads(text)
                entries = [(event, group.get("matcher")) for event, group in json_groups(data, policy)]
            else:
                entries = [(m.group(1), m.group(2)) for m in TOML_HOOK.finditer(text)]
        except ValueError as error:
            print(f"sources-matcher: {rel} does not parse: {error}", file=sys.stderr)
            stale += 1
            continue
        # Keep going after a host fails: one host losing its registration must
        # not hide the state of the others, which is why all are checked.
        problems = registration_errors([event for event, _ in entries], events)
        if problems:
            print(f"sources-matcher: {rel} registers {policy} wrongly: {'; '.join(problems)}",
                  file=sys.stderr)
            stale += 1
            continue
        want = BUILDERS[policy](registry, native)
        if all(current == want for _, current in entries):
            continue
        if check:
            stale += 1
            print(f"sources-matcher: {rel} {policy} is stale\n"
                  f"  have: {' ; '.join(str(current) for _, current in entries)}\n  want: {want}",
                  file=sys.stderr)
            continue
        if kind == "json":
            for _, group in json_groups(data, policy):
                group["matcher"] = want
            path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
        else:
            path.write_text(TOML_HOOK.sub(lambda m: f'event = "{m.group(1)}"\nmatcher = "{want}"{m.group(3)}', text))
        print(f"{rel}: {policy} matcher updated")

    if stale:
        print("Run: python3 .agents/sources-matcher.py", file=sys.stderr)
        return 1
    if check:
        print(f"sources matcher: in sync across {len(HOSTS)} host matchers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
