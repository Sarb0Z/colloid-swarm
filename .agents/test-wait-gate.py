#!/usr/bin/env python3
"""Drive the wait gate against the forms it must and must not refuse.

The table is the contract; the refused rows are shapes observed in this
machine's September transcripts. The end-to-end rows run the policy script the
way the Claude adapter does, so the toggle, the background flag, and the exit
code are covered too.
"""

import importlib.util
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

here = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("wait_gate", here / "hooks" / "lib" / "wait-gate.py")
if spec is None or spec.loader is None:
    raise SystemExit("test-wait-gate: cannot load hooks/lib/wait-gate.py")
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
    "cd /Users/alice/Projects/x; sleep 180; tail -4 /tmp/dcs-verify.log",
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
    "sleep 2; tail -12 /private/tmp/claude-501/-Users-alice-Projects-x/abc/tasks/bv1hhywk6.output",
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

POLL_LOOP = "for i in $(seq 1 115); do [ -f /tmp/x/final-done.txt ] && break; sleep 5; done"

for command in BLOCK:
    reason = gate.verdict(command, None)
    check(f"refuses {command!r}", reason is not None)
for command in ALLOW:
    reason = gate.verdict(command, None)
    check(f"passes {command!r}", reason is None, reason or "")

# (command, Bash's timeout in ms, refused?)
TIMED = [
    (POLL_LOOP, 600000, True),
    (POLL_LOOP, None, False),
    (POLL_LOOP, 120000, False),
    (POLL_LOOP, "abc", False),
    ("until curl -sf http://localhost:3000 >/dev/null; do sleep 2; done", 600000, True),
    ("for i in $(seq 1 40); do curl -sf localhost:3000 && break; sleep 2; done; bun run visual > /tmp/v.log",
     600000, True),
    ("timeout 120 bash -c 'until curl -sf http://localhost:3000 >/dev/null; do sleep 2; done'", 600000, True),
    ("pytest -q", 600000, False),
    ("kill 39150; sleep 2; npm run build", 300000, False),
]
for command, limit, refused in TIMED:
    check(f"timeout {limit!r} {'refuses' if refused else 'passes'} {command!r}",
          (gate.verdict(command, limit) is not None) == refused)

UNREADABLE = [
    "sleep $s",
    'sleep "$DELAY"; echo hi',
    "s=30; [ $s -gt 0 ] && [ $s -lt 590 ] && sleep $s; date -u +%H:%M:%S",
]
for command in UNREADABLE:
    check(f"refuses an unreadable sleep {command!r}", "cannot read" in (gate.verdict(command, None) or ""))

LOOP_CONDITIONS = [
    "while sleep 5; do [ -f x ] && break; done",
    "until sleep 30; do :; done",
    "while ! sleep 5 || [ ! -f x ]; do :; done",
    "while [ ! -f x ] && sleep 5; do :; done",
    "while [ ! -f x ]\ndo\nsleep 5\ndone",
    "while [ ! -f x ] &&\nsleep 5\ndo :; done",
]
for command in LOOP_CONDITIONS:
    check(f"refuses a loop-condition sleep {command!r}", gate.verdict(command, 600000) is not None)
EXTRA_TIMED = [
    ("while sleep 600; do break; done", None, True),
    ("until sleep 30; do :; done", None, True),
    ("if sleep 600; then echo; fi", None, True),
    ("bash -lc 'sleep 600'", None, True),
    ("bash -lc 'until [ -f x ]; do sleep 5; done'", 600000, True),
    ("bash -c 'sleep 3; sleep 3'", None, True),
    ("bash -c 'sleep 2; npm run build'", 300000, False),
    ("sh -c 'kill 1; sleep 1' && npm test", 300000, False),
    ('while read -r line; do echo "$line"; done < f', 600000, False),
    ("for i in 1 2 3; do echo $i; done", 600000, False),
]
for command, limit, refused in EXTRA_TIMED:
    check(f"timeout {limit!r} {'refuses' if refused else 'passes'} {command!r}",
          (gate.verdict(command, limit) is not None) == refused)

# The first rule that fires names itself.
ORDER = [
    ("sleep 90; tail /tmp/c/tasks/abc123.output", None, "background task's output"),
    ("sleep $s", None, "cannot read"),
    ("sleep 90", None, "sleeping 90 s"),
    ("until curl -sf localhost:3000; do sleep 2; done", 600000, "this polls"),
    ("npm run dev &", None, "starts a process"),
]
for command, limit, part in ORDER:
    check(f"{command!r} is refused as {part!r}", part in (gate.verdict(command, limit) or ""))

LOOPED = "until curl -sf localhost:3000; do sleep 2; done"
for limit in (True, 0, -5, float("nan"), float("inf"), "600000", None):
    check(f"timeout {limit!r} reads as the default", gate.limit_ms(limit) == gate.DEFAULT_TIMEOUT_MS)
    check(f"timeout {limit!r} passes a looped short sleep", gate.verdict(LOOPED, limit) is None)
