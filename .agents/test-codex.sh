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
    "implementer": "sonnet",
    "learning-reporter": None,
    "mechanic": "haiku",
    "qa-verifier": "sonnet",
    "researcher": "sonnet",
    "reviewer": None,
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
# Subagent concurrency must be stated, not inherited: an unset cap reads to an
# agent as a ceiling the host imposes and the repository cannot raise.
agents = config.get("agents", {})
assert agents.get("enabled", True) is True, "project config disables subagents"
threads = agents.get("max_concurrent_threads_per_session")
assert isinstance(threads, int) and not isinstance(threads, bool) and threads > 0, \
    "state the subagent concurrency cap as a positive integer"
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
# The matcher is generated from the registry, so a tool is only owed capture
# where its server is registered; a satellite that dropped a server has
# nothing to capture for it.
with (repo / ".agents/mcp.json").open(encoding="utf-8") as stream:
    registry = json.load(stream)["mcpServers"]
import re
for server, tool in (
    ("playwright", "mcp__playwright__browser_navigate"),
    ("research-mcp", "mcp__research-mcp__fetch_readable"),
    ("research-mcp", "mcp__research-mcp__resolve_open_access"),
    ("context7", "mcp__context7__resolve-library-id"),
    ("context7", "mcp__context7__query-docs"),
    ("exa", "mcp__plugin_exa_exa__web_search_exa"),
):
    if server not in registry:
        continue
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
PY

# Prints `checked` or `skipped`. A kit exported without Kimi has no
# .kimi/config.toml.example, and the check must pass there too.
check_kimi() {
  python3 - "$1" <<'PY'
import json
from pathlib import Path
import re
import sys
import tomllib

repo = Path(sys.argv[1])
with (repo / ".agents/mcp.json").open(encoding="utf-8") as stream:
    registry = json.load(stream)["mcpServers"]
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
    for server, tool in (("", "WebSearch"), ("", "FetchURL"),
                         ("research-mcp", "mcp__research-mcp__fetch_readable"),
                         ("exa", "mcp__plugin_exa_exa__web_search_exa")):
        if server and server not in registry:
            continue
        if re.fullmatch(kimi_source["matcher"], tool) is None:
            raise SystemExit(f"Kimi source matcher misses {tool}")
    print("checked")
else:
    print("skipped")
PY
}

check_kimi_in() {  # <root> <expected: checked|skipped>
  local got
  got="$(check_kimi "$1")"
  [[ "$got" == "$2" ]] || { echo "test-codex: Kimi check reported '$got', expected '$2' for $1" >&2; exit 1; }
}

[[ -f "$repo/.kimi/config.toml.example" ]] && check_kimi_in "$repo" checked || check_kimi_in "$repo" skipped
# The branch above only runs where Kimi ships; this one runs everywhere.
stripped="$(mktemp -d)"
trap 'rm -rf "$stripped"' EXIT
mkdir -p "$stripped/.agents"
cp "$repo/.agents/mcp.json" "$stripped/.agents/mcp.json"
check_kimi_in "$stripped" skipped

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
  # `codex mcp list` reads only config.toml, so a malformed hooks.json passes it.
  # hooks/list is the loader that parses hooks.json. A scratch CODEX_HOME that
  # trusts the project keeps the operator's own config out of the result and
  # unwritten; Codex reports a parse failure as a warning on an empty hook list.
  python3 - "$repo" <<'PY'
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import time

repo = Path(sys.argv[1])


def host_hooks(project: Path, home: Path):
    """Return (hooks, diagnostics) as Codex's hooks/list reports them for project."""
    home.mkdir(exist_ok=True)
    (home / "config.toml").write_text(
        f'[projects."{project.resolve()}"]\ntrust_level = "trusted"\n')
    proc = subprocess.Popen(
        ["codex", "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, text=True, env={**os.environ, "CODEX_HOME": str(home)})

    def send(message):
        proc.stdin.write(json.dumps(message) + "\n")
        proc.stdin.flush()

    try:
        send({"id": 0, "method": "initialize",
              "params": {"clientInfo": {"name": "test-codex", "version": "1"}}})
        send({"method": "initialized"})
        send({"id": 1, "method": "hooks/list", "params": {"cwds": [str(project)]}})
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if not select.select([proc.stdout], [], [], 1)[0]:
                continue
            line = proc.stdout.readline()
            if not line:
                break
            reply = json.loads(line)
            if reply.get("id") != 1:
                continue
            if "error" in reply:
                return [], [f"hooks/list failed: {reply['error']}"]
            entries = reply["result"]["data"]
            hooks = [h for e in entries for h in e.get("hooks", [])]
            notes = [n for e in entries for n in (e.get("warnings") or []) + (e.get("errors") or [])]
            return hooks, notes
        return [], ["hooks/list did not answer within 30 seconds"]
    finally:
        proc.terminate()
        proc.wait()


def hook_problems(project: Path, home: Path):
    declared = sum(len(group.get("hooks", []))
                   for groups in json.loads((project / ".codex/hooks.json").read_text())["hooks"].values()
                   for group in groups)
    hooks, notes = host_hooks(project, home)
    problems = list(notes)
    if len(hooks) != declared:
        problems.append(f"Codex loaded {len(hooks)} of {declared} declared hooks")
    return problems


def stage(root: Path, document: str) -> Path:
    (root / ".codex").mkdir(parents=True)
    (root / ".codex/hooks.json").write_text(document)
    return root


with tempfile.TemporaryDirectory() as scratch:
    scratch = Path(scratch)
    # Codex resolves a git worktree's project layer to the main checkout, so
    # loading the repository in place would judge a different hooks.json than
    # the one under test. A staged copy is judged wherever the suite runs.
    source = (repo / ".agents/codex/hooks.json").read_text()
    problems = hook_problems(stage(scratch / "real", source), scratch / "real-home")
    if problems:
        raise SystemExit("test-codex: Codex did not load .agents/codex/hooks.json:\n  " + "\n  ".join(problems))

    # The check must be able to fail: a copy with a handler type Codex rejects
    # has to be reported, or the pass above proves nothing.
    document = json.loads(source)
    next(iter(document["hooks"].values()))[0]["hooks"][0]["type"] = "nonsense"
    broken = stage(scratch / "broken", json.dumps(document))
    if not hook_problems(broken, scratch / "broken-home"):
        raise SystemExit("test-codex: the hooks/list check accepted a malformed hooks.json")
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
synced = run("guard-destructive.sh", {
    "cwd": str(repo), "tool_input": {"command": "python3 .agents/browser-sync.py"},
})
if guard_enabled:
    if blocked.returncode != 2 or "irreversible" not in blocked.stderr:
        raise SystemExit("Codex destructive-command adapter did not block")
    if synced.returncode != 2 or "! python3 .agents/browser-sync.py" not in synced.stderr:
        raise SystemExit("Codex destructive-command adapter did not refuse an agent-run browser sync")
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

python3 - "$repo" <<'PY'
import pathlib, sys, tomllib
repo = pathlib.Path(sys.argv[1])
style = (repo / ".agents/claude/output-style.md").read_text().split("---\n", 2)[2].strip()
codex = tomllib.loads((repo / ".agents/codex/config.toml").read_text())["developer_instructions"].strip()
if style != codex:
    raise SystemExit("test-codex: developer_instructions in .agents/codex/config.toml has drifted from .agents/claude/output-style.md")
PY

python3 "$repo/.agents/codex/test-trust-hooks.py"
echo "Codex integration checks passed (host loader: $loader)."
