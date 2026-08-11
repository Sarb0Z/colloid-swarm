#!/usr/bin/env python3
"""Build native MCP configuration from the tracked registry.

Usage: mcp.py [sync] | enable NAME... | disable NAME...
"""

import json
import os
import re
import stat
import sys
import tempfile
from pathlib import Path

ROOT_TOKEN = "${REPO_ROOT}"
META = {"description", "enabled", "codex_enabled", "kimi_enabled"}
FIELDS = META | {"type", "command", "args", "cwd", "env", "url", "headers"}
ENV = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


def _fail(message):
    raise SystemExit(f"mcp: {message}")


def _write_json(path, value, mode=None):
    if mode is None:
        mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o644
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as output:
        json.dump(value, output, indent=2)
        output.write("\n")
        temp = Path(output.name)
    temp.chmod(mode)
    temp.replace(path)


def _write_text(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o644
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as output:
        output.write(value)
        temp = Path(output.name)
    temp.chmod(mode)
    temp.replace(path)


def _validate_stdio(name, server):
    incompatible = sorted(set(server) & {"url", "headers"})
    if incompatible:
        _fail(f"{name} stdio server has incompatible field(s): {', '.join(incompatible)}")
    if not isinstance(server.get("command"), str):
        _fail(f"{name} stdio server must have a command")
    if not isinstance(server.get("args", []), list) or not all(isinstance(item, str) for item in server.get("args", [])):
        _fail(f"{name}.args must be a string list")
    if "cwd" in server and not isinstance(server["cwd"], str):
        _fail(f"{name}.cwd must be a string")
    if "env" in server and (not isinstance(server["env"], dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in server["env"].items())):
        _fail(f"{name}.env must be a string map")


def _validate_remote(name, server):
    server_type = server["type"]
    incompatible = sorted(set(server) & {"command", "args", "cwd", "env"})
    if incompatible:
        _fail(f"{name} {server_type} server has incompatible field(s): {', '.join(incompatible)}")
    if not isinstance(server.get("url"), str):
        _fail(f"{name} {server_type} server must have a URL")
    headers = server.get("headers", {})
    if not isinstance(headers, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in headers.items()):
        _fail(f"{name}.headers must be a string map")
    bearer = headers.get("Authorization", "")
    if server_type == "http" and server.get("codex_enabled") is not False and headers and (
        set(headers) != {"Authorization"}
        or re.fullmatch(r"Bearer \$\{[A-Za-z_][A-Za-z0-9_]*\}", bearer) is None
    ):
        _fail(f"{name}.headers cannot be represented by Codex")


def _validate_server(name, server):
    if not isinstance(server, dict) or not isinstance(server.get("description"), str):
        _fail(f"{name} must have a description")
    if not isinstance(server.get("enabled"), bool):
        _fail(f"{name} must have boolean enabled")
    unknown = sorted(set(server) - FIELDS)
    if unknown:
        _fail(f"{name} has unsupported field(s): {', '.join(unknown)}")
    for key in ("codex_enabled", "kimi_enabled"):
        if key in server and not isinstance(server[key], bool):
            _fail(f"{name}.{key} must be boolean")
    if server.get("type") == "stdio":
        _validate_stdio(name, server)
    elif server.get("type") in {"http", "sse"}:
        _validate_remote(name, server)
    else:
        _fail(f"{name} has unsupported type {server.get('type')!r}")


def _registry(repo, doc=None):
    if doc is None:
        try:
            doc = json.loads((repo / ".agents/mcp.json").read_text())
        except (OSError, ValueError) as error:
            _fail(f"cannot read .agents/mcp.json: {error}")
    servers = doc.get("mcpServers") if isinstance(doc, dict) else None
    if not isinstance(servers, dict):
        _fail("mcpServers must be an object")
    for name, server in servers.items():
        _validate_server(name, server)
    return doc, servers


def _resolve(server, name, repo, virtual_paths=()):
    value = json.loads(json.dumps(server))
    remainder = {key: item for key, item in value.items() if key not in {"command", "cwd", "args"}}
    if ROOT_TOKEN in json.dumps(remainder):
        _fail(f"{name} uses {ROOT_TOKEN} outside command, cwd, or args")
    for field in ("command", "cwd"):
        if field in value:
            value[field] = value[field].replace(ROOT_TOKEN, str(repo))
    value["args"] = [item.replace(ROOT_TOKEN, str(repo)) for item in value.get("args", [])]
    candidates = []
    for field in ("command", "cwd"):
        item = value.get(field)
        if isinstance(item, str) and item.startswith(str(repo) + os.sep):
            candidates.append((field, Path(item)))
    for item in value.get("args", []):
        if isinstance(item, str) and item.startswith(str(repo) + os.sep):
            candidates.append(("args", Path(item)))
    for field, path in candidates:
        if path in virtual_paths:
            continue
        if (field == "cwd" and not path.is_dir()) or (field != "cwd" and not path.is_file()):
            _fail(f"{name} has missing repository-owned {field}: {path}")
        if field == "command" and not os.access(path, os.X_OK):
            _fail(f"{name} has non-executable repository command: {path}")
    return value


def _public(server):
    return {key: value for key, value in server.items() if key not in META}


def _kimi_record(server):
    item = _public(server)
    server_type = item.pop("type", None)
    if server_type == "sse":
        item["transport"] = "sse"
    return item


def _reader_config(repo, enabled):
    extensions = repo / ".agents/browser-extensions"
    installed = sorted(str(path) for path in extensions.glob("*/manifest.json")) if extensions.is_dir() else []
    launch = {"channel": "chromium"}
    if installed:
        launch["args"] = ["--load-extension=" + ",".join(str(Path(item).parent) for item in installed)]
    if enabled and not installed:
        _fail("playwright-reader is enabled but no extension is installed; run .agents/fetch-extension.sh ublock-lite")
    return {"browser": {"browserName": "chromium", "launchOptions": launch}}


def _toml_string(value):
    return json.dumps(value)


def _codex_config(repo, servers):
    try:
        base = (repo / ".agents/codex/config.toml").read_text()
    except OSError as error:
        _fail(f"cannot read .agents/codex/config.toml: {error}")
    rows = [base.rstrip(), ""]
    for name, server in servers.items():
        if server.get("type") == "sse" or server.get("codex_enabled") is False:
            continue
        enabled = server["enabled"]
        if "${" in str(server.get("url", "")):
            enabled = False
        # Project and user TOML merge per key; a same-name different transport
        # can invalidate the workspace. debt: codex-mcp-transport-collision
        rows.extend([f'[mcp_servers.{_toml_string(name)}]', f"enabled = {str(enabled).lower()}"])
        if server.get("type") == "stdio":
            for key in ("command", "args", "cwd"):
                if key in server:
                    rows.append(f"{key} = {_toml_string(server[key])}")
            if server.get("env"):
                rows.append("")
                rows.append(f'[mcp_servers.{_toml_string(name)}.env]')
                for key, value in sorted(server["env"].items()):
                    rows.append(f"{key} = {_toml_string(value)}")
        else:
            rows.append(f"url = {_toml_string(server['url'])}")
            headers = server.get("headers", {})
            bearer = headers.get("Authorization", "") if isinstance(headers, dict) else ""
            match = re.fullmatch(r"Bearer \$\{([A-Za-z_][A-Za-z0-9_]*)\}", bearer)
            if match:
                rows.append(f"bearer_token_env_var = {_toml_string(match.group(1))}")
        rows.append("")
    return "\n".join(rows).rstrip() + "\n"


def _expand_env(value, missing):
    if isinstance(value, str):
        def replace(match):
            name = match.group(1)
            if name not in os.environ:
                missing.add(name)
                return match.group(0)
            return os.environ[name]
        return ENV.sub(replace, value)
    if isinstance(value, list):
        return [_expand_env(item, missing) for item in value]
    if isinstance(value, dict):
        return {key: _expand_env(item, missing) for key, item in value.items()}
    return value


def _kimi_config(repo, servers):
    if not ((repo / ".kimi").is_dir() or (repo / ".kimi-code").is_dir()):
        return None
    records = {}
    for name, server in servers.items():
        item = _kimi_record(server)
        if server["enabled"] and server.get("kimi_enabled") is not False:
            missing = set()
            item = _expand_env(item, missing)
            if missing:
                item["enabled"] = False
        else:
            item["enabled"] = False
        records[name] = item
    return {"mcpServers": records}


def _claude_settings(repo, servers, enabled):
    path = repo / ".claude/settings.local.json"
    try:
        value = json.loads(path.read_text()) if path.exists() else {}
    except ValueError as error:
        _fail(f"cannot preserve {path}: {error}")
    old = value.get("enabledMcpjsonServers", [])
    if not isinstance(old, list) or not all(isinstance(name, str) for name in old):
        _fail(f"{path}: enabledMcpjsonServers must be a string list")
    value["enabledMcpjsonServers"] = sorted((set(old) - set(servers)) | set(enabled))
    return value


def _build(repo, doc=None):
    doc, raw = _registry(repo, doc)
    reader = _reader_config(repo, raw.get("playwright-reader", {}).get("enabled") is True)
    reader_path = repo / ".agents/.playwright-reader.json"
    servers = {
        name: _resolve(server, name, repo, {reader_path})
        for name, server in raw.items()
    }
    enabled = {name: _public(server) for name, server in servers.items() if server["enabled"]}
    return doc, {
        "reader": reader, "claude_mcp": {"mcpServers": enabled},
        "kimi": _kimi_config(repo, servers),
        "settings": _claude_settings(repo, servers, enabled),
        "codex": _codex_config(repo, servers),
    }


def _commit(repo, outputs):
    _write_json(repo / ".agents/.playwright-reader.json", outputs["reader"])
    _write_json(repo / ".mcp.json", outputs["claude_mcp"])
    if outputs["kimi"] is not None:
        _write_json(repo / ".kimi-code/mcp.json", outputs["kimi"], 0o600)
    _write_json(repo / ".claude/settings.local.json", outputs["settings"])
    _write_text(repo / ".codex/config.toml", outputs["codex"])


def main():
    repo = Path(__file__).resolve().parent.parent
    action, *names = sys.argv[1:] or ["sync"]
    doc = None
    if action in {"enable", "disable"}:
        if not names:
            _fail(f"usage: mcp.py {action} NAME...")
        doc, servers = _registry(repo)
        unknown = sorted(set(names) - set(servers))
        if unknown:
            _fail("unknown server(s): " + ", ".join(unknown))
        for name in names:
            servers[name]["enabled"] = action == "enable"
    elif action != "sync" or names:
        _fail("usage: mcp.py [sync] | enable NAME... | disable NAME...")
    doc, outputs = _build(repo, doc if action in {"enable", "disable"} else None)
    if action in {"enable", "disable"}:
        _write_json(repo / ".agents/mcp.json", doc)
    _commit(repo, outputs)


if __name__ == "__main__":
    main()
