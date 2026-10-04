#!/usr/bin/env python3
"""Drive browser-sync.py against a synthetic Chrome cookie store.

The source is a SQLite file with the columns of Chrome's `cookies` table that
the sync reads, built here. No real Chrome profile is opened. The repository
under test is a fixture copy, a Git work tree, so the ignore checks are real.
"""

import contextlib
import importlib.util
import io
import json
import os
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

# A caller such as `git rebase -x` exports these; the git calls below must
# reach only their own temporary repositories.
for _name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX", "GIT_COMMON_DIR"):
    os.environ.pop(_name, None)

here = Path(__file__).resolve().parent
fails = 0


def check(name, ok, detail=""):
    global fails
    if ok:
        print(f"ok    {name}")
    else:
        fails += 1
        print(f"FAIL  {name}{(chr(10) + '  ' + str(detail)) if detail else ''}")


# Each row: (host_key, top_frame_site_key, kept when zillow.com,
# listed.localhost, and www.example.com are listed). Names and values are unique so any leak into
# output is findable.
ROWS = [
    ("zillow.com", "", True),
    (".zillow.com", "", True),
    ("www.zillow.com", "", True),
    ("notzillow.com", "", False),
    (".notzillow.com", "", False),
    ("zillow.com.evil.net", "", False),
    ("other.com", "", False),
    (".zillow.com", "https://other.com", False),
    (".zillow.com", "https://zillow.com", True),
    ("listed.localhost", "", True),
    ("unlisted.localhost", "", False),
    # A listed subdomain gets the parent's domain cookies Chrome sends to it,
    # and neither the parent's host-only cookies nor a sibling's.
    ("www.example.com", "", True),
    (".example.com", "", True),
    ("example.com", "", False),
    ("api.example.com", "", False),
]
SITES = ["https://Zillow.com/homes/", "listed.localhost", "www.example.com", "nothing-here.org"]


def write_store(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path)
    db.execute("CREATE TABLE meta(key TEXT NOT NULL UNIQUE PRIMARY KEY, value TEXT)")
    db.execute("INSERT INTO meta VALUES ('version', '24')")
    db.execute("CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, "
               "top_frame_site_key TEXT NOT NULL, name TEXT NOT NULL, value TEXT NOT NULL, "
               "encrypted_value BLOB NOT NULL, path TEXT NOT NULL, expires_utc INTEGER NOT NULL)")
    for index, (host, top, _) in enumerate(ROWS):
        db.execute("INSERT INTO cookies VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                   (index, host, top, f"cookie-name-{index}", f"cookie-value-{index}",
                    f"v10sealed-{index}".encode(), "/", 0))
    db.commit()
    db.close()


def rows_of(path):
    db = sqlite3.connect(path)
    try:
        return sorted(db.execute("SELECT host_key, top_frame_site_key FROM cookies"))
    finally:
        db.close()


def fixture(root):
    agents = root / ".agents"
    (agents / "codex").mkdir(parents=True)
    for name in ("mcp.py", "mcp_codex.py", "mcp_playwright.py", "browser-sync.py", "playwright-session.py"):
        shutil.copy2(here / name, agents / name)
    (agents / "codex/config.toml").write_text('model = "fixture"\n')
    (agents / "mcp.json").write_text(json.dumps({"mcpServers": {"playwright": {
        "description": "Fixture browser.", "enabled": True, "type": "stdio", "command": "npx",
        "args": ["-y", "fixture-playwright", "--config",
                 "${REPO_ROOT}/.agents/.browser/playwright.json"]}}}))
    (agents / "config.json").write_text(json.dumps({"browser": {"sync_sites": SITES}}))
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    return agents


