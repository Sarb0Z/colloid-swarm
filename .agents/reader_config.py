"""Generate the reader browser tier's launch config.

The `playwright-reader` registry entry points at `.agents/.playwright-reader.json`,
and `mcp_registry.resolve_registry` validates the local paths of *every* entry
before any enabled filter runs. So the file has to exist before either sync
script resolves the registry — including `sync-codex.sh` run on its own, which is
the fresh-clone path. Both call this.

Extensions reach the browser only through a config file: @playwright/mcp has no
extension flag, and the registry rejects a directory in `args`.
"""

import json
import os
import tempfile

CONFIG_NAME = ".playwright-reader.json"
EXTENSIONS_DIR = "browser-extensions"


def installed_extensions(agents):
    """Operator-installed extension trees, newest-sorted for a stable config."""
    root = os.path.join(agents, EXTENSIONS_DIR)
    if not os.path.isdir(root):
        return []
    found = []
    for entry in sorted(os.listdir(root)):
        path = os.path.join(root, entry)
        # A tree without a manifest is not loadable; ignoring it here is what
        # makes the enabled-but-not-installed check downstream meaningful.
        if os.path.isfile(os.path.join(path, "manifest.json")):
            found.append(path)
    return found


def write(agents, log=None):
    """Write the launch config. Returns the extension paths it recorded."""
    extensions = installed_extensions(agents)
    # Chrome for Testing, never branded Chrome: Chrome dropped --load-extension
    # from branded builds at milestone 137 and now discards it without warning.
    # debt: research-02-reader-tier-loses-branded-chrome
    launch = {"channel": "chromium"}
    if extensions:
        launch["args"] = ["--load-extension=" + ",".join(extensions)]
    payload = {"browser": {"browserName": "chromium", "launchOptions": launch}}

    path = os.path.join(agents, CONFIG_NAME)
    if os.path.islink(path):
        os.unlink(path)
    fd, tmp = tempfile.mkstemp(dir=agents, prefix=".reader-config-")
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
    os.replace(tmp, path)
    if log:
        log("generated " + path)
    return extensions
