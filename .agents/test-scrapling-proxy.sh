#!/usr/bin/env bash
# Seam: the Scrapling launcher over stdio, a copy of it beside a fixture config.json and fixture env files, in the
#   pinned environment .agents/mcp.json resolves; plus the launcher imported by path with a recording session.
# Catches: a proxy name that does not reach the session as the split dictionary, a refusal that quotes a line or a
#   value, a sentinel password (raw, percent-encoded, Basic-auth base64 or the full URL) in any tool error or stderr line,
#   a tool description holding more than names, and a later call in a session opened by name that leaks.
# Misses: a real proxy vendor (every proxy here is a loopback stand-in), Scrapling versions other than the pinned one,
#   and the argument-validation text of a tool, which quotes what the caller typed (a name never holds the password).
#
# Layers: (1) the launcher imported by path: the session receives the dictionary, list_sessions shows no credential;
# (2) the launcher over stdio, no browser needed: the description, every refusal, the scrub; (3) with Scrapling's
# browser installed: a closed proxy port and a loopback proxy answering 407, then fetch, actions and evaluate in a
# session opened by name. Where the browser is missing, layer 3 prints a SKIP line. On macOS every pinned process runs
# under a sandbox-exec profile that refuses off-loopback connections, checked against a control first.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v uvx >/dev/null 2>&1; then
  echo "SKIP scrapling proxy: uvx is not on PATH, so the pinned Scrapling environment cannot be resolved"
  exit 0
fi

exec python3 - "$repo" <<'PY'
import base64, http.server, json, os, select, shutil, signal, socket, stat, subprocess, sys, tempfile, threading, time
from pathlib import Path
from urllib.parse import quote

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / ".agents"))
import mcp as registry

PASSWORD = "Zq7-Sentinel!pw#42"
ENCODED = quote(PASSWORD, safe="")
BASIC = base64.b64encode(f"probe:{PASSWORD}".encode()).decode()
NEIGHBOUR = "Neighbour-Sentinel-9"
MALFORMED = "Malformed-Sentinel-7"
failures, children = [], []


def check(ok, message):
    print(("ok   " if ok else "FAIL ") + message, flush=True)
    if not ok:
        failures.append(message)


def on_signal(signum, frame):
    raise SystemExit(f"FAIL stopped by signal {signum}")


signal.signal(signal.SIGTERM, on_signal)
signal.signal(signal.SIGHUP, on_signal)

work = Path(tempfile.mkdtemp(prefix="scrapling-proxy-"))


class Standin(http.server.BaseHTTPRequestHandler):
    """A loopback proxy. It records the credentials that arrive; a plain request carrying the right Basic
    credentials gets a canned page, every other request, CONNECT included, gets 407."""

    def _answer(self):
        authorization = self.headers.get("Proxy-Authorization")
        self.server.authorizations.append(authorization)
        if self.command == "GET" and authorization == f"Basic {BASIC}" and self.server.accepts:
            body = b"<!doctype html><title>fixture</title><p>fixture page</p>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
        else:
            body = b""
            self.send_response(407)
            self.send_header("Proxy-Authenticate", 'Basic realm="fixture"')
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    do_GET = do_CONNECT = _answer

    def log_message(self, *args):
        pass


def standin(accepts):
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Standin)
    server.authorizations, server.accepts = [], accepts
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


denier, working = standin(False), standin(True)
with socket.socket() as spare:
    spare.bind(("127.0.0.1", 0))
    closed_port = spare.getsockname()[1]
denied_port = denier.server_address[1]

URLS = {
    "CLOSED": f"http://probe:{ENCODED}@127.0.0.1:{closed_port}",
    "DENIED": f"http://probe:{ENCODED}@127.0.0.1:{denied_port}",
    "WORKING": f"http://probe:{ENCODED}@127.0.0.1:{working.server_address[1]}",
    "BADSCHEME": f"ftp://probe:{ENCODED}@127.0.0.1:1",
}
agents = work / ".agents"
(agents / "lib").mkdir(parents=True)
shutil.copy2(repo / ".agents/scrapling-mcp.py", agents / "scrapling-mcp.py")
shutil.copy2(repo / ".agents/lib/proxy.py", agents / "lib/proxy.py")
LAUNCHER = agents / "scrapling-mcp.py"


def env_file(name, lines, mode=0o600):
    path = work / name
    path.write_text("\n".join(lines) + "\n")
    path.chmod(mode)
    return path


