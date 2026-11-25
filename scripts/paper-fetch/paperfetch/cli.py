"""The four commands: status, sources, fetch, push."""

from __future__ import annotations

import argparse
from collections import Counter
from collections.abc import Callable
from pathlib import Path

from .context import Context
from .effects import Effects
from .fetch import FetchOptions, Report, preview, run_fetch
from .layout import Layout, LayoutError
from .ledger import FETCH, PUSH, Ledger, LedgerError, LedgerLocked, latest, read_rows
from .manifest import ManifestError, read_manifest
from .model import Paper
from .plugins import Plugin, PluginError, Plugins, load_plugins
from .polite import Http, Policy, RunStopped
from .push import PushOptions, PushReport, run_push
from .scrub import scrub

OK = 0
USAGE = 2
HOST_CAP = 3
LOCKED = 4

FETCH_DELAY_MS = 1500
FETCH_JITTER_MS = 1200
FETCH_HOST_CAP = 25
# A push calls the operator's own catalogue, not a publisher's pages, and one
# paper takes several requests. A sink may declare its own cap.
PUSH_DELAY_MS = 500
PUSH_JITTER_MS = 300
PUSH_HOST_CAP = 1000

FETCH_STATES = ("pending", "fetched", "converted", "needs-text", "awaiting-inbox", "blocked", "failed")
SUMMARY_ORDER = ("converted", "hand", "fetched", "needs-text", "awaiting-inbox", "blocked", "failed", "skipped")
NOTE_WIDTH = 60

Say = Callable[[str], None]


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

    fetch = commands.add_parser("fetch", parents=[project, plugins], help="get the papers' files")
    fetch.add_argument("--only", help="comma-separated keys; the others are left alone")
    fetch.add_argument(
        "--limit", type=int, default=0, help="stop after N papers that reached a source; 0 means no limit"
    )
    fetch.add_argument("--sources", help="comma-separated source names, in the order to ask them")
    fetch.add_argument("--delay-ms", type=int, default=FETCH_DELAY_MS, help="base pause between requests to a host")
    fetch.add_argument("--jitter-ms", type=int, default=FETCH_JITTER_MS, help="random extra pause, up to N ms")
    fetch.add_argument("--force", action="store_true", help="run a full attempt even for a finished paper")
    fetch.add_argument("--dry-run", action="store_true", help="ask the sources and print; write nothing")

    push = commands.add_parser("push", parents=[project, plugins], help="send fetched papers to a sink")
    push.add_argument("--sink", required=True, help="the name of the sink plugin")
    push.add_argument("--only", help="comma-separated keys; the others are left alone")
    push.add_argument("--delay-ms", type=int, default=PUSH_DELAY_MS, help="base pause between requests to a host")
    push.add_argument("--jitter-ms", type=int, default=PUSH_JITTER_MS, help="random extra pause, up to N ms")
    push.add_argument("--force", action="store_true", help="push a paper again even if it was pushed")
    push.add_argument("--apply", action="store_true", help="write to the sink; without it, print the plan only")
    return parser


def main(argv: list[str], fx: Effects, default_plugins: Path) -> int:
    args = build_parser(default_plugins).parse_args(argv)

    def say(text: str) -> None:
        fx.out(scrub(text, fx.environ))

    try:
        if args.command == "status":
            return command_status(args, say)
        if args.command == "sources":
            return command_sources(args, say)
        if args.command == "fetch":
            return command_fetch(args, fx, say)
        return command_push(args, fx, say)
    except LedgerLocked as error:
        fx.err(scrub(f"error: {error}", fx.environ))
        return LOCKED
    except RunStopped as error:
        fx.err(scrub(f"stopped: {error}", fx.environ))
        return HOST_CAP
    except (ManifestError, PluginError, LedgerError, LayoutError) as error:
        fx.err(scrub(f"error: {error}", fx.environ))
        return USAGE


def _open_project(args: argparse.Namespace) -> tuple[list[Paper], Layout]:
    if not args.root.is_dir():
        raise ManifestError(f"{args.root}: no such project folder")
    # Resolved once, so a relative `--root .` and a symlinked folder compare
    # equal to the absolute paths the tool builds from it.
    papers, layout = read_manifest(args.manifest), Layout(args.root.resolve())
    for paper in papers:
        layout.inbox_paths(paper)  # a save_as that leaves the project is a manifest error, found now
    return papers, layout


def command_status(args: argparse.Namespace, say: Say) -> int:
    papers, layout = _open_project(args)
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


