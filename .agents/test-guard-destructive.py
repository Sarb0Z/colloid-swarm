#!/usr/bin/env python3
"""Drive the destructive-command guard against the forms it must and must not block.

The table is the contract. A row states one command and whether the guard stops
it, so a rule that widens or narrows shows up as a named failure rather than as
a behaviour nobody notices.
"""

import importlib.util
import json
import pathlib
import shutil
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
    # ...behind every wrapper that runs the rest of the line.
    "timeout 5 rm -rf ~/x",
    "timeout -s KILL 5 rm -rf /",
    "timeout --kill-after=2 5s rm -rf /",
    "nice rm -rf /",
    "nice -n 10 rm -rf /",
    "caffeinate -i rm -rf /",
    "caffeinate -t 60 rm -rf /",
    "/usr/bin/env rm -rf /",
    "env -u FOO rm -rf /",
    "sudo -u root rm -rf /",
    "uv run --with x rm -rf /",
    "bash -lc 'rm -rf ~/x'",
    "bash -ec 'rm -rf /'",
    "bash -o pipefail -c 'rm -rf /'",
    "timeout 120 sh -c 'git push --force'",
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
    # ssh: deletion in every spelling, and a write that lands outside scratch.
    "ssh prod 'find /var/myexpenses/exported -type f -mtime +7 -delete'",
    "ssh prod 'find /var/log -name \"*.gz\" -exec rm {} \\;'",
    "ssh prod 'ls /var/log | xargs rm'",
    "ssh prod 'rm /etc/nginx/ssl/old.crt'",
    "ssh prod 'mv /etc/nginx/sites-enabled/x.bak /root/backups/'",
    "ssh prod 'cp nginx.conf /etc/nginx/nginx.conf'",
    "ssh prod 'docker builder prune -af'",
    "ssh prod 'docker system prune -a --volumes'",
    "ssh prod 'docker rm -f web'",
    "ssh prod 'journalctl --vacuum-size=200M'",
    "ssh prod 'truncate -s 0 /var/log/app.log'",
    "ssh prod ': > /var/myexpenses/cron.log'",
    "ssh prod 'echo x > out.txt'",
    "ssh prod 'echo x > /dev/sda'",
    # ssh: a delete hidden behind -exec or xargs, in a shell or not.
    r'''ssh prod "find /var/myexpenses -type f -exec sh -c 'rm -f \"$1\"' _ {} \;"''',
    r'''ssh prod "find /var/myexpenses -type f -print0 | xargs -0 sh -c 'rm -f \"$@\"' _"''',
    "ssh prod 'xargs -I {} rm {}'",
    # ssh: container teardown, and the local rules applied to the far host.
    "ssh prod 'docker compose down -v'",
    "ssh prod 'docker-compose down --volumes'",
    "ssh prod 'docker stop web'",
    "ssh prod \"psql -c 'DROP TABLE users'\"",
    "ssh prod 'kubectl delete namespace prod'",
    "ssh prod 'terraform destroy -auto-approve'",
    "ssh prod 'aws s3 rm s3://bucket/ --recursive'",
    "ssh prod 'git clean -fdx'",
    "ssh prod 'git -C /srv/app reset --hard'",
    # ssh: the remote side is an allowlist of read-only tools, so a write in a
    # spelling no rule names is still denied, and one bad clause denies the line.
    "ssh prod 'service nginx restart'",
    "ssh prod reboot",
    "ssh prod 'chmod 600 /etc/ssl/private/key.pem'",
    "ssh prod 'mkdir -p /srv/app/releases/new'",
    "ssh prod 'ln -sfn /srv/app/releases/new /srv/app/current'",
    "ssh prod 'pm2 restart all'",
    "ssh prod 'npm run migrate'",
    "ssh prod 'curl -X POST http://localhost:8080/admin/flush'",
    "ssh prod 'unknowntool --status'",
    "ssh prod 'tail -n 5 /var/log/syslog; reboot'",
    "ssh prod 'ps aux | grep node | awk \"{print \\$2}\" | xargs kill'",
    "ssh prod 'cat /etc/hosts | xargs -I{} touch {}'",
    "ssh prod 'echo $(reboot)'",
    "ssh prod 'for f in /etc/nginx/*.bak; do rm \"$f\"; done'",
    "ssh prod \"bash -c 'ls /srv && service nginx reload'\"",
    "ssh prod \"sudo bash -lc 'chown -R www-data /srv/app'\"",
    "ssh prod bash -s < deploy.sh",
    "ssh prod 'sh deploy.sh'",
    "ssh prod \"ls 'unterminated\"",
    "ssh bastion ssh prod 'service nginx restart'",
    "ssh prod 'git pull'",
    "ssh prod 'git -C /srv/app checkout main'",
    "ssh prod 'docker exec web sh'",
    "ssh prod 'docker compose -f /srv/compose.yml up -d'",
    "ssh prod 'kubectl apply -f deploy.yaml'",
    "ssh prod 'kubectl -n prod rollout restart deploy/api'",
    "ssh prod 'systemctl -t service mask nginx'",
    "ssh prod 'journalctl --rotate'",
    "ssh prod 'find /srv -name \"*.conf\" -fprint /srv/list.txt'",
    "ssh prod 'sort -o /etc/hosts /etc/hosts'",
    "ssh prod 'uniq /etc/hosts /etc/hosts.new'",
    "ssh prod 'awk -i inplace \"{print}\" /etc/hosts'",
    "ssh prod 'sed --in-place s/a/b/ /etc/hosts'",
    "ssh prod 'date -s \"2020-01-01 00:00\"'",
    "ssh prod 'hostname web-2'",
    "ssh prod 'nginx -s reload'",
    "ssh prod top",
    "ssh prod \"psql -c 'SELECT 1'\"",
    "ssh prod 'cp /etc/nginx/nginx.conf /tmp/'",
    # ssh with no remote command: a tool call has no terminal, so the login
    # shell runs whatever reaches its stdin.
    "ssh prod <<'EOF'\nsudo systemctl restart nginx\nEOF",
    "echo 'rm -rf /srv/app' | ssh prod",
    "ssh prod < deploy.sh",
    "ssh prod",
    "ssh -t prod",
    "ssh -i key.pem -p 2222 deploy@prod",
    "ssh -N -L 5432:localhost:5432 prod",
    "ssh bastion 'cat deploy.sh | ssh prod'",
    "echo reboot | ssh prod 'sudo -s'",
    "ssh prod 'sudo -i'",
    "ssh prod 'sudo -E'",
    "ssh -o RemoteCommand='rm -rf /srv/app' prod",
    "ssh -oRemoteCommand='rm -rf /srv/app' prod",
    "ssh -o 'RemoteCommand rm -rf /srv/app' prod uptime",
    "ssh -tp 2222 prod 'service nginx restart'",
    # A redirect attached to a word is still a redirect.
    "ssh prod 'echo hi>/etc/motd'",
    "ssh prod 'cat a>>~/.bashrc'",
    "ssh prod 'printf x>/srv/app/.env'",
    "ssh prod 'uptime&>/var/log/up.log'",
    # Allowlisted tools in a mode that writes or runs a command.
    """ssh prod "awk 'BEGIN { system(\\"reboot\\") }'" """,
    """ssh prod "awk '{ print | \\"sh\\" }' /tmp/cmds" """,
    """ssh prod "awk '{ print \\$0 > \\"/etc/hosts\\" }' /etc/hosts" """,
    """ssh prod "awk '{ printf \\"%s\\", \\$0 >> \\"/root/.bashrc\\" }' x" """,
    """ssh prod "awk '\\"date\\" | getline d' /dev/null" """,
    "ssh prod 'awk -f /tmp/prog.awk /etc/hosts'",
    """ssh prod "sed -n 'w /etc/hosts' /tmp/x" """,
    """ssh prod "sed -n '/root/W /etc/cron.d/x' /etc/passwd" """,
    """ssh prod "sed 's/.*/reboot/e' /etc/hostname" """,
    """ssh prod "sed -n 's/a/b/w /etc/motd' /etc/hosts" """,
    """ssh prod "sed '1e reboot' /etc/hostname" """,
    """ssh prod "sed -e p -e 'w /etc/x' /etc/hosts" """,
    "ssh prod 'sed -ni p /etc/hosts'",
    "ssh prod 'sed -f /tmp/script.sed /etc/hosts'",
    "ssh prod 'git -c core.pager=reboot log'",
    "ssh prod 'git -c core.fsmonitor=/tmp/x status'",
    "ssh prod 'git diff --output=/etc/motd'",
    "ssh prod 'git log --output /srv/app/.env'",
    "ssh prod 'git grep -O reboot pattern'",
    "ssh prod 'git grep --open-files-in-pager=reboot x'",
    "ssh prod 'git diff --ext-diff'",
    "ssh prod 'git --exec-path=/tmp log'",
    "ssh prod 'LD_PRELOAD=/tmp/x.so cat /etc/hosts'",
    "ssh prod 'PAGER=reboot git log'",
    "ssh prod 'GIT_EXTERNAL_DIFF=/tmp/x git diff'",
    "ssh prod 'env GIT_PAGER=reboot git log'",
    "ssh prod \"env -S 'rm -rf /srv/app'\"",
    "ssh prod \"env --split-string='reboot'\"",
    "ssh prod 'journalctl --cursor-file=/etc/motd -n 5'",
    "ssh prod 'docker --tlscacert ps rm -f web'",
    # The reviewed reader batch, each in its writing mode.
    "ssh prod 'ss -K dst 10.0.0.1'",
    "ssh prod 'crontab -r'",
    "ssh prod 'crontab -e'",
    "ssh prod 'crontab /tmp/cron'",
    "ssh prod 'dmesg -c'",
    "ssh prod 'dmesg --clear'",
    "ssh prod 'ip addr add 10.0.0.2/24 dev eth0'",
    "ssh prod 'ip link set eth0 down'",
    "ssh prod 'ip route del default'",
    "ssh prod 'git branch -D main'",
    "ssh prod 'git branch new-feature'",
    "ssh prod 'git branch -m old new'",
    "ssh prod 'git remote add x https://example.com/x.git'",
    "ssh prod 'git tag v1'",
    "ssh prod 'git tag -d v1'",
    "ssh prod 'curl -d a=1 http://localhost/x'",
    "ssh prod 'curl --data-binary @f http://localhost/x'",
    "ssh prod 'curl -T f http://localhost/x'",
    "ssh prod 'curl -F f=@x http://localhost/x'",
    "ssh prod 'curl -o /etc/x http://localhost/x'",
    "ssh prod 'curl -O http://localhost/f'",
    "ssh prod 'curl -sSLo /srv/x http://localhost/x'",
    "ssh prod 'pm2 delete api'",
    "ssh prod 'while read f; do rm \"$f\"; done < /tmp/list'",
    # Local rules read an attached redirect the same way.
    "rm -rf ~>/dev/null",
    "rm -rf $HOME>/dev/null",
    "env -S 'rm -rf /'",
    # copy onto a remote host: every destination spelling.
    "rsync -av --delete ./dist/ prod:/var/www/html/",
    "rsync -a /srv/ user@prod:/srv/",
    "scp nginx.conf prod:/etc/nginx/nginx.conf",
    "scp -i key.pem nginx.conf prod:/etc/nginx/nginx.conf",
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
    # browser-sync: reading the user's own Chrome cookie store is the user's call.
    "python3 .agents/browser-sync.py",
    ".agents/browser-sync.py",
    "cd .agents && ./browser-sync.py",
    "python3 -u /work/repo/.agents/browser-sync.py --settings /tmp/settings.json",
    "python3 .agents/browser-sync.py --source ~/Library/Application\\ Support/Google/Chrome",
    "python3 .agents/browser-sync.py --source /tmp/../Users/mac/Library",
    "python3 .agents/browser-sync.py --source /tmp",
    "python3 .agents/browser-sync.py --source relative/profile",
    "python3 .agents/browser-sync.py --source /tmp/synthetic --source /Users/mac/Chrome",
    # ...behind any wrapper, interpreter flag, or shell body.
    "timeout 60 python3 .agents/browser-sync.py",
    "timeout 120 sh -c 'python3 .agents/browser-sync.py'",
    "bash -lc 'python3 .agents/browser-sync.py'",
    "bash -ec 'cd .agents && ./browser-sync.py'",
    "/usr/bin/env python3 .agents/browser-sync.py",
    "uv run .agents/browser-sync.py",
    "nice python3 .agents/browser-sync.py",
    "caffeinate -i python3 .agents/browser-sync.py",
    "python3 -X utf8 .agents/browser-sync.py",
    "python3 -W ignore .agents/browser-sync.py",
    "xargs python3 .agents/browser-sync.py",
    "python3 .agents/browser-sync.py --source /tmp/synthetic && python3 .agents/browser-sync.py",
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
    # A wrapper around a scoped or read-only command.
    "timeout 5 rm -rf ./build",
    "nice -n 10 ls",
    "caffeinate -i make",
    "bash -lc 'ls -la'",
    "timeout 5 echo 'rm -rf /'",
    "command -v rm",
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
    # ssh: the read-only neighbour of every deletion form, and scratch writes.
    "ssh prod 'docker ps'",
    "ssh prod 'docker system df'",
    "ssh prod 'journalctl -u nginx -n 50'",
    "ssh prod 'find /var/log -name \"*.log\" -size +100M'",
    "ssh prod 'cat /etc/nginx/nginx.conf > /tmp/nginx.conf'",
    "ssh prod 'nginx -T 2>/dev/null | grep server_name'",
    "ssh prod 'wc -l < /etc/passwd'",
    "ssh prod 'df -h 2>&1'",
    "ssh prod \"find /var/log -name '*.log' -exec grep -l error {} \\;\"",
    "ssh prod 'ls /var/log | xargs wc -l'",
    "ssh prod 'docker logs web'",
    "ssh prod 'kubectl get pods'",
    # ssh: no remote command is an interactive login, and reads in every shape.
    "ssh -G prod",
    "ssh -V",
    "ssh -O check prod",
    "ssh prod 'ss -tlnp'",
    "ssh prod 'netstat -tlnp'",
    "ssh prod 'crontab -l'",
    "ssh prod 'crontab -l -u www-data'",
    "ssh prod 'dmesg -T | tail -50'",
    "ssh prod 'lsof -i :443'",
    "ssh prod 'ip addr'",
    "ssh prod 'ip -br addr show'",
    "ssh prod 'ip route show'",
    "ssh prod 'ip link list'",
    "ssh prod 'ip a s eth0'",
    "ssh prod 'readlink -f /srv/app/current'",
    "ssh prod 'sha256sum /srv/app/release.tgz'",
    "ssh prod 'md5sum /etc/hosts'",
    "ssh prod 'tac /var/log/syslog | head'",
    "ssh prod 'zgrep error /var/log/syslog.2.gz'",
    "ssh prod 'zcat /var/log/syslog.2.gz | tail'",
    "ssh prod 'jq .version /srv/app/package.json'",
    "ssh prod 'git branch'",
    "ssh prod 'git branch -a --contains HEAD'",
    "ssh prod 'git branch --list \"release/*\"'",
    "ssh prod 'git remote -v'",
    "ssh prod 'git tag -l \"v1.*\"'",
    "ssh prod 'git tag'",
    "ssh prod 'while read -r f; do [[ -f \"$f\" ]] && wc -l \"$f\"; done < /tmp/list'",
    "ssh prod 'for f in /etc/*.conf; do test -s \"$f\" && echo \"$f\"; done'",
    "ssh prod 'curl -sS http://localhost:8080/health'",
    "ssh prod 'curl -I https://example.com'",
    "ssh prod 'curl -s -H \"Accept: application/json\" http://localhost/status'",
    "ssh prod 'pm2 logs api --lines 50'",
    "ssh prod 'pm2 list'",
    "ssh prod 'LC_ALL=C sort /etc/hosts'",
    "ssh prod 'TZ=UTC date'",
    "ssh prod 'LANG=C grep x /etc/hosts'",
    """ssh prod "awk '\\$3 > 100 {print \\$1}' /var/log/x" """,
    """ssh prod "awk -F: -v min=1000 '\\$3 >= min {print \\$1}' /etc/passwd" """,
    """ssh prod "sed -n '/error/p' /var/log/syslog" """,
    """ssh prod "sed 's/a/b/g' /etc/hosts" """,
    """ssh prod "sed -n '1,/^$/p' /etc/hosts" """,
    """ssh prod "sed -n -e '/x/{p;q}' /etc/hosts" """,
    "ssh prod 'docker --tlscacert ca.pem ps'",
    "ssh prod 'git diff --stat'",
    "ssh prod 'echo \"a>b\"'",
    "ssh prod 'ls -la /srv && df -h && free -m'",
    "ssh prod 'ps aux | grep nginx | head -5'",
    "ssh prod 'systemctl status nginx --no-pager'",
    "ssh prod 'systemctl is-active nginx'",
    "ssh prod systemctl",
    "ssh prod 'systemctl list-units --failed'",
    "ssh prod 'docker inspect web'",
    "ssh prod 'docker compose -f /srv/compose.yml logs --tail 100 api'",
    "ssh prod 'kubectl -n prod describe pod api'",
    "ssh prod 'kubectl logs -n prod api-1'",
    "ssh prod 'cd /srv/app && git log --oneline -5 && git status'",
    "ssh prod 'sudo journalctl -u nginx --since today | tail -20'",
    "ssh prod \"bash -lc 'uname -a; whoami; id'\"",
    "ssh prod 'sed -n 1,20p /etc/nginx/nginx.conf'",
    "ssh prod \"awk '{print \\$1}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head\"",
    "ssh prod 'top -b -n1 | head -20'",
    "ssh prod 'date +%s'",
    "ssh bastion ssh prod uptime",
    "ssh prod 'for f in /var/log/*.log; do wc -l \"$f\"; done'",
    "ssh prod 'env | sort'",
    "ssh prod 'which nginx && file /usr/sbin/nginx'",
    "ssh prod 'stat /etc/hosts; du -sh /var/log'",
    "ssh prod 'printenv PATH'",
    "ssh prod 'git -C /srv/app diff HEAD~1 --stat'",
    # copy from a remote host, and a local sync.
    "rsync -av prod:/var/www/html/ ./backup/",
    "scp prod:/etc/nginx/nginx.conf /tmp/nginx.conf",
    "rsync -a --delete ./a/ ./b/",
    # The same deletions on this machine are the working tree's own business.
    "find . -name '*.pyc' -delete",
    "docker builder prune -af",
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
    # browser-sync against a synthetic profile under a scratch root, and reads.
    "python3 .agents/browser-sync.py --source /tmp/synthetic-chrome",
    ".agents/browser-sync.py --source=/var/folders/xc/T/synthetic --settings /tmp/s.json",
    "python3 .agents/browser-sync.py --source /private/tmp/synthetic-chrome",
    "cat .agents/browser-sync.py",
    "grep -n source .agents/browser-sync.py",
    "python3 .agents/test-browser-sync.py",
    "timeout 60 python3 .agents/browser-sync.py --source /tmp/synthetic-chrome",
    "sed -n 1,20p .agents/browser-sync.py",
    "head -40 .agents/browser-sync.py",
    "rg SyncError .agents/browser-sync.py",
    "git show HEAD:.agents/browser-sync.py",
    "git diff -- .agents/browser-sync.py",
    "git log -- .agents/browser-sync.py",
    "git add .agents/browser-sync.py",
    'git commit -m "add browser-sync.py"',
    "bash -c 'cat .agents/browser-sync.py'",
    "wc -l .agents/browser-sync.py",
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

