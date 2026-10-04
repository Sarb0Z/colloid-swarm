#!/usr/bin/env bash
# Drive the MCP registry generator against one server of every shape it renders.
#
# The registry under test is a fixture written here, not this repository's own
# .agents/mcp.json. Asserting the carrier's server list makes the suite fail in
# every satellite that ships a different set — the servers are a per-repository
# choice, while mcp.py's behaviour is what this file is for. Only
# `playwright-reader` keeps a real name, because mcp.py special-cases it.
#
# The browser settings come from the fixture's own .agents/config.json. The
# proxy variables are removed from every run, so an operator's endpoint never
# reaches these assertions.
set -euo pipefail
# A caller such as `git rebase -x` exports these; the git calls below must
# reach only their own temporary repositories.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$repo" <<'PY'
import json, os, shutil, stat, subprocess, sys, tempfile, tomllib
from pathlib import Path

source = Path(sys.argv[1])
work = Path(tempfile.mkdtemp(prefix="mcp-test-"))

# One server per shape mcp.py has to render or refuse.
FIXTURE = {"mcpServers": {
    # stdio, on, with a Codex startup timeout and a provenance declaration.
    "fx-docs": {
        "description": "Fixture docs server.", "sources": ["query-docs"],
        "enabled": True, "codex_startup_timeout_sec": 30,
        "type": "stdio", "command": "npx", "args": ["-y", "fx-docs"]},
    # stdio, on, no timeout — so an absent timeout is distinguishable.
    "fx-plain": {
        "description": "Fixture plain server.", "enabled": True,
        "type": "stdio", "command": "npx", "args": ["-y", "fx-plain"]},
    # Repository-owned: ${REPO_ROOT} must expand and the target must exist.
    "fx-owned": {
        "description": "Fixture repository-owned server.", "enabled": False,
        "type": "stdio", "command": "node",
        "args": ["${REPO_ROOT}/.agents/mcp-servers/fx-owned/dist/server.js"],
        "cwd": "${REPO_ROOT}/.agents/mcp-servers/fx-owned"},
    # http with a bearer token env var: Codex renders bearer_token_env_var.
    "fx-token": {
        "description": "Fixture token server.", "enabled": False, "type": "http",
        "url": "https://fixture.invalid/mcp",
        "headers": {"Authorization": "Bearer ${FX_TOKEN}"}},
    # http, outward, no headers — the shape the Codex-incompatibility cases mutate.
    "fx-outward": {
        "description": "Fixture outward server.", "enabled": False, "outward": True,
        "type": "http", "url": "https://fixture.invalid/outward"},
    # sse and codex_enabled:false are the two ways to stay out of Codex entirely.
    "fx-sse": {
        "description": "Fixture sse server.", "enabled": False, "codex_enabled": False,
        "type": "sse", "url": "https://fixture.invalid/sse"},
    "fx-nocodex": {
        "description": "Fixture Codex-excluded server.", "sources": ["*"],
        "enabled": False, "codex_enabled": False, "type": "http",
        "url": "https://fixture.invalid/mcp?key=${FX_KEY}"},
    # The one name mcp.py resolves by hand, for the browser-extension gate.
    "playwright-reader": {
        "description": "Fixture reader.", "sources": ["browser_navigate"],
        "enabled": False, "type": "stdio", "command": "npx",
        "args": ["-y", "fx-reader", "--config", "${REPO_ROOT}/.agents/.playwright-reader.json"]},
    # The generated browser config does not exist in a fresh checkout.
    "fx-browser": {
        "description": "Fixture browser.", "enabled": False, "type": "stdio", "command": "npx",
        "args": ["-y", "fx-browser", "--config", "${REPO_ROOT}/.agents/.browser/playwright.json"]},
}}
ON = {"fx-docs", "fx-plain"}

