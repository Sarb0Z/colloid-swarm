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

with (repo / ".agents/codex/hooks.json").open(encoding="utf-8") as stream:
    codex_hooks = json.load(stream)["hooks"]
# colloid-only
starts = codex_hooks.get("SubagentStart", [])
if len(starts) != 1 or "genome-inject.sh" not in json.dumps(starts[0]):
    raise SystemExit("Codex must inject one genome from native SubagentStart")
# /colloid-only
source_group = next(
    (group for group in codex_hooks["PostToolUse"]
     if "sources-capture.sh" in json.dumps(group)), None,
)
if source_group is None:
    raise SystemExit("Codex source-capture hook is missing")
codex_matcher = source_group["matcher"]
for tool in (
    "mcp__playwright__browser_navigate",
    "mcp__research-mcp__fetch_readable",
    "mcp__research-mcp__resolve_open_access",
    "mcp__context7__resolve-library-id",
    "mcp__context7__query-docs",
    "mcp__plugin_exa_exa__web_search_exa",
):
    import re
    if re.fullmatch(codex_matcher, tool) is None:
        raise SystemExit(f"Codex source matcher misses {tool}")

with (repo / ".agents/claude/settings.json").open(encoding="utf-8") as stream:
    claude_hooks = json.load(stream)["hooks"]
claude_source = next(
    group for group in claude_hooks["PostToolUse"]
    if "sources-capture.sh" in json.dumps(group)
)
for tool in ("WebSearch", "WebFetch", "mcp__context7__query-docs"):
    if re.fullmatch(claude_source["matcher"], tool) is None:
        raise SystemExit(f"Claude source matcher misses {tool}")

kimi_path = repo / ".kimi/config.toml.example"
if kimi_path.is_file():
    kimi_config_text = kimi_path.read_text()
    # colloid-only
    if "adapter.sh genome-inject.sh" in kimi_config_text:
        raise SystemExit("Kimi must not register an output-discarding genome hook")
    # /colloid-only
    with kimi_path.open("rb") as stream:
        kimi_config = tomllib.load(stream)
    kimi_source = next(
        hook for hook in kimi_config["hooks"]
        if "sources-capture.sh" in hook["command"]
    )
    for tool in ("WebSearch", "FetchURL", "mcp__research-mcp__fetch_readable",
                 "mcp__plugin_exa_exa__web_search_exa"):
        if re.fullmatch(kimi_source["matcher"], tool) is None:
            raise SystemExit(f"Kimi source matcher misses {tool}")
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
# colloid-only
assert_json \
  '{"cwd":"/repo","agent_id":"child-1","agent_type":"reviewer"}' \
  genome-inject.sh \
  '{"project_dir":"/repo","subagent_type":"reviewer"}'
# /colloid-only
assert_json \
  '{"cwd":"/repo","tool_name":"mcp__context7__query-docs","tool_input":{"query":"hook contracts","libraryId":"/openai/codex"}}' \
  sources-capture.sh \
  '{"project_dir":"/repo","agent":"unknown","tool_name":"mcp__context7__query-docs","tool_input":{"query":"hook contracts","libraryId":"/openai/codex"}}'

python3 - "$repo" <<'PY'
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1])
source_path = repo / ".agents/hooks/lib/sources-ledger.py"
spec = importlib.util.spec_from_file_location("sources_ledger", source_path)
sources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sources)

