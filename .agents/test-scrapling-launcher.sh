#!/usr/bin/env bash
# Fire the Scrapling launcher over stdio and read what it offers a model.
#
# The launch command is the `scrapling` entry of .agents/mcp.json, resolved by
# mcp.py's own functions, and the launcher runs from its real .agents/ path.
# This catches the schema and the refusals; it does not call a browser tool
# that launches Chromium, so how Scrapling's own browser_open behaves once
# called is left to live QA.
#
# Needs uvx to resolve the pinned Scrapling environment (network on first
# run). Where uvx is absent it prints a SKIP line, which CI turns into a notice.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v uvx >/dev/null 2>&1; then
  echo "SKIP scrapling launcher: uvx is not on PATH, so the pinned Scrapling environment cannot be resolved"
  exit 0
fi

python3 - "$repo" <<'PY'
import json, os, select, signal, subprocess, sys, time
from pathlib import Path

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / ".agents"))
import mcp as registry

_, servers = registry._registry(repo)
entry = registry._resolve(servers["scrapling"], "scrapling", repo)
launch = [entry["command"], *entry["args"]]
assert launch[-1] == str(repo / ".agents/scrapling-mcp.py"), f"launcher is not the last argument: {launch}"

DROPPED = {"executable_path", "additional_args", "cdp_url", "new_context"}
DENIED = {"make_request", "open_request_session", "session_make_request", "browser_save_state", "browser_load_state"}
OPEN = {"session_id", "headless", "real_chrome", "timezone_id", "locale", "useragent", "proxy", "cookies",
        "hide_canvas", "block_webrtc", "allow_webgl"}
FETCH_ONCE = {"url", "extraction_type", "css_selector", "main_content_only", "headless", "google_search",
              "real_chrome", "wait", "proxy", "timezone_id", "locale", "extra_headers", "useragent", "hide_canvas",
              "timeout", "disable_resources", "wait_selector", "cookies", "network_idle", "wait_selector_state",
              "block_webrtc", "allow_webgl", "solve_cloudflare", "pierce_shadow"}
EXPECTED = {"browser_open": (OPEN, ["session_id"]), "browser_fetch_once": (FETCH_ONCE, ["url"])}

UPSTREAM_DESCRIPTIONS = """
import asyncio, json
from scrapling.core.ai import ScraplingMCPServer
server = ScraplingMCPServer()._build_server("127.0.0.1", 8000)
print(json.dumps({t.name: t.description for t in asyncio.run(server.list_tools())}))
"""

failures = []


def check(ok, message):
    print(("ok   " if ok else "FAIL ") + message)
    if not ok:
        failures.append(message)


def start(argv):
    return subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, start_new_session=True)


def stop(proc):
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
    for stream in (proc.stdin, proc.stdout, proc.stderr):
        stream.close()


class Client:
    def __init__(self, argv):
        self.proc = start(argv)
        self.next_id = 0

    def read(self, timeout=240):
        ready, _, _ = select.select([self.proc.stdout], [], [], timeout)
        if not ready:
            raise SystemExit(f"FAIL no reply from the launcher within {timeout}s")
        line = self.proc.stdout.readline()
        if not line:
            raise SystemExit("FAIL the launcher exited:\n" + self.proc.stderr.read())
        return json.loads(line)

    def notify(self, method):
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method}) + "\n")
        self.proc.stdin.flush()

    def call(self, method, params):
        self.next_id += 1
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params}) + "\n")
        self.proc.stdin.flush()
        reply = self.read()
        assert reply.get("id") == self.next_id, reply
        return reply


upstream = start([*launch[:-1], "-c", UPSTREAM_DESCRIPTIONS])
try:
    out, err = upstream.communicate(timeout=240)
    if upstream.returncode != 0:
        raise SystemExit("FAIL upstream descriptions did not resolve:\n" + err)
    upstream_descriptions = json.loads(out)
finally:
    if upstream.poll() is None:
        stop(upstream)

client = Client(launch)
try:
    client.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                               "clientInfo": {"name": "test-scrapling-launcher", "version": "1"}})
    client.notify("notifications/initialized")
    tools = {t["name"]: t for t in client.call("tools/list", {})["result"]["tools"]}

    for name, (params, required) in EXPECTED.items():
        schema = tools[name]["inputSchema"]
        got = set(schema["properties"])
        check(got == params, f"{name} offers exactly the allowed parameters (extra {sorted(got - params)}, missing {sorted(params - got)})")
        check(not got & DROPPED, f"{name} offers none of {sorted(DROPPED)}")
        check(sorted(schema.get("required", [])) == required, f"{name} requires {required}, got {schema.get('required')}")
        check(tools[name]["description"] == upstream_descriptions[name], f"{name} keeps upstream's description")

    pattern = tools["browser_open"]["inputSchema"]["properties"]["session_id"].get("pattern")
    check(pattern == r"^[A-Za-z0-9_-]{1,64}$", f"browser_open session_id pattern is {pattern!r}")
    check(not DENIED & set(tools), f"none of the denied tools is listed (found {sorted(DENIED & set(tools))})")

    for url in ("file:///etc/hosts", "http://169.254.169.254/latest/meta-data/", "https://[fd00:ec2::254]/"):
        reply = client.call("tools/call", {"name": "browser_fetch_once", "arguments": {"url": url}})["result"]
        text = " ".join(part.get("text", "") for part in reply.get("content", []))
        check(reply.get("isError") is True and "Refused" in text, f"browser_fetch_once refuses {url}: {text[:90]!r}")
finally:
    stop(client.proc)

sys.exit(1 if failures else 0)
PY
