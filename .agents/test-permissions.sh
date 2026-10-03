#!/usr/bin/env bash
# Permission rules agree with the MCP registry, and strip no read tool.
#
# These checks read .agents/claude/settings.json and .agents/mcp.json directly.
# They deliberately do not share test-mcp.sh's scratch workspace: that fixture
# reproduces one repository's server set, so a repository with a different
# registry fails before reaching any assertion here, and an unreachable gate
# reads exactly like a passing one.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$repo" <<'PY'
import fnmatch
import json
import os
import re
import subprocess
import sys
from pathlib import Path

source = Path(sys.argv[1])
settings = json.loads((source / ".agents/claude/settings.json").read_text())
registry = json.loads((source / ".agents/mcp.json").read_text())["mcpServers"]
permissions = settings.get("permissions", {})

# Verbs that name irreversible loss. A rule carries the verb as a prefix, which
# covers delete_issue and deleteConfluencePage alike.
DESTRUCTIVE_VERBS = ("delete", "remove", "destroy")

# Plugin and connector servers are host-level, so the registry cannot list them
# and this tuple names them instead. Without it their rules could be deleted
# with every check still green.
HOST_OUTWARD = ("plugin_vercel_vercel",)

# Read tools that must survive the deny list. None carries a verb above, but a
# shorter one would collide: "drop" matches playwright's browser_drop and would
# strip it with no warning, because a deny removes a tool silently.
SAFE_TOOLS = (
    "mcp__playwright__browser_drop",
    "mcp__playwright__browser_drag",
    "mcp__playwright__browser_close",
    "mcp__research-mcp__fetch_readable",
    "mcp__research-mcp__resolve_open_access",
    "mcp__security-mcp__security_scan",
    "mcp__security-mcp__list_security_prompts",
    "mcp__context7__query-docs",
)

# The default browser can carry the operator's synced session cookies, and
# this tool runs arbitrary code in its server process with them.
REQUIRED_DENY = ("mcp__playwright__browser_run_code_unsafe",)

ask_rules = permissions.get("ask")
if not isinstance(ask_rules, list):
    raise SystemExit("settings.json has no permissions.ask list")
deny_rules = permissions.get("deny")
if not isinstance(deny_rules, list):
    raise SystemExit("settings.json has no permissions.deny list")

# A rule naming no known tool normally warns at startup, but that check exempts
# names containing an underscore, so every MCP rule is exempt and a typo is
# silent. Shape validation is what is left: it catches mcp_linear, a trailing
# separator, and an empty segment, though not a well-formed wrong name.
for rule in ask_rules:
    if not rule.startswith("mcp"):
        continue
    if re.fullmatch(r"mcp__[A-Za-z0-9*-]+(?:_[A-Za-z0-9*-]+)*(?:__[A-Za-z0-9*_-]+)?", rule) is None:
        raise SystemExit(f"malformed MCP permission rule: {rule!r}")

# Deny rules use the one glob shape the host documents: a glob-free server
# segment and a trailing star. A wildcard anywhere else is rejected, because
# nothing documents a mid-pattern match and a glob that matches nothing fails
# open in silence.
for rule in deny_rules:
    if re.fullmatch(r"mcp__[A-Za-z0-9_-]+__[A-Za-z0-9_-]+\*?", rule) is None:
        raise SystemExit(f"malformed MCP deny rule: {rule!r}; use mcp__<server>__<prefix>*")

for rule in REQUIRED_DENY:
    if rule not in deny_rules:
        raise SystemExit(f"permissions.deny must carry {rule}; add it to .agents/claude/settings.json")

for tool in SAFE_TOOLS:
    hit = [rule for rule in deny_rules if fnmatch.fnmatchcase(tool, rule)]
    if hit:
        raise SystemExit(f"deny rule {hit[0]!r} would remove the read tool {tool}")