good = env_file("proxies.env", [f"NEIGHBOUR=http://n:{NEIGHBOUR}@127.0.0.1:1", MALFORMED, "EMPTY=",
                                *(f"{key}={url}" for key, url in URLS.items())])
loose = env_file("loose.env", [f"CLOSED={URLS['CLOSED']}"], 0o644)
proxies = {
    "closed": {"env_file": str(good), "key": "CLOSED"},
    "denied": {"env_file": str(good), "key": "DENIED"},
    "working": {"env_file": str(good), "key": "WORKING"},
    "badscheme": {"env_file": str(good), "key": "BADSCHEME"},
    "emptyvalue": {"env_file": str(good), "key": "EMPTY"},
    "nokey": {"env_file": str(good), "key": "ABSENT"},
    "loose": {"env_file": str(loose), "key": "CLOSED"},
    "gone": {"env_file": str(work / "absent.env"), "key": "CLOSED"},
}
(agents / "config.json").write_text(json.dumps({"scrapling": {"proxies": proxies}}))
SECRETS = {"password": PASSWORD, "encoded": ENCODED, "base64": BASIC, "neighbour": NEIGHBOUR, "malformed": MALFORMED,
           **{f"url {key}": url for key, url in URLS.items()}}


def leaks(text):
    return sorted(name for name, secret in SECRETS.items() if secret in text)


# The pinned environment, and the sandbox every process of it runs under.
_, servers = registry._registry(repo)
if "scrapling" not in servers:
    print("SKIP scrapling proxy: this registry has no scrapling entry")
    sys.exit(0)
entry = registry._resolve(servers["scrapling"], "scrapling", repo)
python = [entry["command"], *entry["args"][:-1]]
launch = [*python, str(LAUNCHER)]
subprocess.run([*python, "-c", "pass"], check=True, timeout=300, stdout=subprocess.DEVNULL)  # warm the cache first
wrapper, environment = [], dict(os.environ)
if sys.platform == "darwin" and shutil.which("sandbox-exec"):
    profile = work / "loopback.sb"
    profile.write_text('(version 1)\n(allow default)\n(deny network-outbound)\n'
                       '(allow network-outbound (remote ip "localhost:*"))\n'
                       '(allow network-outbound (remote unix-socket))\n'
                       '(deny network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))\n')
    wrapper, environment["UV_OFFLINE"] = ["sandbox-exec", "-f", str(profile)], "1"
    probe = ("import socket,sys\n"
             "for host, port in (('127.0.0.1', int(sys.argv[1])), ('1.1.1.1', 80)):\n"
             "    try:\n        socket.create_connection((host, port), timeout=3).close(); print(host, 'connected')\n"
             "    except OSError as error:\n        print(host, 'refused')\n")
    control = subprocess.run([*wrapper, sys.executable, "-c", probe, str(denied_port)], capture_output=True, text=True,
                             timeout=30).stdout.split("\n")
    check("127.0.0.1 connected" in control and "1.1.1.1 refused" in control,
          f"the sandbox control: loopback connects and 1.1.1.1 is refused: {control}")
    if failures:
        sys.exit(1)
else:
    print("NOTE no sandbox-exec here: every proxy and page in these rows is a loopback stand-in, so nothing leaves the machine")


def start(argv, stdin=subprocess.DEVNULL):
    err = tempfile.TemporaryFile()
    proc = subprocess.Popen([*wrapper, *argv], stdin=stdin, stdout=subprocess.PIPE, stderr=err, start_new_session=True,
                            env=environment)
    proc.err = err
    children.append(proc)
    return proc


def stderr_text(proc):
    proc.err.seek(0)
    return proc.err.read().decode(errors="replace")


def stop(proc):
    if proc.poll() is None:
        for signum in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(proc.pid, signum)
            except (ProcessLookupError, PermissionError):
                proc.send_signal(signum)
            try:
                proc.wait(timeout=10)
                break
            except subprocess.TimeoutExpired:
                continue
    for stream in (proc.stdin, proc.stdout, proc.err):
        if stream:
            stream.close()


