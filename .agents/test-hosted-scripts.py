#!/usr/bin/env python3
"""Drive the publish guard's hosted-script rule end to end.

A script outside the repository, untracked, or edited since the last commit
that writes to a hosted management API is refused in every mode; the same
script committed and unchanged asks. The first row is the invocation that
changed a production Vercel project, Supabase auth and GitHub secrets from /tmp.
"""

import json
import pathlib
import subprocess
import sys
import tempfile

here = pathlib.Path(__file__).resolve().parent
guard = here / "hooks" / "lib" / "guard-publish.py"
fails = 0

# Host names are assembled at run time so this file does not itself read as a
# script that writes to them; `real()` swaps the placeholders in.
HOSTS = {name: "api." + domain for name, domain in
         (("VERCEL", "vercel.com"), ("SUPABASE", "supabase.com"), ("GITHUB", "github.com"), ("STRIPE", "stripe.com"))}


def real(text):
    for name, host in HOSTS.items():
        text = text.replace(name, host)
    return text


def check(name, ok, detail=""):
    global fails
    print(f"ok    {name}" if ok else f"FAIL  {name}\n  {detail}")
    fails += 0 if ok else 1


WRITER = '''import json, urllib.request
API = "https://VERCEL"
def call(method, path, body=None):
    req = urllib.request.Request(API + path, data=json.dumps(body).encode() if body else None, method=method)
    return urllib.request.urlopen(req)
call("PATCH", "/v9/projects/web", {"framework": "nextjs"})
'''
SIGN_IN = 'fetch("https://abc.supabase.co/auth/v1/token?grant_type=password", {method: "POST", body: "{}"})\n'
READER = 'import urllib.request\nurllib.request.urlopen("https://VERCEL/v9/projects")\n'
GRAPHQL_QUERY = 'import requests\nrequests.post("https://GITHUB/graphql", json={"query": "query { viewer { login } }"})\n'
GRAPHQL_MUTATION = 'import requests\nrequests.post("https://GITHUB/graphql", json={"query": "mutation { addStar(input:{}) { clientMutationId } }"})\n'
MOCKED_TEST = 'def test_charge(mocker):\n    mocker.patch("requests.post")  # https://STRIPE/v1/charges "POST"\n'


def decide(project, command, mode="default", cwd=None):
    payload = {"tool_name": "Bash", "tool_input": {"command": real(command)}, "permission_mode": mode,
               "project_dir": str(project), "cwd": str(cwd or project)}
    out = subprocess.run([sys.executable, str(guard), str(here.parent)], input=json.dumps(payload),
                         capture_output=True, text=True).stdout.strip()
    if not out:
        return "pass", ""
    body = json.loads(out)["hookSpecificOutput"]
    return body["permissionDecision"], body["permissionDecisionReason"]


