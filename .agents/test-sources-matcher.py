#!/usr/bin/env python3
"""Gate the provenance matcher against the MCP registry.

The matcher decides which tool calls reach the sources ledger. A server is
reachable under both a registry name and a marketplace-plugin name, so a matcher
that lists one and not the other captures research whose sources are never
recorded — silently, since a missing ledger row looks exactly like a session
that did no research. These cases fail if the two forms can disagree.
"""

import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("sources_matcher", repo / ".agents/sources-matcher.py")
sm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sm)

fails = 0


def check(name, ok, detail=""):
    global fails
    if ok:
        print(f"ok    {name}")
    else:
        fails += 1
        print(f"FAIL  {name}" + (f"\n  {detail}" if detail else ""))


registry = json.loads((repo / ".agents/mcp.json").read_text())["mcpServers"]
built = sm.matcher(registry, ("WebSearch", "WebFetch"))

# Every host file agrees with the registry right now.
run = subprocess.run([sys.executable, str(repo / ".agents/sources-matcher.py"), "--check"],
                     capture_output=True, text=True)
check("every host matcher is in sync with the registry", run.returncode == 0,
      run.stdout + run.stderr)

# A declared tool must be captured under BOTH the registry name and the
# marketplace-plugin name. Listing one and not the other is the original defect.
for name, server in registry.items():
    declared = server.get("sources")
    if not declared:
        continue
    alias = name.replace("-", "_")
    tools = ["some_tool"] if declared == ["*"] else declared
    for host in (name, f"plugin_{alias}_{alias}"):
        for tool in tools:
            call = f"mcp__{host}__{tool}"
            check(f"{call} is captured", re.fullmatch(built, call) is not None, built)

# Whole-server captures, named outright so a regression is legible rather than
# hidden inside the sweep above: these two expose no distinctive tool name, so
# the server-wildcard rule cannot reach them and only their own alternation can.
# Skipped where the registry under test does not carry them — which servers a
# repository enables is its own choice, and asserting this one's list is what
# makes a suite red in every repository but this one.
for name, call in (("exa", "mcp__exa__web_search_exa"),
                   ("greptile", "mcp__greptile__query_repo")):
    if name not in registry:
        print(f"skip  {call} — no {name} in this registry")
        continue
    check(f"{call} is captured", re.fullmatch(built, call) is not None)

# Capture must not become a blanket: a server with no `sources` stays out.
for call in ("mcp__appium-mcp__mobile_click", "mcp__security-mcp__scan_target"):
    check(f"{call} is NOT captured", re.fullmatch(built, call) is None, built)

# A new source-producing server changes the matcher, so it cannot be added to
# the registry and silently go uncaptured.
grown = dict(registry)
grown["newsearch"] = {"description": "x", "enabled": False, "sources": ["fetch_page"]}
check("a new sources server widens the matcher",
      re.fullmatch(sm.matcher(grown, ()), "mcp__newsearch__fetch_page") is not None)
check("the same server without sources does not",
      re.fullmatch(sm.matcher({**registry, "newsearch": {"description": "x", "enabled": False}}, ()),
                   "mcp__newsearch__fetch_page") is None)

# Host-native web tools stay in, and differ per host.
check("Claude's native web tools are in its matcher", re.fullmatch(built, "WebFetch") is not None)
check("Kimi's native fetch is in Kimi's matcher",
      re.fullmatch(sm.matcher(registry, ("WebSearch", "FetchURL")), "FetchURL") is not None)
check("Kimi's fetch is not in Claude's matcher", re.fullmatch(built, "FetchURL") is None)

print("\n" + ("ALL PASS" if fails == 0 else f"{fails} FAILED"))
sys.exit(1 if fails else 0)
