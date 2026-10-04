#!/usr/bin/env bash
# Gates every Claude Code mod under .agents/claude/mods: the engine's own
# validation of the manifest and module, then the mod's firing tests. Both run
# with no login, so CI runs them against a pinned Claude Code install.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mods="$repo/.agents/claude/mods"

if ! command -v claude >/dev/null; then
  echo "test-mods: the claude CLI is not on PATH; install Claude Code to run the mod tests" >&2
  exit 1
fi

count=0
for manifest in "$mods"/*/.claude-plugin/plugin.json; do
  [[ -f "$manifest" ]] || continue
  mod="$(dirname "$(dirname "$manifest")")"
  name="$(basename "$mod")"
  if ! compgen -G "$mod/tests/*.test.ts" >/dev/null; then
    echo "FAIL: $name has no tests/*.test.ts; every mod ships a firing test" >&2
    exit 1
  fi
  claude plugin validate "$mod" >/dev/null || { claude plugin validate "$mod" >&2; echo "FAIL: $name does not validate" >&2; exit 1; }
  claude plugin test "$mod" || { echo "FAIL: $name's tests failed" >&2; exit 1; }
  printf 'ok    %s validates and its tests pass\n' "$name"
  count=$((count + 1))
done

if [[ "$count" -eq 0 ]]; then
  echo "test-mods: no mods under $mods" >&2
  exit 1
fi
