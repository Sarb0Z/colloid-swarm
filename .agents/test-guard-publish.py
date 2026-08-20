#!/usr/bin/env python3
"""Drive the publish guard against the calls it must and must not flag.

The table is the contract. A row states one tool call and whether the guard
asks for approval, so a rule that widens or narrows shows up as a named
failure rather than as a behaviour nobody notices.
"""

import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

here = pathlib.Path(__file__).resolve().parent
policy = here / "hooks" / "lib" / "guard-publish.py"
spec = importlib.util.spec_from_file_location("guard_publish", policy)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

fails = 0


def check(name, ok, detail=""):
    global fails
    if ok:
        print(f"ok    {name}")
    else:
        fails += 1
        print(f"FAIL  {name}{(chr(10) + '  ' + detail) if detail else ''}")


# (tool_name, tool_input, asks) — the whole policy, one row per shape.
ASK = [
    ("Bash", {"command": "git push"}),
    ("Bash", {"command": "git push origin main"}),
    ("Bash", {"command": "git -C /Users/mac/Projects/repo push origin main"}),
    ("Bash", {"command": "git -c user.name=x push"}),
    ("Bash", {"command": "git --git-dir=/r/.git push"}),
    ("Bash", {"command": "git commit -m x && git push"}),
    ("Bash", {"command": "gh pr create --title x"}),
    ("Bash", {"command": "gh release create v1.0"}),
    ("Bash", {"command": "gh issue comment 5 --body hi"}),
    ("Bash", {"command": "gh api repos/o/r/issues -f title=x"}),
    ("Bash", {"command": "gh api -X POST repos/o/r/issues"}),
    ("Bash", {"command": "gh api --method DELETE repos/o/r"}),
    ("Bash", {"command": "npm publish"}),
    ("Bash", {"command": "pnpm publish --access public"}),
    ("Bash", {"command": "npm unpublish pkg"}),
    ("Bash", {"command": "yarn npm publish"}),
    ("Bash", {"command": "vercel"}),
    ("Bash", {"command": "vercel deploy --prod"}),
    ("Bash", {"command": "vercel --prod"}),
    ("Bash", {"command": "vercel --cwd /tmp deploy --prod"}),
    ("Bash", {"command": "vercel -t TOKEN"}),
    ("Bash", {"command": "vercel --target production"}),
    ("Bash", {"command": "vercel --target=production"}),
    ("Bash", {"command": "vercel -S myteam"}),
    ("Bash", {"command": "vercel --prod -t TOK"}),
    ("Bash", {"command": "vercel -A vercel.json"}),
    ("Bash", {"command": "vercel -d"}),
    ("Bash", {"command": "npx vercel --scope myteam"}),
    ("Bash", {"command": "npx -p vercel vercel --prod"}),
    ("Bash", {"command": "npx -c 'git push origin main'"}),
    ("Bash", {"command": "npx --call \"vercel --prod\""}),
    ("Bash", {"command": "vercel promote dpl_123"}),
    ("Bash", {"command": "npx vercel --prod deploy"}),
    ("Bash", {"command": "netlify deploy --prod"}),
    ("Bash", {"command": "wrangler deploy"}),
    ("Bash", {"command": "firebase deploy"}),
    ("Bash", {"command": "railway up"}),
    ("Bash", {"command": "docker push repo/img:latest"}),
    ("Bash", {"command": "gh workflow run deploy.yml"}),
    ("Bash", {"command": "gh release upload v1 dist.tgz"}),
    ("PowerShell", {"command": "git push origin main"}),
    ("Monitor", {"command": "while true; do git push; sleep 60; done"}),
    ("Artifact", {"file_path": "/tmp/report.html", "favicon": "x"}),
    ("Artifact", {"file_path": "/tmp/report.html", "action": "publish"}),
]

