#!/usr/bin/env bash
# Verify Codex integration generation and normalized hook contracts.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$repo/.agents/sync-codex.sh" --no-trust
"$repo/.agents/sync-codex.sh" --check --no-trust

python3 - "$repo" <<'PY'
import json
from pathlib import Path
import sys
import tomllib

repo = Path(sys.argv[1])
with (repo / ".codex/config.toml").open("rb") as config_file:
    servers = tomllib.load(config_file).get("mcp_servers", {})

with (repo / ".agents/config.json.example").open(encoding="utf-8") as config_file:
    toggles = json.load(config_file)["mcp"]["servers"]
local_path = repo / ".agents/config.json"
if local_path.exists():
    with local_path.open(encoding="utf-8") as config_file:
        local = json.load(config_file).get("mcp", {}).get("servers", {})
    for name, setting in local.items():
        if isinstance(setting, dict):
            toggles.setdefault(name, {}).update(setting)

with (repo / ".agents/mcp.json").open(encoding="utf-8") as registry_file:
    registry = json.load(registry_file)["mcpServers"]

expected = {}
for name, server in registry.items():
    if server.get("type") not in {"stdio", "http"}:
        continue
    setting = toggles.get(name, {})
    enabled = setting.get("enabled") is True and setting.get("codex_enabled", True) is True
    if enabled and "${" in server.get("url", ""):
        enabled = False          # Codex cannot interpolate it; masked, not omitted
    expected[name] = enabled

actual = {name: server.get("enabled", True) for name, server in servers.items()}
if actual != expected:
    raise SystemExit(f"expected generated MCP states {expected}, got {actual}")

PY

# Parsing is not loading. Codex rejects a record whose transport is missing or
# contradicts a lower layer, and such a file is still valid TOML — only the
# binary can say. The scratch home declares no servers, so this covers the case
# where nothing underneath supplies a transport.
if command -v codex >/dev/null 2>&1; then
  # Physical path: mktemp hands back a symlinked one on macOS, and a trust key
  # that does not match the cwd Codex resolves leaves the project untrusted,
  # its config ignored, and this check silently inert.
  loader="$(cd "$(mktemp -d)" && pwd -P)"
  mkdir -p "$loader/home" "$loader/ws/.codex"
  cp "$repo/.codex/config.toml" "$loader/ws/.codex/config.toml"
  printf '[projects."%s/ws"]\ntrust_level = "trusted"\n' "$loader" > "$loader/home/config.toml"
  git -C "$loader/ws" init -q
  if ! ( cd "$loader/ws" && CODEX_HOME="$loader/home" codex mcp list ) \
       >"$loader/out" 2>&1; then
    echo "test-codex: Codex refuses to load the generated config:" >&2
    sed 's/^/  /' "$loader/out" >&2
    rm -rf "$loader"
    exit 1
  fi
  rm -rf "$loader"
fi

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
cp -R "$repo/.agents" "$fixture/.agents"
# config.json is gitignored and per-machine. A fixture that inherits it passes
# or fails on whatever the operator happens to have toggled.
python3 - "$fixture/.agents/config.json" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"mcp": {"servers": {"context7": {"enabled": True},
                                   "exa": {"enabled": False}}}}, f, indent=1)
PY
"$fixture/.agents/sync-mcp.sh" disable context7 >/dev/null
python3 - "$fixture/.codex/config.toml" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as config_file:
    context7 = tomllib.load(config_file)["mcp_servers"]["context7"]
if context7.get("enabled") is not False:
    raise SystemExit("sync-mcp disable must regenerate the Codex server state")
PY
"$fixture/.agents/sync-mcp.sh" enable exa >/dev/null
python3 - "$fixture/.codex/config.toml" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as config_file:
    exa = tomllib.load(config_file)["mcp_servers"]["exa"]
if exa.get("enabled") is not False:
    raise SystemExit("enabling a server whose URL carries a credential must still emit its mask")
PY
# config.json is canonical and overrides per key, so a lone codex_enabled must
# mask the server for Codex without dropping it from the other tools.
python3 - "$fixture/.agents/config.json" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"mcp": {"servers": {"context7": {"codex_enabled": False}}}}, f, indent=1)
PY
"$fixture/.agents/sync-mcp.sh" >/dev/null
python3 - "$fixture" <<'PY'
import json
import sys
import tomllib
from pathlib import Path

