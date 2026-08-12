"""Codex-specific MCP registry validation and TOML rendering."""

import json
import re


META_FIELDS = {"codex_enabled", "codex_startup_timeout_sec"}


def validate_metadata(name, server, fail):
    if "codex_enabled" in server and not isinstance(server["codex_enabled"], bool):
        fail(f"{name}.codex_enabled must be boolean")
    timeout = server.get("codex_startup_timeout_sec")
    invalid = not isinstance(timeout, int) or isinstance(timeout, bool) or timeout <= 0
    if timeout is not None and invalid:
        fail(f"{name}.codex_startup_timeout_sec must be a positive integer")


def render(repo, servers):
    try:
        base = (repo / ".agents/codex/config.toml").read_text()
    except OSError as error:
        raise SystemExit(f"mcp: cannot read .agents/codex/config.toml: {error}")
    rows = [base.rstrip(), ""]
    for name, server in servers.items():
        if server.get("type") == "sse" or server.get("codex_enabled") is False:
            continue
        enabled = server["enabled"] and "${" not in str(server.get("url", ""))
        # Project and user TOML merge per key; a same-name different transport
        # can invalidate the workspace. debt: codex-mcp-transport-collision
        rows.extend([f'[mcp_servers.{json.dumps(name)}]', f"enabled = {str(enabled).lower()}"])
        if "codex_startup_timeout_sec" in server:
            rows.append(f"startup_timeout_sec = {server['codex_startup_timeout_sec']}")
        if server.get("type") == "stdio":
            for key in ("command", "args", "cwd"):
                if key in server:
                    rows.append(f"{key} = {json.dumps(server[key])}")
            if server.get("env"):
                rows.extend(["", f'[mcp_servers.{json.dumps(name)}.env]'])
                for key, value in sorted(server["env"].items()):
                    rows.append(f"{key} = {json.dumps(value)}")
        else:
            rows.append(f"url = {json.dumps(server['url'])}")
            headers = server.get("headers", {})
            bearer = headers.get("Authorization", "") if isinstance(headers, dict) else ""
            match = re.fullmatch(r"Bearer \$\{([A-Za-z_][A-Za-z0-9_]*)\}", bearer)
            if match:
                rows.append(f"bearer_token_env_var = {json.dumps(match.group(1))}")
        rows.append("")
    return "\n".join(rows).rstrip() + "\n"
