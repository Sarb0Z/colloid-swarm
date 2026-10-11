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

Scope: Bash publish/push/deploy commands; migration, seed and schema-push
commands whose database is hosted (database-target.py resolves the target);
and every Artifact action that reaches claude.ai — publishing a page, adding or
deleting one of its files, and posting or resolving a comment thread.
Other outward channels (remote MCP writes, cross-session messages)
keep their own native prompts. The threat model is an honest mistake by the
model — a harness bias toward publishing — not an adversary with a shell.
"""

import importlib.util
import json
import os
import re
import shlex
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
                 "branches create", "branches delete", "branches update",
                 "branches pause", "branches unpause",
                 "config push", "functions delete", "sso add", "sso remove", "sso update",
                 "domains create", "domains reverify", "domains activate", "domains delete",
                 "postgres-config update", "postgres-config delete",
                 "network-restrictions update", "vanity-subdomains activate",
                 "vanity-subdomains delete", "ssl-enforcement update", "network-bans remove",
                 "backups restore", "encryption update-root-key", "orgs create",
                 "notebooks push"},
    "terraform": {"apply", "destroy", "import", "refresh", "taint", "untaint", "force-unlock",
                  "state rm", "state mv", "state push", "state replace-provider",
                  "workspace delete"},
}
DEPLOY_VERBS["tofu"] = DEPLOY_VERBS["terraform"]
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
# `pnpm <word>` and `yarn <word>` run a package binary when the word is not one
# of the manager's own commands (a script of that name runs first, and is
# judged separately through package.json). From `pnpm --help` (10) and
# `yarn --help` (4, plus classic's commands).
PNPM_COMMANDS = {"add", "i", "install", "it", "install-test", "up", "update", "upgrade", "remove",
                 "rm", "un", "uninstall", "link", "ln", "unlink", "import", "rebuild", "rb",
                 "prune", "fetch", "patch", "patch-commit", "patch-remove", "audit", "list", "ls",
                 "ll", "la", "outdated", "why", "licenses", "run", "run-script", "exec", "test",
                 "t", "tst", "start", "stop", "restart", "create", "dlx", "init", "publish",
                 "pack", "deploy", "store", "env", "setup", "config", "c", "get", "set", "root",
                 "bin", "server", "recursive", "multi", "m", "help", "cat-file", "cat-index",
                 "find-hash", "doctor", "self-update", "approve-builds", "ignored-builds", "sbom",
                 "version", "login", "logout", "whoami", "dedupe", "docs", "home", "owner",
                 "search", "view", "info", "show", "unpublish", "dist-tag", "ping", "cache"}
YARN_COMMANDS = {"add", "bin", "cache", "config", "constraints", "dedupe", "dlx", "exec",
                 "explain", "info", "init", "install", "link", "node", "npm", "pack", "patch",
                 "patch-commit", "plugin", "rebuild", "remove", "run", "search", "set", "stage",
                 "unlink", "unplug", "up", "upgrade", "upgrade-interactive", "version", "why",
                 "workspace", "workspaces", "publish", "login", "logout", "test", "start",
                 "global", "list", "outdated", "audit", "autoclean", "check", "create",
                 "generate-lock-entry", "import", "licenses", "owner", "policies", "tag",
                 "team", "help", "sdks", "unpublish"}
# Options the managers read before their command, with a separate value:
# `pnpm --filter api exec ...`, `yarn --cwd api ...`.
MANAGER_VALUED = {"pnpm": {"--filter", "-F", "--filter-prod", "-C", "--dir", "--workspace-dir",
                           "--reporter", "--loglevel", "--test-pattern",
                           "--changed-files-ignore-pattern"},
                  "yarn": {"--cwd"},
                  "bun": {"--cwd", "-r", "--preload", "-c", "--config", "--env-file",
                          "--tsconfig-override", "--main-fields", "--conditions"}}
# `bun <word>` runs a binary or file when the word is not one of bun's own
# commands (`bun --help`, 1.2).
BUN_COMMANDS = {"run", "test", "x", "repl", "exec", "install", "i", "add", "a", "remove", "rm",
                "update", "outdated", "link", "unlink", "publish", "patch", "patch-commit", "pm",
                "info", "init", "create", "c", "upgrade", "build", "audit", "why", "help",
                "completions", "discord", "feedback", "unpublish"}
MANAGER_COMMANDS = {"pnpm": PNPM_COMMANDS, "yarn": YARN_COMMANDS, "bun": BUN_COMMANDS}
# Commands that name the binary to run as their next word.
MANAGER_RUNS = {"pnpm": {"dlx", "exec"}, "yarn": {"dlx", "exec"}, "bun": {"x", "run"}}
# Node options that take a separate value; `--env-file` also names a file the
# process loads, which the database rule reads.
NODE_VALUED = {"-r", "--require", "--import", "--env-file", "--env-file-if-exists", "--loader",
               "--experimental-loader", "-C", "--conditions", "--input-type", "--title"}
ENV_FILE_FLAGS = {"--env-file", "--env-file-if-exists"}
# Interpreters whose `-m <module>` runs a tool by its module name.
MODULE_RUNNERS = re.compile(r"python(?:3(?:\.\d+)?)?")
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
# Tools that apply migrations, seeds or schema pushes. Their verbs and the
# database each reaches are database-target.py's; the names live here because
# the gate below must not load that module for every command. A test holds the
# two lists equal.
DATABASE_NAMES = {"prisma", "alembic", "rails", "rake", "typeorm", "typeorm-ts-node-commonjs",
                  "typeorm-ts-node-esm", "drizzle-kit", "knex", "sequelize", "sequelize-cli",
                  "manage.py", "django-admin", "django", "flask", "mongosh", "mongo",
                  "mongorestore", "mongoimport"}
GATED_NAMES = ({"git", "gh", "docker", "gcloud", "aws"} | NPM_PUBLISHERS | set(DEPLOY_VERBS)
               | set(REMOTE_FLAG_VERBS) | RUNNERS | DATABASE_NAMES)
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
    """How many words name a package runner at the start: `npx` is one;
    `npm exec`, `bun x` and `python -m` are two; `pnpm` and `yarn` count their
    own options too, then `dlx`, `exec` or a binary that is not one of their
    commands (`pnpm --filter api exec`, `yarn workspace api prisma`); anything
    else none."""
    name = shell.base(words[0]) if words else ""
    following = words[1] if len(words) > 1 else ""
    if name in RUNNERS:
        return 1
    if (name == "npm" and following in ("exec", "x")) or (MODULE_RUNNERS.fullmatch(name) and following == "-m"):
        return 2
    if name not in MANAGER_COMMANDS:
        return 0
    index = 1
    while index < len(words) and words[index].startswith("-"):
        index += 2 if words[index] in MANAGER_VALUED[name] else 1
    # `yarn workspace <name> <command>` runs the command in that workspace.
    if name == "yarn" and words[index:index + 1] == ["workspace"] and index + 2 < len(words):
        index += 2
    command = words[index] if index < len(words) else ""
    if command in MANAGER_RUNS[name]:
        return index + 1
    return index if command and command not in MANAGER_COMMANDS[name] else 0


def env_files(words, stripped):
    """Record each `--env-file` a runner or node is given, as a file the
    command loads."""
    for index, word in enumerate(words):
        flag, _, value = word.partition("=")
        if flag in ENV_FILE_FLAGS:
            value = value or (words[index + 1] if index + 1 < len(words) else "")
            if value:
                stripped.append(("env-file", [value]))


def node_tool(words, shell, stripped):
    """`node [options] node_modules/.bin/<tool> ...` runs that tool, and so does
    Prisma's own entry point; the words as the tool's, else None."""
    if not words or shell.base(words[0]) != "node":
        return None
    index = 1
    while index < len(words) and words[index].startswith("-"):
        index += 2 if words[index] in NODE_VALUED else 1
    if index >= len(words):
        return None
    path = words[index]
    if "/.bin/" in path:
        tool = os.path.basename(path)
    elif path.endswith("prisma/build/index.js"):
        tool = "prisma"
    else:
        return None
    env_files(words[1:index], stripped)
    return [tool] + words[index + 1:]


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


# Runners that start a command inside a hosting platform's environment, or
# with secrets a manager injects: its database is the platform's, whatever
# this checkout's env files say. `fly ssh console` takes its command as the
# value of `-C`; the others take it as their trailing words.
PLATFORM_RUNNERS = {"heroku": "run", "railway": "run", "doppler": "run", "infisical": "run",
                    "op": "run", "aws-vault": "exec", "kubectl": "exec", "fly": "ssh", "flyctl": "ssh"}
PLATFORM_KEYS = {(name, (verb,)) for name, verb in PLATFORM_RUNNERS.items()}


def platform_reason(name, rest, shell, place):
    """The ask for a migration a platform runner starts, or None when what it
    runs is not one. The runner's own options are not modelled: every suffix
    of its words is tried as the command, and only a migration verb counts."""
    label = f"{name} {rest[0]}"
    if name in ("fly", "flyctl"):
        bodies = [value for value in (positional_value(rest, ("-C", "--command")),) if value]
        commands = [command.words for body in bodies for command in shell.normalize(body)]
        label += " console -C"
    else:
        after = rest[1:]
        commands = [after[after.index("--") + 1:]] if "--" in after else \
            [after[index:] for index in range(len(after))]
    target = None
    for words in commands:
        stripped = []
        inner, _ = unwrap(words, shell, stripped, place)
        if not inner:
            continue
        target = target or database_target()
        reason = target.verdict(shell.base(inner[0]), inner[1:], stripped, [], "", "", "",
                                shell.base, platform=label)
        if reason:
            return reason
    return None


def positional_value(words, flags):
    """The value of the first of `flags`, given apart or after `=`."""
    for index, word in enumerate(words):
        if word in flags and index + 1 < len(words):
            return words[index + 1]
        flag, _, value = word.partition("=")
        if flag in flags and value:
            return value
    return None


def unwrap(words, shell, stripped, place):
    """(the words of the tool that runs, a reason) past every wrapper and
    runner, recording the stripped prefix in `stripped`.

    `npx <tool> ...` runs the tool; drop the runner and its own options so the
    tool's rule sees the tool's arguments untouched, then any wrapper the
    runner itself runs (`npx dotenv -e f -- prisma`). `npx -c "<shell>"` runs
    its value as a command, so that string is judged on its own."""
    words = shell.lead(words, stripped)
    while True:
        while words and words[0] in shell.CONTROL_KEYWORDS:
            words = shell.lead(words[1:], stripped)
        width = runner_width(words, shell)
        if width:
            env_files(words[1:width], stripped)
            words = words[width:]
            while words and words[0].startswith("-"):
                if words[0] in RUNNER_CALL_FLAGS:
                    for inner in shell.normalize(words[1] if len(words) > 1 else ""):
                        reason = rule_bash(inner, shell, place)
                        if reason:
                            return [], reason
                    words = words[2:]
                else:
                    env_files(words[:2], stripped)
                    words = words[2:] if words[0] in shell.RUNNER_VALUED else words[1:]
            words = [unversioned(words[0])] + words[1:] if words else words
            words = shell.lead(words, stripped)
            continue
        tool = node_tool(words, shell, stripped)
        if tool:
            words = shell.lead(tool, stripped)
            continue
        return words, None


def rule_bash(command, shell, place=None):
    """The reason to ask for one command. `place` locates it for the rules
    that read files: {"here", "repo", "remote", "earlier"}, where `earlier`
    holds the word lists of the command line's segments before this one."""
    place = place or {"here": "", "repo": "", "remote": "", "earlier": [], "lost": False}
    stripped = []
    words, reason = unwrap(command.words, shell, stripped, place)
    if reason or not words:
        return reason
    name, rest = shell.base(words[0]), words[1:]
    # `eval '<literal>'` runs its literal as a command line; an eval of a
    # computed string is the database rule's concern for what follows it.
    if name == "eval" and rest and not any("$" in word or "`" in word for word in rest):
        for inner in shell.normalize(" ".join(rest)):
            reason = rule_bash(inner, shell, place)
            if reason:
                return reason
        return None

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
        # `-R/--repo <owner/repo>` may come before the area: `gh -R o/r pr merge 1`.
        area = rest
        while area and area[0].startswith(("-R", "--repo")):
            area = area[1:] if area[0] not in ("-R", "--repo") else area[2:]
        if len(area) >= 2 and area[0] in GH_MUTATING_AREAS and area[1] in GH_MUTATING_VERBS:
            return f"gh {area[0]} {area[1]} mutates GitHub state."
        if area and area[0] == "api":
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
    if name in DATABASE_NAMES or (name.startswith("python") and rest[:1]
                                  and shell.base(rest[0]) == "manage.py"):
        reason = database_target().verdict(name, rest, stripped, place["earlier"], place["here"],
                                           place["repo"], place["remote"], shell.base,
                                           lost=place.get("lost", False))
        if reason:
            return reason
    if (name, tuple(rest[:1])) in PLATFORM_KEYS and (reason := platform_reason(name, rest, shell, place)):
        return reason
    if name in DEPLOY_VERBS or name in REMOTE_FLAG_VERBS:
        # Longest phrase first, so a two-word verb is not shadowed by its noun.
        positional = positionals(rest, VALUE_FLAGS.get(name, ()))
        phrases = [" ".join(positional[:width]) for width in (2, 1) if positional[:width]]
        for phrase in phrases:
            if phrase in DEPLOY_VERBS.get(name, set()):
                return f"{name} {phrase} deploys or mutates the hosted project."
        verbs, flags = REMOTE_FLAG_VERBS.get(name, (set(), set()))
        for phrase in phrases:
            if phrase in verbs and any(word.split("=")[0] in flags for word in rest):
                return f"{name} {phrase} against the linked project mutates the hosted database."
    return None


