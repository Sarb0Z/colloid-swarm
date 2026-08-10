#!/usr/bin/env python3
"""Emit a de-genomed copy of this scaffold, ready to transplant into a satellite.

No satellite repository carries the genome layer, so the scaffold they receive
is this one minus that subsystem. The export works by **subtraction** only:
drop whole paths, drop hook entries that name a dropped policy, drop named JSON
keys, and drop regions the source marks as colloid-only. It never rewrites
prose, because a generator that string-matches canon's wording breaks silently
the next time canon is reworded.

That constraint is what shapes the source: genome-specific material lives in
files that can be dropped whole, in JSON keys that can be named, or inside
`colloid-only` regions that sit *additively* on text already correct without
them. A `SUBSTITUTIONS` entry is the escape hatch for the few places a marker
cannot reach, and each one fails loudly when its target moves.

Subtraction is the mechanism, not the ambition. `.agents/rules/` travels whole,
stack packs included, so a satellite gains concrete domain guidance rather than
only losing the genome. The export carries every pack and selects none: the
agent running the transplant reads the target and deletes what it does not run,
and `check-stack-packs.py` fails on a pack that agent missed.

Usage:
    .agents/export-scaffold.py <target-dir>

The target receives `.agents/` and `.kimi/` as tracked by git, so a dirty
working tree, a local `config.json`, the ledgers, and `browser-extensions/`
never travel. See `.agents/export/README.md` for the transplant method.
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

# Whole paths the satellites do not carry. The genome subsystem, and the
# research artifacts that only mean something against colloid's own history.
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
    ".agents/export",
    ".agents/test-export.sh",
    # Work queue and debt ledger are this repository's content. A satellite
    # keeps its own, and the transplant must never overwrite them.
    ".agents/breadcrumbs.md",
    ".agents/debt-log.md",
    # Knowledge entries are that same class -- observations this repository
    # made, meaningless in a satellite. Its `README.md` is the exception and
    # travels, because it is the contract rather than content. That split is
    # why the entries sit one level down: it keeps them droppable as whole
    # paths, with no per-file rule reaching inside the directory.
    ".agents/knowledge/index.md",
    ".agents/knowledge/research",
    ".agents/knowledge/transcripts",
)

# Policy files the export omits. Any hook entry naming one is removed from every
# engine's dispatch table, so the tables need no marking of their own -- they
# derive from this list.
DROPPED_POLICIES = ("genome-inject.sh",)

# Config keys that describe a dropped subsystem, plus the one key that marks
# this repository as the pack carrier. Dotted paths, per file.
#
# `stack_packs.carrier` is the whole selection mechanism. Colloid holds every
# pack and chooses between none; dropping the key flips check-stack-packs.py on
# in the target, where a pack matching no file is a pack the transplant should
# have deleted. Subtraction reaches it, so no new machinery does.
DROPPED_KEYS = {
    ".agents/config.json.example": ("swarm", "hooks.genome_inject", "stack_packs"),
}

# The escape hatch: places where the colloid-only material is a fragment of a
# line, so no marker can wrap it. Keep this list short. A missing target is an
# error, never a silent skip -- that is the whole point of listing it here.
SUBSTITUTIONS = {
    ".agents/sync-claude-agents.sh": (
        (
            "prompt='[genome stamp] + [research question]')",
            "prompt='[research question]')",
        ),
        (
            " Exempt from genome stamping — prepend no stamp.",
            "",
        ),
    ),
    "AGENTS.md": ((("`colloid-07-naive-scan`"), "`<area>-07-naive-scan`"),),
    ".agents/claude/README.md": (
        ("colloid-wrap-concurrent-attribution", "wrap-01-concurrent-attribution"),
    ),
    ".agents/hooks/policy/session-wrap.sh": (
        ("debt: colloid-wrap-concurrent-attribution",
         "debt: wrap-01-concurrent-attribution"),
    ),
}

# Debt ids that read as this repository's own. The satellites carry the same
# tradeoff under a name that means something locally.
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

# Debt pointers also sit in the vendored servers' TypeScript, which carries no
# markers and so is skipped by the strip pass.
DEBT_SUFFIXES = TEXT_SUFFIXES | {".ts", ".mjs", ".js"}


def tracked_export(destination):
    """Copy `.agents/` and `.kimi/` as git has them, symlinks and modes intact."""
    with tempfile.TemporaryDirectory() as staging:
        archive = os.path.join(staging, "scaffold.tar")
        with open(archive, "wb") as stream:
            subprocess.run(
                ["git", "-C", str(REPO), "archive", "HEAD", ".agents", ".kimi", "AGENTS.md"],
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
    return "".join(out)


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


def write_debt_entries(target):
    """Seed the debt entries the exported code actually points at.

    Which entries travel depends on what the target keeps -- drop the reader
    tier or a bundled server and its pointer goes with it. So read the emitted
    tree rather than maintaining a list beside it: every `debt: <id>` left in
    the export needs its entry, or the satellite inherits a dangling reference.
    """
    ledger = (REPO / ".agents/debt-log.md").read_text(encoding="utf-8")
    sections = {}
    current = None
    for line in ledger.splitlines(keepends=True):
        if line.startswith("### "):
            current = line[4:].strip()
            sections[current] = []
        elif current:
            sections[current].append(line)

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

    # The pointers were already renamed in the emitted code, so resolve each one
    # back to the heading this ledger files it under.
    source_of = {new: old for old, new in ID_RENAMES.items()}
    missing = sorted(i for i in wanted if source_of.get(i, i) not in sections)
    if missing:
        raise SystemExit(f"export: exported code points at absent debt entries: {missing}")

    out = [
        "# Seed entries for the target repository's `.agents/debt-log.md`\n\n",
        "The exported code carries an inline `debt: <id>` pointer for each entry\n",
        "below, and a pointer with no entry is a dangling reference. Merge these into\n",
        "the repository's own `debt-log.md`, keeping its entries and heading order.\n",
        "Rename an id only where it collides with the repository's convention, and\n",
        "update the inline pointer to match. Do not copy this file into the repository.\n\n",
        "---\n",
    ]
    for identifier in sorted(wanted):
        body = "".join(sections[source_of.get(identifier, identifier)]).strip("\n")
        out.append(f"\n### {identifier}\n\n{body}\n")

    (target / "export/debt-log-entry.md").write_text("".join(out), encoding="utf-8")
    return len(wanted)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: export-scaffold.py <target-dir>")
    target = pathlib.Path(sys.argv[1]).resolve()
    if target.exists() and any(target.iterdir()):
        raise SystemExit(f"export: {target} exists and is not empty")
    target.mkdir(parents=True, exist_ok=True)

    dirty = subprocess.run(
        ["git", "-C", str(REPO), "status", "--porcelain", "--", ".agents", ".kimi", "AGENTS.md"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    if dirty:
        # The export reads HEAD, so a transplant carries reviewed code rather
        # than whatever is open in an editor. Silent staleness is the hazard.
        print("export: WARNING -- uncommitted scaffold changes are NOT in this export:",
              file=sys.stderr)
        for line in dirty.splitlines():
            print(f"  {line}", file=sys.stderr)

    tracked_export(target)

    for relative in DROPPED_PATHS:
        path = target / relative
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        elif path.exists() or path.is_symlink():
            path.unlink()

    # Hook dispatch tables: derived from DROPPED_POLICIES, not listed by hand.
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

    shutil.copytree(REPO / ".agents/export", target / "export")
    entries = write_debt_entries(target)

    print(f"exported to {target}")
    print(f"  dropped {len(DROPPED_PATHS)} paths, stripped markers from {stripped} files")
    print(f"  seeded {entries} debt-log entr{'y' if entries == 1 else 'ies'}")
    print("  next: read export/README.md")


if __name__ == "__main__":
    main()
