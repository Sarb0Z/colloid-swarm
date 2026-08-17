#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/scaffold-export.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "test-export: $*" >&2; exit 1; }

git clone --quiet --no-hardlinks "$repo" "$work/source"
python3 - "$work/source/.agents/debt-log.md" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
needle = "### codex-mcp-transport-collision\n"
if needle not in text:
    raise SystemExit("test-export: referenced debt fixture is absent")
path.write_text(text.replace(needle, needle + "\nDIRTY_EXPORT_CANARY\n", 1))
PY
"$work/source/.agents/export-scaffold.py" "$work/kit" >/dev/null
kit="$work/kit"
if grep -rq 'DIRTY_EXPORT_CANARY' "$kit"; then
  fail "export mixed live debt text into the committed snapshot"
fi

leaked="$(grep -rniE 'genome|mutagen|panspermia|\bswarm\b' "$kit" \
  --exclude-dir=mcp-servers --exclude-dir=node_modules --exclude-dir=export \
  2>/dev/null | grep -v '^Binary' || true)"
[[ -z "$leaked" ]] || { printf '%s\n' "$leaked" >&2; fail "export leaked source-only behavior"; }

for path in \
  .agents/genome.sh .agents/mutagen.sh .agents/skills/panspermia-mutation \
  .agents/eval .agents/fixtures .agents/breadcrumbs.md .agents/debt-log.md \
  .agents/export .agents/export-scaffold.py .agents/test-export.sh \
  .agents/test-stack-packs.sh; do
  [[ ! -e "$kit/$path" ]] || fail "export retained $path"
done

for path in \
  .agents/AGENTS.md .agents/check-layout.py .agents/mcp.py .agents/mcp_codex.py \
  .claude/agents/implementer.md .codex/agents/implementer.toml \
  .codex/hooks.json .github/lsp.json CLAUDE.md export/README.md export/drop-server.py; do
  [[ -e "$kit/$path" ]] || fail "export omitted $path"
done

[[ -L "$kit/CLAUDE.md" ]] || fail "exported CLAUDE.md is not a link"
[[ "$(readlink "$kit/CLAUDE.md")" == "AGENTS.md" ]] \
  || fail "exported CLAUDE.md does not target AGENTS.md"
cmp -s "$kit/CLAUDE.md" "$kit/AGENTS.md" \
  || fail "exported Claude root authority differs from AGENTS.md"

python3 "$kit/.agents/check-layout.py" >/dev/null
mkdir -p "$kit/apps/example"
touch "$kit/apps/example/AGENTS.md"
ln -s ../../apps/example/AGENTS.md "$kit/.claude/rules/example.md"
ln -s ../../apps/example/AGENTS.md "$kit/.github/instructions/example.instructions.md"
python3 "$kit/.agents/check-layout.py" >/dev/null
ln -s ../../.agents/rules/removed.md "$kit/.claude/rules/removed.md"
if python3 "$kit/.agents/check-layout.py" >/dev/null 2>&1; then
  fail "layout accepted a stale scaffold-owned link"
fi
rm "$kit/.claude/rules/removed.md"
"$kit/.agents/lint-skills.sh" >/dev/null
"$kit/.agents/test-mcp.sh" >/dev/null

packs="$(find "$kit/.agents/rules" -name 'stack-*.md' | wc -l | tr -d ' ')"
[[ "$packs" -gt 0 ]] || fail "export carries no stack packs"
python3 - "$kit/.agents/config.json.example" <<'PY'
import json, sys
if "stack_packs" in json.load(open(sys.argv[1], encoding="utf-8")):
    raise SystemExit("export retained source-only stack_packs.carrier")
PY

cp -R "$kit" "$work/lean"
rm -rf "$work/lean/.agents/mcp-servers/security-mcp"
python3 "$work/lean/export/drop-server.py" "$work/lean" security-mcp >/dev/null
python3 "$work/lean/.agents/mcp.py" >/dev/null

echo "Export checks passed."
