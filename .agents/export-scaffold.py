#!/usr/bin/env python3
"""Export the committed scaffold without Colloid-only subsystems.

Usage: export-scaffold.py <empty-target-dir>. The export subtracts whole paths,
hook entries, JSON keys, and marked regions; it never copies ignored state.
"""

import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent

DROPPED_PATHS = (
    ".agents/genome.sh",
    ".agents/mutagen.sh",
    ".agents/mutagen.md",
    ".agents/hooks/policy/genome-inject.sh",
    ".agents/hooks/lib/genome-exempt.py",
    ".agents/skills/panspermia-mutation",
    ".agents/eval",
    ".agents/fixtures",
    ".agents/export-scaffold.py",
    ".agents/test-export.sh",
    ".agents/test-stack-packs.sh",
    ".agents/breadcrumbs.md",
    ".agents/debt-log.md",
    ".agents/knowledge/index.md",
    ".agents/knowledge/research",
    ".agents/knowledge/transcripts",
)

DROPPED_POLICIES = ("genome-inject.sh",)

DROPPED_KEYS = {
    ".agents/config.json.example": ("swarm", "hooks.genome_inject", "stack_packs"),
}

SUBSTITUTIONS = {
    ".agents/hooks/policy/session-wrap.sh": (
        ("debt: colloid-wrap-concurrent-attribution",
         "debt: wrap-01-concurrent-attribution"),
    ),
}

ID_RENAMES = {
    "colloid-wrap-concurrent-attribution": "wrap-01-concurrent-attribution",
}

DEBT_POINTER = re.compile(r"debt: ([a-z0-9][a-z0-9-]*)")

MARKERS = (
    (re.compile(r"^[ \t]*<!-- colloid-only -->[ \t]*$"),
     re.compile(r"^[ \t]*<!-- /colloid-only -->[ \t]*$")),
    (re.compile(r"^[ \t]*#[ \t]*colloid-only[ \t]*$"),
     re.compile(r"^[ \t]*#[ \t]*/colloid-only[ \t]*$")),
)

TEXT_SUFFIXES = {".md", ".sh", ".py", ".toml", ".json", ".txt", ".example"}

DEBT_SUFFIXES = TEXT_SUFFIXES | {".ts", ".mjs", ".js"}


def tracked_export(destination):
    """Copy the canonical scaffold and static host adapters from Git."""
    with tempfile.TemporaryDirectory() as staging:
        archive = os.path.join(staging, "scaffold.tar")
        with open(archive, "wb") as stream:
            subprocess.run(
                [
                    "git", "-C", str(REPO), "archive", "HEAD",
                    ".agents", ".claude", ".codex", ".kimi", "AGENTS.md",
                    ".github/lsp.json", ".github/copilot-instructions.md",
                    ".github/instructions",
                ],
                stdout=stream, check=True,
            )
        with tarfile.open(archive) as tar:
            tar.extractall(destination, filter="data")


def strip_markers(text, path):
    """Remove every marked region. An unbalanced marker is a source defect."""
    lines = text.splitlines(keepends=True)
    out, depth, opener = [], 0, None
    for number, line in enumerate(lines, 1):
        if depth == 0:
            for start, end in MARKERS:
                if start.match(line):
                    depth, opener = 1, (start, end, number)
                    break
            else:
                out.append(line)
                continue
            continue
        if opener[1].match(line):
            depth, opener = 0, None
        elif opener[0].match(line):
            raise SystemExit(f"export: nested colloid-only marker at {path}:{number}")
    if depth:
        raise SystemExit(f"export: unclosed colloid-only marker at {path}:{opener[2]}")
    return "".join(out).rstrip() + "\n"


def prune_hook_entries(node):
    """Drop hook entries whose command names a policy the export does not ship."""
    if isinstance(node, list):
        kept = []
        for item in node:
            if isinstance(item, dict):
                command = item.get("command")
                if isinstance(command, str) and any(p in command for p in DROPPED_POLICIES):
                    continue
                prune_hook_entries(item)
                if item.get("hooks") == []:
                    continue
            else:
                prune_hook_entries(item)
            kept.append(item)
        node[:] = kept
    elif isinstance(node, dict):
        for value in node.values():
            prune_hook_entries(value)


def drop_key(document, dotted):
    node = document
    parts = dotted.split(".")
    for part in parts[:-1]:
        node = node.get(part)
        if not isinstance(node, dict):
            return False
    return node.pop(parts[-1], None) is not None


def debt_sections(path):
    ledger = path.read_text(encoding="utf-8")
    sections = {}
    current = None
    for line in ledger.splitlines(keepends=True):
        if line.startswith("### "):
            current = line[4:].strip()
            sections[current] = []
        elif current:
            sections[current].append(line)
    return sections