# A server that writes to a remote system must prompt, and must refuse the calls
# that destroy data. Rule order is deny, then ask, then allow, so an ask rule
# still prompts after an operator answers "don't ask again" for the same tool.
outward = {name for name, item in registry.items() if item.get("outward")}
for name in sorted(outward):
    if not {f"mcp__{name}", f"mcp__{name}__*"} & set(ask_rules):
        raise SystemExit(
            f"{name} is marked outward but no permissions.ask rule covers it; "
            f'add "mcp__{name}" to .agents/claude/settings.json'
        )
for name in sorted(outward | set(HOST_OUTWARD)):
    missing = [v for v in DESTRUCTIVE_VERBS if f"mcp__{name}__{v}*" not in deny_rules]
    if missing:
        raise SystemExit(
            f"{name} is outward but permissions.deny covers none of "
            f"{', '.join(missing)}; add mcp__{name}__<verb>* to "
            ".agents/claude/settings.json"
        )

# A deny rule removes its tool from the main thread's list, but a subagent whose
# `tools` names the server still sees the tool and receives a bare denial with
# nothing to do next. Each denied tool therefore carries a remedy, the remedy
# hook's matcher covers it, and every persona that would expose it removes it.
remedies = json.loads((source / ".agents/hooks/lib/denied-tools.json").read_text())
for tool in REQUIRED_DENY:
    if tool not in remedies:
        raise SystemExit(f"{tool} is denied but .agents/hooks/lib/denied-tools.json gives no remedy for it")
for tool in remedies:
    if tool not in deny_rules:
        raise SystemExit(f"denied-tools.json names {tool}, which permissions.deny does not deny")
matchers = [
    entry.get("matcher", "")
    for entry in settings.get("hooks", {}).get("PreToolUse", [])
    if any("denied-tool.sh" in hook.get("command", "") for hook in entry.get("hooks", []))
]
for tool in remedies:
    if not any(re.fullmatch(matcher, tool) for matcher in matchers):
        raise SystemExit(f"no PreToolUse denied-tool.sh entry matches {tool}; add it to the matcher")


def frontmatter_list(persona, text, key, absent):
    # An omitted `tools` list inherits every tool, so it reads as "*". Any form
    # other than an inline JSON list fails, because a misread list exposes nothing.
    if not re.search(rf"^{key}:", text, re.MULTILINE):
        return absent
    found = re.search(rf"^{key}:\s*(\[.*\])\s*$", text, re.MULTILINE)
    if found is None:
        raise SystemExit(f"{persona.name}: write {key} as an inline JSON list so this check can read it")
    return json.loads(found.group(1))


for persona in sorted((source / ".agents/personas").glob("*.md")):
    text = persona.read_text()
    exposed = frontmatter_list(persona, text, "tools", ["*"])
    removed = frontmatter_list(persona, text, "disallowedTools", [])
    for tool in remedies:
        if any(fnmatch.fnmatchcase(tool, p) for p in exposed) and not any(
            fnmatch.fnmatchcase(tool, p) for p in removed
        ):
            raise SystemExit(f"{persona.name} exposes the denied {tool}; add it to disallowedTools")

# Fire the hook the way the host does: a listed tool is refused with its remedy,
# any other tool passes.
adapter = source / ".claude/hooks/adapter.sh"
for tool, expect in [(next(iter(remedies)), 2), ("mcp__playwright__browser_click", 0)]:
    event = json.dumps({"hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": {}})
    ran = subprocess.run(
        [str(adapter), "denied-tool.sh"], input=event, capture_output=True, text=True,
        env={**os.environ, "CLAUDE_PROJECT_DIR": str(source)},
    )
    if ran.returncode != expect or (expect == 2 and "Instead," not in ran.stderr):
        raise SystemExit(
            f"denied-tool.sh on {tool}: exit {ran.returncode}, stderr {ran.stderr.strip()!r}; "
            "if hooks.denied_tool.enabled is false in policy.json or config.json, the hook is off by choice"
        )

print(
    f"permission rules passed: {len(deny_rules)} deny, "
    f"{len([r for r in ask_rules if r.startswith('mcp')])} MCP ask, "
    f"{len(outward)} outward server(s)."
)
PY
