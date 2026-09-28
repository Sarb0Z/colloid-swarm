#!/usr/bin/env python3
"""Find a script a shell command runs that writes to a hosted management API.

AGENTS.md §Changes live in the repository: production state is applied by
committed code. A script outside the repository, untracked, or edited since the
last commit can change a hosting project, an auth config or a secret store and
leave nothing behind that says what changed, so it is refused outright; the
remedy — commit it as a plan/apply tool — is the agent's own. The same script
committed and unchanged is reproducible, and asks like any outward mutation. A
hand-typed `curl` write is containment, and asks.

A script counts when the command runs it: the command word, an interpreter's
script operand, or a path named inside inline code (`python3 - <<EOF` importing
`/tmp/x.py` by path). A module run with `-m` does not, so `pytest tests/x.py`
never reads a test file that mocks a vendor call. Inline interpreter code — a
heredoc body or a `-c`/`-e` payload — is itself a script outside the repository.

Detection is textual: a management host and a write signal in the same file.
SDK clients (supabase-js admin, octokit), a CLI spawned from a script, and a
direct database URL are not seen. The threat model is an honest mistake, as in
guard-destructive.
"""

import os
import re
import subprocess

HOSTS = re.compile(
    r"api\.vercel\.com|api\.supabase\.com|api\.github\.com|backboard\.railway\.(?:app|com)"
    r"|api\.railway\.app|api\.cloudflare\.com|api\.netlify\.com|api\.render\.com"
    r"|api\.fly\.io|api\.machines\.dev|api\.heroku\.com|api\.digitalocean\.com"
    r"|api\.neon\.tech|api\.planetscale\.com|api\.upstash\.com|management\.azure\.com"
    # The bracket keeps this file from matching its own pattern when loaded.
    r"|/auth/v1/adm[i]n\b"
)
# A literal write verb, or a method chosen at run time (`method=method`).
WRITES = re.compile(
    r"""["'](?:POST|PUT|PATCH|DELETE)["']|(?:^|\s)-X\s*(?:POST|PUT|PATCH|DELETE)\b"""
    r"""|--request\s+(?:POST|PUT|PATCH|DELETE)\b|\bmethod(?:=|:\s*)(?!None\b|["'])[A-Za-z_]\w*\b(?!\s*\()"""
    r"""|\.(?:post|put|patch|delete)\s*\("""
)
CURL_WRITES = re.compile(r"(?:^|\s)(?:-d|--data(?:-\w+)?|-F|--form|-X\s*(?:POST|PUT|PATCH|DELETE)|--request\s+(?:POST|PUT|PATCH|DELETE))\b")
SCRIPT = re.compile(r"""(?<![\w.])((?:~|\.{1,2})?/?[\w@%+=,./~-]*\.(?:py|mjs|cjs|js|mts|ts|sh|bash|zsh|rb))(?![\w])""")
INTERPRETERS = {"python", "python3", "node", "bun", "deno", "tsx", "ts-node", "ruby", "bash", "sh", "zsh"}
RUNNERS = {"npx", "bunx", "pnpx", "uv", "uvx"}
# A gitignored file under one of these is build output of committed source.
BUILD_DIRS = {"dist", "build", "out", ".next", ".output", "node_modules"}
INLINE = re.compile(r"(?:^|[\s;&|(])(?:python3?(?:\.\d+)?|node|bun|deno|ruby|tsx)\s+(?:-\s*<<|<<|-c\b|-e\b|--eval\b)")
LOADERS = re.compile(r"spec_from_file_location|run_path|exec\(\s*open|execfile|require\(|import\(|subprocess|os\.system")
# Inline code is a script only when it makes the call itself.
HTTP_CALLS = re.compile(r"urlopen|\brequests\.|\bhttpx\.|\bfetch\(|\baxios\b|http\.client|https?\.request\(")
HTTP_CLIENTS = {"curl", "wget", "http", "https", "xh"}
MAX_BYTES = 512 * 1024


def writes_hosted(text):
    """True when the text names a management API and a write to it."""
    hosts = set(HOSTS.findall(text))
    if not hosts or not WRITES.search(text):
        return False
    # GitHub's GraphQL endpoint takes every query as a POST; only a mutation writes.
    if all(host.startswith("api.github") for host in hosts) and "/graphql" in text and "mutation" not in text:
        return False
    return True


def runs(words):
    """The script operand one command runs, or None."""
    if not words or "--dry-run" in words[1:]:
        return None
    name = os.path.basename(words[0])
    if SCRIPT.fullmatch(words[0]) and "/" in words[0]:
        return words[0]
    if name in ("source", ".") and len(words) > 1:
        return words[1]
    # `npx tsx x.ts` runs x.ts; `npx tsc x.ts` only type-checks it.
    if name in RUNNERS:
        words = [w for w in words[1:] if not w.startswith("-") and w != "run"]
        if not words:
            return None
        if SCRIPT.fullmatch(words[0]):
            return words[0]
        name = os.path.basename(words[0])
    if name in INTERPRETERS or name.startswith("python3."):
        # `-m` runs a module; `bash -n` only parses.
        if "-m" in words[1:] or (name in ("bash", "sh", "zsh") and "-n" in words[1:]):
            return None
        return next((w for w in words[1:] if not w.startswith("-") and SCRIPT.fullmatch(w)), None)
    return None


