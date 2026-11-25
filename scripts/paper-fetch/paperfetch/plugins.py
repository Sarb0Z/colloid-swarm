"""Load the plugins the operator drops into a folder.

A folder holds `sources/`, `converters/` and `sinks/`. A plugin is one `.py` file
with a `NAME` and the functions its kind needs. A file whose name starts with
`_` is a template and is never loaded. A file that does not fit stops the load
and is named, because a plugin that is skipped quietly looks like a source that
found nothing.
"""

from __future__ import annotations

import importlib.util
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType

from .model import KINDS

PLUGIN_KINDS = ("sources", "converters", "sinks")
REQUIRED_FUNCTIONS = {
    "sources": ("locate",),
    "converters": ("convert",),
    "sinks": ("plan", "push"),
}
NAME = re.compile(r"[a-z0-9][a-z0-9-]*")


class PluginError(Exception):
    """A plugin file or folder cannot be loaded."""


@dataclass(frozen=True)
class Plugin:
    kind: str
    name: str
    path: Path
    module: ModuleType


@dataclass(frozen=True)
class Plugins:
    by_kind: dict[str, dict[str, Plugin]]

    def of(self, kind: str) -> dict[str, Plugin]:
        return self.by_kind[kind]


def load_plugins(folder: Path) -> Plugins:
    if not folder.is_dir():
        raise PluginError(f"{folder}: no such plugin folder")
    by_kind: dict[str, dict[str, Plugin]] = {}
    for kind in PLUGIN_KINDS:
        plugins: dict[str, Plugin] = {}
        kind_folder = folder / kind
        files = sorted(kind_folder.glob("*.py")) if kind_folder.is_dir() else []
        for path in files:
            if path.name.startswith("_"):
                continue
            plugin = _load(kind, path)
            if plugin.name in plugins:
                raise PluginError(
                    f"{path}: {kind[:-1]} name {plugin.name!r} is also used by {plugins[plugin.name].path}"
                )
            plugins[plugin.name] = plugin
        by_kind[kind] = plugins
    return Plugins(by_kind)


def _load(kind: str, path: Path) -> Plugin:
    module_name = "paperfetch_plugin_" + re.sub(r"\W", "_", f"{kind}_{path.stem}")
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise PluginError(f"{path}: cannot be imported")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    try:
        spec.loader.exec_module(module)
    except Exception as error:
        raise PluginError(f"{path}: raised while loading: {error!r}") from error
    _check_shape(kind, path, module)
    return Plugin(kind=kind, name=module.NAME, path=path, module=module)


def _check_shape(kind: str, path: Path, module: ModuleType) -> None:
    name = getattr(module, "NAME", None)
    if not isinstance(name, str) or not NAME.fullmatch(name):
        raise PluginError(f"{path}: NAME must be a string matching [a-z0-9][a-z0-9-]*")
    for function in REQUIRED_FUNCTIONS[kind]:
        if not callable(getattr(module, function, None)):
            raise PluginError(f"{path}: a {kind[:-1]} needs a function {function}")
    if kind == "converters":
        accepts = getattr(module, "ACCEPTS", None)
        if (
            not isinstance(accepts, (tuple, list))
            or not accepts
            or any(item not in KINDS for item in accepts)
        ):
            raise PluginError(f"{path}: ACCEPTS must be a non-empty tuple drawn from {KINDS}")
    intervals = getattr(module, "HOST_INTERVALS_MS", {})
    if not isinstance(intervals, dict) or any(
        not isinstance(host, str) or not isinstance(ms, int) or ms <= 0
        for host, ms in intervals.items()
    ):
        raise PluginError(f"{path}: HOST_INTERVALS_MS must map a host to a positive integer")
    cap = getattr(module, "MAX_REQUESTS_PER_HOST", 1)
    if not isinstance(cap, int) or isinstance(cap, bool) or cap < 1:
        raise PluginError(f"{path}: MAX_REQUESTS_PER_HOST must be a positive integer")