PASS = [
    ("Bash", {"command": "git status"}),
    ("Bash", {"command": "git commit -m 'push later'"}),
    ("Bash", {"command": "git log origin/main..HEAD"}),
    ("Bash", {"command": "echo git push"}),
    ("Bash", {"command": "grep -r 'git push' docs/"}),
    ("Bash", {"command": "gh pr view 5"}),
    ("Bash", {"command": "gh pr list"}),
    ("Bash", {"command": "gh api repos/o/r/issues"}),
    ("Bash", {"command": "gh api -X GET repos/o/r"}),
    ("Bash", {"command": "npm install"}),
    ("Bash", {"command": "npm run publish-report"}),
    ("Bash", {"command": "vercel ls"}),
    ("Bash", {"command": "vercel inspect dpl_123"}),
    ("Bash", {"command": "vercel --help"}),
    ("Bash", {"command": "vercel --version"}),
    ("Bash", {"command": "vercel --cwd /tmp ls"}),
    ("Bash", {"command": "vercel --scope=myteam ls"}),
    ("Bash", {"command": "vercel -t TOK ls --debug"}),
    ("Bash", {"command": "npx -y vercel ls"}),
    ("Bash", {"command": "npx -c 'ls -la'"}),
    ("Bash", {"command": "git push --dry-run"}),
    ("Bash", {"command": "git push -n origin main"}),
    ("Bash", {"command": "npx create-react-app my-app"}),
    ("Bash", {"command": "docker build -t repo/img ."}),
    ("Bash", {"command": "netlify status"}),
    ("Bash", {"command": "gh workflow list"}),
    ("Artifact", {"action": "list"}),
    ("Read", {"file_path": "/tmp/x"}),
    ("Bash", {}),
]

for tool, tool_input in ASK:
    reason = guard.verdict(tool, tool_input)
    check(f"asks: {tool} {json.dumps(tool_input)[:60]}", reason is not None)

for tool, tool_input in PASS:
    reason = guard.verdict(tool, tool_input)
    check(f"quiet: {tool} {json.dumps(tool_input)[:60]}", reason is None,
          f"unexpected: {reason}")

# The entry point: envelope shape on ask, silence on pass, broken input, toggle.
env = dict(os.environ)


def run(payload, repo=None):
    args = [sys.executable, str(policy)] + ([repo] if repo else [])
    return subprocess.run(args, input=payload, capture_output=True, text=True, env=env)


result = run(json.dumps({"tool_name": "Bash", "tool_input": {"command": "git push"}}))
out = json.loads(result.stdout)
check("entry point exits 0 and emits the ask envelope",
      result.returncode == 0
      and out["hookSpecificOutput"]["permissionDecision"] == "ask"
      and out["hookSpecificOutput"]["hookEventName"] == "PreToolUse"
      and "approval" in out["hookSpecificOutput"]["permissionDecisionReason"])

result = run(json.dumps({"tool_name": "Bash", "tool_input": {"command": "ls"}}))
check("entry point is silent on a quiet call",
      result.returncode == 0 and result.stdout.strip() == "")

result = run("not json")
out = json.loads(result.stdout)
check("entry point asks on unreadable input",
      result.returncode == 0
      and out["hookSpecificOutput"]["permissionDecision"] == "ask")

with tempfile.TemporaryDirectory() as tmp:
    isolated = pathlib.Path(tmp) / "guard-publish.py"
    shutil.copy2(policy, isolated)
    result = subprocess.run(
        [sys.executable, str(isolated)],
        input=json.dumps({"tool_name": "Bash", "tool_input": {"command": "git push"}}),
        capture_output=True, text=True, env=env)
    out = json.loads(result.stdout)
    check("entry point asks when the shell parser is missing",
          result.returncode == 0
          and out["hookSpecificOutput"]["permissionDecision"] == "ask")
    result = subprocess.run(
        [sys.executable, str(isolated)],
        input=json.dumps({"tool_name": "Bash", "tool_input": {"command": "ls -la"}}),
        capture_output=True, text=True, env=env)
    check("a missing shell parser leaves a non-publish command quiet",
          result.returncode == 0 and result.stdout.strip() == "")

