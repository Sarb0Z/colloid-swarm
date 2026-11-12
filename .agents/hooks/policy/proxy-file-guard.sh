#!/usr/bin/env bash
# Engine-agnostic policy: a session passes a configured proxy's name to the
# Scrapling tools instead of reading the env file that holds its password.
#
# A Read, Grep or shell call (Bash, Monitor, PowerShell) that names an
# `env_file` configured under `scrapling.proxies` in .agents/config.json is
# denied: by absolute path, by `~/`, `$HOME/` or `${HOME}/`, quoted or not, with
# a doubled slash or a dot segment, or through a symlink to it, in a Read
# `file_path`, a Grep `path`, or any word of a command. A content-mode Grep, or
# an rg, grep, egrep, fgrep, ag or ack command, over the file's folder or an
# ancestor of it strictly below $HOME is denied too, since it prints the file.
# The file is never opened and never quoted.
#
# Misses: a command that builds the path any other way — a variable, a glob,
# `cd` and a relative name, an interpreter — gets past it, and so does a search
# of $HOME itself. This is a nudge that
# keeps the secret out of a session that follows the instruction, not a
# sandbox; the file's 0600 mode and the launcher's scrubbing are the walls.
#
# Input  (stdin JSON): {"project_dir", "tool_name", "file_path", "path", "command", "output_mode"}
# Output: exit 2 + stderr reason on block; exit 0 otherwise. A config that does
# not load prints one stderr line and allows.
#
# The no-names path stays cheap: a config.json without the text "proxies" exits
# here, before Python starts.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
config="$repo/.agents/config.json"
decide="$repo/.agents/hooks/lib/proxy-file-guard.py"

[[ -f "$config" ]] && grep -q '"proxies"' "$config" || exit 0

if [[ ! -f "$decide" ]]; then
  echo "proxy-file-guard: $decide is missing; the guard cannot run." >&2
  exit 0
fi

exec python3 "$decide" "$repo"
