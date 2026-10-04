#!/usr/bin/env python3
"""Decide whether a tool call is an outward mutation that needs user approval.

Input  (stdin JSON): {"tool_name": "...", "tool_input": {...},
                      "permission_mode": "default" | "auto" | ...}
Output: exit 0 always. Stdout carries the Claude Code PreToolUse envelope
{"hookSpecificOutput": {"permissionDecision": "ask" | "deny", ...}} in two
cases: a rule fired, or the guard could not evaluate a call (unreadable
payload, evaluator error) — it fails closed. Silence otherwise.

This is the enforcement half of `AGENTS.md` §External actions: an outward
mutation requires user approval in the current session. "Ask" is the whole
point — a publish is legitimate exactly when the user says yes, so the guard
forces the dialog rather than denying. Contrast guard-destructive, which
denies, because no mid-session answer legitimizes `rm -rf /`.

The dialog only counts when a human answers it. In auto mode the host is
documented to floor a hook's "ask" at a prompt, and on Claude Code 2.1.258 it
did not: ten `git push` calls in one session each drew an "ask" from this guard
and ran unanswered seconds later, and a probe in a foreground auto-mode session
did the same. In bypassPermissions mode nothing prompts by design, and dontAsk
turns a prompt into a denial anyway. So the guard asks only in the modes known
to prompt, denies in every other and says how the user approves — switch the
mode and answer the prompt, or run the command themselves — because a call the
user never saw is not approved. The publish-approval mod adds a third way: an
approval in its dialog, which reaches the user in every mode, leaves a token
that turns this guard's ask or deny into allow for that one call.

Scope: Bash publish/push/deploy commands, and every Artifact action that
reaches claude.ai — publishing a page, adding or deleting one of its files, and
posting or resolving a comment thread.
Other outward channels (remote MCP writes, cross-session messages)
keep their own native prompts. The threat model is an honest mistake by the
model — a harness bias toward publishing — not an adversary with a shell.
"""