# The ssh denial names the clause and says what to do instead.
ssh_reason = guard.verdict("ssh prod 'uptime && service nginx restart'", PROJECT) or ""
check("the ssh denial names the clause that is not a read",
      "`service nginx restart`" in ssh_reason, ssh_reason)
check("the ssh denial gives the deploy path and the ! prefix",
      "deploy path" in ssh_reason and "! prefix" in ssh_reason, ssh_reason)
check("the ssh denial asks for the entry to be proposed to the user, not added",
      "propose the entry to the user" in ssh_reason and "REMOTE_READS" not in ssh_reason, ssh_reason)

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
check("an attached redirect is a target",
      [(c.words, c.targets) for c in guard.normalize("echo x>/etc/motd")] == [(["echo", "x"], ["/etc/motd"])])
check("a quoted > is a word, not a redirect",
      [(c.words, c.targets) for c in guard.normalize("echo 'a>b'")] == [(["echo", "a>b"], [])])
check("a descriptor duplication stays one redirect",
      [c.words for c in guard.normalize("make 2>&1")] == [["make"]])
check("env -S runs its value as the command",
      guard.lead(["env", "-S", "rm -rf /tmp/x", "y"]) == ["rm", "-rf", "/tmp/x", "y"])
check("an input redirect is not a target",
      [command.targets for command in guard.normalize("wc -l < /etc/passwd")] == [[]])

