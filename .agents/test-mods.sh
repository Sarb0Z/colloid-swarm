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

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# claude plugin validate type-checks a mod's module and tests but reports each
# TypeScript error as a warning and still exits 0, and --strict also fails on
# warnings no mod can act on, such as a missing icon. So a mod validates only
# when the command passes and prints no `error TS` line.
validates() {  # <mod folder>; prints the validator's report when it fails
  local report
  if ! report="$(claude plugin validate "$1" 2>&1)" || grep -q 'error TS' <<<"$report"; then
    printf '%s\n' "$report" >&2
    return 1
  fi
}

count=0
first=""
for manifest in "$mods"/*/.claude-plugin/plugin.json; do
  [[ -f "$manifest" ]] || continue
  mod="$(dirname "$(dirname "$manifest")")"
  name="$(basename "$mod")"
  if ! compgen -G "$mod/tests/*.test.ts" >/dev/null; then
    echo "FAIL: $name has no tests/*.test.ts; every mod ships a firing test" >&2
    exit 1
  fi
  validates "$mod" || { echo "FAIL: $name does not validate, or does not type-check" >&2; exit 1; }
  claude plugin test "$mod" || { echo "FAIL: $name's tests failed" >&2; exit 1; }
  printf 'ok    %s validates, type-checks and its tests pass\n' "$name"
  first="${first:-$mod}"
  count=$((count + 1))
done

if [[ "$count" -eq 0 ]]; then
  echo "test-mods: no mods under $mods" >&2
  exit 1
fi

# A copy of a passing mod with one type error must fail, so a pass means the
# type check still runs and is still read.
cp -R "$first" "$scratch/mistyped"
probe="$(compgen -G "$scratch/mistyped/tests/*.test.ts" | head -n 1)"
printf '\nexport const colloidTypeProbe: number = "not a number"\n' >> "$probe"
if validates "$scratch/mistyped" 2>/dev/null; then
  echo "FAIL: a copy of $(basename "$first") with a type error in $(basename "$probe") still validated; the type check no longer gates the mods" >&2
  exit 1
fi
printf 'ok    a mod with a type error does not validate\n'

# A plugin under .agents/claude/plugins declares components and no module, so
# validation is its whole gate. The validator rejects an unknown key inside an
# lspServers entry; the broken copy proves it still does, so a pass means
# something.
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
