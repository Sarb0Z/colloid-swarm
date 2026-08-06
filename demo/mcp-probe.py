#!/usr/bin/env python3
"""Drive a repository-owned MCP server over stdio and print what it answers.

The demo needs real output from the servers, not a description of them. This
speaks the MCP handshake (initialize -> initialized -> request) against a
server's committed bundle and prints the reply.

Usage:
    mcp-probe.py <server-dir> list
    mcp-probe.py <server-dir> call <tool> <json-arguments>

`list` prints one tool name per line. `call` prints the text content of the
result. Both exit non-zero when the server fails to answer, so a caller running
under `set -e` stops on a broken bundle instead of printing nothing.

Every request this makes is answerable offline. The tools it calls refuse their
targets before they open a socket, which is the property the demo shows.
"""

import json
import pathlib
import signal
import subprocess
import sys

TIMEOUT_SECONDS = 30
PROTOCOL_VERSION = "2024-11-05"


class Server:
    """A running MCP server, spoken to over newline-delimited JSON-RPC."""

    def __init__(self, directory):
        self.directory = pathlib.Path(directory).resolve()
        bundle = self.directory / "dist" / "server.js"
        if not bundle.is_file():
            raise SystemExit(f"mcp-probe: no bundle at {bundle}")
        try:
            self.proc = subprocess.Popen(
                ["node", str(bundle)],
                cwd=self.directory,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )
        except FileNotFoundError:
            raise SystemExit("mcp-probe: node is not on PATH (need >=20.19.0)")

    def send(self, message):
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

    def read(self):
        """Return the next JSON-RPC object, skipping any non-JSON noise."""
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise SystemExit(f"mcp-probe: {self.directory.name} closed the pipe")
            line = line.strip()
            if not line:
                continue
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue

    def request(self, method, params, request_id):
        self.send({
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params,
        })
        while True:
            message = self.read()
            if message.get("id") != request_id:
                continue
            if "error" in message:
                raise SystemExit(f"mcp-probe: {method} failed: {message['error']}")
            return message.get("result", {})

    def handshake(self):
        self.request("initialize", {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "colloid-demo", "version": "0"},
        }, 1)
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def close(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def result_text(result):
    """Join the text blocks of a tools/call result."""
    blocks = result.get("content", [])
    return "\n".join(b.get("text", "") for b in blocks if b.get("type") == "text")


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    directory, command = sys.argv[1], sys.argv[2]

    signal.signal(signal.SIGALRM,
                  lambda *_: (_ for _ in ()).throw(SystemExit("mcp-probe: timed out")))
    signal.alarm(TIMEOUT_SECONDS)

    server = Server(directory)
    try:
        server.handshake()
        if command == "list":
            tools = server.request("tools/list", {}, 2).get("tools", [])
            for tool in tools:
                print(tool["name"])
        elif command == "call":
            if len(sys.argv) != 5:
                raise SystemExit("usage: mcp-probe.py <server-dir> call <tool> <json>")
            result = server.request("tools/call", {
                "name": sys.argv[3],
                "arguments": json.loads(sys.argv[4]),
            }, 2)
            print(result_text(result))
        else:
            raise SystemExit(f"mcp-probe: unknown command {command}")
    finally:
        signal.alarm(0)
        server.close()


if __name__ == "__main__":
    main()
