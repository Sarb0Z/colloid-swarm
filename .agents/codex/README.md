# Codex adapter

`.codex/hooks.json` and `.codex/hooks/*` link here. Custom roles in
`.codex/agents/*.toml` are static host-native definitions. `.codex/config.toml` is
generated in full: `python3 .agents/mcp.py` renders `.agents/codex/config.toml`
and appends the MCP records from `.agents/mcp.json`. It is gitignored, so an edit
made there is discarded on the next run — change the canonical file.

Codex role files accept `name`, `description`, and `developer_instructions`.
Model and reasoning effort are dispatch controls, so each description states
the exact default:

- Luna / low: exploration and mechanical work
- Terra / medium: implementation, QA, and research
- Sol / high: independent hostile review

These are defaults, not a closed taxonomy. A generic cell may use any tier the
task needs. Codex cannot enforce Claude persona tool/MCP/skill frontmatter; the
sandbox and task handoff remain the capability boundary.

The project selects the `repo-autonomous` permission profile. It writes
throughout the repository, including `.git`, `.agents`, and `.codex`, with
network access disabled. Auto-review handles eligible requests that still cross
that boundary; MCP, browser, and connector tools keep their own controls.

Use `repo-localhost` only for a short local-QA session. It adds exact
`localhost` and `127.0.0.1` access, keeps public hosts blocked, and refuses an
upstream proxy. Select it for one command with:

```sh
codex sandbox --permission-profile repo-localhost -C "$(pwd)" -- command
```

For a new interactive QA thread, override the project default at launch:

```sh
codex -C "$(pwd)" -c 'default_permissions="repo-localhost"'
```

The network proxy is experimental. Codex 0.147.0 was observed retaining its
per-command listener pairs, so the default profile leaves it off. The split
reduces descriptor growth; it does not repair Codex's process cleanup. Exit the
whole opt-in thread when QA finishes. See `debt: codex-network-proxy-fd-leak`.
Start a new thread after changing either profile.

## Subagent concurrency

`[agents] max_concurrent_threads_per_session` in `.agents/codex/config.toml` caps
concurrently open spawned-agent threads and excludes the primary, so a value of
N leaves room for N workers alongside it. Codex picks its own low default when
the key is absent, and an agent that meets that ceiling cannot tell a default
from an entitlement — it reports the subscription as the constraint and stops
looking. `.agents/test-codex.sh` fails when the key goes missing.

Older configurations may carry `agents.max_threads` as an alias for the same
setting. A spawned agent inherits the parent's model and reasoning effort unless
its `.codex/agents/*.toml` file or the spawn request names one, so a raised cap
multiplies token burn at the parent's tier rather than at a cheaper one. Start a
new thread after changing the value.

## Hook coverage

<!-- colloid-only -->
Codex `SubagentStart` carries `agent_id` and `agent_type`, so the native hook
injects one genome before a non-exempt subagent's first prompt. Do not prepend a
second genome when dispatching from Codex. `PreToolUse` and `PostToolUse` do not
carry those fields; safety and post-edit policies therefore run without
main/subagent selectors.
<!-- /colloid-only -->

The source trail observes MCP Context7, research, Exa, and browser calls through
`PostToolUse`. Codex hosted tools such as native web search do not enter the
local tool-hook path and cannot be captured here. When tool payloads omit agent
identity, the ledger records `unknown` rather than inventing `main`.

## MCP loading

`.agents/mcp.py` emits all Codex-compatible project records with explicit state.
Disabled records mask the same name from lower user configuration. They cannot
mask unknown names, and a same-name user record with a different transport may
make the merged config invalid. `.agents/test-codex.sh` runs `codex mcp list`
with a timeout when the binary is available; parsing TOML is not equivalent to
loading it.

Start a new thread after changing project MCP state.

## Hook trust

Codex records a hash for each approved hook. A changed `hooks.json` stops
running until the new hash is trusted. After reviewing the file, run:

```sh
python3 .agents/codex/trust-hooks.py "$(pwd)"
```

The script asks Codex for its computed hashes, updates only this repository's
hook records, and preserves unrelated config. It also establishes project trust
because Codex otherwise ignores project configuration. Run one repository at a
time: the user config has no cross-process writer lock.

On a machine with no `codex` on PATH it writes nothing at all, including the
project entry. It refuses when Codex discovers fewer hooks than `hooks.json`
declares: trusting the subset would leave the rest on a stale hash, which stops
them running while the session still reports itself armed.

`test-trust-hooks.py` verifies the config rewriter without touching the real
user config.
