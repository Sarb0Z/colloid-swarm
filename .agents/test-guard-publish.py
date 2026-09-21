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

# A repository's own deploy script shows the guard no vercel or gh word, so the
# repository lists it in the tracked policy.json and the guard asks by path.
with tempfile.TemporaryDirectory() as tmp:
    agents = pathlib.Path(tmp) / ".agents"
    agents.mkdir()
    (agents / "policy.json").write_text(json.dumps({"hooks": {"guard_publish": {
        "outward_commands": ["scripts/deploy.sh", "switch-on/02-vercel.sh",
                             "tools/copy-env-to-prod.py"]}}}))
    outward = guard.outward_commands(tmp)
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
    for command in ("cat scripts/deploy.sh", "grep vercel scripts/deploy.sh",
                    "./scripts/deploy.sh --dry-run",
                    "./scripts/verify.sh", "ls switch-on"):
        reason = guard.verdict("Bash", {"command": command}, outward)
        check(f"quiet on a read or dry run: {command}", reason is None, reason or "")
    # -n is git's rehearsal flag, not these scripts': deploy.sh ignores it.
    for command in ("./scripts/deploy.sh -n", "scripts/deploy.sh -vn", "./scripts/deploy.sh -newer"):
        reason = guard.verdict("Bash", {"command": command}, outward)
        check(f"a short flag is not a dry run: {command}", reason is not None, "quiet")
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
        reason = guard.verdict("Bash", {"command": command}, js_outward)
        check(f"quiet on a local or read-only script: {command}", reason is None, reason or "")

    # An operator's config.json extends the repository's list; it cannot
    # replace it, or one local entry would silence every listed deploy.
    (agents / "config.json").write_text(json.dumps({"hooks": {"guard_publish": {
        "outward_commands": ["scripts/my-local.sh"]}}}))
    outward = guard.outward_commands(tmp)
    check("config.json extends the tracked list rather than replacing it",
          "scripts/deploy.sh" in outward and "scripts/my-local.sh" in outward, str(outward))
    check("a listed deploy still asks with a config.json list present",
          guard.verdict("Bash", {"command": "./scripts/deploy.sh"}, outward) is not None)
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
