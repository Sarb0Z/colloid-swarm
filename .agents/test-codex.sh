#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$repo/.agents/mcp.py"

python3 - "$repo" <<'PY'
import json
from pathlib import Path
import tomllib
import sys

repo = Path(sys.argv[1])
expected = {
    "explorer": "gpt-5.6-luna / low",
    "implementer": "gpt-5.6-terra / medium",
    "learning-reporter": None,
    "mechanic": "gpt-5.6-luna / low",
    "qa-verifier": "gpt-5.6-terra / medium",
    "researcher": "gpt-5.6-terra / medium",
    "reviewer": "gpt-5.6-sol / high",
}
claude_models = {
    "explorer": "haiku",
    "implementer": "claude-sonnet-5",
    "learning-reporter": None,
    "mechanic": "haiku",
    "qa-verifier": "claude-sonnet-5",
    "researcher": "claude-sonnet-5",
    "reviewer": "claude-opus-5",
}

personas = {path.stem for path in (repo / ".agents/personas").glob("*.md")}
if personas != set(expected):
    raise SystemExit(f"unexpected canonical personas: {sorted(personas)}")

for name, dispatch in expected.items():
    source = (repo / ".agents/personas" / f"{name}.md").read_text()
    if not source.startswith("---\n") or source.count("\n---\n") != 1:
        raise SystemExit(f"{name}: expected one YAML frontmatter block")
    model = claude_models[name]
    if model is None:
        if "\nmodel:" in source.split("\n---\n", 1)[0]:
            raise SystemExit(f"{name}: must not invent a Claude model default")
    elif f'\nmodel: "{model}"' not in source.split("\n---\n", 1)[0]:
        raise SystemExit(f"{name}: missing Claude model {model}")
    path = repo / ".codex/agents" / f"{name}.toml"
    with path.open("rb") as stream:
        record = tomllib.load(stream)
    description = record.get("description", "")
    if dispatch is None:
        if "Default dispatch:" in description:
            raise SystemExit(f"{name}: must not invent a dispatch default")
    elif f"Default dispatch: {dispatch}." not in description:
        raise SystemExit(f"{name}: missing exact dispatch {dispatch}")
    if not record.get("developer_instructions", "").strip():
        raise SystemExit(f"{name}: empty developer instructions")

with (repo / ".agents/mcp.json").open("rb") as stream:
    registry = json.load(stream)["mcpServers"]
with (repo / ".codex/config.toml").open("rb") as stream:
    config = tomllib.load(stream)
codex = config.get("mcp_servers", {})
assert config["approval_policy"] == "on-request"
assert config["approvals_reviewer"] == "auto_review"
assert config["default_permissions"] == "repo-autonomous"
assert config["features"]["network_proxy"] is True
default_profile = config["permissions"]["repo-autonomous"]
assert default_profile["extends"] == ":workspace"
workspace = default_profile["filesystem"][":workspace_roots"]
assert workspace == {".git": "write", ".agents": "write", ".codex": "write"}
assert "network" not in default_profile
localhost_profile = config["permissions"]["repo-localhost"]
assert localhost_profile["extends"] == "repo-autonomous"
assert localhost_profile["network"]["enabled"] is True
assert localhost_profile["network"]["allow_upstream_proxy"] is False
assert localhost_profile["network"]["domains"] == {"localhost": "allow", "127.0.0.1": "allow"}
expected_states = {
    name: server["enabled"] and "${" not in server.get("url", "")
    for name, server in registry.items()
    if server.get("type") in {"stdio", "http"}
    and server.get("codex_enabled") is not False
}
states = {name: body.get("enabled", True) for name, body in codex.items()}
if states != expected_states:
    raise SystemExit(f"Codex MCP states {states} != registry states {expected_states}")
for name, server in registry.items():
    timeout = server.get("codex_startup_timeout_sec")
    if timeout is not None and codex[name].get("startup_timeout_sec") != timeout:
        raise SystemExit(f"Codex MCP timeout for {name} was not generated")
PY

loader=skipped
if command -v codex >/dev/null 2>&1; then
  python3 - "$repo" <<'PY'
from pathlib import Path
import subprocess
import sys
import tomllib

repo = Path(sys.argv[1])
with (repo / ".codex/config.toml").open("rb") as stream:
    names = set(tomllib.load(stream).get("mcp_servers", {}))
try:
    result = subprocess.run(
        ["codex", "mcp", "list"], cwd=repo, text=True,
        capture_output=True, timeout=20,
    )
except subprocess.TimeoutExpired:
    raise SystemExit("test-codex: `codex mcp list` timed out after 20 seconds")
if result.returncode:
    raise SystemExit("test-codex: Codex rejected project config:\n" + result.stderr)
missing = sorted(name for name in names if name not in result.stdout)
if missing:
    raise SystemExit(f"test-codex: Codex did not expose project MCP records: {missing}")
PY
  loader=passed
fi

normalizer="$repo/.agents/codex/normalize-hook.py"
assert_json() {
  local payload="$1" policy="$2" expected="$3" actual
  actual="$(printf '%s' "$payload" | python3 "$normalizer" "$policy" "$repo")"
  ACTUAL="$actual" EXPECTED="$expected" python3 - <<'PY'
import json, os
if json.loads(os.environ["ACTUAL"]) != json.loads(os.environ["EXPECTED"]):
    raise SystemExit(f"expected {os.environ['EXPECTED']}, got {os.environ['ACTUAL']}")
PY
}

assert_json \
  '{"cwd":"/repo","tool_input":{"command":"*** Add File: plain.py\n*** Update File: \"dir/file name.ts\"\n*** Delete File: old.py\n*** Move to: moved.py"}}' \
  post-edit-check.sh \
  '{"project_dir":"/repo","files":["plain.py","dir/file name.ts","old.py","moved.py"],"warnings":[]}'
assert_json \
  '{"last_assistant_message":"I am unable to complete this.","stop_hook_active":false}' \
  stop-investigate.sh \
  '{"project_dir":"'"$repo"'","stop_hook_active":false,"transcript_path":"","last_assistant_message":"I am unable to complete this."}'

if printf '%s' '{"last_assistant_message":"I am unable to complete this.","stop_hook_active":false}' \
  | "$repo/.codex/hooks/adapter.sh" stop-investigate.sh >/dev/null 2>&1; then
  echo "test-codex: stop-investigate accepted a blocked completion" >&2
  exit 1
fi
printf '%s' '{"last_assistant_message":"Implemented and verified.","stop_hook_active":false}' \
  | "$repo/.codex/hooks/adapter.sh" stop-investigate.sh >/dev/null

python3 "$repo/.agents/codex/test-trust-hooks.py"
echo "Codex integration checks passed (host loader: $loader)."
