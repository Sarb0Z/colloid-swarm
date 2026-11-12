"""OpenCode host rendering: permissions, agents, and the output style.

OpenCode reads the same harness through its own syntax. Rendering the
translation — rather than hand-writing it — keeps this host from drifting from
the two files Claude Code reads directly, `.agents/claude/settings.json` and
`.agents/personas/*.md`, and it is what `test-opencode.sh` holds in both
directions.

The output is a generated connection file: `.agents/mcp.py` writes it beside
the configs it already emits for Claude, Kimi, and Codex.
"""

import json
import re

import mcp_hosts

SETTINGS = ".agents/claude/settings.json"
PERSONAS = ".agents/personas"
STYLE = ".agents/claude/output-style.md"
CONFIG = ".opencode/opencode.json"
INSTRUCTIONS = ".opencode/instructions/colloid.md"

# Rules OpenCode cannot express: `Artifact` names a Claude tool with no
# counterpart here, and the artifact tool is switched off in user settings.
UNTRANSLATABLE = frozenset({"Artifact"})

# Persona tools with no OpenCode action. `TaskStop` stops a background shell;
# OpenCode leaves that to the operator's interrupt, so the grant is dropped
# rather than silently widening the agent.
UNMAPPED_TOOLS = frozenset({"TaskStop"})

# Claude tool name -> OpenCode permission action. Every other name a persona
# grants has to be listed here; an unknown one fails the render rather than
# disappearing.
ACTIONS = {
    "Read": "read",
    "Glob": "glob",
    "Grep": "grep",
    "Bash": "shell",
    "Write": "edit",
    "Edit": "edit",
    "MultiEdit": "edit",
    "NotebookEdit": "edit",
    "WebFetch": "webfetch",
    "WebSearch": "websearch",
    "Task": "subagent",
    "Agent": "subagent",
    "Skill": "skill",
    "LSP": "lsp",
}

SHELL = re.compile(r"^Bash\((.+)\)$")
MCP_PREFIX = "mcp__"
ENV = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
BLOCK_SCALAR = (">", "|")


def _fail(message):
    raise SystemExit(f"mcp: {message}")


def _frontmatter(path, text):
    """Return the frontmatter fields and the body of a Markdown document."""
    if not text.startswith("---\n"):
        return {}, text.strip()
    end = text.find("\n---\n", 4)
    if end < 0:
        return {}, text.strip()
    fields = {}
    for line in text[4:end].splitlines():
        key, separator, value = line.partition(":")
        if not separator:
            continue
        key, value = key.strip(), value.strip()
        # A block scalar or a comment would reach OpenCode as literal text and
        # ship an agent with a useless field. Refuse instead of guessing.
        if value[:1] in BLOCK_SCALAR or " #" in value:
            _fail(f"{path} uses a YAML form this adapter does not parse: {key}: {value}")
        fields[key] = value.strip("\"'")
    return fields, text[end + 5:].strip()


def _normalize(name):
    """OpenCode's MCP tool naming: anything but alphanumerics becomes `_`."""
    return re.sub(r"[^A-Za-z0-9_*-]", "_", name)


def _mcp_action(resource):
    inner = resource[len(MCP_PREFIX):]
    server, separator, tool = inner.partition("__")
    # A rule naming the whole server has to cover every tool it exposes.
    return _normalize(server) + "_" + _normalize(tool if separator else "*")


def _shell_action(resource):
    match = SHELL.fullmatch(resource)
    if match is None:
        _fail(f"permission rule {resource!r} has no OpenCode translation")
    inner = match.group(1)
    # Claude's `prefix:*` covers the bare command as well; OpenCode spells that
    # coverage `prefix *`, which matches with and without arguments.
    return inner[:-2] + " *" if inner.endswith(":*") else inner


def permission_rules(settings):
    """Translate Claude's ask and deny lists into OpenCode's ordered rules."""
    rules = []
    # OpenCode takes the last matching rule, so every deny follows every ask.
    # That reproduces Claude's deny-over-ask precedence.
    for effect in ("ask", "deny"):
        for resource in settings.get(effect, []):
            if resource in UNTRANSLATABLE:
                continue
            if resource.startswith(MCP_PREFIX):
                rules.append({"action": _mcp_action(resource), "resource": "*", "effect": effect})
            else:
                rules.append({"action": "shell", "resource": _shell_action(resource), "effect": effect})
    return rules


def _list(fields, key, path):
    raw = fields.get(key)
    if raw is None:
        return []
    try:
        value = json.loads(raw)
    except ValueError:
        _fail(f"{path}: {key} is not a JSON list")
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        _fail(f"{path}: {key} must be a list of strings")
    return value


