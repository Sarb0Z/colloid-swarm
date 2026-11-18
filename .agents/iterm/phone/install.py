#!/usr/bin/env python3
"""Install or remove the phone link's parts for this user. `.agents/iterm/install.sh` runs it.

  install.py install [--check] [--zone <IANA zone>] [--tls-proxy HOST:PORT|none]
  install.py uninstall [--check]

`install` puts in place, and leaves alone what already is:

  1. A link `~/.local/bin/<name>` to each iTerm2 pane command of `../bin` and
     each hook adapter of `hooks/`.
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
  4. The Signal TLS proxy setting, `<state>/tls-proxy` (`tls_proxy.py`):
     written by `--tls-proxy HOST:PORT`, removed by `--tls-proxy none`, and
     kept as it is by an install without the flag.
  5. Two launchd agents of this user: `signal-cli daemon` on a Unix socket in
     the state folder, with no TCP or HTTP port and nothing downloaded or
     printed, and with `--tls-proxy HOST:PORT` before `daemon` while a proxy
     is set; and `phone_link.py`, with the phone's time zone (`--zone`,
     default this Mac's).

`uninstall` removes exactly the hook links, the settings entries and the two
agents, in that order, so no session calls the hook while its agents go. Each
step runs whatever became of the ones before, and every failure is reported at
the end, with exit 1. It keeps the pane commands, the state folder and
signal-cli's own data, which hold the event log and the account keys (and the
saved proxy setting): the spec's Undo section says how to remove them.

`--check` prints each change it would make and makes none.

Before the first change, the run reads everything it will touch. A settings
file that is not a JSON object, a file in the way of a link, a missing
signal-cli or a zone the system does not know stops it with nothing changed.
A settings file that changed after the run read it is not written. When an
install's change fails (that, or a launchctl call), the run takes back the
links and settings entries it made, names what it leaves (the state folder,
the agents' files, an agent it started) and the uninstall that removes it, and
exits 1.
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
import tls_proxy

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


class Failed(Exception):
    """A change that could not be made, worded for the operator. Changes before it stand
    until the run takes them back."""


class Run:
    """The changes of one run, collected first and made after, so a refusal changes nothing.
    `undo` takes a change back, for a change that has a way back."""

    def __init__(self, check: bool, script: str):
        self.check, self.script, self.changes = check, script, []

    def change(self, text: str, do, undo=None) -> None:
        self.changes.append((text, do, undo))

    def same(self, text: str) -> None:
        print(f"unchanged: {text}")

    def _preview(self) -> bool:
        """Under --check, or with nothing to change: say so, and True."""
        if self.check:
            for text, _do, _undo in self.changes:
                print(f"would: {text}")
        if not self.changes:
            print("nothing to change")
        return self.check or not self.changes

    def finish_whole(self) -> None:
        """Make every change in order. On a failure, take back each change made that has a
        way back, newest first, and raise Failed naming what was taken back, what is left
        and the command that removes what is left."""
        if self._preview():
            return
        made = []
        for text, do, undo in self.changes:
            try:
                do()
            except (Failed, OSError) as failure:
                said = f"{text} failed: {failure}" if isinstance(failure, OSError) else str(failure)
                raise Failed("\n".join([said, *self._take_back(made)])) from failure
            print(text)
            made.append((text, undo))

    def _take_back(self, made: list) -> list:
        lines, left = [], []
        for text, undo in reversed(made):
            if undo is None:
                left.append(text)
                continue
            try:
                undo()
                lines.append(f"taken back: {text}")
            except (Failed, OSError) as failure:
                left.append(f"{text} (not taken back: {failure})")
        if left:
            lines.extend(f"left in place: {text}" for text in reversed(left))
            lines.append(f"remove it with: {self.script} --uninstall")
        return lines

    def finish_each(self) -> None:
        """Make every change in order, each whatever became of the ones before, and raise
        Failed naming every failure at the end."""
        if self._preview():
            return
        failures = []
        for text, do, _undo in self.changes:
            try:
                do()
            except (Failed, OSError) as failure:
                failures.append(f"{text} failed: {failure}" if isinstance(failure, OSError) else str(failure))
                continue
            print(text)
        if failures:
            raise Failed("\n".join(failures))


# --- links -------------------------------------------------------------------

def adapters(here: Path) -> list:
    return sorted((here / "hooks").glob("phone-*.sh"))


def pane_commands(here: Path) -> list:
    """The iTerm2 pane commands of `.agents/iterm/bin` and the Dev server tab's `connect/dev-server`,
    which an install links beside the hooks and an uninstall leaves."""
    return sorted([*(path for path in (here.parent / "bin").iterdir() if path.is_file()),
                   here.parent / "connect" / "dev-server"])


def links(run: Run, home: Path, sources: list, remove: bool) -> None:
    for adapter in sources:
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
                                                               target.symlink_to(adapter)),
                       target.unlink)


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


def _bytes_of(path: Path):
    try:
        return path.read_bytes()
    except FileNotFoundError:
        return None


def _replace(path: Path, content, read) -> None:
    """Put `content` (bytes, or None for no file) at `path`, when the file there is still
    `read` (the bytes this run read, or None for no file); otherwise raise Failed and write
    nothing. Another writer's change between the read and the replace is not lost."""
    temporary = path.with_name(f".{path.name}.phone-link.tmp")
    if content is not None:
        temporary.write_bytes(content)
        if read is not None:
            shutil.copymode(path, temporary)
    # A window remains between this read and the replace; it is as short as a check can make it.
    if _bytes_of(path) != read:
        temporary.unlink(missing_ok=True)
        raise Failed(f"{path} changed after this run read it; it was left as the other writer made it. "
                     "Run the install again")
    if content is None:
        path.unlink()
    else:
        os.replace(temporary, path)


