#!/usr/bin/env bash
# Drive the OpenCode renderer against one rule and one persona of every shape.
#
# The fixture is written here, not read from this repository, so the suite says
# the same thing in a satellite that runs a different permission list and a
# different registry. The carrier checks read the real sources, which are
# tracked, so they run in a fresh checkout; only the generated-file comparison
# needs `mcp.py sync` to have run.
set -euo pipefail
# A caller such as `git rebase -x` exports these; nothing here may inherit them.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$repo" <<'PY'
import json
import re
import sys
import tempfile
from pathlib import Path

source = Path(sys.argv[1])
sys.path.insert(0, str(source / ".agents"))
import mcp_opencode

fails = 0


def check(label, ok, detail=""):
    global fails
    if ok:
        print(f"ok    {label}")
    else:
        print(f"FAIL  {label}" + (f": {detail}" if detail else ""))
        fails += 1


# --- permission translation ------------------------------------------------

settings = {
    "ask": [
        "Bash(git push:*)",
        "Bash(vercel)",
        "mcp__linear",
        "mcp__plugin_vercel_vercel__*",
        "mcp__playwright-reader__*",
        "mcp__my.server__*",
        "Artifact",
    ],
    "deny": ["mcp__linear__delete*"],
}
rules = mcp_opencode.permission_rules(settings)
by_key = {(rule["action"], rule["resource"]): rule["effect"] for rule in rules}

check("a shell prefix becomes `prefix *`",
      by_key.get(("shell", "git push *")) == "ask")
check("a bare shell rule stays exact",
      by_key.get(("shell", "vercel")) == "ask")
check("a whole MCP server covers every tool",
      by_key.get(("linear_*", "*")) == "ask")
check("an MCP wildcard tool keeps the server prefix",
      by_key.get(("plugin_vercel_vercel_*", "*")) == "ask")
check("an unsupported character in a server name becomes `_`, a hyphen is kept",
      by_key.get(("my_server_*", "*")) == "ask"
      and by_key.get(("playwright-reader_*", "*")) == "ask", rules)
check("an MCP deny names the tool",
      by_key.get(("linear_delete*", "*")) == "deny")
check("the Claude-only Artifact rule is dropped",
      not any(action == "Artifact" for action, _ in by_key), rules)

effects = [rule["effect"] for rule in rules]
check("every deny follows every ask",
      effects.index("deny") > max(i for i, effect in enumerate(effects) if effect == "ask"))

try:
    mcp_opencode.permission_rules({"ask": ["Read(./.env)"], "deny": []})
except SystemExit as error:
    check("an untranslatable rule fails by name", "no OpenCode translation" in str(error))
else:
    check("an untranslatable rule fails by name", False, "no error raised")

# --- agents, style, and servers -------------------------------------------

work = Path(tempfile.mkdtemp(prefix="opencode-test-"))
(work / ".agents/claude").mkdir(parents=True)
(work / ".agents/personas").mkdir()
(work / ".agents/claude/settings.json").write_text(json.dumps({"permissions": settings}))
(work / ".agents/claude/output-style.md").write_text(
    "---\nname: fixture\ndescription: Fixture style\n---\n\nCounter-pressure body.\n")
(work / ".agents/personas/reader.md").write_text(
    "---\nname: reader\ndescription: Reads only.\ntools: [\"Read\", \"Glob\"]\n---\n\n# Reader\n\nReads.\n")
(work / ".agents/personas/writer.md").write_text(
    "---\nname: writer\ndescription: Edits and runs.\n"
    "tools: [\"Read\", \"Write\", \"Bash\", \"mcp__context7__*\"]\n"
    "disallowedTools: [\"mcp__context7__delete*\"]\nmcpServers: [\"context7\"]\n"
    "---\n\n# Writer\n\nWrites.\n")

servers = {
    "on-stdio": {
        "enabled": True, "type": "stdio", "command": "npx", "args": ["-y", "fixture"],
        "env": {"TOKEN": "${FIXTURE_TOKEN}"},
    },
    "on-remote": {
        "enabled": True, "type": "http", "url": "https://fixture.invalid/mcp",
        "headers": {"Authorization": "Bearer ${FIXTURE_TOKEN}"},
    },
    "on-sse": {"enabled": True, "type": "sse", "url": "https://fixture.invalid/sse"},
    "off-stdio": {"enabled": False, "type": "stdio", "command": "npx", "args": ["-y", "off"]},
    "context7": {"enabled": True, "type": "stdio", "command": "npx", "args": ["-y", "ctx"]},
}
document, instructions = mcp_opencode.payload(work, servers).values()

