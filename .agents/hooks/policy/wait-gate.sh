#!/usr/bin/env bash
# Engine-agnostic policy: refuse a shell command that waits blind — a long
# `sleep`, a sleep that polls a host task's output, or a bare `&` background.
#
# Input  (stdin JSON): {"command": "<shell command>", "run_in_background": bool}
# Output: exit 2 + stderr remedy on block; exit 0 otherwise.
#
# The decision needs the shell-aware split in ../lib/guard-destructive.py, so it
# lives in ../lib/wait-gate.py. A policy that cannot run exits 0: every
# non-zero exit other than 2 is a hook failure and the command proceeds anyway.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
decide="$repo/.agents/hooks/lib/wait-gate.py"

if [[ ! -f "$decide" ]]; then
  echo "wait-gate: $decide is missing; the gate cannot run." >&2
  exit 0
fi

exec python3 "$decide" "$repo"
