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
    ("Bash", {"command": "git -C /srv/example/repo push origin main"}),
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
    # A wrapper that runs the rest of the line does not hide the publish.
    ("Bash", {"command": "timeout 600 git push"}),
    ("Bash", {"command": "bash -lc 'git push origin main'"}),
    ("Bash", {"command": "/usr/bin/env npm publish"}),
    ("Bash", {"command": "nice -n 5 vercel --prod"}),
    ("Bash", {"command": "caffeinate -i docker push repo/img"}),
    ("Bash", {"command": "uv run --with x wrangler deploy"}),
    ("Bash", {"command": "npx wrangler@3 deploy"}),
    ("Bash", {"command": "npx -w apps/web vercel deploy --prod"}),
    ("Bash", {"command": "bunx vercel@latest --prod"}),
    ("Bash", {"command": "pnpm dlx vercel@39 --prod"}),
    ("PowerShell", {"command": "git push origin main"}),
    ("Monitor", {"command": "while true; do git push; sleep 60; done"}),
    ("Artifact", {"file_path": "/tmp/report.html", "favicon": "x"}),
    ("Artifact", {"file_path": "/tmp/report.html", "action": "publish"}),
    # Comment and asset actions reach the published page without a file_path.
    ("Artifact", {"url": "https://claude.ai/x", "action": "reply",
                  "thread_id": "t1", "text": "hi"}),
    ("Artifact", {"url": "https://claude.ai/x", "action": "resolve", "thread_id": "t1"}),
    ("Artifact", {"url": "https://claude.ai/x", "action": "upload_asset",
                  "file_path": "/tmp/a.png"}),
    ("Artifact", {"url": "https://claude.ai/x", "action": "delete_asset",
                  "asset_id": "0" * 32}),
    # An action this guard has never seen asks rather than passing silently.
    ("Artifact", {"url": "https://claude.ai/x", "action": "transfer_ownership"}),
]

# The reason reaches the user as the permission prompt, so an unknown action
# must be named in it. Asserting only that a reason exists hides a prompt that
# describes the wrong operation.
unknown = guard.verdict("Artifact", {"action": "transfer_ownership"})
check("an unknown Artifact action names itself in the prompt",
      "transfer_ownership" in unknown
      and "puts this page on a claude.ai URL" not in unknown,
      f"reason was: {unknown}")

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
    ("Bash", {"command": "timeout 60 git status"}),
    ("Bash", {"command": "bash -lc 'git log'"}),
    ("Bash", {"command": "command -v vercel"}),
    ("Bash", {"command": "npx wrangler@3 dev"}),
    ("Bash", {"command": "npx vercel@latest ls"}),
    ("Bash", {"command": "gh workflow list"}),
    ("Artifact", {"action": "list"}),
    ("Artifact", {"url": "https://claude.ai/x", "action": "comments"}),
    ("Artifact", {"url": "https://claude.ai/x", "action": "list_assets"}),
    ("Artifact", {"url": "https://claude.ai/x", "action": "read_asset",
                  "asset_id": "0" * 32}),
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


result = run(json.dumps({"tool_name": "Bash", "tool_input": {"command": "git push"},
                         "permission_mode": "default"}))
out = json.loads(result.stdout)
check("entry point exits 0 and emits the ask envelope",
      result.returncode == 0
      and out["hookSpecificOutput"]["permissionDecision"] == "ask"
      and out["hookSpecificOutput"]["hookEventName"] == "PreToolUse"
      and "approval" in out["hookSpecificOutput"]["permissionDecisionReason"])

result = run(json.dumps({"tool_name": "Bash", "tool_input": {"command": "ls"}}))
check("entry point is silent on a quiet call",
      result.returncode == 0 and result.stdout.strip() == "")

# The mode decides whether a human can answer. Where no prompt is shown, the
# same verdict denies and the reason tells the model how the user approves.
for mode in ("auto", "bypassPermissions", "dontAsk", "", "someFutureMode"):
    result = run(json.dumps({"tool_name": "Bash", "tool_input": {"command": "git push"},
                             "permission_mode": mode}))
    out = json.loads(result.stdout)["hookSpecificOutput"]
    check(f"entry point denies a push in {mode or 'an unnamed'} mode",
          result.returncode == 0 and out["permissionDecision"] == "deny"
          and (mode or "unnamed") in out["permissionDecisionReason"]
          and "Shift+Tab" in out["permissionDecisionReason"]
          and out["permissionDecisionReason"].startswith("git push publishes"),
          f"got: {out}")
    result = run(json.dumps({"tool_name": "Bash", "tool_input": {"command": "ls"},
                             "permission_mode": mode}))
    check(f"entry point stays silent on a quiet call in {mode or 'an unnamed'} mode",
          result.returncode == 0 and result.stdout.strip() == "")
    result = run(json.dumps({"tool_name": "Bash", "permission_mode": mode}))
    out = json.loads(result.stdout)["hookSpecificOutput"]
    check(f"an incomplete payload denies in {mode or 'an unnamed'} mode",
          result.returncode == 0 and out["permissionDecision"] == "deny")
for mode in ("default", "acceptEdits", "plan"):
    result = run(json.dumps({"tool_name": "Bash", "tool_input": {"command": "git push"},
                             "permission_mode": mode}))
    out = json.loads(result.stdout)["hookSpecificOutput"]
    check(f"entry point asks for a push in {mode} mode",
          result.returncode == 0 and out["permissionDecision"] == "ask"
          and "Shift+Tab" not in out["permissionDecisionReason"])

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
        input=json.dumps({"tool_name": "Bash", "tool_input": {"command": "git push"},
                          "permission_mode": "default"}),
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

