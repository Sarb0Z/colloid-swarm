"""Validate and resolve portable MCP registry entries."""

import os

REPO_ROOT_TOKEN = "${REPO_ROOT}"
SENSITIVE_FIELD_PARTS = (
    "authorization", "cookie", "credential", "password", "secret", "token",
)
PORTABLE_PATH_FIELDS = {"command", "cwd", "workingDirectory", "working_directory"}
CWD_FIELDS = PORTABLE_PATH_FIELDS - {"command"}


def _has_sensitive_name(name):
    normalized = name.replace("-", "_").lower()
    return normalized in {"env", "headers"} or any(
        part in normalized for part in SENSITIVE_FIELD_PARTS)


def _reject_secret_interpolation(value, path=()):
    if isinstance(value, str):
        if REPO_ROOT_TOKEN in value and any(_has_sensitive_name(str(part)) for part in path):
            rendered = ".".join(map(str, path)) or "value"
            raise ValueError(
                f"refusing {REPO_ROOT_TOKEN} in secret-bearing field {rendered}")
        return
    if isinstance(value, dict):
        for key, child in value.items():
            _reject_secret_interpolation(child, path + (key,))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _reject_secret_interpolation(child, path + (index,))


def _expand_repo_root(server, name, repo):
    _reject_secret_interpolation(server, ("mcpServers", name))
    expanded = dict(server)
    for field, value in server.items():
        allowed = field in PORTABLE_PATH_FIELDS or field == "args"
        if isinstance(value, str) and REPO_ROOT_TOKEN in value:
            if not allowed:
                raise ValueError(
                    f"refusing {REPO_ROOT_TOKEN} outside a portable path field "
                    f"(mcpServers.{name}.{field})")
            expanded[field] = value.replace(REPO_ROOT_TOKEN, repo)
        elif isinstance(value, list):
            values = []
            for index, item in enumerate(value):
                if isinstance(item, str) and REPO_ROOT_TOKEN in item:
                    if field != "args":
                        raise ValueError(
                            f"refusing {REPO_ROOT_TOKEN} outside a portable path field "
                            f"(mcpServers.{name}.{field}[{index}])")
                    item = item.replace(REPO_ROOT_TOKEN, repo)
                values.append(item)
            expanded[field] = values
    return expanded


def _require_local_paths(server, name, repo):
    candidates = []
    for field in PORTABLE_PATH_FIELDS:
        value = server.get(field)
        if isinstance(value, str) and value.startswith(repo + os.sep):
            candidates.append((field, value))
    for index, value in enumerate(server.get("args", [])):
        if isinstance(value, str) and value.startswith(repo + os.sep):
            candidates.append((f"args[{index}]", value))
    for field, path in candidates:
        exists = os.path.isdir(path) if field in CWD_FIELDS else os.path.isfile(path)
        if not exists:
            kind = "directory" if field in CWD_FIELDS else "file"
            raise ValueError(
                f"refusing {name}; local path {field} is missing or not a {kind}: {path}")
    command = server.get("command")
    if isinstance(command, str) and command.startswith(repo + os.sep) and not os.access(command, os.X_OK):
        raise ValueError(f"refusing {name}; local command is not executable: {command}")


def resolve_registry(registry, repo, program):
    """Return entries with allowed repository paths resolved or fail closed."""
    resolved = {}
    for name, server in registry.items():
        if not isinstance(server, dict):
            raise SystemExit(f"{program}: refusing mcpServers.{name}; entry is not an object")
        try:
            server = _expand_repo_root(server, name, repo)
            _require_local_paths(server, name, repo)
        except ValueError as error:
            raise SystemExit(f"{program}: {error}") from error
        resolved[name] = server
    return resolved
