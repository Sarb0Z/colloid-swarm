#!/usr/bin/env bash
# Verify Codex integration generation and normalized hook contracts.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# --check first and on its own: it is the drift gate on the tracked .codex/
# agent TOMLs, and running the generator ahead of it would rewrite the very
# drift it exists to catch. Regenerating is the developer's job, not the test's.
"$repo/.agents/sync-codex.sh" --check --no-trust
"$repo/.agents/sync-codex.sh" --no-trust

python3 - "$repo" <<'PY'
import json
from pathlib import Path
import sys
import tomllib

repo = Path(sys.argv[1])
with (repo / ".codex/config.toml").open("rb") as config_file:
    servers = tomllib.load(config_file).get("mcp_servers", {})

# The merge rule has one implementation, .agents/toggles.py, and test-mcp.sh
# asserts it against an explicit fixture table. Reimplementing it here would
# only ever catch a divergence between two copies, never a bug in the rule.
sys.path.insert(0, str(repo / ".agents"))
import toggles as toggle_rules

toggles = toggle_rules.resolve(str(repo / ".agents"))

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
loader_checked=no
if command -v codex >/dev/null 2>&1; then
  # Physical path: mktemp hands back a symlinked one on macOS, and a trust key
  # that does not match the cwd Codex resolves leaves the project untrusted,
  # its config ignored, and this check silently inert.
  loader="$(cd "$(mktemp -d)" && pwd -P)"
  trap 'rm -rf "$loader"' EXIT
  mkdir -p "$loader/home" "$loader/ws/.codex"
  cp "$repo/.codex/config.toml" "$loader/ws/.codex/config.toml"
  printf '[projects."%s/ws"]\ntrust_level = "trusted"\n' "$loader" > "$loader/home/config.toml"
  # Without a repository boundary Codex walks up and merges an ancestor
  # .codex/config.toml, so the listing would not be the generated file alone.
  git -C "$loader/ws" init -q
  if ! ( cd "$loader/ws" && CODEX_HOME="$loader/home" codex mcp list ) \
       >"$loader/out" 2>&1; then
    echo "test-codex: Codex refuses to load the generated config:" >&2
    sed 's/^/  /' "$loader/out" >&2
    exit 1
  fi
  # Success also covers "Codex never read the project config" — an untrusted
  # workspace lists nothing and still exits 0. Assert it read what we wrote,
  # or the check reverts to green on a file Codex would refuse.
  python3 - "$repo/.codex/config.toml" "$loader/out" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as config_file:
    names = sorted(tomllib.load(config_file).get("mcp_servers", {}))
with open(sys.argv[2], encoding="utf-8") as listing_file:
    listing = listing_file.read()
missing = [name for name in names if name not in listing]
if missing:
    raise SystemExit(
        "Codex did not read the generated config — absent from `codex mcp list`: "
        f"{missing}")
if not names:
    raise SystemExit("generated config declares no MCP servers; nothing was proven")

# One transport per record. Two makes Codex reject every configuration for the
# workspace, and the merge is per key, so a second one can also arrive from the
# user layer.
with open(sys.argv[1], "rb") as config_file:
    records = tomllib.load(config_file)["mcp_servers"]
both = {name: sorted(k for k in body if k in ("command", "url"))
        for name, body in records.items()
        if "command" in body and "url" in body}
if both:
    raise SystemExit(f"records carrying two transports: {both}")
PY
  rm -rf "$loader"
  trap - EXIT
  loader_checked=yes
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

# colloid-only
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
# /colloid-only

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
# The adapter resolves the repository from its own path, not from cwd.
(
  cd "$repo/.agents"
  printf '%s' '{"last_assistant_message":"Implemented and verified the change.","stop_hook_active":false}' \
    | ../.codex/hooks/adapter.sh stop-investigate.sh >/dev/null
)

# A generation failure must leave .codex/ untouched and the hooks armed. Both
# properties are invisible to a passing sync, so drive one that throws: a
# persona carrying the TOML delimiter makes toml_multiline raise after the first
# agent TOML would otherwise have been written.
txn="$(mktemp -d)"
trap 'rm -rf "$txn"' EXIT
cp -R "$repo/.agents" "$txn/.agents"
git -C "$txn" init -q
"$txn/.agents/sync-codex.sh" --no-trust >/dev/null 2>&1
# trust-hooks.py owns the operator's ~/.codex/config.toml, so the test observes
# a stand-in rather than letting the suite write there.
cat > "$txn/.agents/codex/trust-hooks.py" <<'STUB'
#!/usr/bin/env python3
import os, sys
open(os.path.join(sys.argv[1], ".trust-hooks-ran"), "w").write("ran\n")
STUB
chmod +x "$txn/.agents/codex/trust-hooks.py"
printf '\nSENTINEL\n' >> "$txn/.codex/agents/researcher.toml"
printf "\n'''\n" >> "$txn/.agents/personas/learning-reporter.md"
if "$txn/.agents/sync-codex.sh" >/dev/null 2>&1; then
  echo "test-codex: a persona that cannot build must fail the sync" >&2
  exit 1
fi
if ! grep -q SENTINEL "$txn/.codex/agents/researcher.toml"; then
  echo "test-codex: the aborted sync half-generated .codex/ — build every output before writing any" >&2
  exit 1
fi
if [[ ! -f "$txn/.trust-hooks-ran" ]]; then
  echo "test-codex: the aborted sync skipped the re-trust — the hooks.json re-link leaves them disarmed" >&2
  exit 1
fi
rm -rf "$txn"
trap - EXIT

if [[ "$loader_checked" == "yes" ]]; then
  echo "Codex integration checks passed."
else
  echo "Codex integration checks passed (loader check SKIPPED: codex not on PATH)."
fi

python3 "$repo/.agents/codex/test-trust-hooks.py"
