#!/usr/bin/env python3
"""Warn when a generated MCP record collides with the user-level TOML config.

Codex merges the TOML configuration layers — user, project, and `-c` overrides —
per key. Where two layers name the same server with different transports, the
merged entry holds both a `command` and a `url`, and Codex refuses to load the
whole configuration: every server, every hook, every setting, for that
workspace.

Only the TOML layers merge this way. A configured server replaces a same-name
entry from the plugin catalog outright, so a plugin cannot produce this, and
comparing against the resolved server list would report plugin entries that can
never collide.

The generator cannot avoid the hazard: an enabled record must carry a
transport, so any transport it carries can meet a different one underneath.
This reports the condition instead, which turns a dead workspace into a line on
stderr. debt: codex-mcp-transport-collision

Read-only. Usage: check-mcp-conflicts.py <repo>
"""

import os
import sys
import tomllib


def transports(path, table="mcp_servers"):
    """Server name -> transport, by the key each record carries."""
    try:
        with open(path, "rb") as config_file:
            servers = tomllib.load(config_file).get(table, {})
    except (OSError, tomllib.TOMLDecodeError):
        return {}
    found = {}
    for name, body in servers.items():
        if not isinstance(body, dict):
            continue
        found[name] = "stdio" if "command" in body else "http" if "url" in body else None
    return found


def main():
    repo = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
    ours = transports(os.path.join(repo, ".codex", "config.toml"))
    if not ours:
        return 0
    home = os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")
    theirs = transports(os.path.join(home, "config.toml"))

    conflicts, masked = [], []
    for name, kind in sorted(ours.items()):
        if name not in theirs:
            continue
        if kind and theirs[name] and kind != theirs[name]:
            conflicts.append(f"{name} (this repo: {kind}, user config: {theirs[name]})")
        else:
            masked.append(name)

    if masked:
        print("sync-codex: also in the user config, and masked by this repo: "
              + ", ".join(masked), file=sys.stderr)
    for line in conflicts:
        print(f"sync-codex: TRANSPORT CONFLICT — {line}", file=sys.stderr)
    if conflicts:
        print("sync-codex: Codex loads no configuration at all for a workspace where "
              "one server holds two transports. Rename or disable one side.",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