def _tool_allows(tools, path):
    """The actions a persona's tool list grants, as OpenCode allow rules."""
    allows = []
    for name in tools:
        if name in UNMAPPED_TOOLS:
            continue
        if name.startswith(MCP_PREFIX):
            allows.append({"action": _mcp_action(name), "resource": "*", "effect": "allow"})
            continue
        action = ACTIONS.get(name)
        if action is None:
            _fail(f"{path}: tool {name!r} has no OpenCode action")
        allows.append({"action": action, "resource": "*", "effect": "allow"})
    return allows


def _reaches(action, allowed):
    """Whether a global rule can fire for an action this persona holds."""
    return any(re.fullmatch(re.escape(pattern).replace(r"\*", ".*"), action)
               for pattern in allowed)


def _agent_permissions(fields, path, settings, servers):
    """A persona's grants, then the repository's outward rules on top.

    OpenCode's base policy allows every action, so an allowlist has to open
    with a deny. The global ask and deny rules are repeated last, because
    OpenCode evaluates global rules before an agent's and the persona's `shell`
    allow would otherwise outrank the outward-mutation ask. A rule is repeated
    only for an action the persona holds: repeating the rest would grant a
    read-only persona an `ask` on a command it was denied.
    """
    tools = _list(fields, "tools", path)
    if not tools:
        _fail(f"{path} grants no tools; OpenCode would give the agent everything")
    allows = _tool_allows(tools, path)
    rules = [{"action": "*", "resource": "*", "effect": "deny"}]
    rules.extend(allows)
    for name in _list(fields, "disallowedTools", path):
        rules.append({"action": _mcp_action(name), "resource": "*", "effect": "deny"})
    scoped = _list(fields, "mcpServers", path)
    if scoped:
        for name in sorted(servers):
            if name not in scoped and servers[name]["enabled"]:
                rules.append({"action": _normalize(name) + "_*", "resource": "*", "effect": "deny"})
    held = {rule["action"] for rule in allows}
    rules.extend(rule for rule in permission_rules(settings) if _reaches(rule["action"], held))
    return rules


def _env(value):
    """Translate the registry's `${NAME}` into OpenCode's `{env:NAME}`."""
    if isinstance(value, str):
        return ENV.sub(r"{env:\1}", value)
    if isinstance(value, list):
        return [_env(item) for item in value]
    if isinstance(value, dict):
        return {key: _env(item) for key, item in value.items()}
    return value


def server_config(name, server):
    """One registry server in OpenCode's `mcp.servers` shape."""
    if server.get("type") == "stdio":
        record = {
            "type": "local",
            "command": _env([server["command"], *server.get("args", [])]),
        }
        if "cwd" in server:
            record["cwd"] = _env(server["cwd"])
        if server.get("env"):
            record["environment"] = _env(dict(server["env"]))
        return record
    if server.get("type") == "http":
        url = _env(server["url"])
        if ENV.search(url):
            _fail(f"{name} has an environment placeholder in its URL, which OpenCode does not expand")
        record = {"type": "remote", "url": url}
        if server.get("headers"):
            record["headers"] = _env(dict(server["headers"]))
        return record
    # OpenCode's remote transport is Streamable HTTP only. An SSE endpoint is
    # left out rather than rendered as something it will not reach.
    return None


def agents(repo, settings, servers):
    """The personas as OpenCode subagents."""
    result = {}
    for path in sorted((repo / PERSONAS).glob("*.md")):
        fields, body = _frontmatter(path, path.read_text(encoding="utf-8"))
        name = fields.get("name", path.stem)
        description = fields.get("description")
        if not name or not description or not body:
            _fail(f"{PERSONAS}/{path.name} needs a name, a description, and a body")
        # Model and effort are left to the invocation, as Codex's TOMLs leave
        # them: a subagent inherits the session's model, and pinning a provider
        # here would fail on a machine that never authenticated it.
        result[name] = {
            "description": description,
            "mode": "subagent",
            "system": body,
            "permissions": _agent_permissions(fields, f"{PERSONAS}/{path.name}", settings, servers),
        }
    if not result:
        _fail(f"{PERSONAS} holds no persona")
    return result


def style(repo):
    """The output style's body, which the host would otherwise never read."""
    _, body = _frontmatter(STYLE, (repo / STYLE).read_text(encoding="utf-8"))
    if not body:
        _fail(f"{STYLE} has no body")
    return body


def payload(repo, servers):
    """The project config document and the instruction file's text."""
    try:
        settings = json.loads((repo / SETTINGS).read_text(encoding="utf-8"))["permissions"]
    except (OSError, ValueError, KeyError) as error:
        _fail(f"cannot read {SETTINGS}: {error}")
    rendered = {}
    for name, server in servers.items():
        if server["enabled"] and mcp_hosts.renders(server, "opencode"):
            record = server_config(name, server)
            if record is not None:
                rendered[name] = record
    document = {
        "$schema": "https://opencode.ai/config.json",
        "instructions": [INSTRUCTIONS],
        "permissions": permission_rules(settings),
        "agents": agents(repo, settings, servers),
        "mcp": {"servers": rendered},
    }
    return {"config": document, "instructions": style(repo)}
