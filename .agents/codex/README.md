# Codex integration

Run `.agents/sync-codex.sh` after you change a canonical Codex input.

The script creates `.codex/`. It uses symlinks for this adapter, this file, and
`hooks.json`. It generates `config.toml` and custom-agent TOML files because
Codex requires different formats for these files.

Codex merges project config over user and plugin config by MCP server name.
The generated config includes a record for each compatible registry server that
is off. This record blocks a same-name lower config entry. It cannot block an
unknown server name. Use a managed MCP allowlist when the effective server set
must contain only approved names.

Every record carries its transport, disabled ones included. Codex validates the
merged entry, and a record holding only `enabled` is invalid unless some lower
layer supplies a transport for that name — which nothing guarantees.

Codex merges the TOML layers — user, project, and `-c` overrides — per key, so
a record whose transport differs from a same-name record in another TOML layer
leaves one server holding both a `command` and a `url`, and Codex then refuses
to load the whole configuration rather than that one entry. This applies to
enabled records too, so the generator cannot avoid it; `check-mcp-conflicts.py`
reports the condition on every sync. A configured server replaces a same-name
plugin catalog entry outright, so plugins cannot produce this.
`debt: codex-mcp-transport-collision`.

`.agents/test-codex.sh` runs `codex mcp list` against the generated file in a
scratch home that declares no servers. TOML that parses is not TOML that loads,
and only the binary knows the difference.

`[features] default_mode_request_user_input = true` lets the agent ask the user
a question outside Plan mode. Registration of the `request_user_input` tool
already defaults to on, so the `[tools]` entry adds nothing; this feature is
what makes Default mode eligible. Without it Codex answers `request_user_input
is unavailable in Default mode` and asks in prose instead. It is under
development upstream. The tool needs an interactive client: `codex exec`
refuses it, while an app-server client can answer it.

Start a new thread after you change project MCP config: a thread reloads the
configuration, so restarting the process is safe but not required.

Codex does not expose hosted web search through local tool hooks. The sync
script therefore creates no source-capture hook. Record sources in the response
when you use the hosted search tool.

Codex requires hooks 0.124.0 or later. Earlier versions fire `PreToolUse` and
`PostToolUse` for Bash only, which stops the `apply_patch` and `spawn_agent`
matchers from ever running.

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

Discovery is gated on the project itself being trusted, so the script writes
the `[projects]` entry first. That is what makes a fresh clone on a new machine
work without a manual approval round.

The same path is why `sync-codex.sh` generates the reader tier's launch config
itself, through `.agents/reader_config.py` shared with `sync-mcp.sh`. This script
runs standalone, and `resolve_registry` validates the local paths of *every*
registry entry — enabled or not — before anything is written. A launch config
that only `sync-mcp.sh` produced would be missing on a fresh clone, and the
failure would take down the whole Codex layer, not just the reader.

It refuses to write a config that does not parse, keeps any other keys already
in a hook's block, and reports rather than swallows a Codex warning. It sets
`enabled = true`, so a hook you turned off by hand comes back on at the next
sync. `--no-trust` on the sync skips the step entirely, which is what the test
suite uses; `--dry-run` and `--config=PATH` on the script itself keep a run away
from the real config. `test-trust-hooks.py` covers the rewriter.

This trusts the hooks without asking. Read `hooks.json` before you run the sync
on a repository you did not write.