import importlib.util
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def load_shell_parser():
    spec = importlib.util.spec_from_file_location(
        "guard_destructive", os.path.join(HERE, "guard-destructive.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


GH_MUTATING_VERBS = {"create", "merge", "close", "reopen", "comment", "edit",
                     "delete", "review", "ready", "lock", "unlock", "transfer",
                     "run", "upload"}
GH_MUTATING_AREAS = {"pr", "issue", "release", "repo", "gist", "label", "workflow"}
NPM_PUBLISHERS = {"npm", "pnpm", "yarn", "bun"}
READ_FLAGS_GH_API = {"GET", "HEAD"}
# One deploy vendor per row; the verb set is that CLI's outward-mutating verbs.
# A verb may be two words, matched against the leading positional arguments and
# longest-first, because some CLIs group their verbs under a noun.
# `vercel` is special-cased below because its bare invocation deploys.
DEPLOY_VERBS = {
    "vercel": {"deploy", "promote", "rollback", "alias", "rm", "remove", "redeploy"},
    "netlify": {"deploy"},
    "wrangler": {"deploy", "publish"},
    "firebase": {"deploy"},
    "fly": {"deploy"},
    "flyctl": {"deploy"},
    "railway": {"up", "deploy"},
    "supabase": {"db push", "functions deploy", "secrets set", "secrets unset",
                 "projects create", "projects delete",
                 "branches create", "branches delete"},
}
# More outward verbs, read the same way. These have no `.claude/settings.json`
# permissions.ask rule, which test-guard-publish requires of every DEPLOY_VERBS
# row, so they are gated by this hook alone.
HOSTED_VERBS = {
    "terraform": {"apply", "destroy", "import", "refresh", "taint", "untaint", "force-unlock",
                  "state rm", "state mv", "state push", "state replace-provider",
                  "workspace delete"},
}
HOSTED_VERBS["tofu"] = HOSTED_VERBS["terraform"]
HOSTED_VERBS["supabase"] = {
    "config push", "functions delete", "sso add", "sso remove", "sso update",
    "domains create", "domains reverify", "domains activate", "domains delete",
    "postgres-config update", "postgres-config delete", "network-restrictions update",
    "vanity-subdomains activate", "vanity-subdomains delete", "ssl-enforcement update",
    "network-bans remove", "backups restore", "encryption update-root-key", "branches update",
    "branches pause", "branches unpause", "orgs create", "notebooks push",
}
# `supabase storage` reaches the linked project unless `--local` says
# otherwise, and `cp` writes there only when its destination is an `ss://` path.
SUPABASE_STORAGE_VALUED = {"--cache-control", "--content-type", "-j", "--jobs", "--project-ref"}
# Verbs that are local by default and reach the hosted project only when a flag
# says so. Gating them unconditionally would ask on every `supabase db reset`,
# which is how a developer rebuilds the Docker stack several times an hour; an
# ask that fires on routine local work is one people learn to dismiss.
REMOTE_FLAG_VERBS = {
    "supabase": ({"db reset", "migration up", "migration repair", "db dump", "seed buckets"},
                 {"--linked", "--db-url"}),
}
# The read set is the allowlist, so an action this guard does not recognize asks:
# a new Artifact action is likelier to mutate than to read. Nothing here keys on
# the payload shape — a comment reply and an asset delete reach the published
# page carrying a url and a thread or asset id, never a file_path.
ARTIFACT_READ_ACTIONS = {"list", "comments", "list_assets", "read_asset"}
ARTIFACT_REASONS = {
    "reply": "Artifact reply posts a comment every viewer of that page can see.",
    "resolve": "Artifact resolve changes a comment thread on the published page.",
    "upload_asset": "Artifact upload_asset adds a file to the published page.",
    "delete_asset": "Artifact delete_asset permanently removes a file from the published page.",
}
RUNNERS = {"npx", "pnpx", "bunx"}
RUNNER_CALL_FLAGS = {"-c", "--call"}      # npx -c "<shell>" runs its value
CONTROL_KEYWORDS = {"do", "then", "else", "elif", "if", "while", "until", "time", "{"}
# Names a command must mention before the shell parser is worth loading.
# gcloud ends a group path of any depth with its verb (`gcloud services
# api-keys delete`), and firebase namespaces verbs with colons
# (`firestore:delete`), so neither fits a prefix table or a host prefix rule.
# The verb decides; the groups below only configure the local CLI.
GCLOUD_LOCAL_GROUPS = {"config", "auth", "components", "info", "help", "version",
                       "topic", "cheat-sheet", "feedback", "init", "emulators"}
GCLOUD_TRACKS = {"alpha", "beta", "preview"}
GCLOUD_WRITES = {"create", "delete", "update", "deploy", "set", "unset", "patch",
                 "import", "enable", "disable", "undelete", "restore", "replace",
                 "rollback", "submit", "execute", "add", "remove", "cancel",
                 "resize", "start", "stop", "reset", "promote", "rm", "mv",
                 "publish", "migrate", "export", "run", "call", "apply"}
# A verb family: `set-traffic`, `add-iam-policy-binding`, `enable-oslogin`.
GCLOUD_WRITE_PREFIXES = ("add-", "remove-", "set-", "update-", "create-", "delete-",
                         "enable-", "disable-")
GCLOUD_READS = {"describe", "list", "get", "read", "tail", "ls", "cat", "du"}
FIREBASE_WRITES = {"delete", "set", "unset", "remove", "update", "push", "import",
                   "disable", "enable", "clone", "create", "install", "uninstall",
                   "destroy", "rollback"}
# Global options whose value is the next word, so that value is not read as
# the verb. firebase-tools declares its globals in src/index.ts: `-P, --project
# <alias_or_project_id>`, `--account <email>`, `--token <token>` and `-c,
# --config <path>` take a value; `--json`, `--debug` and the interactivity
# switches do not. `--flag=value` carries its own value and needs no entry.
#
# wrangler's yargs globals (workers-sdk packages/wrangler/src/index.ts). flyctl
# and the Supabase CLI are cobra programs, which find the verb past any flag
# and its value and let the verb parse it, so a verb's own value flags count
# too: flyctl's from internal/flag/flag.go, Supabase's globals from
# `supabase --help` (2.119) plus `--project-ref` and `--db-url`. railway (clap)
# and netlify (commander) reject an option before the verb, so neither has a row.
VALUE_FLAGS = {
    "firebase": {"-P", "--project", "--account", "--token", "-c", "--config"},
    "gcloud": {"--project", "--account", "--configuration", "--impersonate-service-account",
               "--region", "--zone", "--format", "--verbosity"},
    "wrangler": {"--cwd", "-c", "--config", "-e", "--env", "--env-file", "--profile"},
    "fly": {"-t", "--access-token", "-a", "--app", "-c", "--config", "-e", "--env", "-i", "--image",
            "-s", "--signal", "-o", "--org", "-r", "--region", "-g", "--process-group"},
    "supabase": {"--workdir", "--profile", "-o", "--output", "--output-format", "--network-id",
                 "--dns-resolver", "--agent", "--log-level", "--completions",
                 "--project-ref", "--db-url"},
}
VALUE_FLAGS["flyctl"] = VALUE_FLAGS["fly"]
# AWS CLI v2 global options that take a value (docs.aws.amazon.com/cli/latest/
# reference/index.html); the CLI accepts them before the service too.
AWS_VALUE_FLAGS = {"--region", "--profile", "--output", "--query", "--endpoint-url", "--ca-bundle",
                   "--cli-read-timeout", "--cli-connect-timeout", "--color", "--cli-binary-format",
                   "--cli-error-format"}
# The read operations are the allowlist, so an operation this guard does not
# recognize asks: AWS adds services faster than any write list could follow.
AWS_READ_PREFIXES = ("get-", "list-", "describe-", "head-", "batch-get-", "lookup-", "filter-",
                     "search-", "select-", "simulate-", "validate-", "estimate-")
AWS_READS = {"scan", "query", "wait", "tail", "help"}
# Operations that only read, query, or write local credentials and config:
# Logs Insights queries and live tails, a role session, a kubeconfig entry, a
# login token.
AWS_QUIET = {("logs", "start-query"), ("logs", "stop-query"), ("logs", "start-live-tail"),
             ("eks", "update-kubeconfig"), ("sso", "login"), ("codeartifact", "login")}
GATED_NAMES = ({"git", "gh", "docker", "gcloud", "aws"} | NPM_PUBLISHERS | set(DEPLOY_VERBS)
               | set(HOSTED_VERBS) | set(REMOTE_FLAG_VERBS) | RUNNERS)
# Vercel global options that take a value, and ones that only read.
VERCEL_VALUE_FLAGS = {"--cwd", "-Q", "--global-config", "-A", "--local-config",
                      "-S", "--scope", "-t", "--token"}
VERCEL_BOOL_FLAGS = {"-d", "--debug", "--no-color"}
VERCEL_READ_FLAGS = {"-h", "--help", "-v", "--version"}


def vercel_reason(words):
    """Classify Vercel's flag-before-verb and option-only deploy forms.

    A bare `vercel` deploys, so any flag before the first verb that is not a
    known global option is treated as a deploy flag (`--prod`, `--target`,
    `--yes`): the guard asks rather than guessing what an unknown flag does.
    """
    positionals = []
    index = 0
    while index < len(words):
        word = words[index]
        flag, _, inline_value = word.partition("=")
        if flag in VERCEL_READ_FLAGS:
            return None
        if flag in VERCEL_VALUE_FLAGS:
            index += 1 if inline_value else 2
            continue
        if flag in VERCEL_BOOL_FLAGS or (word.startswith("-") and positionals):
            index += 1            # a flag after the verb: the verb decides
            continue
        if word.startswith("-"):
            return f"vercel {flag} before any verb deploys or mutates the hosted project."
        positionals.append(word)
        index += 1
    if not positionals or positionals[0] in DEPLOY_VERBS["vercel"]:
        return "vercel deploys or mutates the hosted project."
    return None


def positionals(words, value_flags=frozenset()):
    """The words that are not options or the separate value of one."""
    found, skip = [], False
    for word in words:
        if skip:
            skip = False
        elif word.startswith("-"):
            skip = word in value_flags
        else:
            found.append(word)
    return found


def gcloud_reason(rest):
    """gcloud's verb is the last word of its group path; a flag value
    (`--project p`) is not part of the path.

    The word after the release track is always a group, never a verb, so
    `run` there is Cloud Run and `emulators` there is the local emulator; the
    same words further down are a verb (`scheduler jobs run`) or an operand
    (`run deploy emulators`). The first word that reads or writes is the verb:
    the operands after a read (`describe update-checker`) are names.
    """
    path = positionals(rest, VALUE_FLAGS["gcloud"])
    start = 1 if path[:1] and path[0] in GCLOUD_TRACKS else 0
    if len(path) <= start or path[start] in GCLOUD_LOCAL_GROUPS:
        return None
    for index in range(start + 1, len(path)):
        word = path[index]
        if word in GCLOUD_READS or word.startswith(("get-", "list-", "describe-")):
            return None
        if word in GCLOUD_WRITES or word.startswith(GCLOUD_WRITE_PREFIXES):
            return f"gcloud {' '.join(path[:index + 1])} mutates the hosted project."
        # A copy or sync writes only when a bucket is the destination.
        if word in ("cp", "rsync") and path[-1].startswith("gs://"):
            return f"gcloud storage {word} uploads to a hosted bucket."
    return None


def runner_width(words, shell):
    """How many words name a package runner at the start: `npx` is one,
    `pnpm dlx`, `yarn dlx` and `bun x` are two, anything else none."""
    name = shell.base(words[0]) if words else ""
    if name in RUNNERS:
        return 1
    if (name in ("pnpm", "yarn") and words[1:2] == ["dlx"]) or (name == "bun" and words[1:2] == ["x"]):
        return 2
    return 0


def unversioned(spec):
    """A package spec without its version: `eas-cli@16` is `eas-cli`, and
    `@scope/pkg@1` is `@scope/pkg`; the scope's own `@` is not a version."""
    at = spec.find("@", 1)
    return spec[:at] if at > 0 else spec


def supabase_storage_reason(rest):
    path = positionals(rest, SUPABASE_STORAGE_VALUED | VALUE_FLAGS["supabase"])
    if path[:1] != ["storage"] or "--local" in rest:
        return None
    verb = path[1] if len(path) > 1 else None
    if verb in ("rm", "mv") or (verb == "cp" and path[-1].startswith("ss:")):
        return f"supabase storage {verb} writes to the linked project's storage."
    return None


def aws_reason(rest):
    path = positionals(rest, AWS_VALUE_FLAGS)
    if len(path) < 2 or path[0] in ("configure", "help"):
        return None
    service, operation = path[0], path[1]
    if service == "s3":
        buckets = [word for word in path[2:] if word.startswith("s3://")]
        # cp and sync write only toward a bucket; a bucket as the sole source is a download.
        toward = bool(buckets) and not (operation in ("cp", "sync") and buckets == path[2:3])
        if operation in ("rm", "rb", "mb", "website") or (operation in ("cp", "sync", "mv") and toward):
            return f"aws s3 {operation} writes to a hosted bucket."
        return None
    if (operation in AWS_READS or operation.startswith(AWS_READ_PREFIXES)
            or (service, operation) in AWS_QUIET
            or (service == "sts" and operation.startswith("assume-role"))):
        return None
    return f"aws {service} {operation} mutates the hosted account."


def rule_bash(command, shell):
    words = shell.lead(command.words)
    while words and words[0] in CONTROL_KEYWORDS:
        words = shell.lead(words[1:])
    # `npx <tool> ...` runs the tool; drop the runner and its own options so
    # the tool's rule sees the tool's arguments untouched. `npx -c "<shell>"`
    # runs its value as a command, so that string is judged on its own.
    while runner_width(words, shell):
        words = words[runner_width(words, shell):]
        while words and words[0].startswith("-"):
            if words[0] in RUNNER_CALL_FLAGS:
                for inner in shell.normalize(words[1] if len(words) > 1 else ""):
                    reason = rule_bash(inner, shell)
                    if reason:
                        return reason
                words = words[2:]
            else:
                words = words[2:] if words[0] in shell.RUNNER_VALUED else words[1:]
        words = [unversioned(words[0])] + words[1:] if words else words
    if not words:
        return None
    name, rest = shell.base(words[0]), words[1:]

    if name == "git":
        # git accepts global options (-C, -c, --git-dir) before the verb;
        # git_verb in guard-destructive.py already knows how to skip them.
        verb, after = shell.git_verb(words)
        if verb == "push":
            letters, longs, _ = shell.parts(after)
            if "n" in letters or "--dry-run" in longs:
                return None
            return "git push publishes commits to the remote."
    if name == "gh":
        if len(rest) >= 2 and rest[0] in GH_MUTATING_AREAS and rest[1] in GH_MUTATING_VERBS:
            return f"gh {rest[0]} {rest[1]} mutates GitHub state."
        if rest and rest[0] == "api":
            method = None
            for index, word in enumerate(rest):
                if word in ("-X", "--method") and index + 1 < len(rest):
                    method = rest[index + 1].upper()
            writes = any(word in ("-f", "-F", "--field", "--raw-field", "--input")
                         for word in rest)
            if (method and method not in READ_FLAGS_GH_API) or (method is None and writes):
                return "gh api with a write method mutates GitHub state."
    if name in NPM_PUBLISHERS and rest and rest[0] in ("publish", "unpublish"):
        return f"{name} {rest[0]} pushes to the package registry."
    if name == "yarn" and rest[:1] == ["npm"] and rest[1:2] and rest[1] in ("publish", "unpublish"):
        return "yarn npm publish pushes to the package registry."
    if name == "docker" and rest and rest[0] == "push":
        return "docker push publishes the image to the registry."
    if name == "vercel":
        return vercel_reason(rest)
    if name == "gcloud":
        return gcloud_reason(rest)
    if name == "aws":
        return aws_reason(rest)
    if name == "firebase":
        positional = positionals(rest, VALUE_FLAGS["firebase"])
        if positional and positional[0].split(":")[-1] in FIREBASE_WRITES:
            return f"firebase {positional[0]} writes to the hosted project."
    if name == "supabase" and (reason := supabase_storage_reason(rest)):
        return reason
    if name in DEPLOY_VERBS or name in HOSTED_VERBS or name in REMOTE_FLAG_VERBS:
        # Longest phrase first, so a two-word verb is not shadowed by its noun.
        positional = positionals(rest, VALUE_FLAGS.get(name, ()))
        phrases = [" ".join(positional[:width]) for width in (2, 1) if positional[:width]]
        for phrase in phrases:
            if phrase in DEPLOY_VERBS.get(name, set()) | HOSTED_VERBS.get(name, set()):
                return f"{name} {phrase} deploys or mutates the hosted project."
        verbs, flags = REMOTE_FLAG_VERBS.get(name, (set(), set()))
        for phrase in phrases:
            if phrase in verbs and any(word.split("=")[0] in flags for word in rest):
                return f"{name} {phrase} against the linked project mutates the hosted database."
    return None


def verdict(tool_name, tool_input, outward=(), rehearsals=(), cwd=None):
    """The reason to ask, or None. `outward` is the repository's script list;
    `rehearsals` names the entries whose --dry-run really rehearses; `cwd` is
    the directory the command starts in, when the host names it."""
    if tool_name in ("Bash", "PowerShell", "Monitor"):
        text = tool_input.get("command")
        if not isinstance(text, str) or not text.strip():
            return None
        # Only a command naming a gated tool is worth the parser; a parser
        # fault must not turn every `ls` into a permission prompt.
        gated = GATED_NAMES | {os.path.basename(entry) for entry in outward}
        if gated.isdisjoint(re.findall(r"[A-Za-z0-9_.-]+", text)):
            return None
        return judge(text, outward, load_shell_parser(), rehearsals, cwd or "")
    if tool_name == "Artifact":
        action = tool_input.get("action")
        if action in ARTIFACT_READ_ACTIONS:
            return None
        if action in ARTIFACT_REASONS:
            return ARTIFACT_REASONS[action]
        if action is None or action == "publish":
            return "Artifact publish puts this page on a claude.ai URL."
        # The prompt is the whole decision surface, so an unrecognized action
        # must name itself rather than borrow the publish wording.
        return (f"Artifact {action} is not a known read-only action and may "
                "change the published page.")
    return None


def judge(text, outward, shell, rehearsals, here, depth=0):
    """The reason to ask for a command line run from directory `here` (empty
    when unknown), following its `cd`s and the command it runs over ssh."""
    for command in shell.normalize(text):
        reason = rule_bash(command, shell)
        if reason:
            return reason
        words = shell.lead(command.words)
        remote = shell.ssh_remote(command.words)
        if remote and depth < 2:
            # The far host's working directory is its own; nothing here locates it.
            reason = judge(remote, outward, shell, rehearsals, "", depth + 1)
        elif words[:1] in (["cd"], ["pushd"]) and len(words) > 1 and "$" not in words[1]:
            here = os.path.normpath(os.path.join(here, os.path.expanduser(words[1])))
        elif outward:
            reason = rule_outward(words, outward, shell, rehearsals, here)
        if reason:
            return reason
    return None


def read_setting(repo, key, default):
    """A layered policy.json/config.json value, or the default when config.py
    is not beside this file — the toggle and the script list must never be the
    reason the guard cannot answer."""
    path = os.path.join(HERE, "config.py")
    if not os.path.exists(path):
        return default
    spec = importlib.util.spec_from_file_location("colloid_config", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.read(module.load(os.path.join(repo, ".agents", "config.json")), key, default)


def enabled(repo):
    return read_setting(repo, "hooks.guard_publish.enabled", True)


def outward_commands(repo):
    """Scripts this repository names as writing to a hosted system.

    `hooks.guard_publish.outward_commands` in the tracked `.agents/policy.json`
    (or the operator's `config.json`): repository-relative paths such as
    `scripts/deploy.sh`. A deploy that goes through a script never shows the
    guard a `vercel` or `gh` word, so the repository has to say which scripts
    those are. Matched by path suffix, so `./scripts/deploy.sh`,
    `bash scripts/deploy.sh`, and an absolute path all count.
    """
    # The two files are read separately and joined: the tracked list is a
    # floor an operator's config.json may extend and never shrink. Through the
    # ordinary layering a config.json naming one local script would replace
    # the repository's whole list, and every deploy it named would run silent.
    agents = os.path.join(repo, ".agents")
    path = os.path.join(HERE, "config.py")
    if not os.path.exists(path):
        return []
    spec = importlib.util.spec_from_file_location("colloid_config", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    listed = []
    for name in ("policy.json", "config.json"):
        document = module._read_json(os.path.join(agents, name))
        entries = module.read(document, "hooks.guard_publish.outward_commands", [])
        if isinstance(entries, list):
            listed.extend(entries)
    return cleaned_entries(listed)


def dry_run_commands(repo):
    """Listed scripts whose `--dry-run` rehearses instead of writing.

    `hooks.guard_publish.dry_run_commands`, read from the tracked
    `.agents/policy.json` alone: a script that ignores its arguments deploys
    with the flag appended, so the exemption is a claim about the script that
    the repository makes once, in review. An operator's config.json may add
    gates, never this exemption.
    """
    path = os.path.join(HERE, "config.py")
    if not os.path.exists(path):
        return []
    spec = importlib.util.spec_from_file_location("colloid_config", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    document = module._read_json(os.path.join(repo, ".agents", "policy.json"))
    entries = module.read(document, "hooks.guard_publish.dry_run_commands", [])
    return cleaned_entries(entries if isinstance(entries, list) else [])


def cleaned_entries(listed):
    seen = []
    for entry in listed:
        if isinstance(entry, str) and entry.strip():
            cleaned = entry.strip().lstrip("./")
            if cleaned not in seen:
                seen.append(cleaned)
    return seen


# A script run through one of these is named by the first operand, not the
# command word. Interpreters with major-version suffixes (python3.12) match by
# prefix below.
#
# The JavaScript package managers belong here for two distinct reasons, and a
# list carrying only `node` misses both: they run a file directly
# (`bun x.mjs`), and they run it behind a manifest alias (`npm run deploy`).
# The alias never resolves to a path, so a repository whose scripts are the
# documented way in must also list the alias itself in `outward_commands`.
INTERPRETERS = {
    "bash", "sh", "zsh", "dash", "source", ".", "python", "python3", "node", "uv",
    "bun", "bunx", "npm", "npx", "pnpm", "pnpx", "yarn", "deno",
    "tsx", "ts-node", "ts-node-transpile-only",
}


def outward_targets(words, shell):
    """Everything a command might be running: its command word, or an
    interpreter's operands.

    A runner does not hold the script in a fixed position -- `bun x.mjs` puts it
    first, `npx tsx x.mjs` puts a tool there instead, and `npm run deploy` names
    a manifest alias that is not a path at all. Returning every operand lets the
    caller match against the listed entries rather than guess the position;
    naming each intermediate tool instead would need a list that grows forever.

    A non-runner yields only its command word, which is what keeps `cat` and
    `grep` quiet: their operands are never inspected.
    """
    if not words:
        return []
    name = shell.base(words[0])
    if words[0] in INTERPRETERS or name in INTERPRETERS or name.startswith("python3."):
        targets = [w for w in words[1:] if not w.startswith("-") and w != "run"]
        if runner_width(words, shell):
            targets += [unversioned(t) for t in targets if unversioned(t) != t]
        return targets
    return [words[0]]


# The boolean vocabulary a dry-run flag's value is read in. A value outside
# both sets after `=` may mean off to the script, so it is a live run.
SWITCHED_ON = {"true", "t", "1", "yes", "y", "on"}
SWITCHED_OFF = {"false", "f", "0", "no", "n", "off", "", "disabled"}


def rehearsal(args):
    """True when the arguments ask for a dry run and every occurrence is on.

    A script reads the last occurrence, so any one that is not on may win.
    `--dry-run=<v>` is on only for a value in SWITCHED_ON. A separate word
    after a bare `--dry-run` is its value only when it is in the boolean
    vocabulary; any other word (`--dry-run production`) is an operand, so the
    flag was bare and on. A script that takes such a word as the flag's value
    is one the repository must not declare in dry_run_commands.
    """
    values = []
    for index, word in enumerate(args):
        if word == "--dry-run":
            following = args[index + 1].strip().lower() if index + 1 < len(args) else None
            values.append(following not in SWITCHED_OFF)
        elif word.startswith("--dry-run="):
            values.append(word.split("=", 1)[1].strip().lower() in SWITCHED_ON)
    return bool(values) and all(values)


def rule_outward(words, outward, shell, rehearsals=(), here=""):
    """`here` is the directory the command runs in, as far as the command's
    own `cd`s and the session's working directory say; empty when unknown."""
    for target in outward_targets(words, shell):
        normalized = target.lstrip("./")
        located = os.path.normpath(os.path.join(here, target)) if here else ""
        for entry in outward:
            # The listed path, or any path ending in it, as typed or as located
            # from `here`: a script that writes to production is worth an ask
            # under whatever path it was reached by. A bare file name alone
            # proves nothing — `.agents/provision.sh` is not `deploy/provision.sh`.
            # Reads never get here — the command word is `cat` or `grep`.
            if any(path == entry or path.endswith("/" + entry) for path in (normalized, located)):
                # Only --dry-run on a script declared to honour it rehearses.
                # `-n` is git's convention, not these scripts'.
                if entry in rehearsals and rehearsal(words[1:]):
                    return None
                return f"{entry} is listed by this repository as writing to a hosted system."
    return None


# Modes in which the host shows a permission prompt to a human. Anything else
# denies: a mode this guard does not know, or a payload without one, fails loud
# rather than running a push nobody saw.
PROMPTING_MODES = {"default", "acceptEdits", "plan"}

APPROVAL = (" AGENTS.md §External actions: outward mutations need in-session "
            "user approval.")
UNPROMPTED = (
    " This session's permission mode is {mode}, where the approval prompt does "
    "not reach the user, so the call is denied instead of asked. Do not retry "
    "or work around it. Report what you want to run and why, then stop: the "
    "user approves by switching the permission mode to default (Shift+Tab) and "
    "answering the prompt when you rerun the command, or by running it "
    "themselves with the ! prefix.")


def emit(reason, mode):
    if mode in PROMPTING_MODES:
        decision, tail = "ask", APPROVAL
    else:
        decision, tail = "deny", APPROVAL + UNPROMPTED.format(mode=mode or "unnamed")
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": reason + tail,
    }}))


# The publish-approval mod (.agents/claude/mods/publish-approval) asks the user
# in a dialog that reaches them in every mode, then writes this token for the
# one call they approved. The window bounds a token whose call some other hook
# denied before this guard read it. The token is a plain file: a process the
# model started earlier can read a pending call's id from the transcript and
# write one, which is within this guard's threat model (an honest mistake, not
# an adversary with a shell) and recorded as debt `publish-token-forgeable`.
APPROVAL_TOKEN = ".publish-approved-"
APPROVAL_WINDOW_SECONDS = 120
TOOL_USE_ID = re.compile(r"[A-Za-z0-9_-]{1,128}")


def approved_in_dialog(repo, tool_use_id, now):
    """Consume the dialog's token for this call: true once, while it is fresh.
    Expired tokens of other calls are removed on the way."""
    directory = os.path.join(repo, ".agents")
    try:
        names = [name for name in os.listdir(directory) if name.startswith(APPROVAL_TOKEN)]
    except FileNotFoundError:
        return False
    wanted = (APPROVAL_TOKEN + tool_use_id
              if isinstance(tool_use_id, str) and TOOL_USE_ID.fullmatch(tool_use_id) else None)
    approved = False
    for name in names:
        path = os.path.join(directory, name)
        try:
            fresh = now - os.path.getmtime(path) <= APPROVAL_WINDOW_SECONDS
            if name != wanted and fresh:
                continue
            os.remove(path)
        except FileNotFoundError:
            continue                   # another hook consumed or pruned it first
        except OSError as error:
            print(f"guard-publish: cannot read or remove {path} ({error}); it approves nothing",
                  file=sys.stderr)
            continue
        approved = approved or (name == wanted and fresh)
    return approved


def allow(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "permissionDecisionReason": reason,
    }}))