check("a stdio server renders local with one command list",
      document["mcp"]["servers"]["on-stdio"] == {
          "type": "local", "command": ["npx", "-y", "fixture"],
          "environment": {"TOKEN": "{env:FIXTURE_TOKEN}"}})
check("a remote server renders remote, with its token translated",
      document["mcp"]["servers"]["on-remote"] == {
          "type": "remote", "url": "https://fixture.invalid/mcp",
          "headers": {"Authorization": "Bearer {env:FIXTURE_TOKEN}"}})
check("an SSE server is left out rather than rendered as unreachable",
      "on-sse" not in document["mcp"]["servers"])
check("a disabled server is omitted", "off-stdio" not in document["mcp"]["servers"])
check("the style frontmatter is stripped", instructions == "Counter-pressure body.")
check("the config points at the instruction file",
      document["instructions"] == [mcp_opencode.INSTRUCTIONS])

reader = document["agents"]["reader"]["permissions"]
writer = document["agents"]["writer"]["permissions"]
check("a persona opens with a deny, because OpenCode's base allows everything",
      reader[0] == {"action": "*", "resource": "*", "effect": "deny"})
check("a persona grants only its own tools",
      {"action": "read", "resource": "*", "effect": "allow"} in reader
      and not any(rule["action"] == "edit" and rule["effect"] == "allow" for rule in reader))
check("a persona without shell gets no shell rule at all, not even an ask",
      not any(rule["action"] == "shell" for rule in reader), reader)
check("an outward ask is repeated after the persona's shell allow",
      [rule["resource"] for rule in writer].index("git push *")
      > [rule["action"] for rule in writer].index("shell"), writer)
check("a disallowed tool is denied",
      {"action": "context7_delete*", "resource": "*", "effect": "deny"} in writer)
check("a persona naming its servers denies the others",
      {"action": "on-stdio_*", "resource": "*", "effect": "deny"} in writer
      and not any(rule["action"] == "context7_*" and rule["effect"] == "deny" for rule in writer))
check("a persona carries its body as the system prompt",
      document["agents"]["reader"]["system"] == "# Reader\n\nReads.")

# --- the carrier itself, from tracked sources ------------------------------

settings = json.loads((source / mcp_opencode.SETTINGS).read_text())["permissions"]
carried = mcp_opencode.permission_rules(settings)
resources = {rule["resource"] for rule in carried if rule["action"] == "shell"}
check("the harness's shell rules reach the config",
      {"git push *", "vercel"} <= resources, sorted(resources)[:5])
check("the harness's Supabase rules reach the config",
      "supabase db push *" in resources)
check("the harness's destructive MCP rules reach the config as denies",
      {"action": "linear_delete*", "resource": "*", "effect": "deny"} in carried)
check("the style renders", bool(mcp_opencode.style(source)))

generated = source / mcp_opencode.CONFIG
if generated.exists():
    current = json.loads(generated.read_text())
    check("the generated rules match a fresh render",
          current["permissions"] == carried, "run `python3 .agents/mcp.py sync`")
    scoped = {name: {"enabled": True} for name in current["mcp"]["servers"]}
    check("the generated agents match a fresh render",
          current["agents"] == mcp_opencode.agents(source, settings, scoped),
          "run `python3 .agents/mcp.py sync`")
    check("the generated instructions match the style",
          (source / mcp_opencode.INSTRUCTIONS).read_text().strip() == mcp_opencode.style(source),
          "run `python3 .agents/mcp.py sync`")
    names = {
        re.search(r"^name:\s*(\S+)", path.read_text(), re.M).group(1)
        for path in (source / mcp_opencode.PERSONAS).glob("*.md")
    }
    check("every persona reaches the config", names == set(current["agents"]),
          sorted(names ^ set(current["agents"])))
else:
    print(f"skip  {mcp_opencode.CONFIG} is absent; run `python3 .agents/mcp.py sync`")

print()
if fails:
    print(f"{fails} FAILURE(S)")
    sys.exit(1)
print("ALL PASS")
PY
