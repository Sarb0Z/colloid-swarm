#!/usr/bin/env python3
"""List disabled project MCP servers.

Usage: mcp-off.py <project-dir>

Prints one `- <name> — <description>` line per off server, so the session can
name what exists but is not connected. A server absent from the registry is not
listed: the registry states what the repository offers.
"""

import json
from pathlib import Path
import sys


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    path = root / ".agents/mcp.json"
    try:
        registry = json.loads(path.read_text(encoding="utf-8")).get("mcpServers", {})
    except (OSError, json.JSONDecodeError):
        return 0
    if not isinstance(registry, dict):
        return 0
    for name, server in sorted(registry.items()):
        if not isinstance(server, dict) or server.get("enabled") is not False:
            continue
        description = server.get("description", "")
        print(f"- {name}" + (f" — {description}" if description else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