def refuse(reason):
    """Deny whatever the mode: the remedy is the agent's, not the user's."""
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))


def hosted_script(tool_name, tool_input, project, cwd, repo, rehearsals=()):
    """hosted-scripts.py's verdict for a shell command, or None. A committed
    script rehearses on the same terms as a listed one: declared in
    `rehearsals`, relative to `repo`, and run with a dry run switched on."""
    command = tool_input.get("command")
    if tool_name not in ("Bash", "PowerShell", "Monitor") or not isinstance(command, str):
        return None
    # Only a command naming a script file or an API host needs the parser.
    if not re.search(r"\.(?:py|mjs|cjs|js|mts|ts|sh|bash|zsh|rb)\b|\bapi\.|/auth/v1/adm[i]n", command):
        return None
    spec = importlib.util.spec_from_file_location("hosted_scripts", os.path.join(HERE, "hosted-scripts.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    declared = {os.path.realpath(os.path.join(repo, entry)) for entry in rehearsals}
    return module.verdict(command, project, load_shell_parser(), cwd,
                          lambda path, args: path in declared and rehearsal(args))


def main():
    # --force asks for the verdict whatever the toggle says, for a caller that
    # runs the command with no hook in front of it: the workloop controller
    # screening a --verify command it will later execute unattended. See the
    # same flag on guard-destructive.py.
    argv = [arg for arg in sys.argv[1:] if arg != "--force"]
    force = len(argv) != len(sys.argv) - 1
    repo = argv[0] if argv else os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
    if not force and not enabled(repo):
        return 0
    # A payload the guard cannot read carries no mode, and the visible signal
    # for a broken guard is the prompt, so these two paths ask.
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        emit("The publish guard could not parse the hook payload.", "default")
        return 0
    if not isinstance(payload, dict):
        emit("The publish guard received an invalid hook payload.", "default")
        return 0
    mode = payload.get("permission_mode")
    mode = mode if isinstance(mode, str) else ""
    tool_input = payload.get("tool_input")
    tool_name = payload.get("tool_name")
    if not isinstance(tool_name, str) or not tool_name or not isinstance(tool_input, dict):
        emit("The publish guard received an incomplete hook payload.", mode)
        return 0
    try:
        project = payload.get("project_dir")
        cwd = payload.get("cwd")
        rehearsals = dry_run_commands(repo)
        hosted = hosted_script(tool_name, tool_input, project if isinstance(project, str) and project else repo,
                               cwd if isinstance(cwd, str) and cwd else None, repo, rehearsals)
        if hosted and hosted[0] == "deny":
            refuse(hosted[1])
            return 0
        reason = hosted[1] if hosted else verdict(tool_name, tool_input, outward_commands(repo), rehearsals,
                                                  cwd if isinstance(cwd, str) and cwd else None)
    except Exception:
        emit("The publish guard could not evaluate this tool call.", mode)
        return 0
    if not reason:
        return 0
    # Only a rule's ask is answerable in the dialog. The hosted-write refusal
    # above and the could-not-evaluate paths never read a token.
    # debt: publish-token-forgeable -- with the mod switched off, no token is read.
    if (read_setting(repo, "hooks.publish_approval.enabled", True)
            and approved_in_dialog(repo, payload.get("tool_use_id"), time.time())):
        allow(reason + " The user approved this call in the publish-approval dialog.")
        return 0
    emit(reason, mode)
    return 0


if __name__ == "__main__":
    sys.exit(main())
