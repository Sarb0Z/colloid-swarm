"""One rule for MCP server toggles: the example is the base, config.json overrides per key.

`config.json.example` is tracked and carries every server with its description.
`config.json` is gitignored, per-repo, and states only what this machine changes.
A local entry therefore overrides the example key by key and inherits the rest —
a local `{"enabled": true}` must not erase the example's description.

Four readers apply this rule: `sync-mcp.sh`, `sync-codex.sh`, the SessionStart
policy, and the Codex suite. A second implementation can only ever be tested
against the first, so there is one.

An entry that is not an object cannot carry a toggle, so it is ignored rather
than merged.
"""

import json
import os


def load(path):
    """One settings file as a dict. An absent or unreadable file states nothing."""
    try:
        with open(path, encoding="utf-8") as source:
            value = json.load(source)
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def servers(settings):
    """The `mcp.servers` table of one settings file, object entries only."""
    table = settings.get("mcp", {})
    table = table.get("servers", {}) if isinstance(table, dict) else {}
    if not isinstance(table, dict):
        return {}
    return {name: dict(entry) for name, entry in table.items() if isinstance(entry, dict)}


def malformed(settings):
    """Server names whose entry is not an object, so it can carry no toggle.

    `merge` drops these silently. A caller that wants to say so out loud reads
    them here rather than re-walking the table.
    """
    table = settings.get("mcp", {})
    table = table.get("servers", {}) if isinstance(table, dict) else {}
    if not isinstance(table, dict):
        return []
    return [name for name, entry in table.items() if not isinstance(entry, dict)]


def merge(example, local):
    """Per server, per key: the local entry overrides and inherits the rest."""
    merged = servers(example)
    for name, entry in servers(local).items():
        merged.setdefault(name, {}).update(entry)
    return merged


def resolve(agents):
    """The merged toggle table for one `.agents` directory."""
    return merge(load(os.path.join(agents, "config.json.example")),
                 load(os.path.join(agents, "config.json")))


def enabled(toggles, name):
    """True only when the merged entry says so. Absent means off."""
    return toggles.get(name, {}).get("enabled") is True
