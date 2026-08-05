#!/usr/bin/env bash
# Sync MCP + LSP connection files from the canonical registry.
#
# Reads the server registry (.agents/mcp.json) and the per-repo toggles in
# .agents/config.json (mcp.servers.<name>.enabled), then generates the files
# each tool actually consumes:
#
#   .mcp.json                  Claude Code — enabled servers only, pass-through
#                              (${VAR} expanded by Claude at runtime).
#   .kimi-code/mcp.json        Kimi CLI project level — ALL registry servers:
#                              enabled ones with ${VAR} expanded HERE at sync
#                              time (skipped with a warning when the env var is
#                              unset), disabled ones present with "enabled":
#                              false so they override same-named user-level
#                              servers instead of being shadow-loaded. 0600:
#                              holds expanded secrets.
#   .codex/config.toml         Codex project level — generated through
#                              sync-codex.sh with explicit server states.
#   .claude/settings.local.json  enabledMcpjsonServers merged in (other keys and
#                              non-registry entries kept).
#   .github/lsp.json           Copilot CLI, regenerated from .agents/lsp.json
#                              (committed — deterministic, machine-independent).
#
# Toggle rule: example toggles are the base; the local config's mcp.servers
# entries override per server. A server absent from both is disabled.
#
# Usage:
#   .agents/sync-mcp.sh                      regenerate from current toggles
#   .agents/sync-mcp.sh enable  <name>...    flip toggles on,  then regenerate
#   .agents/sync-mcp.sh disable <name>...    flip toggles off, then regenerate
#
# MCP servers connect at session start — after enable/disable, the session
# must be restarted (or /reload) for the change to take effect.
#
# Do not hand-edit the generated files — edit .agents/mcp.json (registry) or
# .agents/config.json (toggles) and re-run. Called by sync-claude-agents.sh.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cmd="${1:-}"
if [[ "$cmd" == "enable" || "$cmd" == "disable" ]]; then
  shift
  [[ $# -ge 1 ]] || { echo "usage: sync-mcp.sh $cmd <server> [server...]" >&2; exit 2; }
  python3 - "$repo" "$cmd" "$@" <<'PY'
import json, os, sys, tempfile

repo, cmd, names = sys.argv[1], sys.argv[2], sys.argv[3:]
agents = os.path.join(repo, ".agents")

with open(os.path.join(agents, "mcp.json"), encoding="utf-8") as f:
    registry = json.load(f).get("mcpServers", {})
unknown = [n for n in names if n not in registry]
if unknown:
    print(f"sync-mcp: unknown server(s): {', '.join(unknown)}\n"
          f"registry: {', '.join(sorted(registry))}", file=sys.stderr)
    sys.exit(1)

config_path = os.path.join(agents, "config.json")
try:
    with open(config_path, encoding="utf-8") as f:
        cfg = json.load(f)
    if not isinstance(cfg, dict):
        raise ValueError("top level is not an object")
except FileNotFoundError:
    cfg = {}
except Exception as e:
    print(f"sync-mcp: refusing to edit unreadable {config_path} ({e})", file=sys.stderr)
    sys.exit(1)

servers = cfg.setdefault("mcp", {}).setdefault("servers", {})
on = cmd == "enable"
for name in names:
    entry = servers.setdefault(name, {})
    if not isinstance(entry, dict):
        entry = servers[name] = {}
    entry["enabled"] = on
    print(f"config.json: {name}.enabled = {on}")

fd, tmp = tempfile.mkstemp(dir=agents, prefix=".sync-mcp-cfg-")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
os.replace(tmp, config_path)
PY
elif [[ -n "$cmd" ]]; then
  echo "usage: sync-mcp.sh [enable|disable <server>...]" >&2
  exit 2
fi

python3 - "$repo" <<'PY'
import json, os, re, sys, tempfile

repo = sys.argv[1]
agents = os.path.join(repo, ".agents")
sys.path.insert(0, agents)
from mcp_registry import resolve_registry
import reader_config

def load_json(path, default=None):
    """Missing file -> default. Corrupt file -> default + loud warning."""
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default
    except Exception as e:
        print(f"sync-mcp: WARNING: {path} unreadable ({e}) — ignored", file=sys.stderr)
        return default

def write_json(path, data, mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.islink(path):  # never write through a symlink into the canonical file
        os.unlink(path)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".sync-mcp-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    if mode is not None:
        os.chmod(tmp, mode)
    os.replace(tmp, path)  # atomic: consumers never see a truncated file
    print("generated " + path)

# Toggles: example per-server entries are the base. config.json is canonical —
# every key it states wins for every tool, and keys it leaves out fall back to
# the example. The override is per key, not per server: a hand-written
# {"codex_enabled": false} must mask the server for Codex without dropping the
# `enabled` that keeps it live for the others. Entries are copied, so an
# override never reaches through into the example's own dict.
example = load_json(os.path.join(agents, "config.json.example"), {})
local = load_json(os.path.join(agents, "config.json"), {})
toggles = {name: dict(entry)
           for name, entry in example.get("mcp", {}).get("servers", {}).items()
           if isinstance(entry, dict)}
local_servers = local.get("mcp", {})
if not isinstance(local_servers, dict):
    print("sync-mcp: WARNING: config.json \"mcp\" is not an object — ignored",
          file=sys.stderr)
elif "servers" in local_servers:
    if isinstance(local_servers["servers"], dict):
        for name, entry in local_servers["servers"].items():
            if isinstance(entry, dict):
                toggles.setdefault(name, {}).update(entry)
            else:
                print(f"sync-mcp: WARNING: config.json mcp.servers.{name} is not an object — ignored",
                      file=sys.stderr)
    else:
        print("sync-mcp: WARNING: config.json mcp.servers is not an object — ignored",
              file=sys.stderr)

registry = load_json(os.path.join(agents, "mcp.json"), {}).get("mcpServers", {})
if not registry:
    print("sync-mcp: .agents/mcp.json missing or empty — nothing to do", file=sys.stderr)
    sys.exit(0)

# --- Reader browser tier: the launch config its registry entry points at ------
# Shared with sync-codex.sh, which resolves the same registry on its own.
extensions = reader_config.write(agents, log=print)
if toggles.get("playwright-reader", {}).get("enabled") is True and not extensions:
    print("sync-mcp: playwright-reader is enabled but no extension is installed.\n"
          "          Install one:  .agents/fetch-extension.sh ublock-lite\n"
          "          Or turn it off: .agents/sync-mcp.sh disable playwright-reader",
          file=sys.stderr)
    sys.exit(1)

registry = resolve_registry(registry, repo, "sync-mcp")
enabled = {name: srv for name, srv in registry.items()
           if toggles.get(name, {}).get("enabled") is True}

# --- Claude: enabled servers only, ${VAR} left for runtime expansion ---------
write_json(os.path.join(repo, ".mcp.json"), {"mcpServers": enabled})

# --- Kimi: ALL registry servers; disabled carry "enabled": false so they -----
# override same-named user-level entries instead of being shadow-loaded.
VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}")

def expand(value, missing):
    if isinstance(value, str):
        def sub(m):
            name, default = m.group(1), m.group(2)
            if name in os.environ:
                return os.environ[name]
            if default is not None:
                return default
            missing.add(name)
            return m.group(0)
        return VAR.sub(sub, value)
    if isinstance(value, dict):
        return {k: expand(v, missing) for k, v in value.items()}
    if isinstance(value, list):
        return [expand(v, missing) for v in value]
    return value

def to_kimi(srv):
    expanded = dict(srv)
    server_type = expanded.pop("type", None)
    expanded.pop("transport", None)
    if server_type == "sse":
        expanded["transport"] = "sse"
    if expanded.get("env") == {}:
        del expanded["env"]
    return expanded

kimi_servers = {}
for name, srv in registry.items():
    if name in enabled:
        missing = set()
        expanded = expand(to_kimi(srv), missing)
        if missing:
            print(f"sync-mcp: skipping {name} for Kimi — unset env: {', '.join(sorted(missing))}",
                  file=sys.stderr)
            continue
        kimi_servers[name] = expanded
    else:
        # Present but off: overrides user-level shadows, visible in /mcp.
        # ${VAR} placeholders stay literal — the server never connects.
        entry = to_kimi(srv)
        entry["enabled"] = False
        kimi_servers[name] = entry

write_json(os.path.join(repo, ".kimi-code", "mcp.json"),
           {"mcpServers": kimi_servers}, mode=0o600)

# --- Claude auto-approval: union-merge enabledMcpjsonServers -----------------
# Entries for servers outside our registry are the operator's own — keep them.
claude_dir = os.path.join(repo, ".claude")
if os.path.isdir(claude_dir):
    local_path = os.path.join(claude_dir, "settings.local.json")
    if os.path.exists(local_path):
        settings = load_json(local_path)
        if settings is None:
            print("sync-mcp: REFUSING to overwrite unreadable " + local_path,
                  file=sys.stderr)
        else:
            keep = set(settings.get("enabledMcpjsonServers", [])) - set(registry)
            settings["enabledMcpjsonServers"] = sorted(keep | set(enabled))
            write_json(local_path, settings)
    else:
        write_json(local_path, {"enabledMcpjsonServers": sorted(enabled)})

# --- LSP fan-out: canonical .agents/lsp.json -> .github/lsp.json (Copilot) ---
# Regenerated copy (re-serialized, not byte-identical): single source of
# truth, deletions propagate. Satellites add servers to their own
# .agents/lsp.json, never to the generated file.
lsp = load_json(os.path.join(agents, "lsp.json"))
if lsp:
    write_json(os.path.join(repo, ".github", "lsp.json"), lsp)
PY

# MCP changes do not change hooks, so this path must not write user trust state.
"$repo/.agents/sync-codex.sh" --no-trust

if [[ "$cmd" == "enable" || "$cmd" == "disable" ]]; then
  echo "NOTE: MCP servers connect at session start — restart the session (or /reload) for this to take effect."
fi
