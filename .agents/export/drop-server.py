#!/usr/bin/env python3
"""Remove an MCP server from a repository's registry and toggle template.

`mcp_registry.resolve_registry` validates the local paths of *every* registry
entry before any enabled/disabled filter runs, so a registry entry whose bundle
was not installed makes each sync script exit non-zero. A repository that does
not carry `.agents/mcp-servers/<name>/` must therefore not name it either.

Usage:  drop-server.py <repo> <server-name>
"""

import json
import pathlib
import sys


def drop(path: pathlib.Path, *keys: str) -> bool:
    """Delete a nested key, preserving the file's two-space formatting."""
    data = json.loads(path.read_text(encoding="utf-8"))
    node = data
    for key in keys[:-1]:
        node = node.get(key)
        if not isinstance(node, dict):
            return False
    if keys[-1] not in node:
        return False
    del node[keys[-1]]
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return True


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: drop-server.py <repo> <server-name>")
    repo, name = pathlib.Path(sys.argv[1]), sys.argv[2]
    agents = repo / ".agents"
    if (agents / "mcp-servers" / name).is_dir():
        raise SystemExit(f"drop-server: {name} is installed in {repo}; refusing to unregister it")
    changed = [
        label
        for label, path, keys in (
            ("mcp.json", agents / "mcp.json", ("mcpServers", name)),
            ("config.json.example", agents / "config.json.example", ("mcp", "servers", name)),
            ("config.json", agents / "config.json", ("mcp", "servers", name)),
        )
        if path.exists() and drop(path, *keys)
    ]
    print(f"drop-server: removed {name} from {', '.join(changed) if changed else 'nothing'}")


if __name__ == "__main__":
    main()