adapter = here / "claude" / "adapter.sh"
claude_payload = {"session_id": "t", "hook_event_name": "PreToolUse", "cwd": str(here.parent),
                  "tool_name": "Bash", "tool_input": {"command": "git push origin main"}}
result = subprocess.run(
    [str(adapter), "guard-publish.sh"], input=json.dumps(claude_payload),
    capture_output=True, text=True, env=dict(env, CLAUDE_PROJECT_DIR=str(here.parent)))
out = json.loads(result.stdout)
check("the wired Claude adapter path asks on git push",
      result.returncode == 0 and out["hookSpecificOutput"]["permissionDecision"] == "ask")
result = subprocess.run(
    [str(adapter), "guard-publish-missing.sh"], input=json.dumps(claude_payload),
    capture_output=True, text=True, env=dict(env, CLAUDE_PROJECT_DIR=str(here.parent)))
out = json.loads(result.stdout)
check("the adapter asks when a PreToolUse policy file is missing",
      result.returncode == 0 and out["hookSpecificOutput"]["permissionDecision"] == "ask")

with tempfile.TemporaryDirectory() as tmp:
    wrapper = pathlib.Path(tmp) / ".agents" / "hooks" / "policy" / "guard-publish.sh"
    wrapper.parent.mkdir(parents=True)
    shutil.copy2(here / "hooks" / "policy" / "guard-publish.sh", wrapper)
    result = subprocess.run(
        [str(wrapper)],
        input=json.dumps({"tool_name": "Bash", "tool_input": {"command": "git push"}}),
        capture_output=True, text=True, env=env)
    out = json.loads(result.stdout)
    check("policy wrapper asks when its decision library is missing",
          result.returncode == 0
          and out["hookSpecificOutput"]["permissionDecision"] == "ask")

with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    wrapper = root / ".agents" / "hooks" / "policy" / "guard-publish.sh"
    decision = root / ".agents" / "hooks" / "lib" / "guard-publish.py"
    wrapper.parent.mkdir(parents=True)
    decision.parent.mkdir(parents=True)
    shutil.copy2(here / "hooks" / "policy" / "guard-publish.sh", wrapper)
    shutil.copy2(policy, decision)
    path_dir = root / "path"
    path_dir.mkdir()
    os.symlink(shutil.which("dirname"), path_dir / "dirname")
    os.symlink(shutil.which("cat"), path_dir / "cat")
    missing_env = dict(env, PATH=str(path_dir))
    result = subprocess.run(
        ["/bin/bash", str(wrapper)],
        input=json.dumps({"tool_name": "Bash", "tool_input": {"command": "git push"}}),
        capture_output=True, text=True, env=missing_env)
    out = json.loads(result.stdout)
    check("policy wrapper asks when python3 is unavailable",
          result.returncode == 0
          and out["hookSpecificOutput"]["permissionDecision"] == "ask")

    fake_python = path_dir / "python3"
    fake_python.write_text("#!/bin/sh\nexit 23\n")
    fake_python.chmod(0o755)
    result = subprocess.run(
        ["/bin/bash", str(wrapper)],
        input=json.dumps({"tool_name": "Bash", "tool_input": {"command": "git push"}}),
        capture_output=True, text=True, env=missing_env)
    out = json.loads(result.stdout)
    check("policy wrapper asks when the evaluator exits nonzero",
          result.returncode == 0
          and out["hookSpecificOutput"]["permissionDecision"] == "ask")

with tempfile.TemporaryDirectory() as tmp:
    agents = pathlib.Path(tmp) / ".agents"
    agents.mkdir()
    (agents / "config.json").write_text(
        json.dumps({"hooks": {"guard_publish": {"enabled": False}}}))
    result = run(json.dumps({"tool_name": "Bash",
                             "tool_input": {"command": "git push"}}), repo=tmp)
    check("the config toggle turns the guard off",
          result.returncode == 0 and result.stdout.strip() == "")

print()
print("ALL PASS" if fails == 0 else f"{fails} FAILURE(S)")
sys.exit(1 if fails else 0)
