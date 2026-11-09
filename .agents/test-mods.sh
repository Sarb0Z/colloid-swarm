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

# A plugin under .agents/claude/plugins declares components and no module, so
# validation is its whole gate. The validator rejects an unknown key inside an
# lspServers entry; the broken copy proves it still does, so a pass means
# something.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
for manifest in "$repo"/.agents/claude/plugins/*/.claude-plugin/plugin.json; do
  [[ -f "$manifest" ]] || continue
  plugin="$(dirname "$(dirname "$manifest")")"
  name="$(basename "$plugin")"
  claude plugin validate "$plugin" >/dev/null || { claude plugin validate "$plugin" >&2; echo "FAIL: plugin $name does not validate" >&2; exit 1; }
  if python3 -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1])).get("lspServers") else 1)' "$manifest"; then
    rm -rf "$scratch/broken" && cp -R "$plugin" "$scratch/broken"
    python3 - "$scratch/broken/.claude-plugin/plugin.json" <<'PY'
import json, sys
path = sys.argv[1]
manifest = json.load(open(path))
next(iter(manifest["lspServers"].values()))["colloidUnknownKey"] = True
json.dump(manifest, open(path, "w"))
PY
    if claude plugin validate "$scratch/broken" >/dev/null 2>&1; then
      echo "FAIL: claude plugin validate accepted an unknown key in $name's lspServers; it no longer gates the manifest" >&2
      exit 1
    fi
  fi
  printf 'ok    plugin %s validates, and a broken lspServers entry does not\n' "$name"
done
