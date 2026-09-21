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
user never saw is not approved.

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
# Verbs that are local by default and reach the hosted project only when a flag
# says so. Gating them unconditionally would ask on every `supabase db reset`,
# which is how a developer rebuilds the Docker stack several times an hour; an
# ask that fires on routine local work is one people learn to dismiss.
REMOTE_FLAG_VERBS = {
    "supabase": ({"db reset", "migration up", "migration repair", "db dump"},
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
RUNNER_VALUE_FLAGS = {"-p", "--package"}
RUNNER_CALL_FLAGS = {"-c", "--call"}      # npx -c "<shell>" runs its value
CONTROL_KEYWORDS = {"do", "then", "else", "elif", "if", "while", "until", "time", "{"}
# Names a command must mention before the shell parser is worth loading.
GATED_NAMES = ({"git", "gh", "docker"} | NPM_PUBLISHERS | set(DEPLOY_VERBS)
               | set(REMOTE_FLAG_VERBS) | RUNNERS)
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


def rule_bash(command, shell):
    words = shell.lead(command.words)
    while words and words[0] in CONTROL_KEYWORDS:
        words = shell.lead(words[1:])
    # `npx <tool> ...` runs the tool; drop the runner and its own options so
    # the tool's rule sees the tool's arguments untouched. `npx -c "<shell>"`
    # runs its value as a command, so that string is judged on its own.
    while words and shell.base(words[0]) in RUNNERS:
        words = words[1:]
        while words and words[0].startswith("-"):
            if words[0] in RUNNER_CALL_FLAGS:
                for inner in shell.normalize(words[1] if len(words) > 1 else ""):
                    reason = rule_bash(inner, shell)
                    if reason:
                        return reason
                words = words[2:]
            else:
                words = words[2:] if words[0] in RUNNER_VALUE_FLAGS else words[1:]
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
    if name in DEPLOY_VERBS or name in REMOTE_FLAG_VERBS:
        # Longest phrase first, so a two-word verb is not shadowed by its noun.
        positional = [word for word in rest if not word.startswith("-")]
        phrases = [" ".join(positional[:width]) for width in (2, 1) if positional[:width]]
        for phrase in phrases:
            if phrase in DEPLOY_VERBS.get(name, ()):
                return f"{name} {phrase} deploys or mutates the hosted project."
        verbs, flags = REMOTE_FLAG_VERBS.get(name, (set(), set()))
        for phrase in phrases:
            if phrase in verbs and any(word.split("=")[0] in flags for word in rest):
                return f"{name} {phrase} against the linked project mutates the hosted database."
    return None


def verdict(tool_name, tool_input, outward=()):
    """The reason to ask, or None. `outward` is the repository's script list."""
    if tool_name in ("Bash", "PowerShell", "Monitor"):
        text = tool_input.get("command")
        if not isinstance(text, str) or not text.strip():
            return None
        # Only a command naming a gated tool is worth the parser; a parser
        # fault must not turn every `ls` into a permission prompt.
        gated = GATED_NAMES | {os.path.basename(entry) for entry in outward}
        if gated.isdisjoint(re.findall(r"[A-Za-z0-9_.-]+", text)):
            return None
        shell = load_shell_parser()
        for command in shell.normalize(text):
            reason = rule_bash(command, shell)
            if reason:
                return reason
            if outward:
                reason = rule_outward(shell.lead(command.words), outward, shell)
                if reason:
                    return reason
        return None
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
        return [w for w in words[1:] if not w.startswith("-") and w != "run"]
    return [words[0]]


def rule_outward(words, outward, shell):
    for target in outward_targets(words, shell):
        normalized = target.lstrip("./")
        for entry in outward:
            # The listed path, any path ending in it, or its bare name after a
            # `cd`: a script that writes to production is worth an ask under
            # whatever path it was reached by. Reads never get here — the command
            # word is `cat` or `grep`, not the script.
            if (normalized == entry or normalized.endswith("/" + entry)
                    or os.path.basename(normalized) == os.path.basename(entry)):
                # Only the literal --dry-run is a rehearsal. `-n` is git's
                # convention, not these scripts': deploy.sh ignores it and deploys.
                if "--dry-run" in words[1:]:
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
        reason = verdict(tool_name, tool_input, outward_commands(repo))
    except Exception:
        emit("The publish guard could not evaluate this tool call.", mode)
        return 0
    if not reason:
        return 0
    emit(reason, mode)
    return 0


if __name__ == "__main__":
    sys.exit(main())