def executed(command, shell, cwd):
    """Absolute paths of the scripts the command runs, in order.

    A relative operand resolves against the directory the shell is in when it
    runs: the session's working directory, moved by each `cd` or `pushd`
    earlier in the command. A subshell's `cd` is followed past the subshell,
    which can only make an operand resolve to a file that exists.
    """
    found, here = [], cwd
    for cmd in shell.normalize(command):
        words = shell.lead(cmd.words)
        if words and words[0] in ("cd", "pushd") and len(words) > 1 and "$" not in words[1]:
            here = resolve(words[1], here)
            continue
        script = runs(words)
        if script:
            found.append(resolve(script, here))
    # Inline code runs a path only through a loader; a path it merely names —
    # a file it edits, a string it prints — is data.
    if INLINE.search(command):
        for line in command.split("\n"):
            if LOADERS.search(line):
                found += [resolve(m.group(1), here) for m in SCRIPT.finditer(line) if "/" in m.group(1)]
    return list(dict.fromkeys(found))


def resolve(path, base):
    return os.path.realpath(os.path.join(base, os.path.expanduser(path)))


def written_here(path, command):
    """True when the command itself writes the script before running it."""
    return re.search(r"(?:>|\btee\s+(?:-a\s+)?)\s*[\"']?[^\s\"']*" + re.escape(os.path.basename(path)) + r"\b", command) is not None


def repository(path):
    """The top of the Git repository holding the file, or None."""
    top = subprocess.run(["git", "-C", os.path.dirname(path), "rev-parse", "--show-toplevel"],
                         capture_output=True, text=True)
    return os.path.realpath(top.stdout.strip()) if top.returncode == 0 and top.stdout.strip() else None


def committed(path):
    """True when the file is tracked in its own repository and unchanged since HEAD.

    Its own repository, not the session's: a session opened on a folder of
    several repositories runs each one's committed tools.
    """
    top = repository(path)
    if not top:
        return False
    rel = os.path.relpath(path, top)
    tracked = subprocess.run(["git", "-C", top, "ls-files", "--error-unmatch", "--", rel],
                             capture_output=True).returncode == 0
    clean = subprocess.run(["git", "-C", top, "diff", "--quiet", "HEAD", "--", rel],
                           capture_output=True).returncode == 0
    return tracked and clean


def build_output(path):
    """True for a gitignored file under a build directory of its repository."""
    top = repository(path)
    if not top:
        return False
    rel = os.path.relpath(path, top)
    if not BUILD_DIRS & set(rel.split(os.sep)[:-1]):
        return False
    return subprocess.run(["git", "-C", top, "check-ignore", "-q", "--", rel],
                          capture_output=True).returncode == 0


def read(path):
    try:
        if os.path.getsize(path) > MAX_BYTES:
            return ""
        with open(path, errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


REMEDY = (" AGENTS.md §Changes live in the repository: production state is applied by "
          "committed code. Put this in the repository as a plan/apply tool — a plan "
          "command that reports drift and changes nothing, an apply command that is safe "
          "to rerun, secret values read from a gitignored env file — commit it, and run it "
          "from there. Do not retry it from outside the repository or inline.")


def verdict(command, project, shell, cwd=None):
    """("deny" | "ask", reason) for a hosted write the command makes, or None."""
    project = os.path.realpath(project or ".")
    inline = bool(INLINE.search(command))
    for path in executed(command, shell, os.path.realpath(cwd or project)):
        body = read(path) if os.path.isfile(path) else ""
        # A script written in the same call is missing or stale at hook time;
        # the command text carries its new body, and it is not committed code.
        rewritten = not body or written_here(path, command)
        if not writes_hosted(body + ("\n" + command if rewritten else "")):
            continue
        if not rewritten and committed(path):
            return ("ask", f"{path} writes to a hosted management API.")
        if not rewritten and build_output(path):
            continue
        where = "not committed as it stands" if repository(path) else "outside any repository"
        return ("deny", f"{path} is {where} and writes to a hosted management API." + REMEDY)
    if inline and HTTP_CALLS.search(command) and writes_hosted(command):
        return ("deny", "Inline code in this command writes to a hosted management API." + REMEDY
                + " If the inline code only edits a file that contains such calls, edit it with the editor tool.")
    for cmd in shell.normalize(command):
        words = shell.lead(cmd.words)
        if words and os.path.basename(words[0]) in HTTP_CLIENTS:
            text = " ".join(words)
            if HOSTS.search(text) and CURL_WRITES.search(" " + text):
                return ("ask", f"{words[0]} writes to a hosted management API by hand.")
    return None
