#!/usr/bin/env python3
"""Install or remove the phone link's parts for this user. `.agents/iterm/install.sh` runs it.

  install.py install [--check] [--zone <IANA zone>]
  install.py uninstall [--check]

`install` puts in place, and leaves alone what already is:

  1. A link `~/.local/bin/<name>` to each hook adapter of `hooks/`.
  2. The hook's entry in the user settings of each Claude account that exists
     here (`~/.claude`, `~/.claude-personal`, `~/.claude-family`,
     `~/.claude-guest`): one `PermissionRequest` entry, for every tool except
     AskUserQuestion and ExitPlanMode, with the timeout the hook's own deadline
     assumes (`client.HOOK_TIMEOUT`). Every other key and every other hook
     stays as it is. A settings.json that is a link is written at the file it
     points to, once, however many accounts share it; the file as it was
     before the first change is kept beside it as `settings.json.pre-phone-link`.
  3. The state folder `~/.local/state/phone-link` and its `signal` folder,
     mode 0700, and an empty `errors.log`, mode 0600.
  4. Two launchd agents of this user: `signal-cli daemon` on a Unix socket in
     the state folder, with no TCP or HTTP port and nothing downloaded or
     printed, and `phone_link.py`, with the phone's time zone (`--zone`,
     default this Mac's).

`uninstall` removes exactly the links, the settings entries and the two agents.
It keeps the state folder and signal-cli's own data, which hold the event log
and the account keys: the spec's Undo section says how to remove them.

`--check` prints each change it would make and makes none.

Before the first change, the run reads everything it will touch. A settings
file that is not a JSON object, a file in the way of a link, a missing
signal-cli or a zone the system does not know stops it with nothing changed.
launchd agents belong to the user's real home: with HOME set to another folder
the run refuses, unless `PHONE_LINK_LAUNCHCTL` names a stand-in, as the tests
do. `PHONE_LINK_SIGNAL_CLI` names signal-cli where it is not on PATH.
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import plistlib
import pwd
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import client
import log

ACCOUNTS = (".claude", ".claude-personal", ".claude-family", ".claude-guest")
EVENT = "PermissionRequest"
# Every tool name but these two, which need an answer the hook does not give.
MATCHER = "^(?!(AskUserQuestion|ExitPlanMode)$).*"
SIGNAL_LABEL = "com.colloid.phone-link-signal"
LINK_LABEL = "com.colloid.phone-link"
BACKUP_SUFFIX = ".pre-phone-link"
SIGNAL_FLAGS = ("--no-receive-stdout", "--ignore-attachments", "--ignore-avatars", "--ignore-stickers",
                "--ignore-stories")
AGENT_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
UNLOAD_SECONDS = 5


class Refusal(Exception):
    """A reason to change nothing, worded for the operator."""


class Run:
    """The changes of one run, collected first and made after, so a refusal changes nothing."""

    def __init__(self, check: bool):
        self.check, self.changes = check, []

    def change(self, text: str, do) -> None:
        self.changes.append((text, do))

    def same(self, text: str) -> None:
        print(f"unchanged: {text}")

    def finish(self) -> None:
        for text, do in self.changes:
            if self.check:
                print(f"would: {text}")
            else:
                do()
                print(text)
        if not self.changes:
            print("nothing to change")


# --- links -------------------------------------------------------------------

def adapters(here: Path) -> list:
    return sorted((here / "hooks").glob("phone-*.sh"))


def links(run: Run, home: Path, here: Path, remove: bool) -> None:
    for adapter in adapters(here):
        target = home / ".local" / "bin" / adapter.name
        ours = target.is_symlink() and os.readlink(target) == str(adapter)
        if remove:
            if ours:
                run.change(f"removed: {target}", target.unlink)
        elif ours:
            run.same(str(target))
        elif target.exists() or target.is_symlink():
            raise Refusal(f"{target} exists and is not a link to {adapter}; not replacing it")
        else:
            run.change(f"linked: {target} -> {adapter}",
                       lambda target=target, adapter=adapter: (target.parent.mkdir(parents=True, exist_ok=True),
                                                               target.symlink_to(adapter)))


# --- the settings of each account --------------------------------------------

def hook_command(home: Path) -> str:
    return shlex.quote(str(home / ".local" / "bin" / "phone-permission.sh"))


def our_entry(command: str) -> dict:
    return {"matcher": MATCHER, "hooks": [{"type": "command", "command": command, "timeout": client.HOOK_TIMEOUT}]}


def _entries(settings: dict, path) -> list:
    hooks = settings.get("hooks", {})
    entries = hooks.get(EVENT, []) if isinstance(hooks, dict) else None
    if not isinstance(entries, list):
        raise Refusal(f"{path}: `hooks` is not an object of lists; not changing it")
    return entries


def _is_ours(hook, command: str) -> bool:
    return isinstance(hook, dict) and hook.get("command") == command


def _our_hooks(settings: dict, command: str, path) -> int:
    """How many hooks of the PermissionRequest entries run the phone link's command."""
    return sum(_is_ours(hook, command) for entry in _entries(settings, path)
               if isinstance(entry, dict) and isinstance(entry.get("hooks"), list) for hook in entry["hooks"])