def wanted_debts(target):
    wanted = set()
    for path in sorted(target.rglob("*")):
        if path.is_symlink() or not path.is_file() or path.suffix not in DEBT_SUFFIXES:
            continue
        if "node_modules" in path.parts or "dist" in path.parts:
            continue                   # generated output mirrors its own source
        try:
            wanted.update(DEBT_POINTER.findall(path.read_text(encoding="utf-8")))
        except (UnicodeDecodeError, OSError):
            continue
    return wanted


def write_debt_entries(target, sections):
    wanted = wanted_debts(target)

    source_of = {new: old for old, new in ID_RENAMES.items()}
    missing = sorted(i for i in wanted if source_of.get(i, i) not in sections)
    if missing:
        raise SystemExit(f"export: exported code points at absent debt entries: {missing}")

    out = [
        "# Seed entries for the target repository's `.agents/debt-log.md`\n\n",
        "Merge these referenced entries into the target debt log, preserving its own entries.\n\n",
        "---\n",
    ]
    for identifier in sorted(wanted):
        body = "".join(sections[source_of.get(identifier, identifier)]).strip("\n")
        out.append(f"\n### {identifier}\n\n{body}\n")

    (target / "export/debt-log-entry.md").write_text("".join(out), encoding="utf-8")
    return len(wanted)


def warn_dirty():
    dirty = subprocess.run(
        [
            "git", "-C", str(REPO), "status", "--porcelain", "--",
            ".agents", ".claude", ".codex", ".kimi", ".github/lsp.json",
            ".github/instructions", ".github/copilot-instructions.md", "AGENTS.md",
        ],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    if dirty:
        print("export: WARNING -- uncommitted scaffold changes are NOT in this export:",
              file=sys.stderr)
        for line in dirty.splitlines():
            print(f"  {line}", file=sys.stderr)


def drop_paths(target):
    for relative in DROPPED_PATHS:
        path = target / relative
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        elif path.exists() or path.is_symlink():
            path.unlink()


def rewrite_documents(target):
    for relative in (".agents/claude/settings.json", ".agents/codex/hooks.json"):
        path = target / relative
        document = json.loads(path.read_text(encoding="utf-8"))
        prune_hook_entries(document)
        path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")

    for relative, keys in DROPPED_KEYS.items():
        path = target / relative
        document = json.loads(path.read_text(encoding="utf-8"))
        for dotted in keys:
            if not drop_key(document, dotted):
                raise SystemExit(f"export: {relative} has no key {dotted}")
        path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")

    for relative, pairs in SUBSTITUTIONS.items():
        path = target / relative
        if not path.exists():
            continue                   # AGENTS.md rides along only when asked for
        text = path.read_text(encoding="utf-8")
        for old, new in pairs:
            if old not in text:
                raise SystemExit(f"export: {relative} no longer contains {old!r}")
            text = text.replace(old, new)
        path.write_text(text, encoding="utf-8")


def strip_tree(target):
    stripped = 0
    for path in sorted(target.rglob("*")):
        if path.is_symlink() or not path.is_file() or path.suffix not in TEXT_SUFFIXES:
            continue
        if "mcp-servers" in path.parts:
            continue                   # vendored server source carries no markers
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        if "colloid-only" not in text:
            continue
        path.write_text(strip_markers(text, path.relative_to(target)), encoding="utf-8")
        stripped += 1
    return stripped


def finalize(target, sections):
    shutil.copytree(target / ".agents/export", target / "export", symlinks=True)
    shutil.rmtree(target / ".agents/export")
    for path in sorted(target.rglob("*")):
        if path.is_symlink() and not path.exists():
            path.unlink()
    return write_debt_entries(target, sections)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: export-scaffold.py <target-dir>")
    target = pathlib.Path(sys.argv[1]).resolve()
    if target.exists() and any(target.iterdir()):
        raise SystemExit(f"export: {target} exists and is not empty")
    target.mkdir(parents=True, exist_ok=True)
    warn_dirty()
    tracked_export(target)
    sections = debt_sections(target / ".agents/debt-log.md")
    drop_paths(target)
    rewrite_documents(target)
    stripped = strip_tree(target)
    entries = finalize(target, sections)

    print(f"exported to {target}")
    print(f"  dropped {len(DROPPED_PATHS)} paths, stripped markers from {stripped} files")
    print(f"  seeded {entries} debt-log entr{'y' if entries == 1 else 'ies'}")
    print("  next: read export/README.md")


if __name__ == "__main__":
    main()
