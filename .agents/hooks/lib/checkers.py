#!/usr/bin/env python3
"""What the post-edit hook asks about a checker beyond running it.

A repository that configures a checker has asked for it, so a configured
checker that cannot run, and a run whose output cannot be read, are findings.
A checker the repository never configured stays silent.

Usage:
  checkers.py missing <checker> <project> <session> <path>...
      The hook could not resolve the checker's binary for these edited paths.
      Prints `[<checker>] configured in <config> but not installed: <command>`
      the first time a session meets that checker in that workspace, nothing
      after, and nothing at all when no config is found. Always records the
      checker as missing in the checks ledger and refreshes the `checks` readout.
  checkers.py ran <checker> <project> <path>...
      The binary resolved for these paths: the workspace leaves the ledger.
  checkers.py tsc <project> <session> <workspace> <config> <exit-status> <rel>...
      tsc's output on stdin. Prints the findings: errors in the edited files
      (`<rel>...`), errors in the tsconfig itself, a run that exited non-zero
      with no error line, and errors outside the edited files that are new
      since the session's last run in that workspace.
  checkers.py pyright <project> <workspace> <exit-status> <stderr-file> <1 if a diagnostic was scoped, else 0>
      pyright's --outputjson on stdin. Prints a finding only when the run
      cannot be trusted; diagnostics are tool-errors.py's.
  checkers.py main-root <project>
      The main checkout of the repository the project belongs to.

State lives in `.agents/.readout/` as non-JSON files, which readout.py prunes
after a week: `checks-seen--<session>--<hash>` (created with O_EXCL, so of
concurrent background checks exactly one is first), `checks-outside--...` (the
errors outside the edited files at the last tsc run) and `checks-ledger` (the
missing checkers, from which the `checks` readout is regenerated).
"""

import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_reports  # noqa: E402
import readout  # noqa: E402

LEDGER = "checks-ledger"
READOUT_STALE_AFTER = 604800

ESLINT_FLAT = tuple(f"eslint.config.{ext}" for ext in ("js", "mjs", "cjs", "ts", "mts", "cts"))
ESLINT_LEGACY = (".eslintrc", ".eslintrc.js", ".eslintrc.cjs", ".eslintrc.json",
                 ".eslintrc.yaml", ".eslintrc.yml")


