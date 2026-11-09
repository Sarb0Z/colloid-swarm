#!/usr/bin/env python3
"""Gate the code-intelligence plugin: its registry agreement, its TypeScript
launcher's choice of server, and the session-start check that names a server
that cannot start.

Stub servers on a controlled PATH stand in for the real binaries, so the rows
run the same on a machine with or without them installed.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
PLUGIN = ROOT / ".agents/claude/plugins/code-intelligence"
MANIFEST = PLUGIN / ".claude-plugin/plugin.json"
LAUNCHER = PLUGIN / "scripts/typescript-server"
MISSING = ROOT / ".agents/hooks/lib/lsp-missing.py"
BASE_PATH = "/usr/bin:/bin"

# A test that runs git must not act on a repository a caller's GIT_DIR names.
for variable in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX", "GIT_COMMON_DIR"):
    os.environ.pop(variable, None)

failures = []


def check(condition, message):
    if condition:
        print(f"ok    {message}")
    else:
        failures.append(message)
        print(f"FAIL  {message}", file=sys.stderr)


def stub(directory, name, body):
    path = directory / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"#!/bin/sh\n{body}\n")
    path.chmod(0o755)
    return path


def compiler(directory, major):
    return stub(directory, "tsc", f'[ "$1" = --version ] && echo "Version {major}.0.2" && exit 0\necho "native $*"')


def launch(project, path, *args):
    env = {**os.environ, "PATH": path, "CLAUDE_PROJECT_DIR": str(project)}
    return subprocess.run([str(LAUNCHER), *args], capture_output=True, text=True, env=env, timeout=20)


def registry_agrees():
    claude = json.loads(MANIFEST.read_text())["lspServers"]
    copilot = json.loads((ROOT / ".agents/lsp.json").read_text())["lspServers"]
    check(sorted(claude) == sorted(copilot), "the plugin and lsp.json declare the same servers")
    for name in sorted(set(claude) & set(copilot)):
        check(
            claude[name]["extensionToLanguage"] == copilot[name]["fileExtensions"],
            f"server `{name}` maps the same extensions to the same language IDs in both files",
        )


def launcher_rows(scratch):
    bins = scratch / "bins"
    stub(bins / "tls", "typescript-language-server", 'echo "tls $*"')
    compiler(bins / "ts7", 7)
    compiler(bins / "ts5", 5)

    owned = scratch / "owned"
    (owned / "node_modules/typescript/lib").mkdir(parents=True)
    (owned / "node_modules/typescript/lib/tsserver.js").write_text("")
    bare = scratch / "bare"
    bare.mkdir()

    both = f"{bins / 'tls'}:{bins / 'ts7'}:{BASE_PATH}"
    probe = launch(owned, both, "--probe")
    check(probe.stdout.strip() == "typescript-language-server --stdio",
          "a project with its own TypeScript 5 gets typescript-language-server")
    run = launch(owned, both)
    check(run.stdout.strip() == "tls --stdio", "without --probe the launcher runs the server it chose")

    probe = launch(bare, both, "--probe")
    check(probe.stdout.strip() == f"{bins / 'ts7' / 'tsc'} --lsp --stdio",
          "a project without TypeScript gets TypeScript 7's built-in server")
    run = launch(bare, both)
    check(run.stdout.strip() == "native --lsp --stdio", "the built-in server starts with --lsp --stdio")

    probe = launch(owned, f"{bins / 'ts7'}:{BASE_PATH}", "--probe")
    check(probe.stdout.strip().endswith("tsc --lsp --stdio"),
          "without typescript-language-server, a project's TypeScript 5 falls back to TypeScript 7")

    projects_own = scratch / "own-ts7"
    compiler(projects_own / "node_modules/.bin", 7)
    probe = launch(projects_own, f"{bins / 'ts5'}:{BASE_PATH}", "--probe")
    check(probe.stdout.strip() == f"{projects_own / 'node_modules/.bin/tsc'} --lsp --stdio",
          "a project's own TypeScript 7 compiler comes before PATH's")

    probe = launch(bare, f"{bins / 'ts5'}:{BASE_PATH}", "--probe")
    check(probe.returncode == 1 and "brew install typescript-language-server" in probe.stderr,
          "with only TypeScript 5 on PATH and none in the project, the launcher fails and names the install")


def git(project, *args):
    subprocess.run(["git", "-C", str(project), *args], check=True, capture_output=True)


def project_with(scratch, name, files):
    project = scratch / name
    shutil.copytree(PLUGIN, project / ".agents/claude/plugins/code-intelligence")
    git(project, "init", "-q")
    for file in files:
        (project / file).write_text("")
        git(project, "add", file)
    return project


def missing(project, path):
    # User-level settings come from a scratch folder, never the operator's own.
    env = {**os.environ, "PATH": path, "CLAUDE_CONFIG_DIR": str(project.parent / "user-config")}
    result = subprocess.run([sys.executable, str(MISSING), str(project)],
                            capture_output=True, text=True, env=env, timeout=60)
    return result.returncode, result.stdout.splitlines()


def missing_rows(scratch):
    bins = scratch / "missing-bins"
    stub(bins, "pyright-langserver", "exit 0")
    compiler(bins, 7)
    present = f"{bins}:{BASE_PATH}"

    both = project_with(scratch, "both", ["app.py", "web.tsx"])
    code, lines = missing(both, BASE_PATH)
    check(code == 0 and any(line.startswith("- Python:") and "brew install pyright" in line for line in lines),
          "a tracked .py file with no pyright-langserver names Python and its install command")
    check(any(line.startswith("- TypeScript and JavaScript:") and "brew install typescript-language-server" in line
              for line in lines),
          "a tracked .tsx file with no TypeScript server names TypeScript and its install command")
    check(missing(both, present) == (0, []), "with every server able to start, nothing is printed")

    unused = project_with(scratch, "unused", ["notes.md"])
    check(missing(unused, BASE_PATH) == (0, []), "a project with no file a server handles prints nothing")

    plain = scratch / "plain"
    plain.mkdir()
    check(missing(plain, BASE_PATH) == (0, []), "a project without the plugin prints nothing")


def settings_rows(scratch):
    off = {"enabledPlugins": {"code-intelligence@skills-dir": False}}
    on = {"enabledPlugins": {"code-intelligence@skills-dir": True}}
    user = scratch / "user-config"
    user.mkdir()

    local_off = project_with(scratch, "local-off", ["app.py"])
    (local_off / ".claude").mkdir()
    (local_off / ".claude/settings.local.json").write_text(json.dumps(off))
    check(missing(local_off, BASE_PATH) == (0, []), "the plugin switched off in settings.local.json prints nothing")

    (user / "settings.json").write_text(json.dumps(off))
    user_off = project_with(scratch, "user-off", ["app.py"])
    check(missing(user_off, BASE_PATH) == (0, []), "the plugin switched off in the user's settings prints nothing")
    (user_off / ".claude").mkdir()
    (user_off / ".claude/settings.local.json").write_text(json.dumps(on))
    _, lines = missing(user_off, BASE_PATH)
    check(any(line.startswith("- Python:") for line in lines), "settings.local.json switching it back on overrides the user's")

    (user / "settings.json").write_text("{not json")
    code, lines = missing(user_off, BASE_PATH)
    check(code == 0 and len(lines) == 1 and "Code intelligence check failed" in lines[0] and "settings.json" in lines[0],
          "an unreadable settings file prints the failure instead of nothing")
    (user / "settings.json").unlink()


def failure_rows(scratch):
    bins = scratch / "failure-bins"
    stub(bins, "pyright-langserver", "exit 0")
    compiler(bins, 7)
    present = f"{bins}:{BASE_PATH}"

    broken = project_with(scratch, "broken", ["app.py"])
    (broken / ".agents/claude/plugins/code-intelligence/.claude-plugin/plugin.json").write_text("{not json")
    code, lines = missing(broken, BASE_PATH)
    check(code == 0 and len(lines) == 1 and "Code intelligence check failed" in lines[0],
          "an unreadable manifest prints the failure instead of nothing")

    unknown = project_with(scratch, "unknown", ["app.go"])
    manifest = unknown / ".agents/claude/plugins/code-intelligence/.claude-plugin/plugin.json"
    data = json.loads(manifest.read_text())
    data["lspServers"]["go"] = {"command": "gopls", "extensionToLanguage": {".go": "go"}}
    manifest.write_text(json.dumps(data))
    code, lines = missing(unknown, present)
    check(lines == ["- Code intelligence check failed: lsp-missing.py has no install command for server `go`"],
          "a server with no install command fails the check by name")

    outside = scratch / "outside"
    shutil.copytree(PLUGIN, outside / ".agents/claude/plugins/code-intelligence")
    code, lines = missing(outside, BASE_PATH)
    check(code == 0 and lines and all("Code intelligence check failed" in line for line in lines),
          "a project git cannot read prints the failure instead of nothing")


def main():
    registry_agrees()
    with tempfile.TemporaryDirectory() as directory:
        scratch = Path(directory).resolve()
        launcher_rows(scratch)
        missing_rows(scratch)
        settings_rows(scratch)
        failure_rows(scratch)
    if failures:
        print(f"test-lsp: {len(failures)} failed", file=sys.stderr)
        return 1
    print("PASS: code-intelligence plugin")
    return 0


if __name__ == "__main__":
    sys.exit(main())
