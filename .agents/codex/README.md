# Codex adapter

`.codex/hooks.json` and `.codex/hooks/*` link here. Custom roles in
`.codex/agents/*.toml` are static host-native definitions; MCP config is written
by `python3 .agents/mcp.py`.

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

`test-trust-hooks.py` verifies the config rewriter without touching the real
user config.