def verdict(tool_name, tool_input, outward=(), rehearsals=(), cwd=None, repo=""):
    """The reason to ask, or None. `outward` is the repository's script list;
    `rehearsals` names the entries whose --dry-run really rehearses; `cwd` is
    the directory the command starts in, when the host names it; `repo` the
    repository root, outside which no env file is read."""
    if tool_name in ("Bash", "PowerShell", "Monitor"):
        text = tool_input.get("command")
        if not isinstance(text, str) or not text.strip():
            return None
        # Only a command naming a gated tool is worth the parser; a parser
        # fault must not turn every `ls` into a permission prompt.
        gated = GATED_NAMES | {os.path.basename(entry) for entry in outward}
        if gated.isdisjoint(re.findall(r"[A-Za-z0-9_.-]+", text)):
            return None
        return judge(text, outward, load_shell_parser(), rehearsals, cwd or "", repo=repo or "")
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


def judge(text, outward, shell, rehearsals, here, depth=0, remote=False, repo="", earlier=()):
    """The reason to ask for a command line run from directory `here` (empty
    when unknown), following its `cd`s, the package.json scripts it runs, and
    the command it runs over ssh. `remote` marks a line the far host runs,
    whose package.json scripts and env files are that host's and unreadable
    from here. `earlier` carries the segments that ran before this line, as a
    package.json script inherits what its caller exported."""
    earlier, lost = list(earlier), False
    for command in shell.normalize(text):
        place = {"here": here, "repo": repo, "remote": remote, "earlier": earlier, "lost": lost}
        reason = rule_bash(command, shell, place)
        if reason:
            return reason
        words = shell.lead(command.words)
        if not remote and os.path.isabs(here) and depth < 3:
            reason = rule_script(words, outward, shell, rehearsals, here, depth, repo, earlier)
            if reason:
                return reason
        earlier.append(command.words)
        far = shell.ssh_remote(command.words)
        if far and depth < 2:
            # The far host's working directory is its own; nothing here locates it.
            host = shell.ssh_target(command.words) or "the remote host"
            reason = judge(far, outward, shell, rehearsals, "", depth + 1, remote=host, repo=repo)
        elif words[:1] in (["cd"], ["pushd"]) and len(words) > 1 and "$" not in words[1] \
                and "`" not in words[1] and words[1] != "-":
            here = os.path.normpath(os.path.join(here, os.path.expanduser(words[1])))
        elif words[:1] in (["cd"], ["pushd"], ["popd"]):
            # `cd $DIR`, `cd -`, a bare `cd` and `popd` go where the guard
            # cannot follow, so no env file it would read there is known.
            lost = True
        elif outward:
            reason = rule_outward(words, outward, shell, rehearsals, here)
        if reason:
            return reason
    return None


