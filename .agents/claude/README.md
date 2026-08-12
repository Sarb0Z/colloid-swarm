# Claude adapter

`.claude/settings.json` and `.claude/hooks/*` link here. The adapter normalizes
Claude hook payloads and passes JSON on stdin to engine-neutral policies under
`.agents/hooks/policy/`.

| Policy | Normalized fields |
| --- | --- |
| `guard-destructive.sh` | `project_dir`, `command` |
| `post-edit-check.sh` | `project_dir`, `files` |
| `sources-capture.sh` | `project_dir`, `agent`, `tool_name`, `tool_input` |
| `session-start.sh` | `project_dir`, `source`, `session_id`, `transcript_path` |
| `session-wrap.sh` | `project_dir`, `stop_hook_active`, `session_id`, `transcript_path` |
| `stop-investigate.sh` | `project_dir`, `stop_hook_active`, `last_assistant_message`, `transcript_path` |
| `research-prime.sh` | `project_dir`, `prompt` |
| `pre-compact.sh` | `project_dir`, `trigger` |
<!-- colloid-only -->
| `genome-inject.sh` | `project_dir`, `subagent_type` |
<!-- /colloid-only -->

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