# Layer 1: the launcher imported by path, its session class replaced by one that records and starts nothing.
INPROCESS = r'''
import asyncio, importlib.util, json, sys

spec = importlib.util.spec_from_file_location("scrapling_launcher", sys.argv[1])
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)
from scrapling.core.ai import server as server_module

seen = []


class Recording(server_module.AsyncStealthySession):
    def __init__(self, **kwargs):
        seen.append(kwargs.get("proxy"))
        super().__init__(**kwargs)

    async def start(self):
        return self


async def main():
    server_module.AsyncStealthySession = Recording
    server = launcher.NarrowedScraplingMCPServer()
    await server.browser_open(session_id="by-name", proxy="closed")
    await server.browser_open(session_id="by-url", proxy="http://u:p@127.0.0.1:9")
    listed = [session.model_dump(mode="json") for session in await server.list_sessions()]
    return json.dumps(listed)


listed = asyncio.run(main())
print(json.dumps({"seen": seen, "listed": listed}))
'''
proc = start([*python, "-c", INPROCESS, str(LAUNCHER)])
out, _ = proc.communicate(timeout=300)
if proc.returncode != 0:
    raise SystemExit("FAIL the in-process layer exited non-zero:\n" + stderr_text(proc)[-2000:])
inprocess = json.loads(out.decode().strip().splitlines()[-1])
check(inprocess["seen"] == [{"server": f"http://127.0.0.1:{closed_port}", "username": "probe", "password": PASSWORD},
                            "http://u:p@127.0.0.1:9"],
      "the session receives the split dictionary for a name, and a URL unchanged")
check(not leaks(inprocess["listed"]), f"list_sessions after a named browser_open shows no credential: {leaks(inprocess['listed'])}")


# Layer 2 and 3: over stdio.
class Client:
    def __init__(self, argv):
        self.proc = start(argv, stdin=subprocess.PIPE)
        self.next_id, self.buffer = 0, b""

    def call(self, method, params, timeout=240):
        self.next_id += 1
        self.proc.stdin.write((json.dumps({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params}) + "\n").encode())
        self.proc.stdin.flush()
        deadline = time.monotonic() + timeout
        while True:
            while b"\n" not in self.buffer:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise SystemExit("FAIL no reply from the launcher in time:\n" + stderr_text(self.proc)[-2000:])
                if select.select([self.proc.stdout.fileno()], [], [], remaining)[0]:
                    chunk = os.read(self.proc.stdout.fileno(), 65536)
                    if not chunk:
                        raise SystemExit("FAIL the launcher exited:\n" + stderr_text(self.proc)[-2000:])
                    self.buffer += chunk
            line, _, self.buffer = self.buffer.partition(b"\n")
            message = json.loads(line)
            if message.get("id") == self.next_id and "method" not in message:
                return message

    def tool(self, name, arguments, timeout=240):
        reply = self.call("tools/call", {"name": name, "arguments": arguments}, timeout)
        result = reply.get("result", reply)
        text = " ".join(part.get("text", "") for part in result.get("content", [])) or json.dumps(reply)
        return result.get("isError") is True, text


def url_with(secret):
    return f"ftp://fixture.invalid/{secret}"


