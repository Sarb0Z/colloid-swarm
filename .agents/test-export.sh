#!/usr/bin/env bash
# Verify that export-scaffold.py emits a scaffold a satellite can actually run.
#
# Two postures, because the export is not one artifact: a repository may take
# both MCP bundles and Kimi, or neither. Each posture is installed into a fresh
# git repository and driven through the scaffold's own suites, so this fails on
# anything a transplant would hit -- a dangling policy reference, a registry
# entry with no bundle, a Kimi file written where no engine asked for one.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace="$(mktemp -d "${TMPDIR:-/tmp}/export check.XXXXXX")"
trap 'rm -rf "$workspace"' EXIT

fail() { echo "test-export: $*" >&2; exit 1; }

"$repo/.agents/export-scaffold.py" "$workspace/kit" >/dev/null

# --- The export carries no trace of the subsystem it drops -------------------
# mcp-servers/ is excluded: the vendored servers' package identity is upstream
# provenance, and renaming it would invalidate the committed bundle manifests.
# export/ is the transplant guide, which necessarily names the subsystem it
# drops. Everything else in the tree is scaffold a satellite runs.
leaked="$(grep -rniE 'genome|mutagen|panspermia|\bswarm\b' "$workspace/kit" \
            --exclude-dir=mcp-servers --exclude-dir=node_modules --exclude-dir=export \
            2>/dev/null | grep -v '^Binary' || true)"
if [[ -n "$leaked" ]]; then
  echo "$leaked" | sed "s|$workspace/kit/||" >&2
  fail "export leaked the dropped subsystem"
fi

for path in .agents/genome.sh .agents/mutagen.sh .agents/hooks/policy/genome-guard.sh \
            .agents/skills/panspermia-mutation .agents/eval .agents/fixtures \
            .agents/breadcrumbs.md .agents/debt-log.md .agents/export-scaffold.py \
            .agents/test-export.sh .agents/knowledge/index.md \
            .agents/knowledge/research .agents/knowledge/transcripts; do
  if [[ -e "$workspace/kit/$path" ]]; then fail "export still carries $path"; fi
done

# A dispatch table naming a policy the export omits would fire on every matching
# tool call and fail with "unknown or non-executable policy".
for table in .agents/claude/settings.json .agents/codex/hooks.json; do
  if grep -q 'genome-guard' "$workspace/kit/$table"; then
    fail "$table still dispatches a dropped policy"
  fi
done

[[ -f "$workspace/kit/export/README.md" ]] || fail "export omitted its own transplant guide"
[[ -x "$workspace/kit/export/drop-server.py" ]] || fail "export omitted drop-server.py"

# The knowledge store splits in two: the entries above are dropped as this
# repository's content, but the contract must arrive or the satellite inherits
# an undocumented directory it will never write to.
[[ -f "$workspace/kit/.agents/knowledge/README.md" ]] \
  || fail "export omitted the knowledge contract"

# --- Each posture must survive a real install --------------------------------
install_posture() {           # <name> <keep-security-mcp> <keep-kimi>
  local name="$1" keep_security="$2" keep_kimi="$3"
  local dir="$workspace/$name"
  mkdir -p "$dir"
  cp -R "$workspace/kit/.agents" "$dir/.agents"
  if [[ "$keep_kimi" == yes ]]; then cp -R "$workspace/kit/.kimi" "$dir/.kimi"; fi
  if [[ "$keep_security" == no ]]; then
    rm -rf "$dir/.agents/mcp-servers/security-mcp"
    python3 "$workspace/kit/export/drop-server.py" "$dir" security-mcp >/dev/null
  fi
  cp "$workspace/kit/export/gitignore-fragment" "$dir/.gitignore"
  printf 'node_modules/\n' >> "$dir/.gitignore"
  printf '# Fixture\n' > "$dir/AGENTS.md"
  ln -sf AGENTS.md "$dir/CLAUDE.md"
  git -C "$dir" init -q
  printf '%s\n' "$dir"
}

check_posture() {             # <name> <dir> <expect-kimi-file>
  local name="$1" dir="$2" expect_kimi="$3"
  "$dir/.agents/sync-claude-agents.sh" >/dev/null \
    || fail "[$name] sync failed"
  for suite in lint-skills test-session-start test-mcp test-codex; do
    "$dir/.agents/$suite.sh" >/dev/null 2>&1 || fail "[$name] $suite failed"
  done
  if [[ "$expect_kimi" == yes ]]; then
    [[ -f "$dir/.kimi-code/mcp.json" ]] || fail "[$name] Kimi is wired but no project file was written"
  else
    if [[ -e "$dir/.kimi-code/mcp.json" ]]; then
      fail "[$name] Kimi project file written with no Kimi engine"
    fi
  fi
  # A dangling link means a canonical file the export failed to carry.
  local dangling
  dangling="$(find "$dir/.claude" "$dir/.codex" -type l ! -exec test -e {} \; -print 2>/dev/null || true)"
  if [[ -n "$dangling" ]]; then fail "[$name] dangling links: $dangling"; fi
  echo "  $name: sync + 4 suites pass"
}

check_posture full "$(install_posture full yes yes)" yes
check_posture lean "$(install_posture lean no no)" no

echo "Export checks passed."
