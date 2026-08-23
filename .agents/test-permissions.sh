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
import re
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

print(
    f"permission rules passed: {len(deny_rules)} deny, "
    f"{len([r for r in ask_rules if r.startswith('mcp')])} MCP ask, "
    f"{len(outward)} outward server(s)."
)
PY