SCRIPT_RUN_VERBS = {"run", "run-script", "rum", "urn"}
# npm runs these scripts by their own name; the other managers run any script
# named in place of a subcommand.
NPM_SCRIPT_VERBS = {"start", "test", "stop", "restart"}


def script_call(words, shell):
    """(manager, script name, arguments) when the words run a package.json
    script, else None. The arguments are what the manager appends to it."""
    manager = shell.base(words[0]) if words else ""
    if manager not in NPM_PUBLISHERS:
        return None
    rest = words[1:]
    while rest and rest[0].startswith("-"):
        rest = rest[1:]
    if rest[:1] and rest[0] in SCRIPT_RUN_VERBS:
        rest = rest[1:]
    elif not rest or (manager == "npm" and rest[0] not in NPM_SCRIPT_VERBS):
        return None
    if not rest:
        return None
    args = rest[1:]
    return manager, rest[0], args[1:] if args[:1] == ["--"] else args


def package_scripts(here):
    """(directory, scripts) of the nearest package.json at or above `here`,
    the one a package manager reads; (None, {}) when there is none."""
    directory = here
    while True:
        path = os.path.join(directory, "package.json")
        if os.path.isfile(path):
            with open(path, encoding="utf-8-sig") as handle:
                document = json.load(handle)
            scripts = document.get("scripts") if isinstance(document, dict) else None
            return directory, scripts if isinstance(scripts, dict) else {}
        parent = os.path.dirname(directory)
        if parent == directory:
            return None, {}
        directory = parent


