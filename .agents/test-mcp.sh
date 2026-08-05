#!/usr/bin/env bash
# Verify repository-root expansion and native security-mcp generation.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The fixture path holds a space on purpose: quoting regressions in the sync
# scripts have to fail here rather than on someone's machine.
make_fixture() {
  local fixture
  fixture="$(mktemp -d "${TMPDIR:-/tmp}/security mcp.XXXXXX")"
  # Skip node_modules: it is ~92% of the tree (14.9k of 16.2k files, 291MB) and
  # nothing under test reads it. The servers run from their bundled dist/, which
  # is copied. Including it costs ~16s per fixture, twice per run.
  tar -cf - -C "$repo" --exclude 'node_modules' .agents | tar -xf - -C "$fixture"
  # The copy is of a working tree, so it carries this operator's gitignored
  # state. Left in, the suite tests that state instead of the repository: it
  # would pass here and fail on a clean checkout, and any assertion that a file
  # gets generated would already be satisfied before the generator ran.
  rm -rf "$fixture/.agents/browser-extensions" \
         "$fixture/.agents/.playwright-reader.json" \
         "$fixture/.agents/config.json"
  rm -f "$fixture/.agents/".genome-ledger "$fixture/.agents/".mutagen-ledger \
        "$fixture/.agents/".sources-ledger "$fixture/.agents/".compaction-pending
  rm -f "$fixture/.agents/".wrap-state-* 2>/dev/null || true
  # A synthetic MV3 extension stands in for the operator's install, so the
  # reader tier is exercised on every machine rather than only where uBO Lite
  # happens to be present.
  mkdir -p "$fixture/.agents/browser-extensions/fixture-extension"
  printf '%s\n' '{"manifest_version":3,"name":"fixture","version":"1"}' \
    > "$fixture/.agents/browser-extensions/fixture-extension/manifest.json"
  printf '%s\n' "$fixture"
}

fixture="$(make_fixture)"
trap 'rm -rf "$fixture"' EXIT
python3 - "$fixture/.agents/config.json" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump({"mcp": {"servers": {
        "security-mcp": {"enabled": True},
        "research-mcp": {"enabled": True},
        "playwright-reader": {"enabled": True},
    }}}, output)
PY
"$fixture/.agents/sync-mcp.sh" >/dev/null

python3 - "$fixture" <<'PY'
import json
import sys
import tomllib
from pathlib import Path

root = Path(sys.argv[1])
claude = json.loads((root / ".mcp.json").read_text())["mcpServers"]
kimi = json.loads((root / ".kimi-code/mcp.json").read_text())["mcpServers"]
with (root / ".codex/config.toml").open("rb") as config_file:
    codex = tomllib.load(config_file)["mcp_servers"]
hosts = (("Claude", claude), ("Kimi", kimi), ("Codex", codex))

# Every repository-owned server resolves to the same node/dist/cwd triple on
# all three hosts, with no token left unexpanded.
for name in ("security-mcp", "research-mcp"):
    executable = str(root / f".agents/mcp-servers/{name}/dist/server.js")
    cwd = str(root / f".agents/mcp-servers/{name}")
    for host, servers in hosts:
        server = servers[name]
        if server.get("command") != "node" or server.get("args") != [executable] or server.get("cwd") != cwd:
            raise SystemExit(f"{host} did not preserve {name}'s repository-owned process arguments: {server}")
        if "${REPO_ROOT}" in repr(server):
            raise SystemExit(f"{host} retained an unexpanded repository token for {name}")

# The reader tier reaches its extension only through a generated launch config,
# so the path must be expanded and the file must actually be there.
reader_config = root / ".agents/.playwright-reader.json"
if not reader_config.is_file():
    raise SystemExit("sync-mcp did not generate the reader launch config")
for host, servers in hosts:
    args = servers["playwright-reader"]["args"]
    if "--config" not in args or str(reader_config) not in args:
        raise SystemExit(f"{host} lost the reader launch config: {args}")
    if "${REPO_ROOT}" in repr(servers["playwright-reader"]):
        raise SystemExit(f"{host} retained an unexpanded repository token for playwright-reader")

launch = json.loads(reader_config.read_text())["browser"]["launchOptions"]
# Branded Chrome silently discards --load-extension; only Chrome for Testing
# honours it, so the channel is load-bearing rather than cosmetic.
if launch.get("channel") != "chromium":
    raise SystemExit(f"reader tier must run Chrome for Testing, got {launch.get('channel')!r}")
extension_args = [a for a in launch.get("args", []) if a.startswith("--load-extension=")]
if len(extension_args) != 1 or str(root / ".agents/browser-extensions") not in extension_args[0]:
    raise SystemExit(f"reader tier lost its extension arguments: {launch.get('args')}")
PY

# An enabled reader tier with no extension installed must fail closed: a browser
# that silently starts without its content blocker is the failure to avoid.
rm -rf "$fixture/.agents/browser-extensions"
if "$fixture/.agents/sync-mcp.sh" >/dev/null 2>&1; then
  echo "test-mcp: enabled playwright-reader with no extension must fail closed" >&2
  exit 1
fi
python3 - "$fixture/.agents/config.json" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump({"mcp": {"servers": {"security-mcp": {"enabled": True}}}}, output)
PY
"$fixture/.agents/sync-mcp.sh" >/dev/null

python3 - "$fixture/.agents/config.json" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump({"mcp": {"servers": {"security-mcp": {"enabled": False}}}}, output)
PY
"$fixture/.agents/sync-mcp.sh" >/dev/null
python3 - "$fixture" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
kimi = json.loads((root / ".kimi-code/mcp.json").read_text())["mcpServers"]["security-mcp"]
claude = json.loads((root / ".mcp.json").read_text())["mcpServers"]
if "security-mcp" in claude:
    raise SystemExit("disabled security-mcp must be absent from Claude output")
if kimi.get("enabled") is not False or not kimi.get("command") or not kimi.get("args") or not kimi.get("cwd"):
    raise SystemExit("disabled security-mcp must remain a structurally valid Kimi record")
PY

mv "$fixture/.agents/mcp-servers/security-mcp/dist/server.js" \
   "$fixture/.agents/mcp-servers/security-mcp/dist/server.js.hidden"
if "$fixture/.agents/sync-mcp.sh" >/dev/null 2>&1; then
  echo "test-mcp: missing repository executable must fail closed" >&2
  exit 1
fi

rm -rf "$fixture"
fixture="$(make_fixture)"
python3 - "$fixture/.agents/mcp.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    registry = json.load(source)
registry["mcpServers"]["security-mcp"]["env"] = {"API_TOKEN": "${REPO_ROOT}/must-not-expand"}
with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump(registry, output)
PY
if "$fixture/.agents/sync-mcp.sh" >/dev/null 2>&1; then
  echo "test-mcp: repository token in a secret-bearing field must be rejected" >&2
  exit 1
fi

# A fresh clone runs sync-codex.sh on its own, before sync-mcp.sh has written
# the reader tier's launch config. resolve_registry validates that path for every
# registry entry, so a missing file there takes down the whole Codex layer.
rm -rf "$fixture"
fixture="$(make_fixture)"
rm -f "$fixture/.agents/.playwright-reader.json"
if ! "$fixture/.agents/sync-codex.sh" --no-trust >/dev/null 2>&1; then
  echo "test-mcp: sync-codex.sh must generate the reader config, not fail on it" >&2
  exit 1
fi
[[ -f "$fixture/.agents/.playwright-reader.json" ]] || {
  echo "test-mcp: sync-codex.sh did not generate the reader launch config" >&2
  exit 1
}

echo "MCP repository-root checks passed."
