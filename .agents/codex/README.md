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

Codex gates each hook behind a trust record in `~/.codex/config.toml` under
`[hooks.state]`, keyed by hook and holding the hash Codex computed when you
approved it. A change to `hooks.json` changes that hash, and a hook whose recorded hash
differs from the computed one stops running. The sync rewrites `hooks.json`, so
it would disarm the hooks it just deployed.

`trust-hooks.py` closes that loop. It asks Codex for the hooks it discovers and
the hash it computes for each, through the app-server `hooks/list` method, then
writes those hashes back as trusted. The hash comes from Codex, so the
normalization rules stay Codex's business. It only writes entries for this
repository, it leaves other projects and plugins alone, and it is a no-op when
`codex` is not on PATH.

This trusts the hooks without asking. Read `hooks.json` before you run the sync
on a repository you did not write.
