#!/usr/bin/env python3
"""List the registry MCP servers that are toggled off.

Usage: mcp-off.py <project-dir>

Prints one `- <name> — <description>` line per off server, so the session can
name what exists but is not connected. A server absent from the registry is not
listed: the registry states what the repository offers.
"""

import os
import sys

# .agents/hooks/lib/ -> .agents/, where toggles.py states the one merge rule.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

import toggles  # noqa: E402  (the path above must be set first)


def main():
    agents = os.path.join(sys.argv[1] if len(sys.argv) > 1 else ".", ".agents")
    registry = toggles.load(os.path.join(agents, "mcp.json")).get("mcpServers", {})
    if not isinstance(registry, dict):
        return 0
    table = toggles.resolve(agents)
    for name in sorted(registry):
        if toggles.enabled(table, name):
            continue
        description = table.get(name, {}).get("description", "")
        print(f"- {name}" + (f" — {description}" if description else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