class SettingsWrite:
    """One settings.json written from the bytes read to `after`, with its way back."""

    def __init__(self, path: Path, read, after: dict):
        self.path, self.read = path, read
        self.after = (json.dumps(after, indent=2, ensure_ascii=False) + "\n").encode()
        self.backup = path.with_name(path.name + BACKUP_SUFFIX)
        self.made_backup = False

    def do(self) -> None:
        if self.read is not None and not self.backup.exists():
            shutil.copy2(self.path, self.backup)
            self.made_backup = True
        _replace(self.path, self.after, self.read)

    def undo(self) -> None:
        _replace(self.path, self.read, self.after)
        if self.made_backup:
            self.backup.unlink()


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
        read = _bytes_of(path)
        try:
            before = json.loads(read.decode("utf-8")) if read is not None else {}
        except ValueError as error:  # UnicodeDecodeError is a ValueError too
            raise Refusal(f"{path} is not JSON ({error}); not changing it")
        if not isinstance(before, dict):
            raise Refusal(f"{path} does not hold a JSON object; not changing it")
        after = without_entry(before, command, path) if remove else with_entry(before, command, path)
        if after == before:
            if not remove or read is not None:
                run.same(f"{named}{'' if remove else ' holds the hook'}")
            continue
        verb = "the phone link's hook removed from" if remove else "the phone link's hook added to"
        write = SettingsWrite(path, read, after)
        run.change(f"{verb} {named}", write.do, write.undo)


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


# --- the TLS proxy setting -------------------------------------------------------

def _write_setting(path: Path, content: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        os.fchmod(descriptor, 0o600)
        stream.write(content)


def proxy_setting(run: Run, state: Path, asked):
    """The TLS proxy signal-cli's agent gets, `HOST:PORT` or None: `asked` (`HOST:PORT`, or
    `none` for no proxy), else the saved one. Saving or clearing it is a change of this run."""
    path = state / tls_proxy.FILE
    if asked is None:
        try:
            return tls_proxy.read(state)
        except ValueError as error:
            raise Refusal(f"{error}; set it again with --tls-proxy HOST:PORT, or none")
    wanted = None if asked == "none" else asked
    if wanted is not None:
        try:
            tls_proxy.parse(wanted)
        except ValueError:
            raise Refusal(f"--tls-proxy takes HOST:PORT or none, for example 62.171.166.213:8443; not {asked!r}")
    read = _bytes_of(path)
    content = None if wanted is None else f"{wanted}\n".encode()
    if read == content:
        run.same(f"TLS proxy: {wanted or 'none'}")
        return wanted

    def back() -> None:
        if read is None:
            path.unlink(missing_ok=True)
        else:
            _write_setting(path, read)
    if wanted is None:
        run.change(f"TLS proxy cleared: {path} removed", path.unlink, back)
    else:
        run.change(f"TLS proxy saved: {wanted} in {path}", lambda: _write_setting(path, content), back)
    return wanted


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
            raise Failed(f"launchctl bootstrap {self.domain} {plist} failed: {done.stderr.strip() or done.returncode}")

    def stop(self, label: str) -> None:
        done = self._call("bootout", f"{self.domain}/{label}")
        if done.returncode:
            raise Failed(f"launchctl bootout {self.domain}/{label} failed: {done.stderr.strip() or done.returncode}")
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


def agent_plists(here: Path, state: Path, signal_cli: str, python: str, zone: str, proxy) -> dict:
    """label -> the launchd agent's property list. `proxy` is the TLS proxy's `HOST:PORT`, or
    None; signal-cli takes it as a global option, before the command."""
    path = f"{os.path.dirname(signal_cli)}:{AGENT_PATH}"
    global_options = ["--tls-proxy", proxy] if proxy else []
    return {
        SIGNAL_LABEL: {
            "Label": SIGNAL_LABEL,
            "ProgramArguments": [signal_cli, *global_options, "daemon", "--socket", str(state / "signal" / "socket"),
                                 *SIGNAL_FLAGS],
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
    parser.add_argument("--tls-proxy", help="the Signal TLS proxy as HOST:PORT, or none (default: the saved one)")
    args = parser.parse_args(argv[1:])
    home, here = Path(environ["HOME"]), Path(__file__).resolve().parent
    state = home / ".local" / "state" / "phone-link"
    run = Run(args.check, str(here.parent / "install.sh"))
    try:
        launchd = launchctl(environ, home)
        if args.mode == "uninstall":
            if args.zone:
                raise Refusal("--zone belongs to an install")
            if args.tls_proxy:
                raise Refusal("--tls-proxy belongs to an install")
            # What makes a session call the hook goes first, so a launchctl step that fails
            # leaves no session waiting on a service that is going.
            settings(run, home, remove=True)
            links(run, home, adapters(here), remove=True)
            remove_agents(run, home, launchd)
            run.finish_each()
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
            links(run, home, [*pane_commands(here), *adapters(here)], remove=False)
            settings(run, home, remove=False)
            state_folder(run, state)
            proxy = proxy_setting(run, state, args.tls_proxy)
            agents(run, home, launchd, agent_plists(here, state, signal_cli, python, zone, proxy))
            run.finish_whole()
    except (Refusal, Failed) as problem:
        print(f"install.sh: {problem}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv, os.environ))
