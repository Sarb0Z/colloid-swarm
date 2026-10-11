# Moving a project directory

A directory move is not complete until the agent hosts' session stores point at
the new path. Claude Code, Codex, and Kimi all key session history by absolute
path, so a bare `mv` leaves `--resume` and history search unreachable from both
the old and the new location, and nothing reports it until someone looks.

Rewrite path-valued metadata only. Conversation text that mentions the old path
is history; leave it. Unrelated projects' transcripts routinely mention the
moved path and must not be touched. Back up each store before the rewrite.

| Host | Store | What is keyed by path |
| --- | --- | --- |
| Claude Code | `~/.claude/projects/` (or the `CLAUDE_CONFIG_DIR` equivalent) | Directory name is the absolute path with `/` replaced by `-`. Rename the directory and any `…-apps-web` style subdirectory session dirs, then rewrite every `cwd` key inside its `*.jsonl`. |
| Codex | `~/.codex/` | `sessions/YYYY/MM/DD/rollout-*.jsonl` carry `payload.cwd`. `config.toml` has `[projects."<path>"]` and `[hooks.state."<path>/.codex/hooks.json:…"]` table headers. `.codex-global-state.json` and its `.bak` hold `local-projects.<uuid>.rootPaths[]`. `session_index.jsonl` does not carry the path. |
| Kimi | `~/.kimi-code/` | `sessions/wd_<name>_<hash>/`, plus `workspaces.json` and `session_index.jsonl` (both store `root` or `workDir`). The directory hash derives from the root path and cannot be recomputed by hand; repoint through the Kimi CLI or accept orphaned history. |

Verify by scanning the migrated transcripts for surviving `cwd` values under the
old prefix (expect zero), and by parsing `config.toml` with `tomllib` so a broken
table header fails immediately.

A uv virtual environment in the moved tree is a separate casualty: its
console-script shebangs carry the absolute prefix. Delete `.venv` and re-run
`uv sync`. `bin/python` is an absolute symlink to the uv-managed interpreter
outside the project, so the interpreter still launches; do not read that as
proof the environment survived.