cases = [
    ({"tool_name": "WebSearch", "tool_input": {"query": "codex hooks"}},
     ("search", "codex hooks")),
    ({"tool_name": "FetchURL", "tool_input": {"url": "https://example.test/a"}},
     ("fetch", "https://example.test/a")),
    ({"tool_name": "mcp__playwright__browser_navigate", "tool_input": {"url": "https://example.test/b"}},
     ("browse", "https://example.test/b")),
    ({"tool_name": "mcp__research-mcp__resolve_open_access", "tool_input": {"query": "paper doi"}},
     ("search", "paper doi")),
    ({"tool_name": "mcp__context7__query-docs", "tool_input": {"query": "hook schema"}},
     ("search", "hook schema")),
    ({"tool_name": "mcp__plugin_exa_exa__get_code_context_exa", "tool_input": {"query": "source"}},
     ("search", "source")),
    ({"tool_name": "mcp__plugin_exa_exa__web_search_exa", "tool_input": {"url": "https://example.test/c"}},
     ("fetch", "https://example.test/c")),
]
for payload, expected in cases:
    actual = sources.source_row(payload)
    if actual != expected:
        raise SystemExit(f"source classifier: expected {expected}, got {actual}")
if sources.source_row({"tool_name": "apply_patch", "tool_input": {}}) is not None:
    raise SystemExit("source classifier recorded an unsupported tool")

adapter = repo / ".codex/hooks/adapter.sh"

def run(policy, payload):
    return subprocess.run(
        [adapter, policy], input=json.dumps(payload), text=True,
        capture_output=True, cwd=repo,
    )

# colloid-only
injected = run("genome-inject.sh", {"cwd": str(repo), "agent_type": "reviewer"})
if injected.returncode:
    raise SystemExit(f"Codex genome adapter failed: {injected.stderr}")
context = json.loads(injected.stdout)["hookSpecificOutput"]
if context["hookEventName"] != "SubagentStart":
    raise SystemExit("Codex genome adapter emitted the wrong hook event")
if context["additionalContext"].count("⊰ COLLOID GENOME ·") != 1:
    raise SystemExit("Codex genome adapter did not inject exactly one stamp")

exempt = run("genome-inject.sh", {"cwd": str(repo), "agent_type": "explorer"})
if exempt.returncode or exempt.stdout:
    raise SystemExit("Codex explorer alias must be exempt from genome injection")
# /colloid-only

blocked = run("guard-destructive.sh", {
    "cwd": str(repo), "tool_input": {"command": "rm -rf /"},
})
try:
    local_config = json.loads((repo / ".agents/config.json").read_text())
except (OSError, ValueError):
    local_config = {}
hooks = local_config.get("hooks") if isinstance(local_config, dict) else {}
guard = hooks.get("guard_destructive") if isinstance(hooks, dict) else {}
guard_enabled = guard.get("enabled") is not False if isinstance(guard, dict) else True
if guard_enabled:
    if blocked.returncode != 2 or "irreversible" not in blocked.stderr:
        raise SystemExit("Codex destructive-command adapter did not block")
elif blocked.returncode != 0:
    raise SystemExit("Codex destructive-command adapter ignored the disabled guard")

with tempfile.TemporaryDirectory() as project:
    Path(project, ".agents").mkdir()
    captured = run("sources-capture.sh", {
        "cwd": project,
        "tool_name": "mcp__context7__query-docs",
        "tool_input": {"query": "native policy firing"},
    })
    if captured.returncode:
        raise SystemExit(f"Codex source adapter failed: {captured.stderr}")
    rows = Path(project, ".agents/.sources-ledger").read_text().splitlines()
    if len(rows) != 1 or rows[0].split("\t")[1:] != ["unknown", "search", "native policy firing"]:
        raise SystemExit(f"Codex source adapter wrote the wrong row: {rows}")
PY

if printf '%s' '{"last_assistant_message":"I am unable to complete this.","stop_hook_active":false}' \
  | "$repo/.codex/hooks/adapter.sh" stop-investigate.sh >/dev/null 2>&1; then
  echo "test-codex: stop-investigate accepted a blocked completion" >&2
  exit 1
fi
printf '%s' '{"last_assistant_message":"Implemented and verified.","stop_hook_active":false}' \
  | "$repo/.codex/hooks/adapter.sh" stop-investigate.sh >/dev/null

python3 "$repo/.agents/codex/test-trust-hooks.py"
echo "Codex integration checks passed (host loader: $loader)."