# The publish-approval dialog's token: one fresh token for this exact call turns
# a rule's ask into allow in any mode, once. Nothing else reads it.
with tempfile.TemporaryDirectory() as tmp:
    repo = pathlib.Path(tmp)
    agents = repo / ".agents"
    agents.mkdir()

    def token(call_id, age=0):
        path = agents / f".publish-approved-{call_id}"
        path.write_text("")
        stamp = path.stat().st_mtime - age
        os.utime(path, (stamp, stamp))
        return path

    # A Claude Code payload, mapped by the adapter's own normalizer, so the id
    # the token is named for is the one the guard receives in a live session.
    def decide(call_id, mode="auto", command="git push"):
        claude = json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash",
                             "tool_input": {"command": command}, "tool_use_id": call_id,
                             "permission_mode": mode, "cwd": str(repo)})
        mapped = subprocess.run([sys.executable, str(here / "claude" / "normalize-hook.py"),
                                 "guard-publish.sh", str(repo)],
                                input=claude, capture_output=True, text=True, check=True)
        result = run(mapped.stdout, str(repo))
        return json.loads(result.stdout)["hookSpecificOutput"] if result.stdout.strip() else None

    approved = token("toolu_A")
    out = decide("toolu_A")
    check("a fresh dialog token allows its call in auto mode",
          out["permissionDecision"] == "allow" and "publish-approval dialog" in out["permissionDecisionReason"]
          and not approved.exists(), f"got: {out}")
    out = decide("toolu_A")
    check("the token is spent on first use", out["permissionDecision"] == "deny", f"got: {out}")

    other = token("toolu_B")
    out = decide("toolu_C")
    check("another call's token neither allows nor is spent",
          out["permissionDecision"] == "deny" and other.exists(), f"got: {out}")

    stale = token("toolu_D", age=121)
    out = decide("toolu_D")
    check("a token past the window is removed and the call denied",
          out["permissionDecision"] == "deny" and not stale.exists(), f"got: {out}")

    token("x")
    out = decide("../.publish-approved-x")
    check("a malformed call id never names a token", out["permissionDecision"] == "deny", f"got: {out}")

    (agents / ".publish-approved-toolu_dir").mkdir()
    os.utime(agents / ".publish-approved-toolu_dir", (0, 0))
    result = run(json.dumps({"tool_name": "Bash", "tool_input": {"command": "git push"},
                             "tool_use_id": "toolu_G", "permission_mode": "auto"}), str(repo))
    check("an unremovable token path is reported and approves nothing",
          result.returncode == 0 and json.loads(result.stdout)["hookSpecificOutput"]["permissionDecision"] == "deny"
          and "approves nothing" in result.stderr, f"got: {result.stdout} {result.stderr}")
    (agents / ".publish-approved-toolu_dir").rmdir()

    (agents / "policy.json").write_text('{"hooks": {"publish_approval": {"enabled": false}}}')
    switched_off = token("toolu_H")
    out = decide("toolu_H")
    check("with the dialog switched off, the guard reads no token",
          out["permissionDecision"] == "deny" and switched_off.exists(), f"got: {out}")
    (agents / "policy.json").unlink()
    switched_off.unlink()

    kept = token("toolu_E")
    check("a quiet call leaves the token alone",
          decide("toolu_E", command="ls") is None and kept.exists())

    # The hosted-write refusal is the agent's to fix, not the user's to approve.
    # The host is assembled here so this file does not read as such a script.
    host = "api." + "vercel.com"
    script = repo / "setup.py"
    script.write_text(f'import urllib.request\nurllib.request.urlopen(urllib.request.Request('
                      f'"https://{host}/v9/projects/web", data=b"{{}}", method="PATCH"))\n')
    refused = token("toolu_F")
    out = decide("toolu_F", mode="default", command=f"python3 {script}")
    check("the hosted-write refusal ignores a dialog token",
          out is not None and out["permissionDecision"] == "deny" and refused.exists(), f"got: {out}")