try:
    client = Client(launch)
    client.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                               "clientInfo": {"name": "test-scrapling-proxy", "version": "1"}})
    client.proc.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    client.proc.stdin.flush()
    listing = client.call("tools/list", {})["result"]["tools"]
    tools = {tool["name"]: tool for tool in listing}
    for name in ("browser_open", "browser_fetch_once"):
        description = tools[name]["inputSchema"]["properties"]["proxy"]["description"]
        check(all(proxy_name in description for proxy_name in proxies), f"{name}'s proxy description lists the configured names: {description!r}")
    check("proxy" not in tools["browser_fetch"]["inputSchema"]["properties"], "browser_fetch takes no proxy, as upstream's")
    dumped = json.dumps(listing)
    check(not leaks(dumped) and str(good) not in dumped and str(work) not in dumped,
          f"the tool list holds names only: no secret, no env file path: {leaks(dumped)}")

    # The control: before any name resolves, a URL that holds the password is quoted back by the refusal.
    is_error, control_text = client.tool("browser_fetch_once", {"url": url_with(PASSWORD)})
    check(is_error and PASSWORD in control_text, f"control: the detector sees the password in an unscrubbed refusal: {control_text[:100]!r}")
    control_end = len(stderr_text(client.proc))

    names = ", ".join(sorted(proxies))
    is_error, text = client.tool("browser_fetch_once", {"url": "https://example.com/", "proxy": "nope"})
    check(is_error and "'nope'" in text and all(proxy_name in text for proxy_name in proxies) and not leaks(text),
          f"an unknown name is refused, naming the configured names: {text[:200]!r}")
    for name, expect in (("loose", "ask the operator to run chmod 600"), ("gone", "does not exist"), ("nokey", "no ABSENT=... line"),
                         ("emptyvalue", "value is empty"), ("badscheme", "must use http, https, socks4, or socks5")):
        is_error, text = client.tool("browser_fetch_once", {"url": "https://example.com/", "proxy": name})
        check(is_error and f"proxy '{name}'" in text and expect in text and not leaks(text),
              f"proxy {name!r} is refused saying {expect!r} with no secret: {text[:200]!r}")
    is_error, text = client.tool("browser_open", {"session_id": "x", "proxy": "badscheme"})
    check(is_error and not leaks(text), f"browser_open refuses a bad scheme with no secret: {text[:160]!r}")

    # Once a name resolves, the refusals that quote what the caller typed are scrubbed, whichever tool raises them.
    for forms in (PASSWORD, ENCODED, URLS["CLOSED"]):
        is_error, text = client.tool("browser_fetch_once", {"url": url_with(forms), "proxy": "closed"})
        check(is_error and not leaks(text) and "<proxy closed>" in text,
              f"browser_fetch_once with proxy 'closed' scrubs {forms[:12]!r}...: {text[:160]!r}")
        is_error, text = client.tool("browser_fetch", {"session_id": "absent", "url": url_with(forms)})
        check(is_error and not leaks(text) and "<proxy closed>" in text,
              f"a later browser_fetch with no proxy scrubs {forms[:12]!r}...: {text[:160]!r}")

    # Layer 3: a browser.
    probe = ("import sys; from patchright.async_api import async_playwright\n"
             "import asyncio\n"
             "async def main():\n"
             "    async with async_playwright() as p: print(p.chromium.executable_path)\n"
             "asyncio.run(main())\n")
    found = subprocess.run([*wrapper, *python, "-c", probe], capture_output=True, text=True, env=environment, timeout=120)
    browser = found.stdout.strip().splitlines()[-1] if found.stdout.strip() else ""
    if not browser or not os.path.exists(browser):
        print(f"SKIP scrapling proxy browser block: the bundled Chromium is not installed at {browser or '(unknown)'}; "
              "run the install command in the scrapling registry entry")
    else:
        page = "http://stealth-fixture.test/"
        secure = "https://stealth-fixture.test/"
        for name in ("closed", "denied"):
            for target in (page, secure):
                is_error, text = client.tool("browser_fetch_once", {"url": target, "proxy": name}, 180)
                check(is_error and not leaks(text), f"browser_fetch_once {target} through proxy {name!r} fails with no secret: {text[:160]!r}")
        check(BASIC in (denier.authorizations and " ".join(filter(None, denier.authorizations))),
              "the 407 stand-in received the Basic credentials, so the 'denied' rows exercised them")
        for name in ("closed", "denied", "working"):
            session = f"s-{name}"
            is_error, text = client.tool("browser_open", {"session_id": session, "proxy": name}, 180)
            check(not is_error and not leaks(text), f"browser_open by name {name!r} opens a session with no secret: {text[:120]!r}")
            for tool, arguments in (
                ("browser_fetch", {"session_id": session, "url": page}),
                ("browser_evaluate", {"session_id": session, "expression": f"(() => {{ throw new Error({json.dumps(PASSWORD)}) }})()"}),
                ("browser_actions", {"session_id": session, "actions": [{"type": "wait_element", "target": f"text={PASSWORD}", "timeout": 1000}]}),
                ("list_sessions", {}),
                ("browser_network_requests", {"session_id": session, "include_static": True}),
                ("browser_observe", {"session_id": session}),
            ):
                is_error, text = client.tool(tool, arguments, 180)
                wanted = {"browser_fetch": (False, "fixture page"), "browser_evaluate": (True, "<proxy working>"),
                          "browser_actions": (True, "<proxy working>")}.get(tool) if name == "working" else None
                if wanted:
                    check(is_error is wanted[0] and wanted[1] in text,
                          f"{tool} on a loaded page in the session opened by 'working' {'fails with the secret scrubbed' if wanted[0] else 'returns the page'}: {text[:140]!r}")
                check(not leaks(text), f"{tool} in the session opened by {name!r}: no secret in {'its error' if is_error else 'its result'}: {text[:100]!r}")
            client.tool("close_session", {"session_id": session})
    err = stderr_text(client.proc)
    print(f"NOTE the control's refusal {'reached' if PASSWORD in err[:control_end] else 'did not reach'} stderr")
    stderr_leaks = leaks(err[control_end:])
    check(not stderr_leaks, f"no secret in the launcher's stderr after the control: {stderr_leaks}: {err[control_end:][-300:]!r}")
finally:
    for proc in children:
        stop(proc)
    denier.shutdown()
    working.shutdown()
    shutil.rmtree(work, ignore_errors=True)

sys.exit(1 if failures else 0)
PY
