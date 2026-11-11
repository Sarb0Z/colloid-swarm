#!/usr/bin/env bash
# Fire the Scrapling launcher and check what it offers a model and refuses.
#
# Three layers, each against the pinned environment the `scrapling` entry of
# .agents/mcp.json resolves (uvx, `python -I`):
# - the launcher imported by path: the address and proxy readings, the
#   environment scrub, the executable override and the browser-level route
#   pattern, called directly;
# - the launcher over stdio: the instructions, the twelve tools and their
#   schemas against upstream's after exactly the narrowing, and the refusals
#   that need no browser;
# - one live session through the launcher's server: in-page requests to a
#   metadata host fail with the block's own error. Where the browser is not
#   installed it prints a SKIP line and the other layers still gate.
#
# Needs uvx to resolve the pinned Scrapling environment (network on first
# run). Where uvx is absent, or the registry has no `scrapling` entry, it
# prints a SKIP line, which CI turns into a notice.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v uvx >/dev/null 2>&1; then
  echo "SKIP scrapling launcher: uvx is not on PATH, so the pinned Scrapling environment cannot be resolved"
  exit 0
fi

# exec, so a SIGTERM sent to this test reaches the process that owns the
# children and stops them.
exec python3 - "$repo" <<'PY'
import json, os, re, select, signal, subprocess, sys, tempfile, time
from pathlib import Path

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / ".agents"))
import mcp as registry

LAUNCHER = repo / ".agents/scrapling-mcp.py"
PINNED_ARGS = ["--python", "3.12", "--exclude-newer", "2026-11-09T00:00:00Z", "--from", "scrapling[ai]==0.5.1",
               "python", "-I", str(LAUNCHER)]
DROPPED = {"executable_path", "additional_args", "cdp_url", "new_context"}
DENIED = {"make_request", "open_request_session", "session_make_request", "browser_save_state", "browser_load_state"}
KEPT = {"browser_open", "browser_fetch_once", "browser_fetch", "close_session", "list_sessions", "browser_extract",
        "browser_actions", "browser_evaluate", "browser_network_requests", "browser_network_request",
        "browser_screenshot", "browser_observe"}
SESSION_ID_SCHEMA = {"description": "Browser session ID: 1 to 64 letters, digits, '-' or '_'.",
                     "pattern": r"^[A-Za-z0-9_-]{1,64}$", "title": "Session Id", "type": "string"}