with tempfile.TemporaryDirectory() as scratch:
    root = pathlib.Path(scratch).resolve()
    project, outside = root / "project", root / "tmp"
    (project / "tools").mkdir(parents=True)
    outside.mkdir()
    git = ["git", "-C", str(project), "-c", "user.name=t", "-c", "user.email=t@t"]
    subprocess.run(git + ["init", "-q"], check=True)

    for name, body in [("production-vercel-github-setup.py", WRITER), ("check.mjs", SIGN_IN),
                       ("read.py", READER), ("gql-read.py", GRAPHQL_QUERY), ("gql-write.py", GRAPHQL_MUTATION)]:
        (outside / name).write_text(real(body))
    (project / "tools" / "apply.py").write_text(real(WRITER))
    (project / "tools" / "edited.py").write_text(real(READER))
    (project / "test_charge.py").write_text(real(MOCKED_TEST))
    subprocess.run(git + ["add", "tools/apply.py", "tools/edited.py", "test_charge.py"], check=True)
    subprocess.run(git + ["commit", "-q", "-m", "tools"], check=True)
    (project / "tools" / "edited.py").write_text(real(WRITER))
    (project / "tools" / "untracked.py").write_text(real(WRITER))
    (project / ".gitignore").write_text("dist/\n")
    (project / "dist").mkdir()
    (project / "dist" / "index.js").write_text(real(WRITER))
    (project / "tools" / "deploy.ts").write_text(real(WRITER))
    (project / "checkout.ts").write_text('await fetch("https://api.stripe.com/v1/checkout/sessions", {method: "POST"})\n')

    example = (f'python3 - <<\'EOF\'\nimport importlib.util\nspec=importlib.util.spec_from_file_location('
               f'"s","{outside}/production-vercel-github-setup.py"); s=importlib.util.module_from_spec(spec); '
               f'spec.loader.exec_module(s)\nEOF')
    edit_snippet = (f"python3 - <<'EOF'\nf='{project}/tools/apply.py'\ns=open(f).read()\n"
                    f"open(f,'w').write(s.replace('nextjs', 'vite'))\nEOF")
    rows = [
        ("the operator's example: inline python importing a /tmp setup script", example, "default", "deny"),
        ("the same script run directly", f"python3 {outside}/production-vercel-github-setup.py", "default", "deny"),
        ("refused in auto mode too", f"python3 {outside}/production-vercel-github-setup.py", "auto", "deny"),
        ("written and run in one call", f"cat > {outside}/new.py <<'EOF'\n{WRITER}EOF\npython3 {outside}/new.py", "default", "deny"),
        ("inline -c code writing to a management API",
         'python3 -c "import urllib.request as u; u.urlopen(u.Request(\'https://SUPABASE/v1/projects/x/config/auth\', method=\'PATCH\'))"',
         "default", "deny"),
        ("an untracked script in the repository", "python3 tools/untracked.py", "default", "deny"),
        ("a committed script edited since the commit", "python3 tools/edited.py", "default", "deny"),
        ("the committed, unchanged script asks", "python3 tools/apply.py", "default", "ask"),
        ("the committed script is denied where no prompt reaches the user", "python3 tools/apply.py", "auto", "deny"),
        ("--dry-run passes", "python3 tools/apply.py --dry-run", "default", "pass"),
        ("a hand curl write to a management API asks", "curl -X PATCH https://VERCEL/v9/projects/web -d '{}'", "default", "ask"),
        ("a curl read passes", "curl -s https://VERCEL/v9/projects", "default", "pass"),
        ("a /tmp check that signs in to the app passes", f"node {outside}/check.mjs", "default", "pass"),
        ("a /tmp script that only reads a management API passes", f"python3 {outside}/read.py", "default", "pass"),
        ("a GraphQL query passes", f"python3 {outside}/gql-read.py", "default", "pass"),
        ("a GraphQL mutation is refused", f"python3 {outside}/gql-write.py", "default", "deny"),
        ("a test module run with -m is not read", "python3 -m pytest test_charge.py", "default", "pass"),
        ("writing a script file without running it passes", f"cat > {outside}/later.py <<'EOF'\n{WRITER}EOF", "default", "pass"),
        ("inline code that edits a writing script passes", edit_snippet, "default", "pass"),
        ("gitignored build output of committed source passes", "node dist/index.js", "default", "pass"),
        ("npx tsc only type-checks, so it passes", "npx tsc --noEmit tools/deploy.ts", "default", "pass"),
        ("npx tsx runs the script, so it is read", "npx tsx tools/deploy.ts", "default", "deny"),
        ("uv run python runs the script, so it is read", "uv run python tools/untracked.py", "default", "deny"),
        ("an application's own payment calls are not infrastructure", "node checkout.ts", "default", "pass"),
        ("an ordinary command passes", "ls -la", "default", "pass"),
    ]
    (outside / "harmless.py").write_text("print('hello')\n")
    (outside / "lib.sh").write_text(real("curl -X PATCH https://VERCEL/v9/projects/web -d '{}'\n"))
    setup = "production-vercel-github-setup.py"
    rows += [
        ("a relative script after cd", f"cd {outside} && python3 {setup}", "default", "deny"),
        ("a relative script after cd in a subshell", f"(cd {outside} && python3 {setup})", "default", "deny"),
        ("a relative script after pushd", f"pushd {outside} && python3 {setup}", "default", "deny"),
        ("./script after cd", f"cd {outside}; ./{setup}", "default", "deny"),
        ("a dry run chained before the real run", f"python3 {outside}/{setup} --dry-run && python3 {outside}/{setup}", "default", "deny"),
        ("an existing harmless file overwritten and run in one call",
         f"cat > {outside}/harmless.py <<'EOF'\n{WRITER}EOF\npython3 {outside}/harmless.py", "default", "deny"),
        ("a sourced shell file", f"source {outside}/lib.sh", "default", "deny"),
        ("a dot-sourced shell file", f". {outside}/lib.sh", "default", "deny"),
    ]
    for name, command, mode, expected in rows:
        got, reason = decide(project, command, mode)
        check(name, got == expected, f"expected {expected}, got {got}: {reason[:200]}")

    got, _ = decide(project, f"python3 {setup}", cwd=outside)
    check("a relative script resolves against the session's working directory", got == "deny", got)

    got, reason = decide(project, f"python3 {outside}/production-vercel-github-setup.py")
    check("the refusal names the plan/apply remedy and says not to retry",
          "plan/apply tool" in reason and "Do not retry" in reason, reason)

print("\nALL PASS" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