# End to end through the shell entry point, which is what an engine invokes.
#
# The entry point resolves its repository from its own location and reads that
# repository's .agents/config.json, which can turn the guard off. So these cases
# run from a sandbox carrying an explicit config rather than from this checkout:
# they assert what the guard does, not how the repository around it is
# configured. A repository that ships the guard disabled would otherwise fail
# here permanently, and for the wrong reason, while the guard behaved exactly as
# it was told to.
def sandbox_guard(root, enabled):
    """A minimal repository around the real entry point. Returns its path."""
    agents = pathlib.Path(root) / ".agents"
    (agents / "hooks" / "policy").mkdir(parents=True)
    (agents / "hooks" / "lib").mkdir(parents=True)
    entry = agents / "hooks" / "policy" / "guard-destructive.sh"
    shutil.copy2(here / "hooks" / "policy" / "guard-destructive.sh", entry)
    shutil.copy2(policy, agents / "hooks" / "lib" / "guard-destructive.py")
    shutil.copy2(here / "hooks" / "lib" / "config.py", agents / "hooks" / "lib" / "config.py")
    (agents / "config.json").write_text(
        json.dumps({"hooks": {"guard_destructive": {"enabled": enabled}}}))
    return str(entry)


with tempfile.TemporaryDirectory() as armed_dir, tempfile.TemporaryDirectory() as off_dir:
    armed = sandbox_guard(armed_dir, True)
    disarmed = sandbox_guard(off_dir, False)

    def run(payload, entry=None):
        return subprocess.run([entry or armed], input=json.dumps(payload),
                              text=True, capture_output=True)

    blocked = run({"command": "rm -rf /"})
    check("entry point exits 2 on a block", blocked.returncode == 2, f"exit {blocked.returncode}")
    check("entry point states the reason", "irreversible" in blocked.stderr, blocked.stderr)
    check("entry point exits 0 otherwise", run({"command": "ls -la"}).returncode == 0)
    synced = run({"command": "python3 .agents/browser-sync.py"})
    check("entry point refuses an agent-run browser sync", synced.returncode == 2, f"exit {synced.returncode}")
    check("the refusal tells the user to run it with !",
          "! python3 .agents/browser-sync.py" in synced.stderr, synced.stderr)
    check("entry point exits 0 on an empty payload", run({}).returncode == 0)
    check("entry point exits 0 on unreadable input",
          subprocess.run([armed], input="{not json", text=True,
                         capture_output=True).returncode == 0)

    off = run({"command": "rm -rf /"}, entry=disarmed)
    check("the config toggle turns the guard off", off.returncode == 0, off.stderr)
    consent = run({"command": "python3 .agents/browser-sync.py"}, entry=disarmed)
    check("the toggle leaves the browser-sync consent rule on", consent.returncode == 2, consent.stderr)

    # The workloop controller asks this way. It runs a --verify command with no
    # PreToolUse hook in front of it, so the toggle that governs the hook must
    # not take its floor away.
    forced = subprocess.run(
        [sys.executable, str(pathlib.Path(off_dir) / ".agents/hooks/lib/guard-destructive.py"),
         "--force"],
        input=json.dumps({"command": "rm -rf /"}), text=True, capture_output=True)
    check("--force keeps the verdict when the toggle is off",
          forced.returncode == 2, forced.stderr)

    # policy.json is the repository's tracked word; config.json is one
    # operator's, and wins where both speak.
    with tempfile.TemporaryDirectory() as layered_dir:
        entry = sandbox_guard(layered_dir, True)
        agents = pathlib.Path(layered_dir) / ".agents"
        (agents / "config.json").unlink()
        (agents / "policy.json").write_text(
            json.dumps({"hooks": {"guard_destructive": {"enabled": False}}}))
        check("policy.json alone switches the guard off",
              run({"command": "rm -rf /"}, entry=entry).returncode == 0)
        (agents / "config.json").write_text(
            json.dumps({"hooks": {"guard_destructive": {"enabled": True}}}))
        check("config.json overrides policy.json for the same key",
              run({"command": "rm -rf /"}, entry=entry).returncode == 2)

    # The guard must run when nothing states a preference, or a repository that
    # never wrote a config would ship unguarded.
    with tempfile.TemporaryDirectory() as bare_dir:
        bare = sandbox_guard(bare_dir, True)
        (pathlib.Path(bare_dir) / ".agents" / "config.json").unlink()
        check("the guard is on when no config states otherwise",
              run({"command": "rm -rf /"}, entry=bare).returncode == 2)

print("\nALL PASS" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