# Runs in the pinned environment. Loads the launcher by path and calls its
# functions; reads upstream's server and applies exactly the narrowing's text
# edits there, so the expected descriptions come from the same process that
# reads upstream's.
UNIT = r'''
import asyncio, importlib.util, json, re, sys

spec = importlib.util.spec_from_file_location("scrapling_launcher", sys.argv[1])
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)
rows = []


def check(ok, message):
    rows.append([bool(ok), message])


def refusal(function, value):
    try:
        function(value)
    except ValueError as error:
        return str(error)
    return None


WEB_ONLY = "pass its http(s) address"
METADATA = "cloud-metadata hosts are not fetched"
BACKSLASH = "forward slashes"
REFUSED_URLS = {
    "file:///etc/hosts": WEB_ONLY,
    "FILE:///etc/hosts": WEB_ONLY,
    "ftp://example.com/": WEB_ONLY,
    "data:text/html,hi": WEB_ONLY,
    "javascript:alert(1)": WEB_ONLY,
    "http://169.254.169.254/latest/meta-data/": METADATA,
    "HTTP://169.254.169.254/": METADATA,
    "http://user:pw@169.254.169.254:80/": METADATA,
    "https://[fd00:ec2::254]/": METADATA,
    "https://[FD00:EC2:0:0:0:0:0:254]/": METADATA,
    "http://[::ffff:169.254.169.254]/": METADATA,
    "http://[::ffff:a9fe:a9fe]/": METADATA,
    "http://2852039166/": METADATA,
    "http://0xA9FEA9FE/": METADATA,
    "http://0xa9.0xfe.0xa9.0xfe/": METADATA,
    "http://0251.0376.0251.0376/": METADATA,
    "http://169.254.43518/": METADATA,
    "http://169.16689662/": METADATA,
    "http://169.254.169.254./": METADATA,
    "http://%31%36%39.254.169.254/": METADATA,
    "http://169.254.169.254%2E/": METADATA,
    "http://\uff11\uff16\uff19\uff0e\uff12\uff15\uff14\uff0e\uff11\uff16\uff19\uff0e\uff12\uff15\uff14/": METADATA,
    "http://169.254.169.254\\@example.invalid/": BACKSLASH,
    "http:\\\\169.254.169.254\\": BACKSLASH,
    "https://example.com\\path": BACKSLASH,
}
PASSED_URLS = ["https://example.com/", "http://169.254.169.253/", "http://169.254.169.254.example.com/",
               "https://example.com/?next=http://169.254.169.254/", "http://169.254.169.254@example.com/",
               "http://[2001:db8::1]/", "http://127.0.0.1:8080/", "https://user@example.com/path"]
for url, reason in REFUSED_URLS.items():
    message = refusal(launcher._refuse_address, url)
    check(message is not None and message.startswith("Refused") and reason in message,
          f"the url check refuses {url!r} saying {reason!r}: {message!r}")
for url in PASSED_URLS:
    message = refusal(launcher._refuse_address, url)
    check(message is None, f"the url check passes {url!r}: {message!r}")

REFUSED_PROXIES = ["http://169.254.169.254:3128", "socks5://[::ffff:a9fe:a9fe]:1080", "http://0xA9FEA9FE:80",
                   {"server": "169.254.169.254:80"}, {"server": "http://2852039166", "username": "u"},
                   "http://proxy.example.com\\@169.254.169.254:80"]
PASSED_PROXIES = [None, "http://proxy.example.com:3128", "socks5://127.0.0.1:1080",
                  {"server": "proxy.example.com:3128", "username": "u", "password": "p"}]
for proxy in REFUSED_PROXIES:
    message = refusal(launcher._refuse_proxy, proxy)
    check(message is not None and message.startswith("Refused"), f"the proxy check refuses {proxy!r}: {message!r}")
for proxy in PASSED_PROXIES:
    message = refusal(launcher._refuse_proxy, proxy)
    check(message is None, f"the proxy check passes {proxy!r}: {message!r}")

# URLs as Chromium hands them to a route: already canonical.
BLOCKED_REQUESTS = ["http://169.254.169.254/", "http://169.254.169.254", "https://169.254.169.254:8443/x?y",
                    "http://u:p@169.254.169.254/latest", "ws://169.254.169.254/", "http://[fd00:ec2::254]/",
                    "http://[fd00:ec2::254]:80/x", "http://[::ffff:a9fe:a9fe]/"]
ROUTED_REQUESTS = ["http://169.254.169.25/", "http://169.254.169.2540/", "http://169.254.169.254.example.com/",
                   "http://example.com/169.254.169.254", "http://example.com/?u=http://169.254.169.254/",
                   "http://169.254.169.254@example.com/", "http://[fd00:ec2::2540]/", "https://example.com/"]
pattern = launcher.METADATA_REQUEST
check(isinstance(pattern, re.Pattern), "the browser block's route is a regex, so the driver intercepts only its matches")
for url in BLOCKED_REQUESTS:
    check(launcher._is_metadata_request(url), f"the browser block aborts {url}")
for url in ROUTED_REQUESTS:
    check(not launcher._is_metadata_request(url), f"the browser block lets {url} through")

from scrapling.core.ai import server as server_module
session_class = server_module.AsyncStealthySession
check(session_class._initialize_context is launcher._initialize_context_blocked,
      "every browser context the server's sessions create gets the block")
check(session_class._get_page is launcher._get_page_blocked,
      "every page Scrapling re-routes gets the block after its own route")

environment = {"NODE_OPTIONS": "--require /tmp/x.js", "NODE_PATH": "/tmp", "PLAYWRIGHT_BROWSERS_PATH": "/tmp",
               "PLAYWRIGHT_NODEJS_PATH": "/tmp/node", "PATCHRIGHT_DRIVER": "/tmp", "SCRAPLING_EXECUTABLE_PATH": "/bin/sh",
               "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib", "LD_PRELOAD": "/tmp/x.so", "PATH": "/usr/bin",
               "HTTPS_PROXY": "http://proxy.example.com:3128", "LANG": "C.UTF-8", "MY_NODE_OPTIONS": "kept"}
launcher._scrub_environment(environment)
check(environment == {"PATH": "/usr/bin", "HTTPS_PROXY": "http://proxy.example.com:3128", "LANG": "C.UTF-8",
                      "MY_NODE_OPTIONS": "kept"},
      f"the environment scrub removes every NODE_, PLAYWRIGHT_, PATCHRIGHT_, SCRAPLING_, DYLD_ and LD_ name: {sorted(environment)}")

narrowed = launcher.NarrowedScraplingMCPServer(executable_path="/bin/sh")
check(narrowed._resolve_executable_path("/bin/sh") is None and narrowed._resolve_executable_path(None) is None,
      "no executable path reaches a browser session")

from scrapling.core.ai import ScraplingMCPServer
upstream = ScraplingMCPServer()._build_server("127.0.0.1", 8000)


def edited(text, edits, what):
    for old, new in edits:
        if text.count(old) != 1:
            raise SystemExit(f"FAIL upstream's {what} no longer contains {old!r} once; recheck the narrowing")
        text = text.replace(old, new)
    return text


instructions = edited(upstream.instructions, [
    ("2. Unless the user chooses a tool, start with HTTP for low to mid protection; use browsers for strong protection or JavaScript.\n", ""),
    ("3. Use `make_request` or `browser_fetch_once` for standalone fetches; they close automatically.",
     "3. Use `browser_fetch_once` for standalone fetches; it closes automatically."),
], "instructions")
number = iter(range(1, 100))
instructions = re.sub(r"(?m)^\d+\. ", lambda match: f"{next(number)}. ", instructions)
description_edits = {"browser_open": [("local or remote browser session", "local browser session")]}
tools = {}
for tool in asyncio.run(upstream.list_tools()):
    dumped = tool.model_dump(by_alias=True, mode="json", exclude_none=True)
    dumped["description"] = edited(dumped["description"], description_edits.get(tool.name, []), f"{tool.name} description")
    tools[tool.name] = dumped
print(json.dumps({"rows": rows, "instructions": instructions, "tools": tools}))
'''

