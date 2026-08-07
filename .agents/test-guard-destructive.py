#!/usr/bin/env python3
"""Drive the destructive-command guard against the forms it must and must not block.

The table is the contract. A row states one command and whether the guard stops
it, so a rule that widens or narrows shows up as a named failure rather than as
a behaviour nobody notices.
"""

import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile

here = pathlib.Path(__file__).resolve().parent
policy = here / "hooks" / "lib" / "guard-destructive.py"
spec = importlib.util.spec_from_file_location("guard_destructive", policy)
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


# (command, blocked) — the whole policy, one row per shape.
BLOCK = [
    # rm: every spelling of recursive, every spelling of a broad target.
    "rm -rf /",
    "rm -Rf /",
    "rm -r -f /",
    "rm -rf -- /",
    "rm --recursive --force /",
    'rm -rf "$HOME"',
    "rm -rf ${HOME}/",
    "rm -rf ~",
    "rm -rf ~/Documents",
    "rm -rf ./*",
    "rm -rf *",
    "rm -rf /etc",
    "rm -rf /usr/*",
    # Depth is not safety. Every one of these is deeper than two components and
    # none is this session's to delete.
    "rm -rf /Users/mac",
    "rm -rf /home/ubuntu",
    "rm -rf /var/lib/postgresql",
    "rm -rf /etc/nginx",
    "rm -rf ~/Projects/other-repo",
    # A relative glob that reaches out of the working tree. `.*` matches `..`.
    "rm -rf .*",
    "rm -rf ./.*",
    "sudo rm -rf /",
    "/bin/rm -rf /",
    "TMPDIR=/x rm -rf /",
    # ...reached through every way a segment can start.
    "cd /tmp && rm -rf /",
    "echo hi; rm -rf /",
    "echo hi\nrm -rf /",
    "(cd /tmp && rm -rf /)",
    "true | rm -rf /",
    'bash -c "rm -rf /"',
    # git: the global options must not hide the subcommand.
    "git push --force origin main",
    "git push -f",
    "git push --force-with-lease",
    "git -C /repo reset --hard",
    "git reset --hard HEAD~3",
    "git clean -fdx",
    "git -C /repo clean --force",
    "git -c user.name=x push --force",
    "git commit -n -m x",
    "git commit --no-verify -m x",
    "git push --no-verify",
    # ssh: the remote command, however it is quoted.
    "ssh prod systemctl restart nginx",
    'ssh -p 2222 prod "systemctl restart nginx"',
    "ssh prod 'sed -i s/a/b/ /etc/hosts'",
    "ssh prod 'rm -rf /var/log/app'",
    'ssh prod "echo x > /etc/motd"',
    "ssh prod 'apt-get install nginx'",
    # SQL: the keyword decides, not the punctuation around it.
    'psql -c "DROP TABLE users"',
    'psql -c "TRUNCATE users"',
    'mysql -e "TRUNCATE TABLE users;"',
    'psql -c "DELETE FROM users"',
    'psql -c "UPDATE users SET admin = true"',
    'psql -c "SELECT 1 WHERE x; DELETE FROM users"',
    # cloud: the verbs that delete live infrastructure.
    "terraform destroy",
    "terraform destroy -auto-approve",
    "tofu destroy",
    "aws s3 rm s3://bucket --recursive",
    "aws s3 rb s3://bucket --force",
    "kubectl delete namespace prod",
    "kubectl delete ns prod",
    "kubectl delete pods --all",
]

