"""The four commands: status, sources, fetch, push."""

from __future__ import annotations

import argparse
from collections import Counter
from pathlib import Path

from .effects import Effects
from .layout import Layout, LayoutError
from .ledger import FETCH, PUSH, LedgerError, latest, read_rows
from .manifest import ManifestError, read_manifest
from .plugins import PluginError, load_plugins
from .scrub import scrub

OK = 0
USAGE = 2
HOST_CAP = 3
LOCKED = 4

FETCH_STATES = ("pending", "fetched", "converted", "needs-text", "awaiting-inbox", "blocked", "failed")
NOTE_WIDTH = 60


def build_parser(default_plugins: Path) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="papers.py",
        description="Fetch the papers a manifest lists and push them to a catalogue.",
    )
    commands = parser.add_subparsers(dest="command", required=True)

    project = argparse.ArgumentParser(add_help=False)
    project.add_argument("--manifest", type=Path, required=True, help="CSV with key and doi columns")
    project.add_argument("--root", type=Path, required=True, help="the project folder")

    plugins = argparse.ArgumentParser(add_help=False)
    plugins.add_argument(
        "--plugins", type=Path, default=default_plugins, help="folder of sources, converters and sinks"
    )

    commands.add_parser("status", parents=[project], help="show every paper's state; reads only")
    commands.add_parser("sources", parents=[plugins], help="list the loaded plugins")
    return parser


def main(argv: list[str], fx: Effects, default_plugins: Path) -> int:
    args = build_parser(default_plugins).parse_args(argv)

    def say(text: str) -> None:
        fx.out(scrub(text, fx.environ))

    try:
        if args.command == "status":
            return command_status(args, say)
        return command_sources(args, say)
    except (ManifestError, PluginError, LedgerError, LayoutError) as error:
        fx.err(scrub(f"error: {error}", fx.environ))
        return USAGE


def command_status(args: argparse.Namespace, say) -> int:
    if not args.root.is_dir():
        raise ManifestError(f"{args.root}: no such project folder")
    papers = read_manifest(args.manifest)
    layout = Layout(args.root)
    states = latest(read_rows(layout.ledger))
    counts: Counter[str] = Counter()
    for paper in papers:
        fetch = states.get((paper.key, FETCH))
        push = states.get((paper.key, PUSH))
        fetch_state = fetch.state if fetch else "pending"
        counts[fetch_state] += 1
        note = ""
        if fetch_state == "awaiting-inbox":
            note = f"inbox: {layout.inbox(paper.key).relative_to(layout.root)}"
        elif fetch is not None:
            note = " ".join(part for part in (fetch.source, fetch.detail) if part)[:NOTE_WIDTH]
        say(f"{paper.key:<32} {fetch_state:<15} {push.state if push else '-':<7} {note}".rstrip())
    summary = ", ".join(f"{state} {counts[state]}" for state in FETCH_STATES if counts[state])
    say(f"{len(papers)} papers: {summary}")
    return OK


def command_sources(args: argparse.Namespace, say) -> int:
    plugins = load_plugins(args.plugins)
    loaded = 0
    for kind, found in plugins.by_kind.items():
        for plugin in found.values():
            say(f"{kind[:-1]:<10} {plugin.name:<24} {plugin.path}")
            loaded += 1
    if not loaded:
        say(f"no plugins loaded from {args.plugins}")
    return OK
