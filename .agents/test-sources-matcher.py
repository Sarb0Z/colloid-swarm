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
import shutil
import subprocess
import sys
import tempfile
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
    tools = ["some_tool"] if declared == ["*"] else declared
    for host in (name, f"plugin_{name}_{name}"):
        for tool in tools:
            call = f"mcp__{host}__{tool}"
            check(f"{call} is captured", re.search(built, call) is not None, built)

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
    check(f"{call} is captured", re.search(built, call) is not None)

# Capture must not become a blanket: a server with no `sources` stays out.
for call in ("mcp__appium-mcp__mobile_click", "mcp__security-mcp__scan_target"):
    check(f"{call} is NOT captured", re.search(built, call) is None, built)

# A new source-producing server changes the matcher, so it cannot be added to
# the registry and silently go uncaptured.
grown = dict(registry)
grown["newsearch"] = {"description": "x", "enabled": False, "sources": ["fetch_page"]}
check("a new sources server widens the matcher",
      re.search(sm.matcher(grown, ()), "mcp__newsearch__fetch_page") is not None)
check("the same server without sources does not",
      re.search(sm.matcher({**registry, "newsearch": {"description": "x", "enabled": False}}, ()),
                   "mcp__newsearch__fetch_page") is None)

# Host-native web tools stay in, and differ per host.
check("Claude's native web tools are in its matcher", re.search(built, "WebFetch") is not None)
check("Kimi's native fetch is in Kimi's matcher",
      re.search(sm.matcher(registry, ("WebSearch", "FetchURL")), "FetchURL") is not None)
check("Kimi's fetch is not in Claude's matcher", re.search(built, "FetchURL") is None)
check("a native tool name is not matched inside a longer one",
      re.search(built, "mcp__foo__WebFetchLike") is None and re.search(built, "xWebFetch") is None)

# The untrusted-content matcher names every `sources` server whole, in both forms.
untrusted = sm.untrusted_matcher(registry, ("WebFetch", "WebSearch"))
for call in ("mcp__playwright__browser_click",
             "mcp__plugin_playwright_playwright__browser_snapshot",
             "mcp__scrapling__browser_open",
             "mcp__research-mcp__fetch_readable",
             "mcp__plugin_research-mcp_research-mcp__x",
             "WebFetch"):
    check(f"{call} gets the untrusted note", re.search(untrusted, call) is not None, untrusted)
for call in ("mcp__linear__list_issues", "mcp__appium-mcp__appium_tap", "Bash", "mcp__foo__WebFetchLike"):
    check(f"{call} gets no untrusted note", re.search(untrusted, call) is None, untrusted)
check("a new sources server appears in the untrusted matcher",
      re.search(sm.untrusted_matcher(grown, ()), "mcp__newsearch__anything") is not None)
check("the same server without sources does not",
      re.search(sm.untrusted_matcher({"newsearch": {"description": "x"}}, ()),
                   "mcp__newsearch__anything") is None)

# The checker is run against a copy of the files it reads, so no tracked file
# changes. `edit` receives the copied settings.json and hooks.json as parsed data.
def fixture_run(edit, *args):
    with tempfile.TemporaryDirectory() as scratch:
        fixture = Path(scratch)
        for rel in (".agents/sources-matcher.py", ".agents/mcp.json", ".agents/claude/settings.json",
                    ".agents/codex/hooks.json"):
            (fixture / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(repo / rel, fixture / rel)
        files = {rel: json.loads((fixture / rel).read_text())
                 for rel in (".agents/claude/settings.json", ".agents/codex/hooks.json")}
        edit(files)
        for rel, data in files.items():
            (fixture / rel).write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
        run = subprocess.run([sys.executable, str(fixture / ".agents/sources-matcher.py"), *args],
                             capture_output=True, text=True)
        return run, {rel: json.loads((fixture / rel).read_text()) for rel in files}


def untrusted_groups(data, event):
    return [g for g in data["hooks"].get(event, [])
            if "untrusted-content.sh" in " ".join(h.get("command", "") for h in g["hooks"])]


def hand_edit(files):
    for group in files[".agents/claude/settings.json"]["hooks"]["PostToolUseFailure"]:
        group["matcher"] = "WebFetch"


drift, _ = fixture_run(hand_edit, "--check")
check("a hand-edited untrusted matcher fails --check",
      drift.returncode != 0 and "untrusted-content.sh is stale" in drift.stderr, drift.stderr)


def drop_failure_key(files):
    del files[".agents/claude/settings.json"]["hooks"]["PostToolUseFailure"]


def drop_untrusted_post_tool_use(files):
    hooks = files[".agents/claude/settings.json"]["hooks"]
    hooks["PostToolUse"] = [g for g in hooks["PostToolUse"] if g not in untrusted_groups(files[".agents/claude/settings.json"], "PostToolUse")]


for label, edit in (("the PostToolUseFailure key is deleted", drop_failure_key),
                    ("only the PostToolUse untrusted group is deleted", drop_untrusted_post_tool_use)):
    for args in ((), ("--check",)):
        run, _ = fixture_run(edit, *args)
        check(f"{label}: run {' '.join(args) or 'plain'} fails naming file, policy and event",
              run.returncode != 0 and ".agents/claude/settings.json" in run.stderr
              and "untrusted-content.sh" in run.stderr and "PostToolUse" in run.stderr, run.stderr)


def differing_groups(files):
    groups = untrusted_groups(files[".agents/claude/settings.json"], "PostToolUse") \
        + untrusted_groups(files[".agents/claude/settings.json"], "PostToolUseFailure")
    groups[0]["matcher"] = "WebFetch"
    groups[1]["matcher"] = "WebSearch"


run, repaired = fixture_run(differing_groups)
claude = repaired[".agents/claude/settings.json"]
check("two untrusted groups that differ are both repaired by the plain run",
      run.returncode == 0 and all(
          g["matcher"] == sm.untrusted_matcher(registry, ("WebFetch", "WebSearch"))
          for event in ("PostToolUse", "PostToolUseFailure") for g in untrusted_groups(claude, event)),
      run.stderr)

print("\n" + ("ALL PASS" if fails == 0 else f"{fails} FAILED"))
sys.exit(1 if fails else 0)