# Runs in the pinned environment: one browser session through the launcher's
# server, a local page served on port 0, and in-page requests to the metadata
# host. Each request must fail with the block's own error, which a request
# the block missed cannot produce.
LIVE = r'''
import asyncio, http.server, importlib.util, json, os, sys, threading

spec = importlib.util.spec_from_file_location("scrapling_launcher", sys.argv[1])
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)
from patchright.async_api import async_playwright

# The block's `blockedbyclient` abort as Chromium reports it: a subresource
# with the DevTools suffix, a top-level navigation without. Scrapling's own ad
# block aborts as net::ERR_FAILED, and an unreachable host fails otherwise.
BLOCKED = "net::ERR_BLOCKED_BY_CLIENT.Inspector"
BLOCKED_NAVIGATION = "net::ERR_BLOCKED_BY_CLIENT"
FETCH = """async (a) => { try { await fetch(a.url, {signal: AbortSignal.timeout(5000)}); return 'reached'; }
                          catch (error) { return 'failed'; } }"""
rows, skips = [], []


def check(ok, message):
    rows.append([bool(ok), message])


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<!doctype html><title>block</title><p>block</p>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


async def failures_for(failures, path):
    for _ in range(40):
        found = [failure for url, failure in failures if url.endswith(path)]
        if found:
            return found
        await asyncio.sleep(0.1)
    return []


async def exercise(server, session_id, page_url, real_chrome):
    label = "real Chrome" if real_chrome else "the stealth browser"
    await server.browser_open(session_id=session_id, real_chrome=real_chrome)
    try:
        failures = []
        context = server._sessions[session_id].session.context
        context.on("requestfailed", lambda request: failures.append((request.url, request.failure)))
        await server.browser_fetch(url=page_url, session_id=session_id)
        spellings = ["http://169.254.169.254/row-plain", "http://2852039166/row-decimal",
                     "http://[::ffff:169.254.169.254]/row-mapped", "http://[fd00:ec2::254]/row-v6"]
        for url in spellings:
            await server.browser_evaluate(session_id=session_id, expression=FETCH, arg={"url": url})
            path = url[url.rindex("/"):]
            found = await failures_for(failures, path)
            check(found == [BLOCKED], f"{label}: an in-page fetch of {url} fails with {BLOCKED}: {found}")
        # A non-empty blocked_domains makes Scrapling install its `**/*` page
        # route, which outranks the context route and continues every request
        # it does not block, so only the page route keeps the block here.
        await server.browser_fetch(url=page_url, session_id=session_id, blocked_domains={"ads.example"})
        await server.browser_evaluate(session_id=session_id, expression=FETCH,
                                      arg={"url": "http://169.254.169.254/row-own-domains"})
        found = await failures_for(failures, "/row-own-domains")
        check(found == [BLOCKED], f"{label}: browser_fetch's blocked_domains does not lift the block: {found}")
        # A new page carries no route of Scrapling's, so only the context route covers it.
        await server.browser_evaluate(session_id=session_id, expression="() => { window.open('http://169.254.169.254/row-popup'); return null; }")
        found = await failures_for(failures, "/row-popup")
        check(found == [BLOCKED_NAVIGATION], f"{label}: a page the model opens fails at the metadata host with {BLOCKED_NAVIGATION}: {found}")
        await server.browser_evaluate(session_id=session_id, expression=FETCH,
                                      arg={"url": page_url + "row-allowed"})
        found = await failures_for(failures, "/row-allowed")
        check(found == [], f"{label}: an in-page fetch of the local page is not blocked: {found}")
    finally:
        await server.close_session(session_id)


async def main():
    async with async_playwright() as playwright:
        bundled = playwright.chromium.executable_path
    if not os.path.exists(bundled):
        skips.append(f"the bundled Chromium is not installed at {bundled}; run the install command in the scrapling registry entry")
        return
    page_server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
    thread = threading.Thread(target=page_server.serve_forever, daemon=True)
    thread.start()
    try:
        page_url = f"http://127.0.0.1:{page_server.server_address[1]}/"
        server = launcher.NarrowedScraplingMCPServer()
        await exercise(server, "live", page_url, real_chrome=False)
        chrome = {"darwin": "/Applications/Google Chrome.app"}.get(sys.platform, "/opt/google/chrome/chrome")
        if os.path.exists(chrome):
            await exercise(server, "live-chrome", page_url, real_chrome=True)
        else:
            skips.append(f"real Chrome is not installed at {chrome}, so its path ran no live row")
    finally:
        page_server.shutdown()
        page_server.server_close()


asyncio.run(main())
print(json.dumps({"rows": rows, "skips": skips}))
'''