def load(agents):
    sys.path.insert(0, str(agents))
    spec = importlib.util.spec_from_file_location("browser_sync", agents / "browser-sync.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(module, argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        status = module.main(argv, platform="darwin")
    return status, out.getvalue(), err.getvalue()


def leaked(text):
    return [needle for needle in ("cookie-name-", "cookie-value-", "v10sealed-", "other.com",
                                  "notzillow", "unlisted.localhost", "evil.net", "api.example.com")
            if needle in text]


def files_mentioning(directory, needle):
    return [path for path in directory.rglob("*") if path.is_file() and needle in path.read_bytes()]


os.environ.pop("PLAYWRIGHT_PROXY", None)
work = Path(tempfile.mkdtemp(prefix="browser-sync-test-")).resolve()
try:
    repo = work / "repo"
    agents = fixture(repo)
    module = load(agents)
    source = work / "chrome"
    write_store(source / "Default/Cookies")
    profile = agents / ".browser/profile"
    target = profile / "Default/Cookies"

    # Filtering and output.
    status, out, err = run(module, ["--source", str(source)])
    check("sync succeeds", status == 0, err)
    expected = sorted((host, top) for host, top, kept in ROWS if kept)
    check("only listed sites' cookies are copied", rows_of(target) == expected, rows_of(target))
    expected_after_sync = expected
    check("output carries no cookie names, values, or unlisted hosts", not leaked(out + err), leaked(out + err))
    check("output counts per listed site", "zillow.com: 4" in out and "listed.localhost: 1" in out and "www.example.com: 2" in out, out)
    check("output names listed sites with no cookies", "No cookies for: nothing-here.org" in out, out)
    check("store is 0600", stat.S_IMODE(target.stat().st_mode) == 0o600)
    check("profile directories are 0700",
          all(stat.S_IMODE(path.stat().st_mode) == 0o700 for path in (agents / ".browser", profile, target.parent)))
    check("no page of the store keeps an unlisted cookie", not files_mentioning(agents / ".browser", b"cookie-value-3"))
    config = json.loads((agents / ".browser/playwright.json").read_text())["browser"]
    check("the regenerated server config uses the synced profile",
          config.get("userDataDir") == str(profile)
          and config["launchOptions"].get("ignoreDefaultArgs") == ["--use-mock-keychain"], config)
    check("the browser directory ignores itself", (agents / ".browser/.gitignore").read_text() == "*\n")
    porcelain = subprocess.run(["git", "-C", str(repo), "status", "--porcelain", "--untracked-files=all"],
                               capture_output=True, text=True, check=True).stdout
    check("git status shows nothing under .agents/.browser", ".browser" not in porcelain, porcelain)

    # Every server process gets its own browser profile: the config carries the
    # source profile for the launcher to copy, and the unsynced case is isolated.
    check("a synced config does not claim isolation", "isolated" not in config, config)
    launcher = agents / "playwright-session.py"
    (profile / "Local State").write_text('{"fixture": true}')
    (profile / "Default/Cache").mkdir()
    (profile / "Default/Cache/blob").write_text("cache")
    probe = ("import json,os,sys;"
             "c=json.load(open(sys.argv[sys.argv.index('--config')+1]))['browser'];"
             "d=c['userDataDir'];print(d);print(sorted(os.path.relpath(os.path.join(r,f),d) "
             "for r,_,fs in os.walk(d) for f in fs));print(oct(os.stat(d).st_mode&0o777))")
    command = [sys.executable, str(launcher), sys.executable, "-c", probe, "--config",
               str(agents / ".browser/playwright.json"), "--extra"]
    runs = [subprocess.run(command, capture_output=True, text=True) for _ in range(2)]
    check("the launcher runs its command and passes the exit status", all(r.returncode == 0 for r in runs),
          [r.stderr for r in runs])
    copies = [r.stdout.splitlines()[0] for r in runs]
    check("each launch gets a different profile directory, not the source",
          copies[0] != copies[1] and str(profile) not in copies, copies)
    check("the copy holds the cookie store and Local State, no cache",
          runs[0].stdout.splitlines()[1] == "['Default/Cookies', 'Local State']", runs[0].stdout)
    check("the copy is private", runs[0].stdout.splitlines()[2] == "0o700", runs[0].stdout)
    shutil.rmtree(profile / "Default/Cache")
    check("the copy is gone when the command ends", not any(Path(c).exists() for c in copies)
          and not any(Path(c).parent.exists() for c in copies), copies)
    check("the copy holds the synced cookies",
          rows_of(target) == expected_after_sync, "source unchanged")
    sleeper = subprocess.Popen(
        [sys.executable, str(launcher), sys.executable, "-c",
         "import json,sys,time;print(json.load(open(sys.argv[sys.argv.index('--config')+1]))"
         "['browser']['userDataDir'],flush=True);time.sleep(60)",
         "--config", str(agents / ".browser/playwright.json")],
        stdout=subprocess.PIPE, text=True)
    held = Path(sleeper.stdout.readline().strip())
    check("the copy exists while the command runs", held.is_dir(), held)
    sleeper.terminate()
    sleeper.wait(timeout=15)
    check("SIGTERM to the launcher ends the command and deletes the copy",
          not held.exists() and not held.parent.exists(), held)
    refused_run = subprocess.run([sys.executable, str(launcher), "true"], capture_output=True, text=True)
    check("a command without --config is refused by name",
          refused_run.returncode != 0 and "needs --config" in refused_run.stderr, refused_run.stderr)

    unsynced = agents / ".browser/profile.hold"
    profile.rename(unsynced)
    subprocess.run([sys.executable, str(agents / "mcp.py")], check=True)
    isolated_config = json.loads((agents / ".browser/playwright.json").read_text())["browser"]
    check("without a synced profile the server runs isolated",
          isolated_config.get("isolated") is True and "userDataDir" not in isolated_config, isolated_config)
    unsynced.rename(profile)
    subprocess.run([sys.executable, str(agents / "mcp.py")], check=True)

    # Rerun: same result, stale sidecars gone, the rest of the profile kept.
    Path(f"{target}-journal").write_text("stale")
    (profile / "Local State").write_text("{}")
    first = target.read_bytes()
    status, again, err = run(module, ["--source", str(source)])
    check("rerun succeeds with the same output", status == 0 and again == out, again + err)
    check("rerun keeps the same rows", rows_of(target) == expected)
    check("rerun removes a stale journal beside the store", not Path(f"{target}-journal").exists())
    check("rerun keeps the rest of the profile", (profile / "Local State").exists())
    check("rerun writes identical bytes", target.read_bytes() == first)

    # --settings replaces config.json for this run.
    alternate = work / "alternate.json"
    alternate.write_text(json.dumps({"browser": {"sync_sites": ["listed.localhost"]}}))
    status, out, err = run(module, ["--source", str(source), "--settings", str(alternate)])
    check("--settings replaces the site list", status == 0 and rows_of(target) == [("listed.localhost", "")],
          out + err)

    # A failure after the source is read leaves no unfiltered byte on disk.
    for label, attribute in (("while filtering", "_kept"), ("before the rename", "_fsync")):
        original = getattr(module, attribute)

        def broken(*args, **kwargs):
            raise RuntimeError("injected")

        setattr(module, attribute, broken)
        before = target.read_bytes()
        try:
            run(module, ["--source", str(source)])
            raised = False
        except (RuntimeError, sqlite3.OperationalError):
            raised = True
        finally:
            setattr(module, attribute, original)
        check(f"an injected failure {label} propagates", raised)
        check(f"a failure {label} leaves the store unchanged", target.read_bytes() == before)
        check(f"a failure {label} leaves no unlisted cookie on disk",
              not files_mentioning(agents / ".browser", b"notzillow"))
        check(f"a failure {label} leaves no temp file",
              not [path.name for path in target.parent.iterdir() if path.name != "Cookies"],
              list(target.parent.iterdir()))

    # Allowlist entries: the stored form, and the names that match only themselves.
    check("an IDN entry becomes its ASCII form", module.normalize_site("https://Bücher.de/x") == "xn--bcher-kva.de")
    check("localhost is allowed", module.normalize_site("http://localhost:3000/") == "localhost")
    check("an IP entry is allowed", module.normalize_site("127.0.0.1:8080") == "127.0.0.1")
    check("localhost matches only itself",
          module.site_of("localhost", ["localhost"]) == "localhost"
          and module.site_of("unlisted.localhost", ["localhost"]) is None)
    check("an IP entry matches only itself",
          module.site_of("127.0.0.1", ["127.0.0.1"]) == "127.0.0.1"
          and module.site_of("127.0.0.1", ["0.0.1"]) is None
          and module.site_of("10.0.0.1", ["0.0.1"]) is None)

    # Refusals, each by name and without touching the store.
    def refused(argv, message, settings=None):
        if settings is not None:
            (agents / "config.json").write_text(json.dumps({"browser": settings}))
        before = target.read_bytes()
        status, out, err = run(module, argv)
        if settings is not None:
            (agents / "config.json").write_text(json.dumps({"browser": {"sync_sites": SITES}}))
        return status == 1 and message in err and target.read_bytes() == before, out + err

    # A given --source must hold its own store, and never the default Chrome one.
    outside = work / "outside"
    write_store(outside / "Default/Cookies")
    escaping = work / "escaping"
    escaping.mkdir()
    (escaping / "Default").symlink_to(outside / "Default")
    check("a store that links out of --source is refused",
          *refused(["--source", str(escaping)], "resolves outside it"))
    default_chrome = module.CHROME
    module.CHROME = outside.resolve()
    try:
        check("a --source inside the default Chrome directory is refused",
              *refused(["--source", str(outside)], "into the default Chrome directory"))
    finally:
        module.CHROME = default_chrome

    check("an empty site list is refused",
          *refused(["--source", str(source)], "sync_sites is empty", {"sync_sites": []}))
    check("a public suffix is refused",
          *refused(["--source", str(source)], "is a public suffix", {"sync_sites": ["co.uk"]}))
    check("a single-label site is refused by name",
          *refused(["--source", str(source)], "is a single-label name", {"sync_sites": ["intranet"]}))
    check("a numeric name that is no IP address is refused",
          *refused(["--source", str(source)], "neither a host name nor an IP address", {"sync_sites": ["0.0.1"]}))
    check("a missing source is refused",
          *refused(["--source", str(work / "absent")], "no Chrome cookie store"))
    check("an unknown setting is refused",
          *refused(["--source", str(source)], "unknown browser setting", {"sync_sites": SITES, "typo": 1}))
    (agents / "policy.json").write_text(json.dumps({"browser": {"sync_sites": ["zillow.com"]}}))
    check("browser settings in the tracked policy.json are refused",
          *refused(["--source", str(source)], "belong in the ignored .agents/config.json"))
    (agents / "policy.json").unlink()

    live = f"fixture-host-{os.getpid()}"
    (profile / "SingletonLock").symlink_to(live)
    check("a synced profile in use by a browser is refused", *refused(["--source", str(source)], "running on the synced profile"))
    (profile / "SingletonLock").unlink()
    (source / "SingletonLock").symlink_to(live)
    check("a source Chrome in use is refused", *refused(["--source", str(source)], "quit Chrome"))
    (source / "SingletonLock").unlink()
    dead = subprocess.Popen([sys.executable, "-c", "pass"])
    dead.wait()
    (profile / "SingletonLock").symlink_to(f"fixture-host-{dead.pid}")
    status, out, err = run(module, ["--source", str(source)])
    check("a lock left by a dead process is not a lock", status == 0, err)
    (profile / "SingletonLock").unlink()

    locked = work / "locked"
    write_store(locked / "Default/Cookies")
    holder = sqlite3.connect(locked / "Default/Cookies")
    holder.execute("PRAGMA locking_mode=EXCLUSIVE")
    holder.execute("BEGIN EXCLUSIVE")
    check("a store Chrome holds open is refused",
          *refused(["--source", str(locked)], "Chrome holds its cookie store open"))
    holder.rollback()
    holder.close()

    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        status = module.main(["--source", str(source)], platform="linux")
    check("another operating system is refused by name", status == 1 and "needs macOS" in err.getvalue())

    # A file under the browser directory that Git tracks is refused.
    tracked = agents / ".browser/profile/Default/Cookies"
    subprocess.run(["git", "-C", str(repo), "add", "-f", str(tracked)], check=True)
    check("a tracked store is refused", *refused(["--source", str(source)], "Git does not ignore it"))
    subprocess.run(["git", "-C", str(repo), "rm", "-q", "--cached", str(tracked)], check=True)
finally:
    shutil.rmtree(work)

print("\nALL PASS" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
