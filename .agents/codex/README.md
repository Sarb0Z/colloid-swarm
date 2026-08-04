# Codex integration

Run `.agents/sync-codex.sh` after you change a canonical Codex input.

The script creates `.codex/`. It uses symlinks for this adapter, this file, and
`hooks.json`. It generates `config.toml` and custom-agent TOML files because
Codex requires different formats for these files.

Codex does not expose hosted web search through local tool hooks. It does not
create a source-capture hook. Record sources in the response when you use the
hosted search tool.
