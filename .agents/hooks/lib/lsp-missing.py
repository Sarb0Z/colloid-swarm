#!/usr/bin/env python3
"""Name the code-intelligence servers that cannot start in a project.

Usage: lsp-missing.py <project-dir>

Reads the language servers the repository's `code-intelligence` plugin declares
and prints one `- <language>: …` line per server that has work here (a tracked
file with one of its extensions) but cannot start: its command is not on PATH,
or its launcher's `--probe` fails. A project without the plugin prints nothing.
A check that cannot run prints its reason as a line, so a broken check never
reads as every server starting.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

MANIFEST = ".agents/claude/plugins/code-intelligence/.claude-plugin/plugin.json"
PLUGIN_ROOT = "${CLAUDE_PLUGIN_ROOT}"

# Server name -> (what the user calls the language, how to install its server).
SERVERS = {
    "typescript": (
        "TypeScript and JavaScript",
        "`brew install typescript-language-server`, which also brings TypeScript 7's built-in server",
    ),
    "python": ("Python", "`brew install pyright`"),
}


class CheckFailed(Exception):
    """The check itself could not run, as opposed to a server that cannot start."""


def has_files(project, extensions):
    """Whether git tracks a file with one of the extensions."""
    try:
        result = subprocess.run(
            ["git", "-C", str(project), "ls-files", "-z", "--", *(f"*{ext}" for ext in extensions)],
            capture_output=True,
        )
    except OSError as error:
        raise CheckFailed(f"git could not run ({error})") from error
    if result.returncode != 0:
        reason = result.stderr.decode(errors="replace").strip().splitlines()
        raise CheckFailed(reason[-1] if reason else f"git ls-files exited {result.returncode}")
    return bool(result.stdout)


def starts(project, plugin_root, server):
    """Whether the server's command can start here."""
    command = server.get("command", "")
    if not command.startswith(PLUGIN_ROOT):
        return shutil.which(command) is not None
    launcher = str(plugin_root) + command[len(PLUGIN_ROOT):]
    env = {**os.environ, "CLAUDE_PROJECT_DIR": str(project)}
    try:
        probe = subprocess.run([launcher, "--probe"], capture_output=True, env=env, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise CheckFailed(f"{launcher} --probe did not finish ({error})") from error
    return probe.returncode == 0


def main():
    project = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    manifest = project / MANIFEST
    if not manifest.exists():
        return 0
    try:
        servers = json.loads(manifest.read_text(encoding="utf-8"))["lspServers"]
        if not all(isinstance(server.get("extensionToLanguage"), dict) for server in servers.values()):
            raise ValueError("a server has no extensionToLanguage map")
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        print(f"- Code intelligence check failed: {MANIFEST} is unreadable ({error})")
        return 0
    plugin_root = manifest.parent.parent
    for name, server in sorted(servers.items()):
        if name not in SERVERS:
            print(f"- Code intelligence check failed: lsp-missing.py has no install command for server `{name}`")
            continue
        language, install = SERVERS[name]
        try:
            if has_files(project, server["extensionToLanguage"]) and not starts(project, plugin_root, server):
                print(f"- {language}: no language server can start. Install it with {install}.")
        except CheckFailed as error:
            print(f"- Code intelligence check failed for {language}: {error}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