failures = []
children = []


def check(ok, message):
    print(("ok   " if ok else "FAIL ") + message, flush=True)
    if not ok:
        failures.append(message)


def on_signal(signum, frame):
    raise SystemExit(f"FAIL stopped by signal {signum}")


signal.signal(signal.SIGTERM, on_signal)
signal.signal(signal.SIGHUP, on_signal)


def start(argv, stdin=subprocess.DEVNULL):
    """Start `argv` in its own process group, its stderr kept in a file so it can never fill a pipe."""
    err = tempfile.TemporaryFile()
    proc = subprocess.Popen(argv, stdin=stdin, stdout=subprocess.PIPE, stderr=err, start_new_session=True)
    proc.err = err
    children.append(proc)
    return proc


def stderr_of(proc):
    proc.err.seek(0)
    return proc.err.read().decode(errors="replace")[-4000:]


def signal_group(proc, signum):
    try:
        os.killpg(proc.pid, signum)
    except (ProcessLookupError, PermissionError):
        # The group is gone, or macOS refuses a group whose leader exited.
        try:
            proc.send_signal(signum)
        except ProcessLookupError:
            pass


def stop(proc):
    if proc.poll() is None:
        signal_group(proc, signal.SIGTERM)
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            signal_group(proc, signal.SIGKILL)
            proc.wait()
    for stream in (proc.stdin, proc.stdout, proc.err):
        if stream:
            stream.close()


def run_json(argv, what, timeout):
    """Run a pinned-environment script and parse the JSON on its last stdout line."""
    proc = start(argv)
    try:
        out, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        raise SystemExit(f"FAIL {what} did not finish within {timeout}s:\n" + stderr_of(proc))
    if proc.returncode != 0:
        raise SystemExit(f"FAIL {what} exited {proc.returncode}:\n" + out.decode(errors="replace")[-2000:] + stderr_of(proc))
    lines = out.decode().strip().splitlines()
    return json.loads(lines[-1])


class Client:
    """A JSON-RPC client over the launcher's stdio that reads until the reply's id."""

    def __init__(self, argv):
        self.proc = start(argv, stdin=subprocess.PIPE)
        self.next_id = 0
        self.buffer = b""

    def _message(self, deadline):
        fd = self.proc.stdout.fileno()
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise SystemExit("FAIL no reply from the launcher in time:\n" + stderr_of(self.proc))
            ready, _, _ = select.select([fd], [], [], remaining)
            if ready:
                chunk = os.read(fd, 65536)
                if not chunk:
                    raise SystemExit("FAIL the launcher exited:\n" + stderr_of(self.proc))
                self.buffer += chunk
        line, _, self.buffer = self.buffer.partition(b"\n")
        return json.loads(line)

    def send(self, message):
        self.proc.stdin.write((json.dumps(message) + "\n").encode())
        self.proc.stdin.flush()

    def notify(self, method):
        self.send({"jsonrpc": "2.0", "method": method})

    def call(self, method, params, timeout=240):
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})
        deadline = time.monotonic() + timeout
        while True:
            message = self._message(deadline)
            if message.get("id") == self.next_id and "method" not in message:
                return message