try:
    agents = work / ".agents"
    (agents / "codex").mkdir(parents=True)
    for relative in ("mcp.py", "mcp_codex.py", "mcp_playwright.py"):
        shutil.copy2(source / ".agents" / relative, agents / relative)
    (agents / "mcp.py").chmod(0o755)
    # A minimal Codex base, so the rendered mcp_servers tables are all that is
    # asserted and the carrier's own Codex configuration is not read.
    (agents / "codex/config.toml").write_text('model = "fixture"\n')
    (agents / "mcp.json").write_text(json.dumps(FIXTURE, indent=2) + "\n")
    for name in ("fx-owned",):
        (agents / "mcp-servers" / name / "dist").mkdir(parents=True)
        (agents / "mcp-servers" / name / "dist/server.js").write_text("// fixture\n")
    (work / ".kimi").mkdir()
    (work / ".claude").mkdir()
    (work / ".claude/settings.local.json").write_text(
        json.dumps({"keep": True, "enabledMcpjsonServers": ["outside"]}))

    PROXY_VARS = {"PLAYWRIGHT_PROXY", "FX_PROXY"}
    base_env = {key: value for key, value in os.environ.items() if key not in PROXY_VARS}

    def run(*args, **env):
        return subprocess.run(
            [sys.executable, str(agents / "mcp.py"), *args], cwd=work, text=True,
            capture_output=True, check=True, env={**base_env, **env})

    def refuse(*args, **env):
        return subprocess.run(
            [sys.executable, str(agents / "mcp.py"), *args], cwd=work, text=True,
            capture_output=True, env={**base_env, **env})

    run()
    registry = json.loads((agents / "mcp.json").read_text())["mcpServers"]
    defaults = {name for name, item in registry.items() if item["enabled"]}
    assert defaults == ON, defaults
    claude = json.loads((work / ".mcp.json").read_text())["mcpServers"]
    assert set(claude) == defaults
    # Metadata is registry-only and must never reach a host's configuration.
    for item in claude.values():
        assert item["type"] in {"stdio", "http"}
        assert not ({"description", "sources", "outward", "codex_startup_timeout_sec"} & set(item)), item
    assert json.loads((work / ".claude/settings.local.json").read_text())["enabledMcpjsonServers"] \
        == sorted(defaults | {"outside"})
    assert (agents / ".playwright-reader.json").is_file()

    kimi = work / ".kimi-code/mcp.json"
    assert stat.S_IMODE(kimi.stat().st_mode) == 0o600
    kimi_records = json.loads(kimi.read_text())["mcpServers"]
    assert kimi_records["fx-owned"]["enabled"] is False
    assert all("codex_startup_timeout_sec" not in item for item in kimi_records.values())
    assert all("sources" not in item for item in kimi_records.values())

    codex = tomllib.loads((work / ".codex/config.toml").read_text())["mcp_servers"]
    assert codex["fx-docs"]["enabled"] is True and codex["fx-owned"]["enabled"] is False
    assert codex["fx-docs"]["startup_timeout_sec"] == 30
    assert "startup_timeout_sec" not in codex["fx-plain"]
    assert "fx-sse" not in codex and "fx-nocodex" not in codex
    assert codex["fx-token"]["bearer_token_env_var"] == "FX_TOKEN"

    original_registry = (agents / "mcp.json").read_bytes()

    def mutate(server, field, value):
        document = json.loads(original_registry)
        document["mcpServers"][server][field] = value
        (agents / "mcp.json").write_text(json.dumps(document))

    mutate("fx-docs", "env", {"FIXTURE_ENV": "value"})
    run()
    with (work / ".codex/config.toml").open("rb") as stream:
        assert tomllib.load(stream)["mcp_servers"]["fx-docs"]["env"] == {"FIXTURE_ENV": "value"}
    (agents / "mcp.json").write_bytes(original_registry)
    run()

    for field, value, message in (
        ("command", "curl", "incompatible field"),
        ("headers", {"X-Fixture": "value"}, "cannot be represented by Codex"),
        ("codex_startup_timeout_sec", 0, "must be a positive integer"),
        ("sources", [], "must be a non-empty list"),
        ("sources", ["*", "fetch"], "cannot mix"),
    ):
        mutate("fx-outward", field, value)
        rejected = refuse()
        assert rejected.returncode and message in rejected.stderr, (field, rejected.stderr)
    (agents / "mcp.json").write_bytes(original_registry)

    outputs = [work / ".mcp.json", work / ".codex/config.toml", kimi,
               agents / ".playwright-reader.json"]
    before = {path: path.read_bytes() for path in outputs}
    (work / ".claude/settings.local.json").write_text('{"enabledMcpjsonServers": {}}')
    malformed = refuse()
    assert malformed.returncode and "must be a string list" in malformed.stderr
    assert {path: path.read_bytes() for path in outputs} == before
    (work / ".claude/settings.local.json").write_text(
        json.dumps({"keep": True, "enabledMcpjsonServers": ["outside"]}))

    registry_mode = stat.S_IMODE((agents / "mcp.json").stat().st_mode)
    run("enable", "fx-owned")
    assert json.loads((agents / "mcp.json").read_text())["mcpServers"]["fx-owned"]["enabled"] is True
    assert stat.S_IMODE((agents / "mcp.json").stat().st_mode) == registry_mode
    run("disable", "fx-docs")
    assert "fx-docs" not in json.loads((work / ".mcp.json").read_text())["mcpServers"]
    generated = json.loads((work / ".mcp.json").read_text())["mcpServers"]["fx-owned"]
    assert generated["args"][0] == str((agents / "mcp-servers/fx-owned/dist/server.js").resolve())
    assert "${REPO_ROOT}" not in repr(generated), generated

    # An unset env var leaves the record disabled rather than shipping a literal
    # `${...}` to a host that would send it as a credential.
    run("enable", "fx-token")
    assert json.loads(kimi.read_text())["mcpServers"]["fx-token"]["enabled"] is False
    run(FX_TOKEN="fixture-key")
    token = json.loads(kimi.read_text())["mcpServers"]["fx-token"]
    assert token["headers"]["Authorization"] == "Bearer fixture-key"
    assert "enabled" not in token

    # playwright-reader without an installed extension must refuse and change
    # nothing — neither the generated outputs nor the registry's own toggle.
    before = {path: path.read_bytes() for path in outputs}
    registry_before = (agents / "mcp.json").read_bytes()
    failed = refuse("enable", "playwright-reader", FX_TOKEN="fixture-key")
    assert failed.returncode and "no extension is installed" in failed.stderr
    assert {path: path.read_bytes() for path in outputs} == before
    assert (agents / "mcp.json").read_bytes() == registry_before

    # ...and must succeed once one is installed, so the refusal above is the
    # gate working rather than the fixture simply lacking a directory.
    extension = agents / "browser-extensions/fx-blocker"
    extension.mkdir(parents=True)
    (extension / "manifest.json").write_text('{"manifest_version": 3}')
    run("enable", "playwright-reader", FX_TOKEN="fixture-key")
    reader = json.loads((agents / ".playwright-reader.json").read_text())
    # mcp.py resolves its own root, so the expected path is the physical one.
    assert reader["browser"]["launchOptions"]["args"] == \
        [f"--load-extension={extension.resolve()}"], reader
    run("disable", "playwright-reader", FX_TOKEN="fixture-key")
    shutil.rmtree(agents / "browser-extensions")
    (agents / "mcp.json").write_bytes(registry_before)
    run(FX_TOKEN="fixture-key")

    registry_before = (agents / "mcp.json").read_bytes()
    for server, field, value, message in (
        ("fx-token", "url", "${REPO_ROOT}/secret", "outside command, cwd, or args"),
        ("fx-docs", "command", "${REPO_ROOT}/.agents/mcp.json", "non-executable repository command"),
        ("fx-plain", "args", ["${REPO_ROOT}/.agents/missing.js"], "missing repository-owned args"),
    ):
        mutate(server, field, value)
        rejected = refuse()
        assert rejected.returncode and message in rejected.stderr, (server, rejected.stderr)
        (agents / "mcp.json").write_bytes(registry_before)

    # config.json.example documents the generator's defaults; drift misleads
    # every operator who copies it.
    sys.path.insert(0, str(agents))
    import mcp_playwright
    example = json.loads((source / ".agents/config.json.example").read_text())
    assert example["browser"] == mcp_playwright.DEFAULTS, example["browser"]

    # The default browser: with nothing configured the server keeps its own
    # profile, context, and network, as it did before the config existed.
    browser_dir = agents / ".browser"
    browser_path = browser_dir / "playwright.json"
    run()
    assert json.loads(browser_path.read_text()) == {
        "browser": {"browserName": "chromium", "launchOptions": {"channel": "chrome"}},
        "webmcp": False}, browser_path.read_text()
    assert stat.S_IMODE(browser_path.stat().st_mode) == 0o600
    assert stat.S_IMODE(browser_dir.stat().st_mode) == 0o700
    assert (browser_dir / ".gitignore").read_text() == "*\n"
    assert json.loads((agents / ".playwright-reader.json").read_text())["webmcp"] is False

    def browser_settings(**values):
        (agents / "config.json").write_text(json.dumps({"browser": values}))

    def browser():
        return json.loads(browser_path.read_text())["browser"]

    browser_settings(user_agent="Fixture/1", locale="en-GB", timezone="Europe/London",
                     viewport={"width": 1280, "height": 800}, headless=True)
    run()
    assert browser()["contextOptions"] == {
        "userAgent": "Fixture/1", "locale": "en-GB", "timezoneId": "Europe/London",
        "viewport": {"width": 1280, "height": 800}}, browser()
    assert browser()["launchOptions"]["headless"] is True
    for values, message in (
        ({"viewport": {"width": 0, "height": 1}}, "browser.viewport"),
        ({"headless": "yes"}, "browser.headless"),
        ({"surprise": 1}, "unknown browser setting"),
        ({"proxy_env": "not a name"}, "browser.proxy_env"),
    ):
        browser_settings(**values)
        rejected = refuse()
        assert rejected.returncode and message in rejected.stderr, (values, rejected.stderr)
    (agents / "config.json").unlink()

    (agents / "policy.json").write_text(json.dumps({"browser": {"proxy": True}}))
    rejected = refuse()
    assert rejected.returncode and "not the tracked .agents/policy.json" in rejected.stderr
    (agents / "policy.json").unlink()

    alternate = work / "alternate-settings.json"
    alternate.write_text(json.dumps({"browser": {"locale": "fr-FR"}}))
    run("sync", "--settings", str(alternate))
    assert browser()["contextOptions"] == {"locale": "fr-FR"}
    assert refuse("sync", "--settings").returncode
    assert refuse("sync", "--bogus").returncode

    # A synced profile: the server launches it without the mock keychain, at
    # an absolute path, so the copied Keychain-sealed cookies decrypt.
    profile = browser_dir / "profile"
    (profile / "Default").mkdir(parents=True)
    (profile / "Default/Cookies").write_bytes(b"")
    run()
    assert browser()["userDataDir"] == str(profile.resolve()), browser()
    assert browser()["launchOptions"]["ignoreDefaultArgs"] == ["--use-mock-keychain"]
    shutil.rmtree(profile)
    run()
    assert "userDataDir" not in browser() and "ignoreDefaultArgs" not in browser()["launchOptions"]

    # Proxy: explicit, fed from the environment, one stored session token.
    token_path = browser_dir / "session-token"
    browser_settings(proxy=True, proxy_env="FX_PROXY", proxy_bypass=["*.internal.test"])
    before = browser_path.read_bytes()
    absent = refuse()
    assert absent.returncode and "$FX_PROXY is not set" in absent.stderr, absent.stderr
    assert browser_path.read_bytes() == before
    endpoint = "http://user-{session}:p%40ss-secret@proxy.fixture.test:8080"
    shown = run(FX_PROXY=endpoint)
    proxy = browser()["launchOptions"]["proxy"]
    token = token_path.read_text().strip()
    assert proxy == {
        "server": "http://proxy.fixture.test:8080", "username": f"user-{token}",
        "password": "p@ss-secret",
        "bypass": "localhost,*.localhost,127.0.0.1,[::1],*.internal.test"}, proxy
    assert stat.S_IMODE(token_path.stat().st_mode) == 0o600
    assert stat.S_IMODE(browser_path.stat().st_mode) == 0o600
    assert "secret" not in shown.stdout + shown.stderr
    run(FX_PROXY=endpoint)
    assert token_path.read_text().strip() == token, "the session token must persist"
    run("sync", "--new-proxy-session", FX_PROXY=endpoint)
    assert token_path.read_text().strip() != token, "--new-proxy-session must rotate the token"
    for value, message in (
        ("http://user:secret/host", "is not a proxy URL"),
        ("http://user:secret@host", "is not a proxy URL"),
        ("ftp://user:secret@host:21", "must use http, https, or socks5"),
        ("socks5://user:secret@host:1080", "Chromium cannot send"),
        ("http://user:secret@host:8080/path", "is not a proxy URL"),
    ):
        rejected = refuse(FX_PROXY=value)
        assert rejected.returncode and message in rejected.stderr, (value, rejected.stderr)
        assert "secret" not in rejected.stdout + rejected.stderr, rejected.stderr
    (agents / "config.json").unlink()
    run("sync", "--new-proxy-session")
    assert not token_path.exists() and "proxy" not in browser()["launchOptions"]

    # Git must ignore the generated file; a tracked one is refused.
    subprocess.run(["git", "init", "-q", str(work)], check=True)
    subprocess.run(["git", "-C", str(work), "add", "-f", str(browser_path)], check=True)
    rejected = refuse()
    assert rejected.returncode and "Git does not ignore it" in rejected.stderr, rejected.stderr
    subprocess.run(["git", "-C", str(work), "rm", "-q", "--cached", str(browser_path)], check=True)
    run()

    print("MCP registry tests passed.")
finally:
    shutil.rmtree(work)
PY