adapter = here / "claude" / "adapter.sh"
claude_payload = {"session_id": "t", "hook_event_name": "PreToolUse", "cwd": str(here.parent),
                  "permission_mode": "default",
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

# The host names the mode at the top of its payload; the adapter carries it
# through, and every fallback that would have asked denies where nobody answers.
auto_payload = dict(claude_payload, permission_mode="auto")
result = subprocess.run(
    [str(adapter), "guard-publish.sh"], input=json.dumps(auto_payload),
    capture_output=True, text=True, env=dict(env, CLAUDE_PROJECT_DIR=str(here.parent)))
out = json.loads(result.stdout)["hookSpecificOutput"]
check("the wired Claude adapter path denies a push in auto mode",
      result.returncode == 0 and out["permissionDecision"] == "deny"
      and "auto" in out["permissionDecisionReason"], f"got: {out}")
result = subprocess.run(
    [str(adapter), "guard-publish-missing.sh"], input=json.dumps(auto_payload),
    capture_output=True, text=True, env=dict(env, CLAUDE_PROJECT_DIR=str(here.parent)))
out = json.loads(result.stdout)
check("the adapter denies a missing PreToolUse policy in auto mode",
      result.returncode == 0 and out["hookSpecificOutput"]["permissionDecision"] == "deny")

with tempfile.TemporaryDirectory() as tmp:
    wrapper = pathlib.Path(tmp) / ".agents" / "hooks" / "policy" / "guard-publish.sh"
    wrapper.parent.mkdir(parents=True)
    shutil.copy2(here / "hooks" / "policy" / "guard-publish.sh", wrapper)
    result = subprocess.run(
        [str(wrapper)],
        input=json.dumps({"tool_name": "Bash", "tool_input": {"command": "git push"},
                          "permission_mode": "default"}),
        capture_output=True, text=True, env=env)
    out = json.loads(result.stdout)
    check("policy wrapper asks when its decision library is missing",
          result.returncode == 0
          and out["hookSpecificOutput"]["permissionDecision"] == "ask")
    result = subprocess.run(
        [str(wrapper)],
        input=json.dumps({"tool_name": "Bash", "tool_input": {"command": "git push"}}),
        capture_output=True, text=True, env=env)
    out = json.loads(result.stdout)
    check("policy wrapper denies a missing decision library when no mode is named",
          result.returncode == 0
          and out["hookSpecificOutput"]["permissionDecision"] == "deny")

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
    os.symlink(shutil.which("grep"), path_dir / "grep")   # the mode check needs it
    missing_env = dict(env, PATH=str(path_dir))
    result = subprocess.run(
        ["/bin/bash", str(wrapper)],
        input=json.dumps({"tool_name": "Bash", "tool_input": {"command": "git push"},
                          "permission_mode": "default"}),
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
        input=json.dumps({"tool_name": "Bash", "tool_input": {"command": "git push"},
                          "permission_mode": "default"}),
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

    # The workloop controller asks this way. It screens a --verify command it
    # will later run unattended in the integration worktree, with no PreToolUse
    # hook in front of it, so the toggle that governs the hook must not take
    # its floor away.
    forced = subprocess.run(
        [sys.executable, str(policy), tmp, "--force"],
        input=json.dumps({"tool_name": "Bash", "tool_input": {"command": "npm publish"},
                          "permission_mode": "default"}),
        capture_output=True, text=True, env=env)
    check("--force keeps the verdict when the toggle is off",
          forced.returncode == 0 and forced.stdout.strip() != "",
          forced.stdout.strip() or "no envelope emitted")

# A policy file that does not parse hides which scripts are outward, so while it
# is broken the guard asks on every command that could run one, names the file,
# and reports the parse failure once per call.
for broken_name in ("policy.json", "config.json"):
    with tempfile.TemporaryDirectory() as tmp:
        agents = pathlib.Path(tmp) / ".agents"
        agents.mkdir()
        (agents / broken_name).write_text('{"hooks": {"guard_publish": ')

        def call(command, mode="default"):
            return run(json.dumps({"tool_name": "Bash", "tool_input": {"command": command},
                                   "permission_mode": mode, "cwd": tmp}), tmp)

        for command in ("npm run anything", "pnpm deploy", "bash scripts/x.sh",
                        "./scripts/x.sh", "npx tsx scripts/seed.ts", "python3 tools/sync.py",
                        "cd scripts && sh ./x.sh", "git push"):
            result = call(command)
            out = json.loads(result.stdout or "{}").get("hookSpecificOutput", {})
            check(f"broken {broken_name}: asks on {command}",
                  out.get("permissionDecision") == "ask"
                  and f".agents/{broken_name}" in out.get("permissionDecisionReason", "")
                  and "fix" in out.get("permissionDecisionReason", "").lower(),
                  f"got: {result.stdout.strip() or 'silence'}")
            check(f"broken {broken_name}: the parse report prints once for {command}",
                  result.stderr.count("config.py:") == 1, result.stderr)
        result = call("npm run anything", "auto")
        out = json.loads(result.stdout or "{}").get("hookSpecificOutput", {})
        check(f"broken {broken_name}: denies where no prompt reaches the user",
              out.get("permissionDecision") == "deny"
              and f".agents/{broken_name}" in out.get("permissionDecisionReason", ""),
              f"got: {result.stdout.strip() or 'silence'}")
        for command in ("ls -la", "cat scripts/x.sh", "rg deploy scripts/", "python3 -c 'print(1)'"):
            result = call(command)
            check(f"broken {broken_name}: quiet on {command}", result.stdout.strip() == "",
                  result.stdout.strip())

with tempfile.TemporaryDirectory() as tmp:
    agents = pathlib.Path(tmp) / ".agents"
    agents.mkdir()
    (agents / "policy.json").write_text(json.dumps({"hooks": {"guard_publish": {
        "outward_commands": ["scripts/deploy.sh"]}}}))
    for command in ("npm run anything", "bash scripts/x.sh", "./scripts/x.sh"):
        result = run(json.dumps({"tool_name": "Bash", "tool_input": {"command": command},
                                 "permission_mode": "default", "cwd": tmp}), tmp)
        check(f"a valid policy.json leaves an unlisted script quiet: {command}",
              result.stdout.strip() == "" and result.stderr == "", result.stdout + result.stderr)

# A repository's own deploy script shows the guard no vercel or gh word, so the
# repository lists it in the tracked policy.json and the guard asks by path.
with tempfile.TemporaryDirectory() as tmp:
    agents = pathlib.Path(tmp) / ".agents"
    agents.mkdir()
    (agents / "policy.json").write_text(json.dumps({"hooks": {"guard_publish": {
        "outward_commands": ["scripts/deploy.sh", "switch-on/02-vercel.sh",
                             "tools/copy-env-to-prod.py"],
        "dry_run_commands": ["scripts/deploy.sh"]}}}))
    outward = guard.outward_commands(tmp)
    rehearsals = guard.dry_run_commands(tmp)
    check("dry_run_commands reads the tracked policy file", rehearsals == ["scripts/deploy.sh"],
          str(rehearsals))
    check("outward_commands reads the tracked policy file",
          outward == ["scripts/deploy.sh", "switch-on/02-vercel.sh", "tools/copy-env-to-prod.py"],
          str(outward))
    for command in ("./scripts/deploy.sh", "scripts/deploy.sh --prod",
                    "bash scripts/deploy.sh", "sh -x ./scripts/deploy.sh",
                    "ALLOW_DIRTY=1 ./scripts/deploy.sh",
                    "cd switch-on && ./02-vercel.sh",
                    "python3 ../tools/copy-env-to-prod.py SENTRY_DSN",
                    f"{tmp}/scripts/deploy.sh"):
        reason = guard.verdict("Bash", {"command": command}, outward)
        check(f"asks on a listed script: {command}", reason is not None and "hosted system" in (reason or ""),
              reason or "quiet")
    reason = guard.verdict("Bash", {"command": "timeout 600 eas build"}, ["eas"])
    check("a listed command behind timeout asks", reason is not None, "quiet")
    # A listed path matches by its directory too: the bare file name counts
    # only once a `cd`, or the session's working directory, puts it there.
    nested = ["deploy/provision.sh", "e2e/judge/cli.ts"]
    for command, cwd in (("cd deploy && ./provision.sh", None), ("cd e2e/judge && npx tsx cli.ts", None),
                         ("bash deploy/provision.sh", None), ("cd /srv/app/deploy; bash provision.sh", None),
                         ("cd e2e && cd judge && node ./cli.ts", None), ("./provision.sh", "/srv/app/deploy"),
                         ("cd ../deploy && ./provision.sh", "/srv/app/e2e")):
        reason = guard.verdict("Bash", {"command": command}, nested, cwd=cwd)
        check(f"asks on a listed path reached by its directory: {command} (cwd {cwd})", reason is not None, "quiet")
    for command, cwd in ((".agents/provision.sh", None), ("bash .agents/provision.sh /tmp/wt", None),
                         ("npx tsx src/cli.ts", None), ("cd src && npx tsx cli.ts", None),
                         ("./provision.sh", "/srv/app/.agents"), ("cd deploy && ./other.sh && ../provision.sh", None)):
        reason = guard.verdict("Bash", {"command": command}, nested, cwd=cwd)
        check(f"quiet on a file sharing only a listed name: {command} (cwd {cwd})", reason is None, reason or "")
    # TypeScript runners name the script they run like any interpreter.
    for command in ("tsx scripts/seed-prod.ts", "npx tsx scripts/seed-prod.ts --env prod",
                    "ts-node scripts/seed-prod.ts", "ts-node-transpile-only scripts/seed-prod.ts"):
        reason = guard.verdict("Bash", {"command": command}, ["scripts/seed-prod.ts"])
        check(f"asks on a listed script run by a TypeScript runner: {command}", reason is not None, "quiet")
    reason = guard.verdict("Bash", {"command": "tsx scripts/seed-local.ts"}, ["scripts/seed-prod.ts"])
    check("quiet on an unlisted script run by tsx", reason is None, reason or "")
    # terraform changes live infrastructure and its remote state on these
    # verbs; planning, validating and formatting touch neither.
    for command in ("terraform apply", "terraform apply tfplan", "terraform -chdir=infra apply -auto-approve",
                    "terraform destroy", "terraform import aws_s3_bucket.b b", "tofu apply tfplan",
                    "terraform state rm aws_instance.web", "terraform taint aws_instance.web",
                    "terraform workspace delete staging"):
        reason = guard.verdict("Bash", {"command": command}, ())
        check(f"asks on a terraform write: {command}", reason is not None, "quiet")
    for command in ("terraform plan -out tfplan", "terraform validate", "terraform fmt -check -recursive",
                    "terraform init", "terraform show tfplan", "terraform output -json",
                    "terraform state list", "terraform -chdir=infra plan", "tofu plan",
                    "terraform workspace select staging"):
        reason = guard.verdict("Bash", {"command": command}, ())
        check(f"quiet on a terraform read or local step: {command}", reason is None, reason or "")
    # A runner's pinned version is not part of the package name.
    for command in ("npx eas-cli@16 submit", "npx eas-cli@latest build -p ios",
                    "bunx eas-cli@16.3.1 submit", "pnpm dlx eas-cli@16 submit",
                    "npx @acme/deploy@2 run", "npx -y @acme/deploy@^2.1 run"):
        reason = guard.verdict("Bash", {"command": command}, ["eas-cli", "@acme/deploy"])
        check(f"asks on a listed package pinned to a version: {command}", reason is not None, "quiet")
    for command in ("npx eas-cli-helper@16 submit", "npx @acme/other@2 run", "npx prettier@3 --check ."):
        reason = guard.verdict("Bash", {"command": command}, ["eas-cli", "@acme/deploy"])
        check(f"quiet on another package pinned to a version: {command}", reason is None, reason or "")
    # The command an ssh session runs on the far host is read like a local one.
    for command in ("ssh host 'cd /opt/app && bash scripts/deploy.sh'",
                    "ssh -p 2222 -i key.pem deploy@host ./scripts/deploy.sh --prod",
                    "ssh host 'cd /opt/app/scripts && ./deploy.sh'",
                    "ssh host 'cd /opt/app && git push origin main'",
                    "ssh -o BatchMode=yes host \"cd /srv && npx wrangler deploy\""):
        reason = guard.verdict("Bash", {"command": command}, outward)
        check(f"asks on an outward command run over ssh: {command}", reason is not None, "quiet")
    for command in ("ssh host 'cat /opt/app/scripts/deploy.sh'", "ssh host uptime",
                    "ssh host 'ls /opt/app/scripts'", "ssh host 'cd /opt/app && git status'"):
        reason = guard.verdict("Bash", {"command": command}, outward)
        check(f"quiet on a read over ssh: {command}", reason is None, reason or "")
    for command in ("cat scripts/deploy.sh", "grep vercel scripts/deploy.sh",
                    "./scripts/deploy.sh --dry-run",
                    "./scripts/verify.sh", "ls switch-on"):
        reason = guard.verdict("Bash", {"command": command}, outward, rehearsals)
        check(f"quiet on a read or dry run: {command}", reason is None, reason or "")
    # Only a script the policy says honours --dry-run rehearses with it. One
    # that ignores its arguments deploys with the flag appended.
    for command in ("./scripts/deploy.sh --dry-run", "cd switch-on && ./02-vercel.sh --dry-run",
                    "python3 tools/copy-env-to-prod.py X --dry-run"):
        reason = guard.verdict("Bash", {"command": command}, outward)
        check(f"a script not declared to honour --dry-run asks: {command}", reason is not None, "quiet")
    reason = guard.verdict("Bash", {"command": "cd switch-on && ./02-vercel.sh --dry-run"}, outward, rehearsals)
    check("--dry-run on an undeclared script asks beside a declared one", reason is not None, "quiet")
    # A script whose flag takes a value reads `--dry-run false` as a live run.
    for command in ("./scripts/deploy.sh --dry-run false", "./scripts/deploy.sh --dry-run FALSE",
                    "./scripts/deploy.sh --dry-run 0", "./scripts/deploy.sh --dry-run no",
                    "./scripts/deploy.sh --dry-run off"):
        reason = guard.verdict("Bash", {"command": command}, outward, rehearsals)
        check(f"a dry-run flag switched off is a live run: {command}", reason is not None, "quiet")
    # The script reads the last occurrence; any switched-off one may be it.
    for command in ("./scripts/deploy.sh --dry-run n", "./scripts/deploy.sh --dry-run=false",
                    "./scripts/deploy.sh --dry-run true --dry-run false"):
        reason = guard.verdict("Bash", {"command": command}, outward, rehearsals)
        check(f"a dry-run flag switched off is a live run: {command}", reason is not None, "quiet")
    # Only a value known to switch the flag on rehearses: an empty, padded or
    # unfamiliar value may read as off.
    for command in ("./scripts/deploy.sh --dry-run=", "./scripts/deploy.sh --dry-run=disabled",
                    "./scripts/deploy.sh --dry-run \"false \"", "./scripts/deploy.sh --dry-run ''",
                    "./scripts/deploy.sh --dry-run=maybe", "./scripts/deploy.sh --dry-run disabled",
                    "./scripts/deploy.sh --dry-run --dry-run=off"):
        reason = guard.verdict("Bash", {"command": command}, outward, rehearsals)
        check(f"a dry-run flag not clearly on is a live run: {command}", reason is not None, "quiet")
    # A following word outside the boolean vocabulary is an operand, so the
    # flag before it was bare.
    for command in ("./scripts/deploy.sh --dry-run=YES", "./scripts/deploy.sh --dry-run=' on'",
                    "./scripts/deploy.sh --dry-run 1", "./scripts/deploy.sh --dry-run production",
                    "./scripts/deploy.sh --dry-run true --dry-run"):
        reason = guard.verdict("Bash", {"command": command}, outward, rehearsals)
        check(f"quiet on a dry run switched on: {command}", reason is None, reason or "")
    for command in ("./scripts/deploy.sh --dry-run true", "./scripts/deploy.sh --dry-run --prod",
                    "./scripts/deploy.sh --dry-run=true"):
        reason = guard.verdict("Bash", {"command": command}, outward, rehearsals)
        check(f"quiet on a dry run followed by a value or flag: {command}", reason is None, reason or "")
    # -n is git's rehearsal flag, not these scripts': deploy.sh ignores it.
    for command in ("./scripts/deploy.sh -n", "scripts/deploy.sh -vn", "./scripts/deploy.sh -newer"):
        reason = guard.verdict("Bash", {"command": command}, outward)
        check(f"a short flag is not a dry run: {command}", reason is not None, "quiet")
    # gcloud ends a group path with its verb, and firebase namespaces verbs
    # with colons; a write is the verb, wherever the path puts it.
    for command in ("gcloud services api-keys delete k --project rumah-y3ecek",
                    "gcloud run deploy web --image i", "gcloud --project p functions delete f",
                    "gcloud run services update s --set-env-vars A=1",
                    "gcloud secrets versions add s --data-file=-", "gcloud storage rm gs://b/o",
                    "gcloud storage cp ./f gs://b/", "gcloud projects add-iam-policy-binding p",
                    "firebase firestore:delete /vendors -r", "firebase database:set /a d.json",
                    "firebase functions:delete f", "firebase auth:import u.json",
                    "firebase functions:secrets:set KEY", "firebase hosting:disable"):
        reason = guard.verdict("Bash", {"command": command}, ())
        check(f"asks on a hosted gcloud or firebase write: {command}", reason is not None, "quiet")
    # gcloud names a write by a verb family as well as a fixed verb, and a
    # traffic split, a message, a job run or a bucket sync is a write too.
    for command in ("gcloud run services update-traffic web --to-latest",
                    "gcloud app services set-traffic default --splits v2=1",
                    "gcloud compute instances add-metadata vm --metadata k=v",
                    "gcloud compute instances remove-metadata vm --keys k",
                    "gcloud compute instances set-machine-type vm --machine-type e2",
                    "gcloud compute backend-services create-signed-url-key b",
                    "gcloud compute disks delete-snapshot-schedule d",
                    "gcloud compute instances enable-oslogin vm",
                    "gcloud iam service-accounts disable-key k",
                    "gcloud storage rsync ./dist gs://b", "gcloud storage rsync -r ./dist gs://b/site",
                    "gcloud pubsub topics publish t --message m", "gcloud scheduler jobs run j",
                    "gcloud firestore export gs://b", "gcloud app versions migrate v2",
                    "gcloud functions call f --data {}", "gcloud deploy apply --file=pipeline.yaml",
                    "gcloud beta run deploy web --image i", "gcloud alpha scheduler jobs run j",
                    "gcloud run deploy emulators --image i"):
        reason = guard.verdict("Bash", {"command": command}, ())
        check(f"asks on a hosted gcloud write: {command}", reason is not None, "quiet")
    for command in ("gcloud run services describe update-checker", "gcloud run services list",
                    "gcloud secrets versions get latest", "gcloud projects get-iam-policy p",
                    "gcloud logging read x", "gcloud app logs tail", "gcloud run services logs read web",
                    "gcloud config set run/region us-east1", "gcloud auth login",
                    "gcloud storage rsync gs://b ./local", "gcloud storage ls gs://b/run",
                    "gcloud emulators firestore start", "gcloud beta emulators pubsub start",
                    "gcloud alpha emulators bigtable start", "gcloud beta config set project p"):
        reason = guard.verdict("Bash", {"command": command}, ())
        check(f"quiet on a gcloud read or local command: {command}", reason is None, reason or "")
    # A global flag's separate value is not the verb.
    for command in ("firebase --project prod firestore:delete /vendors -r",
                    "firebase -P prod database:set /a d.json", "firebase --project prod deploy",
                    "firebase -P prod deploy --only hosting", "firebase --project=prod deploy",
                    "firebase --project=prod firestore:delete /vendors",
                    "firebase --account a@b.c -c alt.json hosting:disable",
                    "firebase --token T --json deploy", "npx firebase -P prod deploy"):
        reason = guard.verdict("Bash", {"command": command}, ())
        check(f"asks on a firebase write after a global flag: {command}", reason is not None, "quiet")
    for command in ("firebase -P prod projects:list", "firebase --project prod emulators:start",
                    "firebase --json use prod"):
        reason = guard.verdict("Bash", {"command": command}, ())
        check(f"quiet on a firebase read after a global flag: {command}", reason is None, reason or "")
    for command in ("gcloud run services describe s", "gcloud services api-keys list",
                    "gcloud config set project p", "gcloud auth list",
                    "gcloud storage cp gs://b/o .", "gcloud logging read x",
                    "gcloud beta emulators firestore start", "gcloud emulators pubsub start",
                    "firebase emulators:start", "firebase firestore:indexes",
                    "firebase projects:list", "firebase use p"):
        reason = guard.verdict("Bash", {"command": command}, ())
        check(f"quiet on a gcloud or firebase read: {command}", reason is None, reason or "")
    # The Supabase CLI groups its verbs under a noun, and one of them is both
    # the routine local reset and the production rebuild. Splitting on the
    # remote flag is what lets the dangerous form ask without the safe form
    # asking several times an hour.
    for command in ("supabase db push", "supabase db push --linked",
                    "supabase functions deploy purchase-ticket",
                    "supabase secrets set STRIPE_KEY=x", "supabase secrets unset STRIPE_KEY",
                    "supabase projects delete abcd", "supabase branches create preview",
                    "supabase db reset --linked", "supabase migration up --linked",
                    "supabase db reset --db-url postgres://host/db"):
        reason = guard.verdict("Bash", {"command": command}, ())
        check(f"asks on a hosted Supabase command: {command}", reason is not None, "quiet")
    # A deploy CLI's value-taking global flag sits before the verb without
    # becoming it.
    for command in ("wrangler --env prod deploy", "wrangler -e prod deploy",
                    "wrangler -c wrangler.prod.toml deploy", "wrangler --config w.toml --env production publish",
                    "npx wrangler --env-file .env.prod deploy", "wrangler --cwd apps/worker deploy",
                    "fly -a web deploy", "flyctl --app web deploy", "fly -c fly.prod.toml deploy",
                    "fly -t TOKEN deploy", "fly -r ord -a web deploy",
                    "supabase --workdir apps/api db push", "supabase --profile prod functions deploy hello",
                    "supabase -o json secrets set A=1", "supabase --project-ref abcd config push",
                    "supabase --workdir apps/api storage rm ss:///b/a",
                    "supabase --network-id n db reset --linked"):
        reason = guard.verdict("Bash", {"command": command}, ())
        check(f"asks on a deploy verb after a global flag: {command}", reason is not None, "quiet")
    for command in ("wrangler --env prod dev", "wrangler -e prod tail", "fly -a web status",
                    "fly -a web logs", "supabase --workdir apps/api db reset",
                    "supabase --workdir apps/api start", "supabase -o json status"):
        reason = guard.verdict("Bash", {"command": command}, ())
        check(f"quiet on a local verb after a global flag: {command}", reason is None, reason or "")
    # The AWS CLI names a write by its operation's verb family; a global flag
    # before the service does not hide it, and s3 writes only toward a bucket.
    for command in ("aws lambda update-function-code --function-name f --zip-file fileb://f.zip",
                    "aws --region us-east-1 --profile prod lambda update-function-code --function-name f",
                    "aws --profile=prod s3 sync ./dist s3://bucket", "aws s3 cp ./f s3://b/f --acl public-read",
                    "aws s3 mv s3://a/x s3://a/y", "aws s3 rm s3://b/key", "aws s3 rb s3://b", "aws s3 mb s3://new",
                    "aws cloudformation deploy --template-file t.yml --stack-name s",
                    "aws ec2 terminate-instances --instance-ids i-1", "aws ec2 run-instances --image-id ami-1",
                    "aws ec2 start-instances --instance-ids i-1", "aws ec2 stop-instances --instance-ids i-1",
                    "aws iam attach-role-policy --role-name r --policy-arn a",
                    "aws iam detach-role-policy --role-name r --policy-arn a",
                    "aws dynamodb put-item --table-name t --item {}",
                    "aws rds modify-db-instance --db-instance-identifier d",
                    "aws ssm put-parameter --name n --value v", "aws lambda invoke --function-name f out.json",
                    "aws secretsmanager create-secret --name n", "aws --output json ecs update-service --cluster c",
                    "aws s3api delete-object --bucket b --key k",
                    "aws route53 change-resource-record-sets --hosted-zone-id Z --change-batch file://c.json",
                    "aws sns publish --topic-arn t --message m", "aws sqs purge-queue --queue-url u",
                    "aws dynamodb batch-write-item --request-items file://i.json",
                    "aws kms schedule-key-deletion --key-id k", "aws rds-data execute-statement --sql x",
                    "aws ecs execute-command --cluster c --task t --command sh",
                    "aws ec2 release-address --allocation-id a"):
        reason = guard.verdict("Bash", {"command": command}, ())
        check(f"asks on an AWS write: {command}", reason is not None, "quiet")
    for command in ("aws sts get-caller-identity", "aws s3 ls s3://b", "aws s3 cp s3://b/f ./f",
                    "aws s3 sync s3://b ./local", "aws ec2 describe-instances", "aws lambda list-functions",
                    "aws logs tail /aws/lambda/f --follow", "aws configure", "aws configure set region us-east-1",
                    "aws --region us-east-1 --profile prod ec2 describe-instances",
                    "aws logs start-query --log-group-name g --query-string q", "aws s3 presign s3://b/k",
                    "aws ecr get-login-password", "aws --version", "aws help", "aws lambda help", "aws s3api get-object --bucket b --key k o",
                    "aws eks update-kubeconfig --name prod", "aws logs start-live-tail --log-group-identifiers g",
                    "aws sts assume-role --role-arn r --role-session-name s", "aws sso login --profile p",
                    "aws codeartifact login --tool npm --domain d", "aws dynamodb scan --table-name t",
                    "aws dynamodb query --table-name t", "aws dynamodb batch-get-item --request-items x",
                    "aws s3api head-object --bucket b --key k", "aws cloudformation wait stack-create-complete",
                    "aws cloudtrail lookup-events", "aws logs filter-log-events --log-group-name g",
                    "aws iam simulate-principal-policy --policy-source-arn a",
                    "aws cloudformation validate-template --template-body x",
                    "aws pricing get-products --service-code AmazonEC2"):
        reason = guard.verdict("Bash", {"command": command}, ())
        check(f"quiet on an AWS read or local command: {command}", reason is None, reason or "")
    # The hosted-only management verbs: config, functions, storage, SSO,
    # custom domains, Postgres settings and network rules.
    for command in ("supabase config push", "supabase config push --project-ref abcd",
                    "supabase functions delete hello", "supabase storage rm ss:///avatars/a.png",
                    "supabase storage rm -r ss:///avatars --linked", "supabase storage mv ss:///b/a ss:///b/c",
                    "supabase storage cp ./a.png ss:///avatars/a.png",
                    "supabase storage cp --cache-control no-cache -r ./dir ss:///b",
                    "supabase sso add --type saml --metadata-url https://idp/x", "supabase sso remove 1234",
                    "supabase sso update 1234 --domains a.com", "supabase domains create --custom-hostname a.com",
                    "supabase domains activate", "supabase domains delete", "supabase domains reverify",
                    "supabase postgres-config update --config max_connections=100",
                    "supabase postgres-config delete --config max_connections",
                    "supabase network-restrictions update --db-allow-cidr 10.0.0.0/8",
                    "supabase vanity-subdomains activate --desired-subdomain acme",
                    "supabase ssl-enforcement update --enable-db-ssl-enforcement",
                    "supabase network-bans remove --db-unban-ip 1.2.3.4",
                    "supabase backups restore --timestamp 1700000000", "supabase encryption update-root-key",
                    "supabase branches update preview --git-branch main", "supabase branches pause preview",
                    "supabase branches unpause preview", "supabase orgs create acme",
                    "supabase notebooks push", "supabase seed buckets --linked"):
        reason = guard.verdict("Bash", {"command": command}, ())
        check(f"asks on a hosted Supabase management verb: {command}", reason is not None, "quiet")
    for command in ("supabase config pull", "supabase functions list", "supabase functions download hello",
                    "supabase functions serve", "supabase functions new hello",
                    "supabase storage ls ss:///avatars", "supabase storage cp ss:///avatars/a.png ./a.png",
                    "supabase storage cp -r ss:///bucket/docs .", "supabase storage rm --local ss:///b/a",
                    "supabase storage cp --local ./a.png ss:///b/a.png", "supabase sso list", "supabase sso show 1234",
                    "supabase sso info", "supabase domains get", "supabase postgres-config get",
                    "supabase network-restrictions get", "supabase ssl-enforcement get",
                    "supabase vanity-subdomains check-availability --desired-subdomain acme",
                    "supabase network-bans get", "supabase backups list", "supabase encryption get-root-key",
                    "supabase branches list", "supabase branches get preview", "supabase orgs list",
                    "supabase notebooks pull", "supabase seed buckets"):
        reason = guard.verdict("Bash", {"command": command}, ())
        check(f"quiet on a Supabase read or local verb: {command}", reason is None, reason or "")
    for command in ("supabase db reset", "supabase migration up", "supabase start",
                    "supabase status", "supabase stop", "supabase db diff",
                    "supabase migration new add_memos",
                    "supabase gen types typescript --local"):
        reason = guard.verdict("Bash", {"command": command}, ())
        check(f"quiet on a local Supabase command: {command}", reason is None, reason or "")

    # A JavaScript repository reaches its scripts through a package manager, so
    # a list carrying only `node` leaves the documented invocation ungated.
    # Both shapes matter: the runner as an interpreter, and the manifest alias,
    # which never resolves to a path and so must be listed in its own right.
    js_outward = ["supabase/tests/schema_verification.mjs", "db:verify"]
    for command in ("bun --env-file=.env supabase/tests/schema_verification.mjs",
                    "bun run db:verify", "npm run db:verify", "pnpm run db:verify",
                    "yarn db:verify", "npx tsx supabase/tests/schema_verification.mjs",
                    "deno run -A supabase/tests/schema_verification.mjs",
                    "cd supabase/tests && bun schema_verification.mjs"):
        reason = guard.verdict("Bash", {"command": command}, js_outward)
        check(f"asks on a package-manager invocation: {command}",
              reason is not None and "hosted system" in (reason or ""), reason or "quiet")
    for command in ("cat supabase/tests/schema_verification.mjs",
                    "bun run db:reset", "bun run lint",
                    "bun run db:verify --dry-run"):
        reason = guard.verdict("Bash", {"command": command}, js_outward, ["db:verify"])
        check(f"quiet on a local or read-only script: {command}", reason is None, reason or "")

    # A package.json script runs its command with the arguments appended, so
    # the rules read the command it resolves to, arguments included.
    app = pathlib.Path(tmp) / "app"
    (app / "sub").mkdir(parents=True)
    (app / "package.json").write_text(json.dumps({"scripts": {
        "db:reset": "supabase db reset", "deploy": "wrangler deploy", "release": "bun run deploy",
        "lint": "eslint .", "ship": "echo built", "postship": "git push", "test": "vitest"}}))
    for command in ("bun run db:reset --linked", "npm run db:reset -- --linked", "pnpm db:reset --linked",
                    "yarn db:reset --db-url postgres://x/db", "pnpm run db:reset --linked", "bun run deploy",
                    "npm run release", "npm run ship", "cd sub && bun run db:reset --linked"):
        reason = guard.verdict("Bash", {"command": command}, (), (), str(app))
        check(f"asks on a script alias that resolves to an outward command: {command}", reason is not None, "quiet")
    for command in ("bun run db:reset", "npm run lint", "bun run lint --fix", "pnpm install", "bun test",
                    "npm run missing", "yarn lint"):
        reason = guard.verdict("Bash", {"command": command}, (), (), str(app))
        check(f"quiet on a script alias that resolves to a local command: {command}", reason is None, reason or "")
    # Every manager runs a script's pre- and post- hooks around it.
    (app / "package.json").write_text(json.dumps({"scripts": {
        "db:reset": "supabase db reset", "deploy": "wrangler deploy", "release": "echo tagged",
        "prerelease": "git push origin main", "lint": "eslint .", "ship": "echo built",
        "postship": "git push", "test": "vitest"}}))
    for command in ("bun run release", "pnpm run release", "yarn release"):
        reason = guard.verdict("Bash", {"command": command}, (), (), str(app))
        check(f"asks on a script whose pre- hook is outward: {command}", reason is not None, "quiet")
    # A package.json on this machine says nothing about a script the far host runs.
    reason = guard.verdict("Bash", {"command": f"ssh prod 'cd {app} && npm run ship'"}, (), (), str(app))
    check("a script run over ssh is not resolved against a local package.json", reason is None, reason or "")
    # Editors on Windows save package.json with a byte-order mark; npm reads it.
    bom = pathlib.Path(tmp) / "bom"
    bom.mkdir()
    (bom / "package.json").write_text("\ufeff" + json.dumps({"scripts": {
        "lint": "eslint .", "deploy": "wrangler deploy"}}), encoding="utf-8")
    reason = guard.verdict("Bash", {"command": "npm run lint"}, (), (), str(bom))
    check("quiet on a benign script in a package.json with a byte-order mark", reason is None, reason or "")
    reason = guard.verdict("Bash", {"command": "npm run deploy"}, (), (), str(bom))
    check("asks on a deploy script in a package.json with a byte-order mark", reason is not None, "quiet")
    reason = guard.verdict("Bash", {"command": "bun run deploy --dry-run"}, ["deploy"], ["deploy"], str(app))
    check("a declared alias rehearsal is not undone by resolving the alias", reason is None, reason or "")

    # An operator's config.json extends the repository's list; it cannot
    # replace it, or one local entry would silence every listed deploy.
    (agents / "config.json").write_text(json.dumps({"hooks": {"guard_publish": {
        "outward_commands": ["scripts/my-local.sh"]}}}))
    outward = guard.outward_commands(tmp)
    check("config.json extends the tracked list rather than replacing it",
          "scripts/deploy.sh" in outward and "scripts/my-local.sh" in outward, str(outward))
    check("a listed deploy still asks with a config.json list present",
          guard.verdict("Bash", {"command": "./scripts/deploy.sh"}, outward) is not None)
    # Declaring a rehearsal silences a gate, so only the tracked policy may.
    (agents / "config.json").write_text(json.dumps({"hooks": {"guard_publish": {
        "dry_run_commands": ["switch-on/02-vercel.sh"]}}}))
    check("config.json cannot declare a dry-run rehearsal",
          guard.dry_run_commands(tmp) == ["scripts/deploy.sh"], str(guard.dry_run_commands(tmp)))
    (agents / "config.json").unlink()
    result = subprocess.run([sys.executable, str(policy), tmp],
                            input=json.dumps({"tool_name": "Bash", "permission_mode": "default",
                                              "tool_input": {"command": "./scripts/deploy.sh"}}),
                            capture_output=True, text=True, env=env)
    out = json.loads(result.stdout)["hookSpecificOutput"]
    check("the entry point asks on a listed script",
          out["permissionDecision"] == "ask" and "scripts/deploy.sh" in out["permissionDecisionReason"],
          result.stdout)

# The declarative half. `.claude/settings.json` permissions.ask covers the same
# ground from a tier the hook cannot reach: a settings rule outranks an `allow`
# entry, applies to subagent tool calls, and still holds with guard_publish
# toggled off. It is prefix matching, so it can never express the evasion forms
# the shell parser catches (`git -C dir push`) — the check that means anything
# is that every rule names something this guard also treats as outward.
settings = json.loads((here / "claude" / "settings.json").read_text(encoding="utf-8"))
ask_rules = settings["permissions"]["ask"]
check("permissions.ask gates the Artifact tool", "Artifact" in ask_rules)

# The direction that protects the operator. With `guard_publish` disabled the
# settings layer stands alone, so every plain form the parser gates must have a
# rule. The parser still catches shapes no prefix can state (`git -C dir push`,
# `npx -p vercel vercel --prod`); those are the parser's alone by design, and
# this list is the subset the settings layer promises to hold without it.
PLAIN_FORMS = [
    "git push",
    "gh pr create", "gh pr merge", "gh pr close", "gh pr reopen", "gh pr edit",
    "gh pr comment", "gh pr review", "gh pr ready", "gh pr lock",
    "gh issue create", "gh issue comment", "gh issue edit", "gh issue close",
    "gh issue delete",
    "gh release create", "gh release upload", "gh release delete", "gh release edit",
    "gh repo create", "gh repo edit", "gh repo delete",
    "gh gist create", "gh gist edit", "gh gist delete",
    "gh workflow run",
    "npm publish", "npm unpublish", "pnpm publish", "pnpm unpublish",
    "yarn publish", "yarn unpublish", "yarn npm publish",
    "bun publish", "bun unpublish",
    "docker push",
    "vercel", "vercel deploy", "vercel promote", "vercel rollback",
    "vercel alias", "vercel rm", "vercel remove", "vercel redeploy", "vercel --prod",
    "netlify deploy", "wrangler deploy", "wrangler publish",
    "firebase deploy", "fly deploy", "flyctl deploy",
    "railway up", "railway deploy",
    "npx vercel", "npx wrangler deploy", "npx netlify deploy",
    "npx firebase deploy", "npx fly deploy",
]
prefixes = [r[len("Bash("):].rstrip(")").removesuffix(":*")
            for r in ask_rules if r.startswith("Bash(")]
for command in PLAIN_FORMS:
    check(f"the guard gates the plain form: {command}",
          guard.verdict("Bash", {"command": command}) is not None)
    check(f"permissions.ask covers the plain form: {command}",
          any(command == prefix or command.startswith(prefix + " ")
              for prefix in prefixes),
          "guard_publish disabled would leave this command unprompted")
for rule in ask_rules:
    if not rule.startswith("Bash("):
        continue
    command = rule[len("Bash("):].rstrip(")")
    if command.endswith(":*"):
        command = command[: -len(":*")]
    check(f"permissions.ask rule matches the guard: {command}",
          guard.verdict("Bash", {"command": command}) is not None,
          "the settings rule prompts on a command the guard treats as benign")

# Derived from the guard's own table rather than the hand-written list above,
# because the list is what a new vendor gets forgotten in: the hook would gate
# the command while the host's own permission layer stayed blind to it.
# The flag-conditional verbs are deliberately absent -- a static prefix rule
# cannot see `--linked`, and a rule matching the bare verb would prompt on the
# local one.
for vendor, verbs in guard.DEPLOY_VERBS.items():
    for verb in verbs:
        command = f"{vendor} {verb}"
        check(f"permissions.ask covers a gated vendor verb: {command}",
              any(command == prefix or command.startswith(prefix + " ")
                  for prefix in prefixes),
              "the guard gates this but settings.json has no ask rule for it")

print()
print("ALL PASS" if fails == 0 else f"{fails} FAILURE(S)")
sys.exit(1 if fails else 0)