def narrowed_schema(name, schema):
    schema = json.loads(json.dumps(schema))
    if name in ("browser_open", "browser_fetch_once"):
        for dropped in DROPPED:
            schema["properties"].pop(dropped, None)
        if "required" in schema:
            schema["required"] = [field for field in schema["required"] if field not in DROPPED]
    if name == "browser_open":
        schema["properties"]["session_id"] = SESSION_ID_SCHEMA
        schema["required"] = ["session_id"]
    return schema


def tool_error(client, name, arguments):
    reply = client.call("tools/call", {"name": name, "arguments": arguments})["result"]
    text = " ".join(part.get("text", "") for part in reply.get("content", []))
    return reply.get("isError") is True, text


try:
    _, servers = registry._registry(repo)
    if "scrapling" not in servers:
        print("SKIP scrapling launcher: this registry has no scrapling entry")
        sys.exit(0)
    entry = registry._resolve(servers["scrapling"], "scrapling", repo)
    check(entry["command"] == "uvx" and entry["args"] == PINNED_ARGS,
          f"the registry launches the launcher pinned: {[entry['command'], *entry['args']]}")
    launch = [entry["command"], *entry["args"]]
    python = launch[:-1]

    unit = run_json([*python, "-c", UNIT, str(LAUNCHER)], "the launcher's import checks", 240)
    for ok, message in unit["rows"]:
        check(ok, message)
    expected_tools = {name: tool for name, tool in unit["tools"].items() if name not in DENIED}

    client = Client(launch)
    try:
        init = client.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                          "clientInfo": {"name": "test-scrapling-launcher", "version": "1"}})
        client.notify("notifications/initialized")
        instructions = init["result"].get("instructions")
        check(instructions == unit["instructions"],
              f"the server instructions are upstream's minus the HTTP-first and make_request advice: {instructions!r}")
        tools = {tool["name"]: tool for tool in client.call("tools/list", {})["result"]["tools"]}
        check(set(tools) == KEPT, f"exactly the twelve kept tools are listed (extra {sorted(set(tools) - KEPT)}, missing {sorted(KEPT - set(tools))})")
        check(not DENIED & set(tools), f"none of the denied tools is listed (found {sorted(DENIED & set(tools))})")
        for name in sorted(KEPT & set(tools)):
            want = dict(expected_tools[name], inputSchema=narrowed_schema(name, expected_tools[name]["inputSchema"]))
            check(tools[name] == want, f"{name} equals upstream's tool after exactly the narrowing")

        for name, arguments, reason in [
            ("browser_fetch_once", {"url": "file:///etc/hosts"}, "pass its http(s) address"),
            ("browser_fetch_once", {"url": "http://0xA9FEA9FE/"}, "cloud-metadata hosts"),
            ("browser_fetch_once", {"url": "http://169.254.169.254\\@example.invalid/"}, "forward slashes"),
            ("browser_fetch_once", {"url": "https://example.com/", "proxy": "http://169.254.169.254:80"}, "cloud-metadata hosts"),
            ("browser_fetch", {"url": "http://[::ffff:a9fe:a9fe]/", "session_id": "absent"}, "cloud-metadata hosts"),
            ("browser_fetch", {"url": "ftp://example.com/", "session_id": "absent"}, "pass its http(s) address"),
            ("browser_open", {"session_id": "proxied", "proxy": {"server": "2852039166:80"}}, "cloud-metadata hosts"),
        ]:
            is_error, text = tool_error(client, name, arguments)
            check(is_error and f"{name}: Refused" in text and reason in text, f"{name} refuses {arguments}: {text[:120]!r}")
        is_error, text = tool_error(client, "browser_fetch", {"url": "https://example.com/", "session_id": "absent"})
        check(is_error and "not found" in text, f"browser_fetch passes a web address on to the session lookup: {text[:120]!r}")
    finally:
        stop(client.proc)

    live = run_json([*python, "-c", LIVE, str(LAUNCHER)], "the live browser row", 300)
    for skipped in live["skips"]:
        print(f"SKIP scrapling browser block: {skipped}")
    for ok, message in live["rows"]:
        check(ok, message)
finally:
    for proc in children:
        stop(proc)

sys.exit(1 if failures else 0)
PY
