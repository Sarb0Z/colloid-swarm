"""The files a write tool's input names, and where they land, read one way by
every hook.

Edit, Write and NotebookEdit name one file under `file_path`, `path` or
`notebook_path`; MultiEdit names one per entry of `edits`. The Claude hook
normalizer, the parallel-writers gate and the product-folder grant all import
`named`, so a new key is learned in one place. The gate resolves each name with
`resolved` and asks `under` whether it lies in the checkout, so every one of its
checks means the same thing by "inside".
"""

import os

KEYS = ("file_path", "path", "notebook_path")


def named(tool_input):
    """Every non-empty file name `tool_input` carries, in the order it names them."""
    if not isinstance(tool_input, dict):
        return []
    names = [tool_input.get(key) for key in KEYS]
    edits = tool_input.get("edits")
    if isinstance(edits, list):
        names += [edit.get("file_path") for edit in edits if isinstance(edit, dict)]
    return [name for name in names if isinstance(name, str) and name]


def resolved(root, tool_input):
    """The real path of every file `tool_input` names; a relative name is read from `root`."""
    return [os.path.realpath(os.path.join(root, os.path.expanduser(name))) for name in named(tool_input)]


def under(path, root):
    """True when the real path `path` is `root` or lies beneath it."""
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)
