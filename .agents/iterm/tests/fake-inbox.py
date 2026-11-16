#!/usr/bin/env python3
"""A stand-in for a Claude Code session's inbox socket, for test-pane-run.sh.

  fake-inbox.py serve <socket> <outdir> [<registry> <status>]
      Bind and listen, then return while a child keeps serving. Each
      connection's bytes land in <outdir>/post-<n>, read until the poster
      closes; a poster that does not close leaves <outdir>/unclosed-<n>. With
      <registry>, each post also sets that JSON file's `status`, as a session
      does when a message changes what it is doing.
  fake-inbox.py stop <socket>
      End the server and return once it has handled every earlier connection,
      so the caller reads <outdir> with nothing still in flight.
"""
import json
import os
import socket
import sys

STOP = b"\x00stop\n"


def serve(path, outdir, registry=None, status=None):
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen(16)
    if os.fork():
        return
    count = 0
    while True:
        conn, _ = server.accept()
        conn.settimeout(10)
        data, closed = b"", True
        try:
            while chunk := conn.recv(65536):
                data += chunk
        except socket.timeout:
            closed = False
        if data == STOP:
            conn.close()
            os.unlink(path)
            os._exit(0)
        count += 1
        with open(os.path.join(outdir, f"{'post' if closed else 'unclosed'}-{count}"), "wb") as out:
            out.write(data)
        if registry:
            with open(registry) as stream:
                entry = json.load(stream)
            entry["status"] = status
            with open(registry, "w") as stream:
                json.dump(entry, stream)
        conn.close()


def stop(path):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.connect(path)
    client.sendall(STOP)
    client.shutdown(socket.SHUT_WR)
    while client.recv(1):
        pass


if __name__ == "__main__":
    {"serve": serve, "stop": stop}[sys.argv[1]](*sys.argv[2:])
