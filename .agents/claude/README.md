# Claude adapter

`.claude/settings.json` and `.claude/hooks/*` link here. The adapter normalizes
Claude hook payloads and passes JSON on stdin to engine-neutral policies under
`.agents/hooks/policy/`.

| Policy | Normalized fields |
| --- | --- |
| `guard-destructive.sh` | `project_dir`, `command` |
| `guard-publish.sh` | `project_dir`, `tool_name`, `tool_input` |
| `post-edit-check.sh` | `project_dir`, `files` |
| `sources-capture.sh` | `project_dir`, `agent`, `tool_name`, `tool_input` |
| `session-start.sh` | `project_dir`, `source`, `session_id`, `transcript_path` |
| `session-wrap.sh` | `project_dir`, `stop_hook_active`, `session_id`, `transcript_path` |
| `stop-investigate.sh` | `project_dir`, `stop_hook_active`, `last_assistant_message`, `transcript_path` |
| `research-prime.sh` | `project_dir`, `prompt` |
| `done-prime.sh` | `project_dir`, `prompt` |
| `ui-gate.sh` | `project_dir`, `event`, `session_id`, `tool_name`, `files`, `stop_hook_active` |
| `pre-compact.sh` | `project_dir`, `trigger` |
<!-- colloid-only -->
| `genome-inject.sh` | `project_dir`, `subagent_type` |
<!-- /colloid-only -->

`.claude/output-styles/colloid.md` links to `output-style.md`, and `settings.json` selects it with `outputStyle`. With `keep-coding-instructions: true` it appends to the system prompt of the main conversation without replacing the host's coding instructions; subagents do not receive it. `.agents/codex/config.toml` mirrors the same text as `developer_instructions`, and `test-codex.sh` fails when the two drift. An operator who wants another style sets `outputStyle` in `.claude/settings.local.json`.

## Gating outward mutations

Two layers enforce `AGENTS.md` §External actions.

`guard-publish.sh` parses the shell command. It catches shapes that a prefix
rule cannot state, such as `git -C dir push`, `npx -p vercel vercel --prod`,
and a bare `vercel` that deploys with no verb. `config.json` can disable this
hook. A host without an ask-equivalent PreToolUse decision cannot run it.

`settings.json` `permissions.ask` matches a command prefix. This layer outranks
an `allow` entry and applies to subagent tool calls. It holds the plain forms
listed as `PLAIN_FORMS` in `test-guard-publish.py` when `guard_publish` is
disabled. It does not hold the shapes in the paragraph above. Do not read the
two layers as equivalent: with the hook off, coverage is the listed prefixes
only.

`test-guard-publish.py` asserts both directions. Every rule must name a command
that `guard-publish.sh` also treats as an outward mutation, so no rule prompts
on a benign command. Every plain form must have a rule, so disabling the hook
cannot silently drop one.

The `Artifact` rule names the whole tool, so the settings layer prompts on the
read actions that `ARTIFACT_READ_ACTIONS` lets through. On this host the hook's
read set therefore changes nothing for Artifact. That set still governs a host
that runs the hook without the settings layer, and it decides the reason text
the prompt shows.

`gh api` carries no rule. A prefix rule cannot separate a read from a write, and
a prompt on every read teaches the operator to approve without reading. The
parser inspects the method and gates the writes.

Both layers stop at this repository. To cover every session on a machine, use a
Claude Code policy helper. `managed-settings.json` names an executable file.
The executable writes `{"appendSystemPrompt": ..., "managedSettings": ...}` to
stdout. `appendSystemPrompt` is the only key that adds text to the system
prompt without a command-line flag. Claude Code accepts this key from helper
stdout only, and rejects it in a static managed payload. `device/` holds that
kit and `install-device-policy.sh` installs it.

The adapter fails closed on an unknown or non-executable policy. Policies own
their behavior and exit contract; do not duplicate that logic here.

`sources-capture.sh` deliberately receives the raw tool name and input. The
shared `sources-ledger.py` classifies native search/fetch, Context7, readable
fetch, open-access resolution, and browser navigation calls, so each host does
not carry a separate mapping. Unsupported or empty tool shapes write no row.

| Tool shape | Ledger row |
| --- | --- |
| `WebSearch` with `query` | `search`, query |
| `WebFetch`, `FetchURL`, or `*__fetch_readable` with `url` | `fetch`, URL |
| `*__browser_navigate` with `url` | `browse`, URL |
| `*__resolve_open_access` with `query` | `search`, query |
| Context7 `*__resolve-library-id` / `*__query-docs` with `query` | `search`, query |
| plugin Exa with `url`, otherwise `query` | `fetch` URL, otherwise `search` query |

## Personas

`.agents/personas/*.md` are Claude-native definitions linked at
`.claude/agents/*.md`. Their frontmatter directly names tools, model, effort,
MCP servers, turn limit, and permission mode where applicable. Edit the
canonical persona and run `python3 .agents/check-layout.py`; no generation step
exists.

Models are deliberately explicit: `haiku`, `claude-sonnet-5`, and
`claude-opus-5`.
Generic delegation remains valid when no cached persona fits.

## Local state

`.claude/settings.local.json` is operator-local and gitignored. `.agents/mcp.py`
updates only `enabledMcpjsonServers`, preserving unrelated keys. MCP changes
take effect in a new session.

Use `.agents/test-session-start.sh` for SessionStart behavior and
`.agents/test-codex.sh` for the shared policy normalizers exercised through the
Codex adapter. Host-native Claude persona discovery has no non-interactive list
command in this scaffold; verify it from Claude's `/agents` UI after transplant.
