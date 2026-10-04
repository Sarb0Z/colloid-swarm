#!/usr/bin/env python3
"""Drive the wait gate against the forms it must and must not refuse.

The table is the contract; the refused rows are shapes observed in this
machine's September transcripts. The end-to-end rows run the policy script the
way the Claude adapter does, so the toggle, the background flag, and the exit
code are covered too.
"""

import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile

here = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("wait_gate", here / "hooks" / "lib" / "wait-gate.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

fails = 0


def check(name, ok, detail=""):
    global fails
    if ok:
        print(f"ok    {name}")
    else:
        fails += 1
        print(f"FAIL  {name}{(chr(10) + '  ' + detail) if detail else ''}")


BLOCK = [
    "sleep 520",
    "sleep 90; echo waited",
    "sleep 240; git status --short | head -20",
    "cd /Users/mac/Projects/x; sleep 180; tail -4 /tmp/dcs-verify.log",
    "sleep 60; curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/login",
    "sleep 3; sleep 3",
    "sleep 1m",
    "sleep infinity",
    "for i in $(seq 1 38); do pgrep -f pytest >/dev/null || break; sleep 15; done",
    "until grep -q DONE /tmp/run.log; do sleep 30; done",
    "while kill -0 123 2>/dev/null; do sleep 10; done; tail log",
    "timeout 600 bash -c 'until grep -q DONE log; do sleep 30; done'",
    "bash -c 'sleep 300; tail x.log'",
    "echo 'a # b' & srv",
    "echo a#b & srv",
    "sleep 2; tail -12 /private/tmp/claude-501/-Users-mac-Projects-x/abc/tasks/bv1hhywk6.output",
    "until [ -s /private/tmp/claude-501/p/s/tasks/b72i5hegt.output ]; do sleep 1; done",
    "(bun run judge --local > /tmp/p4-judge.log 2>&1; echo EXIT=$? >> /tmp/p4-judge.log) &",
    "nohup npm run dev > /tmp/dev.log 2>&1 &",
    "uv run pytest -q > /tmp/full.log 2>&1 &\nsleep 2",
    "npm run dev &",
    "( srv & )",
]

ALLOW = [
    "sleep 5",
    "kill 39150 39148 2>/dev/null; sleep 3; npm start --help",
    "pkill -f 'next dev'; sleep 2; rm -rf .next",
    "until curl -sf http://localhost:3000 >/dev/null; do sleep 2; done",
    "timeout 120 bash -c 'until curl -sf http://localhost:3000 >/dev/null; do sleep 2; done'",
    "npm run build > /tmp/build.log 2>&1",
    "npm test &>/tmp/t.log",
    "ls >&2",
    "a && b || c",
    "a | b |& c",
    "pytest a & pytest b & wait",
    "echo 'sleep 600 &'",
    "grep -rn sleep src/",
    "cat <<'EOF' > notes.md\nsleep 900\nnpm run dev &\nEOF",
    "python3 -c 'import time; print(1)'",
    "echo hi # a & b",
    "echo hi  # sleep 600",
    "ls; # start it & later",
    "set -e\n# ── Analytics & tracking\ndefaults write com.apple.finder X -bool YES",
    "",
]

for command in BLOCK:
    check(f"refuses {command!r}", gate.verdict(command) is not None)
for command in ALLOW:
    reason = gate.verdict(command)
    check(f"passes {command!r}", reason is None, reason or "")

reason = gate.verdict("sleep 90; echo waited") or ""
check("the sleep remedy names each way to wait",
      all(part in reason for part in ("end your turn", "run_in_background: true", "until curl", "gh run watch")))
reason = gate.verdict("npm run dev &") or ""
check("the background remedy names run_in_background and wait",
      "run_in_background: true" in reason and "`wait`" in reason)

policy = here / "hooks" / "policy" / "wait-gate.sh"


def run(repo, payload):
    fixture = pathlib.Path(repo) / ".agents"
    return subprocess.run(["bash", str(policy)], input=json.dumps(payload), capture_output=True, text=True,
                          env={"PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"}, cwd=fixture.parent)


blocked = run(here.parent, {"command": "sleep 300"})
check("the policy exits 2 with the reason on stderr", blocked.returncode == 2 and "Blocked" in blocked.stderr,
      f"{blocked.returncode} {blocked.stderr!r}")
background = run(here.parent, {"command": "sleep 300", "run_in_background": True})
check("a command the host runs in the background passes", background.returncode == 0)
garbage = subprocess.run(["bash", str(policy)], input="not json", capture_output=True, text=True)
check("an unreadable payload passes", garbage.returncode == 0)

with tempfile.TemporaryDirectory() as scratch:
    root = pathlib.Path(scratch)
    (root / ".agents" / "hooks").mkdir(parents=True)
    for part in ("policy", "lib"):
        (root / ".agents" / "hooks" / part).symlink_to(here / "hooks" / part)
    (root / ".agents" / "config.json").write_text('{"hooks":{"wait_gate":{"enabled":false}}}')
    off = subprocess.run(["bash", str(root / ".agents" / "hooks" / "policy" / "wait-gate.sh")],
                         input=json.dumps({"command": "sleep 300"}), capture_output=True, text=True)
    check("the config toggle turns the gate off", off.returncode == 0, off.stderr)

print("\nALL PASS" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
