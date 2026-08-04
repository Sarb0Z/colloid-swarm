# Codex integration

Run `.agents/sync-codex.sh` after you change a canonical Codex input.

The script creates `.codex/`. It uses symlinks for this adapter, this file, and
`hooks.json`. It generates `config.toml` and custom-agent TOML files because
Codex requires different formats for these files.

Codex does not expose hosted web search through local tool hooks. The sync
script therefore creates no source-capture hook. Record sources in the response
when you use the hosted search tool.

Codex requires hooks 0.124.0 or later. Earlier versions fire `PreToolUse` and
`PostToolUse` for Bash only, which stops the `apply_patch` and `Agent` matchers
from ever running.

Codex also gates each hook behind a trust record in `~/.codex/config.toml`
under `[hooks.state]`. A hook stays inactive until you approve it, and a change
to `hooks.json` invalidates the recorded hash. Approve the hooks in Codex after
you run the sync, then confirm that each entry for this project carries
`enabled = true`.