def without_entry(settings: dict, command: str, path) -> dict:
    """`settings` without the phone link's hook. An entry, the event's list and the `hooks`
    object go too when that leaves them empty; nothing else changes."""
    if not _our_hooks(settings, command, path):
        return settings
    result = copy.deepcopy(settings)
    kept = []
    for entry in result["hooks"][EVENT]:
        if isinstance(entry, dict) and isinstance(entry.get("hooks"), list):
            others = [hook for hook in entry["hooks"] if not _is_ours(hook, command)]
            if not others and entry["hooks"]:
                continue
            entry["hooks"] = others
        kept.append(entry)
    result["hooks"][EVENT] = kept
    if not kept:
        del result["hooks"][EVENT]
    if not result["hooks"]:
        del result["hooks"]
    return result


def with_entry(settings: dict, command: str, path) -> dict:
    """`settings` with the phone link's hook once, in an entry of its own as `our_entry` gives
    it. An entry of an earlier install that differs (another matcher or timeout) is replaced."""
    if _our_hooks(settings, command, path) == 1 and our_entry(command) in _entries(settings, path):
        return settings
    result = copy.deepcopy(without_entry(settings, command, path))
    result.setdefault("hooks", {}).setdefault(EVENT, []).append(our_entry(command))
    return result


def _write_settings(path: Path, settings: dict, before) -> None:
    backup = path.with_name(path.name + BACKUP_SUFFIX)
    if before is not None and not backup.exists():
        shutil.copy2(path, backup)
    temporary = path.with_name(f".{path.name}.phone-link.tmp")
    temporary.write_text(json.dumps(settings, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if before is not None:
        shutil.copymode(path, temporary)
    os.replace(temporary, path)


def settings(run: Run, home: Path, remove: bool) -> None:
    files: dict = {}  # the real file -> the accounts whose settings it is
    for account in ACCOUNTS:
        if (home / account).is_dir():
            files.setdefault(Path(os.path.realpath(home / account / "settings.json")), []).append(account)
    if not files and not remove:
        raise Refusal(f"no Claude account folder ({', '.join(ACCOUNTS)}) is in {home}")
    command = hook_command(home)
    for path, accounts in files.items():
        named = f"{path} (the settings of {', '.join(accounts)})"
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            text = None
        try:
            before = json.loads(text) if text is not None else {}
        except ValueError as error:
            raise Refusal(f"{path} is not JSON ({error}); not changing it")
        if not isinstance(before, dict):
            raise Refusal(f"{path} does not hold a JSON object; not changing it")
        after = without_entry(before, command, path) if remove else with_entry(before, command, path)
        if after == before:
            if not remove or text is not None:
                run.same(f"{named}{'' if remove else ' holds the hook'}")
            continue
        verb = "the phone link's hook removed from" if remove else "the phone link's hook added to"
        run.change(f"{verb} {named}",
                   lambda path=path, after=after, text=text: _write_settings(path, after, text))


# --- the state folder -----------------------------------------------------------

def state_folder(run: Run, state: Path) -> None:
    def make() -> None:
        log.prepare(state)
        log.prepare(state / "signal")
        errors = state / "errors.log"
        os.close(os.open(errors, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600))
        os.chmod(errors, 0o600)

    def mode(path: Path):
        return path.stat().st_mode & 0o777 if path.exists() else None
    if (mode(state), mode(state / "signal"), mode(state / "errors.log")) == (0o700, 0o700, 0o600):
        run.same(str(state))
    else:
        run.change(f"state folder made: {state} (0700), with signal/ (0700) and errors.log (0600)", make)


# --- launchd --------------------------------------------------------------------

class Launchd:
    def __init__(self, program: str):
        self.program, self.domain = program, f"gui/{os.getuid()}"

    def _call(self, *arguments: str):
        return subprocess.run([self.program, *arguments], capture_output=True, text=True)

    def loaded(self, label: str) -> bool:
        return self._call("print", f"{self.domain}/{label}").returncode == 0

    def start(self, plist: Path) -> None:
        done = self._call("bootstrap", self.domain, str(plist))
        if done.returncode:
            raise Refusal(f"launchctl bootstrap {self.domain} {plist} failed: {done.stderr.strip() or done.returncode}")

    def stop(self, label: str) -> None:
        done = self._call("bootout", f"{self.domain}/{label}")
        if done.returncode:
            raise Refusal(f"launchctl bootout {self.domain}/{label} failed: {done.stderr.strip() or done.returncode}")
        # launchd unloads after it answers; a start before that fails.
        limit = time.time() + UNLOAD_SECONDS
        while self.loaded(label) and time.time() < limit:
            time.sleep(0.1)


def launchctl(environ, home: Path) -> Launchd:
    named = environ.get("PHONE_LINK_LAUNCHCTL")
    if named:
        return Launchd(named)
    real_home = pwd.getpwuid(os.getuid()).pw_dir
    if os.path.realpath(home) != os.path.realpath(real_home):
        raise Refusal(f"HOME is {home}, not this user's home {real_home}: launchd agents are the user's, so the "
                      "phone link installs into the real home only (a test names a stand-in in PHONE_LINK_LAUNCHCTL)")
    program = shutil.which("launchctl")
    if not program:
        raise Refusal("launchctl is not on PATH: the phone link's Mac install needs launchd")
    return Launchd(program)


def agent_plists(here: Path, state: Path, signal_cli: str, python: str, zone: str) -> dict:
    """label -> the launchd agent's property list."""
    path = f"{os.path.dirname(signal_cli)}:{AGENT_PATH}"
    return {
        SIGNAL_LABEL: {
            "Label": SIGNAL_LABEL,
            "ProgramArguments": [signal_cli, "daemon", "--socket", str(state / "signal" / "socket"), *SIGNAL_FLAGS],
            "EnvironmentVariables": {"PATH": path},
            # Its socket and its data are the owner's alone.
            "Umask": 0o077,
            "RunAtLoad": True, "KeepAlive": True,
            # Nothing signal-cli says about a message of any chat is kept.
            "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null",
        },
        LINK_LABEL: {
            "Label": LINK_LABEL,
            "ProgramArguments": [python, str(here / "phone_link.py"), "--zone", zone, "--state", str(state)],
            "EnvironmentVariables": {"PATH": path},
            "RunAtLoad": True, "KeepAlive": True,
            "StandardOutPath": "/dev/null", "StandardErrorPath": str(state / "errors.log"),
        },
    }


def _plist_path(home: Path, label: str) -> Path:
    return home / "Library" / "LaunchAgents" / f"{label}.plist"


def _read_plist(path: Path):
    try:
        with open(path, "rb") as stream:
            return plistlib.load(stream)
    except FileNotFoundError:
        return None
    except (plistlib.InvalidFileException, ValueError):
        return {}  # Not a property list: it differs from ours, and is replaced.


def _write_plist(path: Path, content: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as stream:
        plistlib.dump(content, stream)


def agents(run: Run, home: Path, launchd: Launchd, plists: dict) -> None:
    for label, content in plists.items():
        path = _plist_path(home, label)
        differs, loaded = _read_plist(path) != content, launchd.loaded(label)
        if differs:
            run.change(f"launchd agent written: {path}", lambda path=path, content=content: _write_plist(path, content))
        if differs and loaded:
            run.change(f"restarted: {label}",
                       lambda path=path, label=label: (launchd.stop(label), launchd.start(path)))
        elif not loaded:
            run.change(f"started: {label}", lambda path=path: launchd.start(path))
        else:
            run.same(f"{label} is loaded (after a code change, restart it: "
                     f"launchctl kickstart -k {launchd.domain}/{label})")


def remove_agents(run: Run, home: Path, launchd: Launchd) -> None:
    for label in (LINK_LABEL, SIGNAL_LABEL):
        path = _plist_path(home, label)
        if launchd.loaded(label):
            run.change(f"stopped: {label}", lambda label=label: launchd.stop(label))
        if path.exists():
            run.change(f"removed: {path}", path.unlink)


# --- the run ----------------------------------------------------------------------

def local_zone() -> str:
    """This Mac's time zone, from where /etc/localtime points."""
    target = os.path.realpath("/etc/localtime")
    if "/zoneinfo/" not in target:
        raise Refusal("cannot tell this machine's time zone from /etc/localtime; name the phone's with --zone")
    return target.split("/zoneinfo/", 1)[1]


def main(argv, environ) -> int:
    parser = argparse.ArgumentParser(description="Install or remove the phone link's parts for this user.")
    parser.add_argument("mode", choices=("install", "uninstall"))
    parser.add_argument("--check", action="store_true", help="print the changes and make none")
    parser.add_argument("--zone", help="the phone's time zone (default: this machine's)")
    args = parser.parse_args(argv[1:])
    home, here = Path(environ["HOME"]), Path(__file__).resolve().parent
    state = home / ".local" / "state" / "phone-link"
    run = Run(args.check)
    try:
        launchd = launchctl(environ, home)
        if args.mode == "uninstall":
            if args.zone:
                raise Refusal("--zone belongs to an install")
            remove_agents(run, home, launchd)
            settings(run, home, remove=True)
            links(run, home, here, remove=True)
        else:
            zone = args.zone or local_zone()
            try:
                ZoneInfo(zone)
            except (ZoneInfoNotFoundError, ValueError) as error:
                raise Refusal(f"--zone {zone!r} is not a time zone this system knows ({error})")
            signal_cli = environ.get("PHONE_LINK_SIGNAL_CLI") or shutil.which("signal-cli")
            if not signal_cli or not os.access(signal_cli, os.X_OK):
                raise Refusal("signal-cli is not installed (brew install signal-cli), or PHONE_LINK_SIGNAL_CLI "
                              "does not name it; it must also be linked to the operator's Signal account")
            python = shutil.which("python3")
            if not python:
                raise Refusal("python3 is not on PATH")
            links(run, home, here, remove=False)
            settings(run, home, remove=False)
            state_folder(run, state)
            agents(run, home, launchd, agent_plists(here, state, signal_cli, python, zone))
        run.finish()
    except Refusal as refusal:
        print(f"install.sh: {refusal}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv, os.environ))
