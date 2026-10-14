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

# Lead refusals that a cell's call, capped by Bash's own timeout, may run:
# a sleep of 5 s or less in a command reading a task's output file.
SHORT_POLLS = {BLOCK[15], BLOCK[16]}
CELL_ALLOW = [
    "for i in $(seq 110); do grep -q '^exit=' /tmp/out.log && break; sleep 5; done",
    "for i in $(seq 110); do grep -q '^exit=' /private/tmp/claude-501/p/s/tasks/b72i5hegt.output && break; sleep 5; done",
    "until [ -s /private/tmp/claude-501/p/s/tasks/b72i5hegt.output ]; do sleep 1; done",
]
CELL_BLOCK = [
    "for i in $(seq 110); do grep -q '^exit=' /private/tmp/claude-501/p/s/tasks/b72i5hegt.output && break; sleep 30; done",
    "sleep 90; tail -4 /private/tmp/claude-501/p/s/tasks/b72i5hegt.output",
    "for i in $(seq 110); do grep -q '^exit=' /tmp/out.log && break; sleep 30; done",
    "sleep 4; sleep 4; tail /private/tmp/claude-501/p/s/tasks/b72i5hegt.output",
]

for command in BLOCK:
    check(f"refuses {command!r}", gate.verdict(command, "lead") is not None)
    check(f"a cell {'passes' if command in SHORT_POLLS else 'is refused'} {command!r}",
          (gate.verdict(command, "cell") is None) == (command in SHORT_POLLS))
for command in ALLOW:
    for agent in ("lead", "cell"):
        reason = gate.verdict(command, agent)
        check(f"passes {command!r} for the {agent}", reason is None, reason or "")
for command in CELL_ALLOW:
    reason = gate.verdict(command, "cell")
    check(f"a cell's capped poll passes {command!r}", reason is None, reason or "")
for command in CELL_BLOCK:
    check(f"a cell's long sleep refused {command!r}", gate.verdict(command, "cell") is not None)
check("a lead's capped poll on a task's output is refused as before",
      "output file" in (gate.verdict(CELL_ALLOW[1], "lead") or ""))

lead_sleep = gate.verdict("sleep 90; echo waited", "lead") or ""
cell_sleep = gate.verdict("sleep 90; echo waited", "cell") or ""
lead_amp = gate.verdict("npm run dev &", "lead") or ""
cell_amp = gate.verdict("npm run dev &", "cell") or ""
check("the lead's sleep remedy names each way to wait",
      all(part in lead_sleep for part in ("end your turn", "run_in_background: true", "for i in $(seq 60)", "gh run watch")))
check("the cell's sleep remedy is the cell's",
      all(part in cell_sleep for part in ("run_in_background: true", 'echo "exit=$?"', "seq 110", "TaskStop", "600000"))
      and "end your turn" not in cell_sleep)
check("the cell's bare & refusal carries the cell's remedy",
      "`wait`" in cell_amp and "run_in_background: true" in cell_amp and "seq 110" in cell_amp)
check("the lead's bare & refusal carries the lead's text",
      "`wait`" in lead_amp and "run_in_background: true" in lead_amp and "seq 110" not in lead_amp)
check("the lead's remedy no longer names timeout", "timeout" not in lead_sleep and "bash -c" not in lead_sleep)
check("each remedy's capped loop reports how it ended",
      "echo up || echo down" in lead_sleep and "echo up || echo down" in cell_sleep and "|| echo still-running" in cell_sleep)
check("the cell's end marker covers the whole command and names a pipeline's status",
      '{ <cmd>; } 2>&1; echo "exit=$?"' in cell_sleep and "pipefail" in cell_sleep)
for name, text in (("lead sleep", lead_sleep), ("cell sleep", cell_sleep), ("lead &", lead_amp), ("cell &", cell_amp),
                   ("lead task poll", gate.verdict(CELL_ALLOW[1], "lead") or "")):
    check(f"no {name} remedy names timeout followed by a number", not re.search(r"timeout\W+\d", text), text)

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

cell_blocked = run(here.parent, {"command": "sleep 300", "agent_id": "a1"})
check("the policy gives a payload with an agent_id the cell's remedy",
      cell_blocked.returncode == 2 and "seq 110" in cell_blocked.stderr, cell_blocked.stderr)
check("the policy gives a payload without one the lead's remedy",
      blocked.returncode == 2 and "seq 110" not in blocked.stderr and "end your turn" in blocked.stderr)


def normalized(payload):
    out = subprocess.run([sys.executable, str(here / "claude" / "normalize-hook.py"), "wait-gate.sh", str(here.parent)],
                         input=json.dumps(payload), capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


tool = {"command": "sleep 20", "run_in_background": False}
check("the normalizer passes a cell's agent_id to the gate",
      normalized({"tool_input": tool, "agent_id": "a1b2", "agent_type": "implementer"})["agent_id"] == "a1b2")
check("the normalizer passes an empty agent_id for the lead", normalized({"tool_input": tool})["agent_id"] == "")
# A `claude --agent <name>` main session carries agent_type alone; it is the lead.
check("the normalizer treats a named main session as the lead",
      normalized({"tool_input": tool, "agent_type": "implementer"})["agent_id"] == "")
registered = json.loads((here / "claude" / "settings.json").read_text())
wait_commands = [hook["command"] for group in registered["hooks"]["PreToolUse"] for hook in group["hooks"]
                 if "wait-gate.sh" in hook["command"]]
check("wait-gate is registered once, for every agent",
      len(wait_commands) == 1 and "--agent" not in wait_commands[0], str(wait_commands))


def through_hook(extra):
    """Run the registered hook command end to end: adapter, normalizer, policy."""
    payload = {"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": tool, **extra}
    env = {**os.environ, "CLAUDE_PROJECT_DIR": str(here.parent)}
    return subprocess.run(["bash", "-c", wait_commands[0]], input=json.dumps(payload), capture_output=True,
                          text=True, env=env, cwd=here.parent)


hook_cell = through_hook({"agent_id": "a1b2", "agent_type": "implementer"})
hook_named = through_hook({"agent_type": "implementer"})
check("through the hook, a cell gets the cell's remedy",
      hook_cell.returncode == 2 and "seq 110" in hook_cell.stderr, hook_cell.stderr)
check("through the hook, a named main session gets the lead's remedy",
      hook_named.returncode == 2 and "end your turn" in hook_named.stderr, hook_named.stderr)

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
