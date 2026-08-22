---
date: 2026-08-21
subject: How Claude Code 2.1.238 admits text into the system prompt, and which permission tier wins
kind: research
source: /Users/mac/.local/share/claude/versions/2.1.238 (shipped binary, read with `strings`); `claude --help`; four live `claude -p` runs on this machine
---

## Scope note

Two kinds of claim, graded apart. Readings of the shipped binary are `[P]` — it
is the implementation, not a description of one — but the build is minified, so
an interpretation error is possible and each claim below quotes the token it
rests on. Behavioral claims come from runs on one machine, one version, macOS
only, and are marked `[A]` with the command that produced them.

Not checked: Windows, Linux, the IDE extension, the desktop app, cloud
sessions, and any enterprise-managed configuration.

## Getting text into the system prompt

`[P]` There is no settings key for it. The Zod settings schema around
`outputStyle` carries 72 keys and `appendSystemPrompt` is not among them. Only
two routes exist: the `--append-system-prompt` / `--append-system-prompt-file`
command-line flags, and a policy helper (below).

`[P]` The assembled prompt puts an appended block last:

```js
systemPrompt: km([
  ...(typeof o === "string" ? [o] : Array.isArray(o) ? o : u),  // default prompt
  ...(m ? [m] : []),
  ...(h ? [h] : []),                                            // skills persistence
  ...(i ? [i] : []),                                            // appendSystemPrompt
])
```

An output style is a section *inside* the default prompt, so it competes with
the host's own instructions in mid-document. An appended block sits after all
of it. `[A]` Whether the trailing position changes adherence was not measured
here; only the ordering is established.

`[P]` A policy helper is the only route that reaches `appendSystemPrompt`
without a flag. `managed-settings.json` names an executable; its stdout must
parse as `{managedSettings?, claudeMd?, appendSystemPrompt?}`. The binary's own
validator rejects the key in a static payload, with the message: *"a static
payload is the managedSettings SUBTREE, not the helper's stdout envelope"*.
Helper entry fields are `path`, `script`, `interpreter`, `timeoutMs`,
`refreshIntervalMs`, `defaultSettings`; per-OS keys are `macos`, `linux`,
`windows`, `wsl`; inline `script` is rejected on the singular `policyHelper`
key. macOS reads `/Library/Application Support/ClaudeCode/`.

`[P]` No environment variable carries it. The only near matches in the binary
are `CLAUDE_CODE_ENABLE_APPEND_SUBAGENT_PROMPT`,
`CLAUDE_CODE_FORCE_MID_CONVERSATION_SYSTEM`, `CLAUDE_CODE_SIMPLE_SYSTEM_PROMPT`
and `CLAUDE_CODE_SYSTEM_PROMPT_GB_FEATURE`, none of which is an equivalent.

## Subagents do not inherit it

`[P]` Agent definitions carry their own `appendSystemPrompt` boolean, and
exactly one definition in the binary sets it true — the built-in `claude`
catch-all. A separate `appendSubagentSystemPrompt` option exists and is not
exposed by `claude --help`, which lists only `--system-prompt`,
`--append-system-prompt` and `--exclude-dynamic-system-prompt-sections`.

`[P]` Nineteen internal call sites hardcode `hasAppendSystemPrompt:!1` — web
fetch apply, the web search tool, compaction. Those are utility calls, not the
agent loop.

## `ask` outranks `allow`, measured

`[A]` A user-tier `permissions.ask` rule beat a project-tier `allow` rule.
Method: a scratch git repository whose `.claude/settings.local.json` allowed
both `Bash(git push:*)` and the exact `Bash(git push origin main)`, with
`Bash(git push:*)` in `~/.claude/settings.json` `permissions.ask`; then
`claude -p "Run this exact single command ...: git push origin main"`. The
command did not execute. The harness returned: *"Claude requested permissions
to use Bash, but you haven't granted it yet."*

`[A]` A user-tier rule set applies with no project configuration at all. In a
scratch repository with no scaffold, a session quoted a `~/.claude`
output-style rule back verbatim, and `git push origin main` was refused before
execution.

`[A]` In `-p` (headless) mode an `ask` cannot prompt, so it resolves as a
refusal. This makes `ask` rules testable headlessly, and it means a headless
automation that needs a gated command will fail rather than hang.

`[A]` A compound command is evaluated per part: `git push origin main 2>&1;
echo ...` was refused with *"This Bash command contains multiple operations"*
even where the bare command had an allow rule. Do not conclude a rule failed
from a compound-command refusal.

## Could not verify

- Whether a **hook** `permissionDecision: "ask"` beats an `allow` rule. Only
  the declarative rule was measured. The hook path remains open.
- Whether the `Artifact` tool accepts a permission specifier
  (`Artifact(publish:*)` style) or only the bare tool name.
- Which reason string is displayed when a hook `ask` and a settings `ask` match
  the same call.