ALLOW = [
    # rm: a scoped path is the agent's own call.
    "rm -rf /tmp/scratch",
    "rm -rf ./build",
    "rm -rf node_modules",
    'rm -rf "$workdir"',
    "rm -r build/nested/dir",
    "rm file.txt",
    # A command that merely carries the text of one is not one.
    'grep -q "rm -rf /" file',
    "echo 'rm -rf / is irreversible'",
    """printf '%s' '{"command":"rm -rf /"}' | ./guard.sh""",
    "cat > note.sh <<'EOF'\nrm -rf /\nEOF",
    'git commit -m "guard rm -rf / and git push --force"',
    # git: the safe neighbours of every blocked form.
    "git push origin main",
    "git push -n origin main",
    "git reset --soft HEAD~1",
    "git clean -n",
    "git status",
    "git -C /repo log --oneline",
    # ssh: read-only remote work, and lines that must not pair up.
    "ssh prod uptime",
    'ssh prod "tail -n 50 /var/log/syslog"',
    "ssh prod uptime\nsed -i s/a/b/ local.txt",
    "ssh prod uptime\nrm -rf ./build",
    # SQL: a restricted statement, and the keyword outside a client.
    'psql -c "SELECT * FROM users"',
    'psql -c "DELETE FROM users WHERE id = 1"',
    'psql -c "UPDATE users SET a = 1 WHERE id = 2"',
    'echo "DROP TABLE users"',
    # cloud: the read verbs, and a single scoped delete.
    "terraform plan",
    "aws s3 ls",
    "aws s3 rm s3://bucket/key",
    "kubectl delete pod foo",
    "kubectl get pods",
    # Nothing to decide on.
    "",
    "ls -la",
    "cd /tmp",
]

PROJECT = "/work/repo"

for command in BLOCK:
    reason = guard.verdict(command, PROJECT)
    check(f"block: {command!r}", reason is not None, "no rule fired")

for command in ALLOW:
    reason = guard.verdict(command, PROJECT)
    check(f"allow: {command!r}", reason is None, f"blocked with: {reason}")

# The two carve-outs that keep the absolute-path rule usable, and their edges.
check("a path inside the project is the agent's own call",
      guard.verdict("rm -rf /work/repo/build", PROJECT) is None)
check("the project root itself is not",
      guard.verdict("rm -rf /work/repo", PROJECT) is not None)
check("a sibling of the project is not",
      guard.verdict("rm -rf /work/other", PROJECT) is not None)
check("a scratch path is the agent's own call",
      guard.verdict("rm -rf /var/folders/xc/T/session", PROJECT) is None)
check("with no project known, an absolute path is broad",
      guard.verdict("rm -rf /work/repo/build", "") is not None)

# The normalizer itself, where a rule cannot show the shape it depends on.
check("operators split a segment", guard.segments("a && b | c ; d") == ["a", "b", "c", "d"])
check("quotes hold a segment together", guard.segments('echo "a; b"') == ['echo "a; b"'])
check("a line continuation does not split", guard.segments("echo a \\\nb") == ["echo a \\\nb"])
check("a heredoc body is dropped",
      guard.strip_heredocs("cat <<'EOF'\nrm -rf /\nEOF\nls") == "cat <<'EOF'\nls")
check("an unterminated heredoc keeps its lines",
      guard.strip_heredocs("cat <<'EOF'\nrm -rf /") == "cat <<'EOF'\nrm -rf /")
check("a herestring is not a heredoc",
      guard.strip_heredocs("cat <<<word\nls") == "cat <<<word\nls")
check("an unbalanced quote drops the segment", guard.normalize("rm -rf '/") == [])
check("a redirect target is not an operand",
      [command.targets for command in guard.normalize("echo x > /etc/motd")] == [["/etc/motd"]])

# End to end through the shell entry point, which is what an engine invokes.
entry = str(here / "hooks" / "policy" / "guard-destructive.sh")


def run(payload, repo=None):
    return subprocess.run(
        [entry] if repo is None else ["python3", str(policy), repo],
        input=json.dumps(payload), text=True, capture_output=True)


blocked = run({"command": "rm -rf /"})
check("entry point exits 2 on a block", blocked.returncode == 2, f"exit {blocked.returncode}")
check("entry point states the reason", "irreversible" in blocked.stderr, blocked.stderr)
check("entry point exits 0 otherwise", run({"command": "ls -la"}).returncode == 0)
check("entry point exits 0 on an empty payload", run({}).returncode == 0)
check("entry point exits 0 on unreadable input",
      subprocess.run([entry], input="{not json", text=True, capture_output=True).returncode == 0)

with tempfile.TemporaryDirectory() as sandbox:
    os.makedirs(os.path.join(sandbox, ".agents"))
    with open(os.path.join(sandbox, ".agents", "config.json"), "w", encoding="utf-8") as config:
        json.dump({"hooks": {"guard_destructive": {"enabled": False}}}, config)
    off = run({"command": "rm -rf /"}, repo=sandbox)
    check("the config toggle turns the guard off", off.returncode == 0, off.stderr)

print("\nALL PASS" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
