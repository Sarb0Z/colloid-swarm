#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$repo" <<'PY'
import json, shutil, stat, subprocess, sys, tempfile, tomllib
from pathlib import Path

source = Path(sys.argv[1])
work = Path(tempfile.mkdtemp(prefix="mcp-test-"))
try:
    agents = work / ".agents"
    agents.mkdir()
    for relative in ("mcp.py", "mcp.json", "codex/config.toml"):
        destination = agents / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / ".agents" / relative, destination)
    (agents / "mcp.py").chmod(0o755)
    for name in ("research-mcp", "security-mcp"):
        root = agents / "mcp-servers" / name
        (root / "dist").mkdir(parents=True)
        (root / "dist/server.js").write_text("// fixture\n")
    (work / ".kimi").mkdir()
    (work / ".claude").mkdir()
    (work / ".claude/settings.local.json").write_text(json.dumps({"keep": True, "enabledMcpjsonServers": ["outside"]}))

    def run(*args):
        return subprocess.run([sys.executable, str(agents / "mcp.py"), *args], cwd=work, text=True, capture_output=True, check=True)

    run()
    registry = json.loads((agents / "mcp.json").read_text())["mcpServers"]
    defaults = {name for name, item in registry.items() if item["enabled"]}
    assert defaults == {"context7", "playwright", "research-mcp"}, defaults
    claude = json.loads((work / ".mcp.json").read_text())["mcpServers"]
    assert set(claude) == defaults and all("description" not in item and item["type"] in {"stdio", "http"} for item in claude.values())
    assert json.loads((work / ".claude/settings.local.json").read_text())["enabledMcpjsonServers"] == ["context7", "outside", "playwright", "research-mcp"]
    assert (agents / ".playwright-reader.json").is_file()
    kimi = work / ".kimi-code/mcp.json"
    assert stat.S_IMODE(kimi.stat().st_mode) == 0o600
    assert json.loads(kimi.read_text())["mcpServers"]["security-mcp"]["enabled"] is False
    codex = tomllib.loads((work / ".codex/config.toml").read_text())["mcp_servers"]
    assert codex["context7"]["enabled"] is True and codex["security-mcp"]["enabled"] is False
    assert "atlassian" not in codex and "exa" not in codex and codex["greptile"]["bearer_token_env_var"] == "GREPTILE_API_KEY"
    original_registry = (agents / "mcp.json").read_bytes()
    document = json.loads(original_registry)
    document["mcpServers"]["context7"]["env"] = {"FIXTURE_ENV": "value"}
    (agents / "mcp.json").write_text(json.dumps(document))
    run()
    with (work / ".codex/config.toml").open("rb") as stream:
        assert tomllib.load(stream)["mcp_servers"]["context7"]["env"] == {"FIXTURE_ENV": "value"}
    (agents / "mcp.json").write_bytes(original_registry)
    run()

    for field, value, message in (
        ("command", "curl", "incompatible field"),
        ("headers", {"X-Fixture": "value"}, "cannot be represented by Codex"),
    ):
        document = json.loads(original_registry)
        document["mcpServers"]["linear"][field] = value
        (agents / "mcp.json").write_text(json.dumps(document))
        rejected = subprocess.run(
            [sys.executable, str(agents / "mcp.py")], cwd=work,
            text=True, capture_output=True,
        )
        assert rejected.returncode and message in rejected.stderr
    (agents / "mcp.json").write_bytes(original_registry)
    outputs = [work / ".mcp.json", work / ".codex/config.toml", kimi, agents / ".playwright-reader.json"]
    before = {path: path.read_bytes() for path in outputs}
    (work / ".claude/settings.local.json").write_text('{"enabledMcpjsonServers": {}}')
    malformed = subprocess.run(
        [sys.executable, str(agents / "mcp.py")], cwd=work,
        text=True, capture_output=True,
    )
    assert malformed.returncode and "must be a string list" in malformed.stderr
    assert {path: path.read_bytes() for path in outputs} == before
    (work / ".claude/settings.local.json").write_text(json.dumps({"keep": True, "enabledMcpjsonServers": ["outside"]}))
    registry_mode = stat.S_IMODE((agents / "mcp.json").stat().st_mode)
    run("enable", "security-mcp")
    assert json.loads((agents / "mcp.json").read_text())["mcpServers"]["security-mcp"]["enabled"] is True, (agents / "mcp.json").read_text()
    assert stat.S_IMODE((agents / "mcp.json").stat().st_mode) == registry_mode
    run("disable", "context7")
    assert "context7" not in json.loads((work / ".mcp.json").read_text())["mcpServers"]
    generated = json.loads((work / ".mcp.json").read_text())["mcpServers"]["security-mcp"]
    assert generated["args"][0] == str((agents / "mcp-servers/security-mcp/dist/server.js").resolve()) and "${REPO_ROOT}" not in repr(generated), generated
    run("enable", "greptile")
    kimi_servers = json.loads(kimi.read_text())["mcpServers"]
    assert kimi_servers["greptile"]["enabled"] is False
    subprocess.run(
        [sys.executable, str(agents / "mcp.py")], cwd=work, check=True,
        env={**dict(__import__("os").environ), "GREPTILE_API_KEY": "fixture-key"},
    )
    greptile = json.loads(kimi.read_text())["mcpServers"]["greptile"]
    assert greptile["headers"]["Authorization"] == "Bearer fixture-key"
    assert "enabled" not in greptile

    before = {path: path.read_bytes() for path in outputs}
    registry_before = (agents / "mcp.json").read_bytes()
    failed = subprocess.run(
        [sys.executable, str(agents / "mcp.py"), "enable", "playwright-reader"], cwd=work,
        text=True, capture_output=True,
    )
    assert failed.returncode and "no extension is installed" in failed.stderr
    assert {path: path.read_bytes() for path in outputs} == before
    assert (agents / "mcp.json").read_bytes() == registry_before

    document = json.loads(registry_before)
    document["mcpServers"]["greptile"]["url"] = "${REPO_ROOT}/secret"
    (agents / "mcp.json").write_text(json.dumps(document))
    rejected = subprocess.run(
        [sys.executable, str(agents / "mcp.py")], cwd=work,
        text=True, capture_output=True,
    )
    assert rejected.returncode and "outside command, cwd, or args" in rejected.stderr
    (agents / "mcp.json").write_bytes(registry_before)

    document = json.loads(registry_before)
    document["mcpServers"]["context7"]["command"] = "${REPO_ROOT}/.agents/mcp.json"
    (agents / "mcp.json").write_text(json.dumps(document))
    rejected = subprocess.run(
        [sys.executable, str(agents / "mcp.py")], cwd=work,
        text=True, capture_output=True,
    )
    assert rejected.returncode and "non-executable repository command" in rejected.stderr
    (agents / "mcp.json").write_bytes(registry_before)
    print("MCP registry tests passed.")
finally:
    shutil.rmtree(work)
PY