check("120001 refuses a looped sleep", gate.verdict(LOOPED, 120001) is not None)
check("a limit past the host's ceiling is quoted at the ceiling", "600 s" in (gate.verdict(LOOPED, 9999999) or ""))

wait = gate.WAIT
sleep_reason = gate.verdict("sleep 90; echo waited", None) or ""
check("the remedy names each way to wait",
      all(part in wait for part in ("end your turn", "run_in_background: true", "for i in $(seq 30)",
                                    "gh run watch", "split", "echo up || echo down")) and "seq 110" not in wait)
check("a refusal carries the remedy", wait in sleep_reason)
unreadable = gate.verdict("sleep $s", None) or ""
check("the unreadable refusal names the remedy once",
      unreadable.count("Pick the wait that ends with the event") == 1, unreadable)
example = re.search(r"for i in \$\(seq (\d+)\); do .*? -m (\d+) .*?sleep (\d+); done", wait)
check("the remedy's own poll fits the 2-minute default",
      bool(example) and int(example[1]) * (int(example[3]) + int(example[2])) + int(example[2]) < 120,
      str(example and example.groups()))
# Every poll the scaffold's prose recommends must itself finish inside Bash's default limit.
for doc in sorted([*(here / "personas").glob("*.md"), here / "skills" / "workloop" / "working-practice.md"]):
    for line in doc.read_text().splitlines():
        for found in re.finditer(r"seq (\d+)\)[^\n]*?sleep (\d+)", line):
            count, nap = int(found[1]), int(found[2])
            probe = re.search(r"-m (\d+)", line)
            probe_s = int(probe[1]) if probe else 0
            check(f"{doc.name}: seq {count} / sleep {nap} fits the default limit",
                  count * (nap + probe_s) + probe_s < 120, line)
for name, text in (("sleep", sleep_reason), ("bare &", gate.verdict("npm run dev &", None) or ""),
                   ("task poll", gate.verdict(BLOCK[15], None) or ""), ("remedy", wait)):
    check(f"no {name} text names timeout followed by a number", not re.search(r"timeout\W+\d", text), text)
check("a bare & refusal names wait and run_in_background",
      all(part in (gate.verdict("npm run dev &", None) or "") for part in ("`wait`", "run_in_background: true")))

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

timed = run(here.parent, {"command": POLL_LOOP, "timeout": 600000})
untimed = run(here.parent, {"command": POLL_LOOP})
check("the policy refuses the polling loop under a raised timeout", timed.returncode == 2, timed.stderr)
check("the policy passes the polling loop without a timeout", untimed.returncode == 0, untimed.stderr)
with_agent = run(here.parent, {"command": "sleep 300", "agent_id": "a1"})
check("a payload with an agent_id gets the same verdict as one without",
      with_agent.returncode == blocked.returncode and with_agent.stderr == blocked.stderr, with_agent.stderr)


def normalized(payload):
    out = subprocess.run([sys.executable, str(here / "claude" / "normalize-hook.py"), "wait-gate.sh", str(here.parent)],
                         input=json.dumps(payload), capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


tool = {"command": "sleep 20", "run_in_background": False}
check("the normalizer passes Bash's timeout to the gate",
      normalized({"tool_input": {**tool, "timeout": 600000}})["timeout"] == 600000)
check("the normalizer gives None when no timeout is set", normalized({"tool_input": tool})["timeout"] is None)
registered = json.loads((here / "claude" / "settings.json").read_text())
wait_commands = [hook["command"] for group in registered["hooks"]["PreToolUse"] for hook in group["hooks"]
                 if "wait-gate.sh" in hook["command"]]
check("wait-gate is registered once, for every agent",
      len(wait_commands) == 1 and "--agent" not in wait_commands[0], str(wait_commands))


def through_hook(extra):
    """Run the registered hook command end to end: adapter, normalizer, policy."""
    payload = {"hook_event_name": "PreToolUse", "tool_name": "Bash", **extra}
    env = {**os.environ, "CLAUDE_PROJECT_DIR": str(here.parent)}
    return subprocess.run(["bash", "-c", wait_commands[0]], input=json.dumps(payload), capture_output=True,
                          text=True, env=env, cwd=here.parent)


loop = {"command": POLL_LOOP, "timeout": 600000}
hook_lead = through_hook({"tool_input": loop})
hook_cell = through_hook({"tool_input": loop, "agent_id": "a1b2", "agent_type": "implementer"})
hook_plain = through_hook({"tool_input": {"command": POLL_LOOP}})
check("through the hook, the lead's polling loop under a raised timeout is refused",
      hook_lead.returncode == 2, hook_lead.stderr)
check("through the hook, a cell's is refused too", hook_cell.returncode == 2, hook_cell.stderr)
check("through the hook, the same loop without a timeout passes", hook_plain.returncode == 0, hook_plain.stderr)

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