fixture = Path(sys.argv[1])
claude = json.loads((fixture / ".mcp.json").read_text())["mcpServers"]
with (fixture / ".codex/config.toml").open("rb") as config_file:
    codex = tomllib.load(config_file)["mcp_servers"]
if "context7" not in claude:
    raise SystemExit("a lone codex_enabled must leave the server in the Claude output")
if codex.get("context7", {}).get("enabled") is not False:
    raise SystemExit("a lone codex_enabled must mask the server for Codex")
PY

rm -rf "$fixture"
trap - EXIT

normalizer="$repo/.agents/codex/normalize-hook.py"
assert_json() {
  local payload="$1" policy="$2" expected="$3"
  actual="$(printf '%s' "$payload" | python3 "$normalizer" "$policy" "$repo")"
  ACTUAL="$actual" EXPECTED="$expected" python3 - <<'PY'
import json, os
if json.loads(os.environ["ACTUAL"]) != json.loads(os.environ["EXPECTED"]):
    raise SystemExit(f"expected {os.environ['EXPECTED']}, got {os.environ['ACTUAL']}")
PY
}

stamp="⊰ COLLOID GENOME · THE test"
missing='{"cwd":"'"$repo"'","tool_input":{"message":"review this","agent_type":"worker"}}'
stamped='{"cwd":"'"$repo"'","tool_input":{"message":"'"$stamp"'\nreview this","agent_type":"worker"}}'
duplicate='{"cwd":"'"$repo"'","tool_input":{"message":"'"$stamp"'\n'"$stamp"'\nreview this","agent_type":"worker"}}'
exempt='{"cwd":"'"$repo"'","tool_input":{"message":"review this","agent_type":"learning-reporter"}}'

for payload in "$missing" "$stamped" "$duplicate" "$exempt"; do
  set +e
  printf '%s' "$payload" | "$repo/.codex/hooks/adapter.sh" genome-guard.sh >/dev/null 2>&1
  rc=$?
  set -e
  case "$payload" in
    "$missing"|"$duplicate") [[ $rc -eq 2 ]] ;;
    *) [[ $rc -eq 0 ]] ;;
  esac
done

assert_json \
  '{"cwd":"/repo","tool_input":{"command":"*** Add File: plain.py\n*** Update File: \"dir/file name.ts\"\n*** Delete File: old.py\n*** Move to: moved.py"}}' \
  post-edit-check.sh \
  '{"project_dir":"/repo","files":["plain.py","dir/file name.ts","old.py","moved.py"],"warnings":[]}'
assert_json \
  '{"last_assistant_message":"I am unable to complete this.","stop_hook_active":false}' \
  stop-investigate.sh \
  '{"project_dir":"'"$repo"'","stop_hook_active":false,"transcript_path":"","last_assistant_message":"I am unable to complete this."}'

if printf '%s' '{"last_assistant_message":"Implemented work.\nI am unable to complete this.","stop_hook_active":false}' | "$repo/.codex/hooks/adapter.sh" stop-investigate.sh >/dev/null 2>&1; then
  echo "test-codex: stop-investigate must block a hedge" >&2
  exit 1
fi
printf '%s' '{"last_assistant_message":"Implemented and verified the change.","stop_hook_active":false}' | "$repo/.codex/hooks/adapter.sh" stop-investigate.sh >/dev/null
transcript="$(mktemp)"
printf '%s\n' '{"message":{"role":"assistant","content":"I am unable to complete this."}}' > "$transcript"
if printf '%s' '{"transcript_path":"'"$transcript"'","stop_hook_active":false}' | "$repo/.codex/hooks/adapter.sh" stop-investigate.sh >/dev/null 2>&1; then
  rm -f "$transcript"
  echo "test-codex: stop-investigate must fall back to transcript" >&2
  exit 1
fi
rm -f "$transcript"
if printf '%s' '{"last_assistant_message":"The lint errors are pre-existing.","stop_hook_active":false}' | "$repo/.codex/hooks/adapter.sh" stop-investigate.sh >/dev/null 2>&1; then
  echo "test-codex: stop-investigate must ratchet an unfiled defect" >&2
  exit 1
fi
(
  cd "$repo/.agents"
  printf '%s' "$stamped" | ../.codex/hooks/adapter.sh genome-guard.sh >/dev/null
)

echo "Codex integration checks passed."

python3 "$repo/.agents/codex/test-trust-hooks.py"