def rule_script(words, outward, shell, rehearsals, here, depth, repo="", earlier=()):
    """Judge the command a package.json script runs, with the arguments typed
    after its name appended as the manager appends them, and its pre- and
    post- hooks. Whether a manager runs those depends on its version and
    settings, which this guard cannot see, so they are read for every one."""
    call = script_call(words, shell)
    if not call:
        return None
    manager, name, args = call
    # The repository's declaration that this alias rehearses covers its body.
    if name in rehearsals and rehearsal(args):
        return None
    root, scripts = package_scripts(here)
    for script in (name, f"pre{name}", f"post{name}"):
        body = scripts.get(script)
        if not isinstance(body, str):
            continue
        line = body + "".join(" " + shlex.quote(arg) for arg in args) if script == name else body
        reason = judge(line, outward, shell, rehearsals, root, depth + 1, repo=repo, earlier=earlier)
        if reason:
            return f"The package.json script {script} runs `{body}`: {reason}"
    return None


_config = []


def config_module():
    """config.py, loaded once per process so each file it reads is parsed and
    reported once; None when it is not beside this file — the toggle and the
    script list must never be the reason the guard cannot answer."""
    if not _config:
        path = os.path.join(HERE, "config.py")
        module = None
        if os.path.exists(path):
            spec = importlib.util.spec_from_file_location("colloid_config", path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
        _config.append(module)
    return _config[0]


def read_setting(repo, key, default):
    """A layered policy.json/config.json value, or the default without config.py."""
    module = config_module()
    if module is None:
        return default
    return module.read(module.load(os.path.join(repo, ".agents", "config.json")), key, default)


def unparsed(repo):
    """The repository-relative policy and config files that do not parse."""
    module = config_module()
    if module is None:
        return []
    return [os.path.relpath(path, repo)
            for path in module.unparsed(os.path.join(repo, ".agents", "config.json"))]


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
    module = config_module()
    if module is None:
        return []
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
    module = config_module()
    if module is None:
        return []
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


SCRIPT_FILE = re.compile(r"\.(?:py|mjs|cjs|js|mts|cts|ts|sh|bash|zsh|rb)$")


def repository_script(word, repo):
    """True when a word names a script file in the repository: a relative path
    or a script file name, or an absolute path inside the repository."""
    path = os.path.expanduser(word)
    if os.path.isabs(path):
        return path.startswith(repo.rstrip("/") + "/")
    return "/" in path or bool(SCRIPT_FILE.search(path))


def could_run_outward(text, shell, repo):
    """True when a command line could run a script the repository lists as
    outward, with no list to check it against: a package-manager script run, an
    interpreter running a repository script, or a repository script run by path."""
    for command in shell.normalize(text):
        words = shell.lead(command.words)
        while words and words[0] in shell.CONTROL_KEYWORDS:
            words = shell.lead(words[1:])
        if not words:
            continue
        if script_call(words, shell):
            return True
        name = shell.base(words[0])
        if words[0] in INTERPRETERS or name in INTERPRETERS or name.startswith("python3."):
            if any(repository_script(target, repo) for target in outward_targets(words, shell)):
                return True
        elif "/" in words[0] and repository_script(words[0], repo):
            return True
    return False


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
    " This session's permission mode ({mode}) shows the user no approval "
    "prompt, so the call is denied instead of asked. Do not retry "
    "or work around it. Report what you want to run and why, then stop: the "
    "user approves either by switching to default mode (Shift+Tab) and "
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


def database_target():
    """database-target.py, loaded only for a command naming a migration tool."""
    spec = importlib.util.spec_from_file_location("database_target", os.path.join(HERE, "database-target.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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
        start = cwd if isinstance(cwd, str) and cwd else project if isinstance(project, str) and project else repo
        reason = hosted[1] if hosted else verdict(tool_name, tool_input, outward_commands(repo), rehearsals, start, repo)
        broken = unparsed(repo)
        command = tool_input.get("command")
        if broken and tool_name in ("Bash", "PowerShell", "Monitor") and isinstance(command, str):
            if not reason and could_run_outward(command, load_shell_parser(), repo):
                reason = "This command could run a script the repository lists as outward."
            if reason:
                names = " and ".join(broken)
                reason += (f" {names} does not parse, so the guard cannot read which scripts "
                           f"are outward and asks on every command that could run one. "
                           f"Fix the JSON in {names} to restore the list.")
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