def read_text(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError:
        return ""


def package_has(directory, key):
    try:
        data = json.loads(read_text(os.path.join(directory, "package.json")) or "null")
    except ValueError:
        return False
    return isinstance(data, dict) and key in data


def toml_section(directory, prefix):
    """True when the directory's pyproject.toml opens a `[prefix...]` table."""
    text = read_text(os.path.join(directory, "pyproject.toml"))
    return re.search(rf"^\[{re.escape(prefix)}(\.[^\]]*)?\]", text, flags=re.M) is not None


def first_file(directory, names):
    for name in names:
        if os.path.isfile(os.path.join(directory, name)):
            return name
    return None


def prefixed_file(directory, prefixes):
    try:
        entries = sorted(os.listdir(directory))
    except OSError:
        return None
    for entry in entries:
        if entry.startswith(prefixes) and os.path.isfile(os.path.join(directory, entry)):
            return entry
    return None


def ruff_config(directory):
    return (first_file(directory, ("ruff.toml", ".ruff.toml"))
            or ("pyproject.toml" if toml_section(directory, "tool.ruff") else None))


def eslint_config(directory):
    return (first_file(directory, ESLINT_FLAT + ESLINT_LEGACY)
            or ("package.json" if package_has(directory, "eslintConfig") else None))


def prettier_config(directory):
    return (prefixed_file(directory, (".prettierrc", "prettier.config."))
            or ("package.json" if package_has(directory, "prettier") else None))


def tsc_config(directory):
    return first_file(directory, ("tsconfig.json",))


def pyright_config(directory):
    return (first_file(directory, ("pyrightconfig.json",))
            or ("pyproject.toml" if toml_section(directory, "tool.pyright") else None))


def dart_config(directory):
    """analysis_options.yaml counts only beside a pubspec.yaml: the package root."""
    if os.path.isfile(os.path.join(directory, "pubspec.yaml")):
        return first_file(directory, ("analysis_options.yaml",))
    return None


# checker -> (config finder, package that provides it, ecosystem)
CHECKERS = {
    "ruff": (ruff_config, "ruff", "python"),
    "pyright": (pyright_config, "pyright", "python"),
    "eslint": (eslint_config, "eslint", "node"),
    "prettier": (prettier_config, "prettier", "node"),
    "tsc": (tsc_config, "typescript", "node"),
    "dart": (dart_config, "dart", "dart"),
}


def find_config(checker, path, project):
    """(config path, its directory) for the nearest config at or above `path`."""
    finder = CHECKERS[checker][0]
    directory = path if os.path.isdir(path) else os.path.dirname(path)
    while True:
        name = finder(directory)
        if name:
            return os.path.join(directory, name), directory
        if directory == project or directory == os.path.dirname(directory):
            return None, None
        directory = os.path.dirname(directory)


def node_manager(directory, project):
    lockfiles = (("pnpm-lock.yaml", "pnpm"), ("bun.lock", "bun"), ("bun.lockb", "bun"),
                 ("yarn.lock", "yarn"), ("package-lock.json", "npm"))
    while True:
        for lockfile, manager in lockfiles:
            if os.path.isfile(os.path.join(directory, lockfile)):
                return manager
        if directory == project or directory == os.path.dirname(directory):
            return "npm"
        directory = os.path.dirname(directory)


def node_declares(directory, package):
    try:
        data = json.loads(read_text(os.path.join(directory, "package.json")) or "null")
    except ValueError:
        return False
    return isinstance(data, dict) and any(
        package in (data.get(section) or {}) for section in ("dependencies", "devDependencies"))


def install_command(checker, directory, project):
    _, package, ecosystem = CHECKERS[checker]
    if ecosystem == "dart":
        return "install the Dart SDK, then run `dart pub get` (`flutter pub get` for a Flutter package)"
    if ecosystem == "python":
        if not os.path.isfile(os.path.join(directory, "pyproject.toml")):
            return f"uv tool install {package}"
        # A quoted requirement ("ruff>=0.5"), not a `[tool.ruff]` table.
        declared = re.search(rf"[\"']{re.escape(package)}[\s<>=~!\[;\"']",
                             read_text(os.path.join(directory, "pyproject.toml")))
        return "uv sync" if declared else f"uv add --dev {package}"
    manager = node_manager(directory, project)
    if node_declares(directory, package):
        return f"{manager} install"
    return f"{manager} {'install' if manager == 'npm' else 'add'} -D {package}"


def state_folder(project):
    path = readout.folder(project)
    path.mkdir(parents=True, exist_ok=True)
    return path


def key(session, *parts):
    digest = hashlib.sha256("\0".join(parts).encode()).hexdigest()[:10]
    return f"{readout.clean_session(session) or 'nosession'}--{digest}"


def replace_atomically(directory, target, text):
    handle, temp = tempfile.mkstemp(dir=directory, prefix=".write-", suffix=".tmp")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            out.write(text)
        os.replace(temp, target)
    except BaseException:
        os.unlink(temp)
        raise


def first_time(directory, name):
    """True for exactly one caller per name: the one whose create succeeds."""
    try:
        os.close(os.open(directory / name, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644))
    except FileExistsError:
        return False
    return True


class Ledger:
    """The missing checkers as tab-separated rows, locked for the read-modify-write
    because background checks run concurrently. Writing it refreshes the `checks`
    readout, so the two never disagree."""

    def __init__(self, project):
        self.project = project
        self.directory = state_folder(project)
        self.path = self.directory / LEDGER

    def __enter__(self):
        self.lock = open(self.directory / f"{LEDGER}.lock", "w")
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        self.rows = {}
        for line in read_text(self.path).splitlines():
            checker, workspace, config, command = line.split("\t")
            self.rows[(checker, workspace)] = (config, command)
        return self

    def __exit__(self, *exc):
        self.lock.close()

    def save(self):
        text = "".join(f"{c}\t{w}\t{cfg}\t{cmd}\n" for (c, w), (cfg, cmd) in sorted(self.rows.items()))
        replace_atomically(self.directory, self.path, text)
        names = sorted({checker for checker, _ in self.rows})
        note = "\n".join(f"{c}: configured in {cfg}, not installed: {cmd}"
                         for (c, _), (cfg, cmd) in sorted(self.rows.items()))
        readout.write(self.project, "checks", strip=f"checks: {', '.join(names)} missing" if names else "",
                      note=note, stale_after=READOUT_STALE_AFTER)


def relative(path, project):
    return os.path.relpath(path, project)


def missing(checker, project, session, paths):
    reports = []
    with Ledger(project) as ledger:
        changed = False
        for path in paths:
            config, workspace = find_config(checker, path, project)
            if not config:
                continue
            workspace_rel = relative(workspace, project)
            command = install_command(checker, workspace, project)
            row = (relative(config, project), command)
            if ledger.rows.get((checker, workspace_rel)) != row:
                ledger.rows[(checker, workspace_rel)] = row
                changed = True
            seen = f"checks-seen--{key(session, checker, workspace_rel)}"
            if first_time(ledger.directory, seen):
                reports.append(f"[{checker}] configured in {row[0]} but not installed: {command}")
        if changed:
            ledger.save()
    return "\n".join(dict.fromkeys(reports))


def ran(checker, project, paths):
    if not (readout.folder(project) / LEDGER).exists():
        return                                # nothing was ever missing here
    with Ledger(project) as ledger:
        dropped = False
        for path in paths:
            _, workspace = find_config(checker, path, project)
            if workspace and ledger.rows.pop((checker, relative(workspace, project)), None):
                dropped = True
        if dropped:
            ledger.save()


def locked_folder(project):
    """The state folder, with an exclusive lock held on it until the handle closes.
    The lock is on the folder itself: readout.py's prune deletes stale files in it
    but never the folder."""
    handle = os.open(state_folder(project), os.O_RDONLY)
    fcntl.flock(handle, fcntl.LOCK_EX)
    return handle


def baseline_swapper(project, session, workspace):
    """The baseline of tsc errors for this session and workspace, as a function:
    it stores the lines it is given and returns the previous ones (None before
    the first run). Read and replace happen under the folder lock, because two
    background checks can finish together."""
    def swap(lines):
        handle = locked_folder(project)
        try:
            directory = state_folder(project)
            target = directory / f"checks-outside--{key(session, 'tsc', relative(workspace, project))}"
            previous = read_text(target).splitlines() if target.exists() else None
            replace_atomically(directory, target, "".join(f"{line}\n" for line in lines))
            return previous
        finally:
            os.close(handle)
    return swap


def tsc(project, session, workspace, config, status, rels, raw):
    return check_reports.tsc(project, workspace, config, status, rels, raw,
                             baseline_swapper(project, session, workspace))


def pyright(project, workspace, status, stderr_path, scoped, raw):
    return check_reports.pyright(project, workspace, status, read_text(stderr_path), raw, scoped)


def main_checkout(project):
    """The main checkout of the repository `project` belongs to, which is the
    project itself outside a linked worktree and outside Git."""
    try:
        done = subprocess.run(
            ["git", "-C", project, "rev-parse", "--path-format=absolute", "--git-common-dir"],
            capture_output=True, text=True)
    except OSError:
        return os.path.realpath(project)
    common = done.stdout.strip()
    if done.returncode != 0 or not common:
        return os.path.realpath(project)
    return os.path.dirname(os.path.realpath(common))


def main(argv):
    command, args = (argv[0], argv[1:]) if argv else ("", [])
    if command == "missing" and len(args) >= 4 and args[0] in CHECKERS:
        out = missing(args[0], args[1], args[2], args[3:])
    elif command == "ran" and len(args) >= 3 and args[0] in CHECKERS:
        ran(args[0], args[1], args[2:])
        out = ""
    elif command == "tsc" and len(args) >= 6:
        out = tsc(args[0], args[1], args[2], args[3], int(args[4]), args[5:], sys.stdin.read())
    elif command == "pyright" and len(args) == 5:
        out = pyright(args[0], args[1], int(args[2]), args[3], args[4] == "1", sys.stdin.read())
    elif command == "main-root" and len(args) == 1:
        out = main_checkout(args[0])
    else:
        raise SystemExit(__doc__)
    if out:
        print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