def command_sources(args: argparse.Namespace, say: Say) -> int:
    plugins = load_plugins(args.plugins)
    loaded = 0
    for kind, found in plugins.by_kind.items():
        for plugin in found.values():
            say(f"{kind[:-1]:<10} {plugin.name:<24} {plugin.path}")
            loaded += 1
    if not loaded:
        say(f"no plugins loaded from {args.plugins}")
    return OK


def command_fetch(args: argparse.Namespace, fx: Effects, say: Say) -> int:
    papers, layout = _open_project(args)
    plugins = load_plugins(args.plugins)
    sources = choose_sources(plugins, args.sources)
    options = FetchOptions(only=choose_keys(papers, args.only), limit=args.limit, force=args.force)
    policy = Policy(
        delay_ms=args.delay_ms,
        jitter_ms=args.jitter_ms,
        max_per_host=FETCH_HOST_CAP,
        host_intervals_ms=host_intervals(sources),
        read_only=args.dry_run,
    )
    shared = {
        "layout": layout,
        "http": Http(fx, policy, say),
        "run": fx.run,
        "say": say,
        "sources": sources,
        "converters": sorted(plugins.of("converters").values(), key=lambda plugin: plugin.name),
    }
    if args.dry_run:
        preview(papers, Context(ledger=None, **shared), options)
        return OK
    with Ledger.locked(layout.ledger, fx.stamp, fx.environ) as ledger:
        report = run_fetch(papers, Context(ledger=ledger, **shared), options)
    say(summarize(report))
    return HOST_CAP if report.stopped else OK


def command_push(args: argparse.Namespace, fx: Effects, say: Say) -> int:
    papers, layout = _open_project(args)
    sinks = load_plugins(args.plugins).of("sinks")
    if args.sink not in sinks:
        raise PluginError(f"--sink names no loaded sink: {args.sink} (loaded: {', '.join(sorted(sinks)) or 'none'})")
    sink = sinks[args.sink]
    policy = Policy(
        delay_ms=args.delay_ms,
        jitter_ms=args.jitter_ms,
        max_per_host=getattr(sink.module, "MAX_REQUESTS_PER_HOST", PUSH_HOST_CAP),
        host_intervals_ms=host_intervals([sink]),
        read_only=not args.apply,
    )
    options = PushOptions(only=choose_keys(papers, args.only), force=args.force, apply=args.apply)
    shared = {
        "layout": layout, "http": Http(fx, policy, say), "run": fx.run, "say": say,
        "sources": [], "converters": [],
    }
    if not args.apply:
        report = run_push(papers, sink, Context(ledger=None, **shared), options)
        say(summarize_push(report) + "; nothing was written, add --apply to write")
        return HOST_CAP if report.stopped else OK
    with Ledger.locked(layout.ledger, fx.stamp, fx.environ) as ledger:
        report = run_push(papers, sink, Context(ledger=ledger, **shared), options)
    say(summarize_push(report))
    return HOST_CAP if report.stopped else OK


def summarize_push(report: PushReport) -> str:
    parts = [f"{name} {report.counts[name]}" for name in ("pushed", "planned", "failed", "skipped") if report.counts[name]]
    return ("stopped early: " if report.stopped else "done: ") + (", ".join(parts) if parts else "nothing to do")


def choose_keys(papers: list[Paper], text: str | None) -> frozenset[str] | None:
    if text is None:
        return None
    wanted = [key.strip() for key in text.split(",") if key.strip()]
    unknown = sorted(set(wanted) - {paper.key for paper in papers})
    if unknown:
        raise ManifestError(f"--only names keys the manifest does not hold: {', '.join(unknown)}")
    return frozenset(wanted)


def choose_sources(plugins: Plugins, text: str | None) -> list[Plugin]:
    loaded = plugins.of("sources")
    if text is None:
        return [loaded[name] for name in sorted(loaded)]
    names = [name.strip() for name in text.split(",") if name.strip()]
    unknown = [name for name in names if name not in loaded]
    if unknown:
        known = ", ".join(sorted(loaded)) or "none loaded"
        raise PluginError(f"--sources names no loaded source: {', '.join(unknown)} (loaded: {known})")
    return [loaded[name] for name in names]


def host_intervals(plugins: list[Plugin]) -> dict[str, int]:
    """The slowest pace any plugin asks for, per host."""
    merged: dict[str, int] = {}
    for plugin in plugins:
        for host, interval in getattr(plugin.module, "HOST_INTERVALS_MS", {}).items():
            merged[host.lower()] = max(merged.get(host.lower(), 0), interval)
    return merged


def summarize(report: Report) -> str:
    parts = [f"{name} {report.counts[name]}" for name in SUMMARY_ORDER if report.counts[name]]
    return ("stopped early: " if report.stopped else "done: ") + (", ".join(parts) if parts else "nothing to do")
