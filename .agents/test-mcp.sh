#!/usr/bin/env bash
# Verify repository-root expansion and native repository-owned server generation.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Default capability is persona-bound. A registry server not named by a cached
# persona is available on request, not resident in every main session.
python3 - "$repo/.agents/config.json.example" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    config = json.load(source)
persona_servers = {
    name
    for agent in config.get("subagents", {}).values()
    for name in (agent.get("mcp_servers") or [])
}
enabled_servers = {
    name
    for name, setting in config.get("mcp", {}).get("servers", {}).items()
    if setting.get("enabled") is True
}
if enabled_servers != persona_servers:
    raise SystemExit(
        "default-enabled MCP set must equal persona-bound set: "
        f"enabled={sorted(enabled_servers)}, personas={sorted(persona_servers)}"
    )
PY

# The subject is repository-owned server handling, not one named server. A
# repository may carry only research-mcp, so drive whichever are installed and
# let the single-server cases use the first.
owned=()
for candidate in research-mcp security-mcp; do
  if [[ -d "$repo/.agents/mcp-servers/$candidate" ]]; then owned+=("$candidate"); fi
done
if [[ ${#owned[@]} -eq 0 ]]; then
  echo "test-mcp: no repository-owned MCP server is installed" >&2
  exit 1
fi
primary="${owned[0]}"
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
  rm -f "$fixture/.agents/".sources-ledger "$fixture/.agents/".compaction-pending
  # colloid-only
  rm -f "$fixture/.agents/".genome-ledger "$fixture/.agents/".mutagen-ledger
  # /colloid-only
  rm -f "$fixture/.agents/".wrap-state-* 2>/dev/null || true
  # A synthetic MV3 extension stands in for the operator's install, so the
  # reader tier is exercised on every machine rather than only where uBO Lite
  # happens to be present.
  mkdir -p "$fixture/.agents/browser-extensions/fixture-extension"
  printf '%s\n' '{"manifest_version":3,"name":"fixture","version":"1"}' \
    > "$fixture/.agents/browser-extensions/fixture-extension/manifest.json"
  # sync-mcp writes Kimi's project file only where the engine is wired. The
  # subject here is the generator, so the fixture wires it; the gate's
  # off-branch gets its own case below.
  mkdir -p "$fixture/.kimi/hooks"
  printf '%s\n' "$fixture"
}

fixture="$(make_fixture)"
trap 'rm -rf "$fixture"' EXIT
python3 - "$fixture/.agents/config.json" "${owned[@]}" <<'PY'
import json
import sys

servers = {name: {"enabled": True} for name in sys.argv[2:]}
servers["playwright-reader"] = {"enabled": True}
with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump({"mcp": {"servers": servers}}, output)
PY
"$fixture/.agents/sync-mcp.sh" >/dev/null

python3 - "$fixture" "${owned[@]}" <<'PY'
import json
import sys
import tomllib
from pathlib import Path

root = Path(sys.argv[1])
owned = sys.argv[2:]
claude = json.loads((root / ".mcp.json").read_text())["mcpServers"]
kimi = json.loads((root / ".kimi-code/mcp.json").read_text())["mcpServers"]
with (root / ".codex/config.toml").open("rb") as config_file:
    codex = tomllib.load(config_file)["mcp_servers"]
hosts = (("Claude", claude), ("Kimi", kimi), ("Codex", codex))

# Every repository-owned server resolves to the same node/dist/cwd triple on
# all three hosts, with no token left unexpanded.
for name in owned:
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
# Failing closed also means leaving no residue. The exit code alone passes even
# when the guard runs after the write, and that ordering ships a launch config
# with no --load-extension while the operator reads the red exit as a no-op.
python3 - "$fixture/.agents/.playwright-reader.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    launch = json.load(handle)["browser"]["launchOptions"]
if not [a for a in launch.get("args", []) if a.startswith("--load-extension=")]:
    raise SystemExit(
        "the aborted sync rewrote the reader launch config without --load-extension: "
        "the guard must run before reader_config.write")
PY
python3 - "$fixture/.agents/config.json" "$primary" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump({"mcp": {"servers": {sys.argv[2]: {"enabled": True}}}}, output)
PY
"$fixture/.agents/sync-mcp.sh" >/dev/null

python3 - "$fixture/.agents/config.json" "$primary" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump({"mcp": {"servers": {sys.argv[2]: {"enabled": False}}}}, output)
PY
"$fixture/.agents/sync-mcp.sh" >/dev/null
python3 - "$fixture" "$primary" <<'PY'
import json
import sys
from pathlib import Path

root, name = Path(sys.argv[1]), sys.argv[2]
kimi = json.loads((root / ".kimi-code/mcp.json").read_text())["mcpServers"][name]
claude = json.loads((root / ".mcp.json").read_text())["mcpServers"]
if name in claude:
    raise SystemExit(f"disabled {name} must be absent from Claude output")
if kimi.get("enabled") is not False or not kimi.get("command") or not kimi.get("args") or not kimi.get("cwd"):
    raise SystemExit(f"disabled {name} must remain a structurally valid Kimi record")
PY

mv "$fixture/.agents/mcp-servers/$primary/dist/server.js" \
   "$fixture/.agents/mcp-servers/$primary/dist/server.js.hidden"
if "$fixture/.agents/sync-mcp.sh" >/dev/null 2>&1; then
  echo "test-mcp: missing repository executable must fail closed" >&2
  exit 1
fi

rm -rf "$fixture"
fixture="$(make_fixture)"
python3 - "$fixture/.agents/mcp.json" "$primary" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    registry = json.load(source)
registry["mcpServers"][sys.argv[2]]["env"] = {"API_TOKEN": "${REPO_ROOT}/must-not-expand"}
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

# The Kimi writer is gated on the engine being wired. A repository with neither
# .kimi/ nor .kimi-code/ must come out of a sync with no Kimi project file:
# that file carries expanded credentials and would otherwise sit untracked in a
# repository that never asked for the engine.
rm -rf "$fixture"
fixture="$(make_fixture)"
rm -rf "$fixture/.kimi" "$fixture/.kimi-code"
"$fixture/.agents/sync-mcp.sh" >/dev/null
if [[ -e "$fixture/.kimi-code/mcp.json" ]]; then
  echo "test-mcp: Kimi project file written into a repository with no Kimi engine" >&2
  exit 1
fi

# The toggle-merge rule, against an explicit table rather than a second
# implementation of itself: four readers apply this rule, so a bug in it is a
# bug everywhere at once.
python3 - "$repo" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/.agents")
import toggles

CASES = [
    # name, example, local, expected merged table
    ("local overrides one key and inherits the rest",
     {"mcp": {"servers": {"exa": {"enabled": False, "description": "web search"}}}},
     {"mcp": {"servers": {"exa": {"enabled": True}}}},
     {"exa": {"enabled": True, "description": "web search"}}),
    ("a server only the local file names still lands",
     {"mcp": {"servers": {}}},
     {"mcp": {"servers": {"new": {"enabled": True}}}},
     {"new": {"enabled": True}}),
    ("an absent local file changes nothing",
     {"mcp": {"servers": {"exa": {"enabled": False}}}},
     {},
     {"exa": {"enabled": False}}),
    ("a non-object local entry carries no toggle and is ignored",
     {"mcp": {"servers": {"exa": {"enabled": False}}}},
     {"mcp": {"servers": {"exa": "yes"}}},
     {"exa": {"enabled": False}}),
    ("a non-object mcp block states nothing",
     {"mcp": {"servers": {"exa": {"enabled": True}}}},
     {"mcp": "on"},
     {"exa": {"enabled": True}}),
]

fails = 0
for name, example, local, expected in CASES:
    got = toggles.merge(example, local)
    if got != expected:
        fails += 1
        print(f"test-mcp: toggle merge — {name}\n  expected {expected}\n  got      {got}", file=sys.stderr)

# The example must not be reachable through the merged table, or a later write
# would reach back into the tracked file's own dict.
example = {"mcp": {"servers": {"exa": {"enabled": False}}}}
merged = toggles.merge(example, {})
merged["exa"]["enabled"] = True
if example["mcp"]["servers"]["exa"]["enabled"] is not False:
    fails += 1
    print("test-mcp: toggle merge — the merged table aliases the example", file=sys.stderr)

if toggles.malformed({"mcp": {"servers": {"a": {}, "b": 1}}}) != ["b"]:
    fails += 1
    print("test-mcp: toggle merge — malformed() did not name the non-object entry", file=sys.stderr)

if fails:
    sys.exit(1)
print(f"test-mcp: toggle merge — {len(CASES) + 2} assertions pass")
PY

echo "MCP repository-root checks passed."
