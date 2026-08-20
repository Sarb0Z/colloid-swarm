#!/usr/bin/env python3
"""Decide whether a tool call is an outward mutation that needs user approval.

Input  (stdin JSON): {"tool_name": "...", "tool_input": {...}}
Output: exit 0 always. Stdout carries the Claude Code PreToolUse envelope
{"hookSpecificOutput": {"permissionDecision": "ask", ...}} in two cases: a rule
fired, or the guard could not evaluate a call (unreadable payload, evaluator
error) — it fails closed. Silence otherwise.

This is the enforcement half of `AGENTS.md` §External actions: an outward
mutation requires user approval in the current session. "Ask" is the whole
point — a publish is legitimate exactly when the user says yes, so the guard
forces the dialog rather than denying. Contrast guard-destructive, which
denies, because no mid-session answer legitimizes `rm -rf /`.

Scope: Bash publish/push/deploy commands and the Artifact tool's publish
action. Other outward channels (remote MCP writes, cross-session messages)
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
# `vercel` is special-cased below because its bare invocation deploys.
DEPLOY_VERBS = {
    "vercel": {"deploy", "promote", "rollback", "alias", "rm", "remove", "redeploy"},
    "netlify": {"deploy"},
    "wrangler": {"deploy", "publish"},
    "firebase": {"deploy"},
    "fly": {"deploy"},
    "flyctl": {"deploy"},
    "railway": {"up", "deploy"},
}
RUNNERS = {"npx", "pnpx", "bunx"}
RUNNER_VALUE_FLAGS = {"-p", "--package"}
RUNNER_CALL_FLAGS = {"-c", "--call"}      # npx -c "<shell>" runs its value
CONTROL_KEYWORDS = {"do", "then", "else", "elif", "if", "while", "until", "time", "{"}
# Names a command must mention before the shell parser is worth loading.
GATED_NAMES = {"git", "gh", "docker"} | NPM_PUBLISHERS | set(DEPLOY_VERBS) | RUNNERS
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
    if name in DEPLOY_VERBS:
        if rest and rest[0] in DEPLOY_VERBS[name]:
            return f"{name} {rest[0]} deploys or mutates the hosted project."
    return None


def verdict(tool_name, tool_input):
    """The reason to ask, or None."""
    if tool_name in ("Bash", "PowerShell", "Monitor"):
        text = tool_input.get("command")
        if not isinstance(text, str) or not text.strip():
            return None
        # Only a command naming a gated tool is worth the parser; a parser
        # fault must not turn every `ls` into a permission prompt.
        if GATED_NAMES.isdisjoint(re.findall(r"[A-Za-z0-9_.-]+", text)):
            return None
        shell = load_shell_parser()
        for command in shell.normalize(text):
            reason = rule_bash(command, shell)
            if reason:
                return reason
        return None
    if tool_name == "Artifact":
        if tool_input.get("action") == "list":
            return None
        if isinstance(tool_input.get("file_path"), str):
            return "Artifact publish puts this page on a claude.ai URL."
    return None


def enabled(repo):
    try:
        with open(os.path.join(repo, ".agents", "config.json"), encoding="utf-8") as config:
            settings = json.load(config)
    except (OSError, ValueError):
        return True
    node = settings
    for name in ("hooks", "guard_publish", "enabled"):
        if not isinstance(node, dict) or name not in node:
            return True
        node = node[name]
    return node is not False


def emit_ask(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "ask",
        "permissionDecisionReason":
            reason + " AGENTS.md §External actions: outward mutations need "
            "in-session user approval.",
    }}))


def main():
    repo = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
    if not enabled(repo):
        return 0
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        emit_ask("The publish guard could not parse the hook payload.")
        return 0
    if not isinstance(payload, dict):
        emit_ask("The publish guard received an invalid hook payload.")
        return 0
    tool_input = payload.get("tool_input")
    tool_name = payload.get("tool_name")
    if not isinstance(tool_name, str) or not tool_name or not isinstance(tool_input, dict):
        emit_ask("The publish guard received an incomplete hook payload.")
        return 0
    try:
        reason = verdict(tool_name, tool_input)
    except Exception:
        emit_ask("The publish guard could not evaluate this tool call.")
        return 0
    if not reason:
        return 0
    emit_ask(reason)
    return 0


if __name__ == "__main__":
    sys.exit(main())
