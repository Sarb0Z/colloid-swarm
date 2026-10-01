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
  .agents/decisions.md \
  .agents/export .agents/export-scaffold.py .agents/test-export.sh \
  .agents/test-stack-packs.sh; do
  [[ ! -e "$kit/$path" ]] || fail "export retained $path"
done

retained=(
  .agents/AGENTS.md .agents/check-layout.py .agents/mcp.py .agents/mcp_codex.py \
  .agents/workloop.py .agents/skills/workloop/SKILL.md \
  .claude/agents/implementer.md .codex/agents/implementer.toml \
  .codex/hooks.json .github/lsp.json CLAUDE.md export/README.md export/drop-server.py \
  .worktreeinclude
)
for path in "${retained[@]}"; do
  [[ -e "$kit/$path" ]] || fail "export omitted $path"
done

# Every satellite runs the scaffold's verification list as written; a check it
# names but the export drops fails there with "No such file".
while read -r path; do
  [[ -e "$kit/$path" ]] || fail "exported .agents/AGENTS.md names $path, which the export drops"
done < <(grep -oE '\.agents/[A-Za-z0-9_./-]+\.(sh|py)' "$kit/.agents/AGENTS.md" | sort -u)

# A hook that starts writing a new runtime state file leaves the kit's
# gitignore fragment behind, and every target then commits that state. The
# repository's own ignore rules are the source of truth for what is transient.
# Both sides come from the clone, which is HEAD: the kit is built by
# `git archive HEAD`, so comparing it against the working tree would fail the
# very edit that fixes the drift, until it was committed.
python3 - "$work/source/.gitignore" "$kit/export/gitignore-fragment" <<'PY'
import sys

COLLOID_ONLY = {".agents/.genome-ledger", ".agents/.mutagen-ledger"}


def transient(path):
    return {
        line.strip()
        for line in open(path, encoding="utf-8")
        if line.strip().startswith(".agents/.")
    }


missing = transient(sys.argv[1]) - transient(sys.argv[2]) - COLLOID_ONLY
if missing:
    raise SystemExit(
        "export: gitignore-fragment does not ignore "
        + ", ".join(sorted(missing))
        + " — a target would commit that runtime state"
    )
PY

python3 - "$kit/.claude/settings.json" "$kit/.codex/hooks.json" <<'PY'
import json, sys
for path in sys.argv[1:]:
    hooks = json.load(open(path, encoding="utf-8")).get("hooks", {})
    for event, groups in hooks.items():
        if not groups:
            raise SystemExit(f"export left {path} event {event} with no matcher groups")
        for group in groups:
            if not group.get("hooks"):
                raise SystemExit(f"export left {path} event {event} a matcher group with no commands: {group}")
PY

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

# merge-kit applies only the carrier's change, keeps the satellite's edits and
# deletions, and leaves a same-line edit on both sides to a hand merge.
base="$work/base-kit" sat="$work/satellite"
cp -R "$kit" "$base"
printf 'old line\n' >"$base/.agents/README.md"
printf 'one\ntwo\nthree\nfour\nfive\n' >"$base/.agents/playbooks/hostile-review.md"
printf 'skill base\n' >"$base/.agents/skills/qa-verifier/AGENTS.md"
printf 'persona base\n' >"$base/.agents/personas/mechanic.md"
rm "$base/.agents/test-codex.sh"
mkdir -p "$base/.agents/hooks/lib/__pycache__"
printf 'bytecode\n' >"$base/.agents/hooks/lib/__pycache__/config.pyc"
cp -R "$base" "$sat"
rm -rf "$sat/export"
printf 'ONE\ntwo\nthree\nfour\nfive\n' >"$sat/.agents/playbooks/hostile-review.md"
rm "$sat/.agents/skills/qa-verifier/AGENTS.md"
printf 'persona satellite\n' >"$sat/.agents/personas/mechanic.md"
printf 'persona kit\n' >"$kit/.agents/personas/mechanic.md"
printf 'one\ntwo\nthree\nfour\nFIVE\n' >"$kit/.agents/playbooks/hostile-review.md"
# A carrier file added under a skill or MCP bundle the satellite pruned stays out.
rm -rf "$sat/.agents/skills/perf-budget" "$sat/.agents/mcp-servers/security-mcp"
printf 'new\n' >"$kit/.agents/skills/perf-budget/new.md"
printf 'new\n' >"$kit/.agents/mcp-servers/security-mcp/new.js"
# A mode-only carrier change is a change.
chmod +x "$kit/.agents/rules/documentation.md"
# Line endings survive a three-way merge.
printf 'a\r\nb\r\nc\r\nd\r\ne\r\n' >"$base/.agents/playbooks/crlf.md"
printf 'A\r\nb\r\nc\r\nd\r\ne\r\n' >"$sat/.agents/playbooks/crlf.md"
printf 'a\r\nb\r\nc\r\nd\r\nE\r\n' >"$kit/.agents/playbooks/crlf.md"
# A new kit directory where the satellite holds a file is a conflict, found
# before anything is written.
printf 'satellite file\n' >"$sat/.agents/blocked"
mkdir -p "$kit/.agents/blocked"
printf 'kit file\n' >"$kit/.agents/blocked/inner.md"
before="$(cd "$sat" && find . -type f -exec cksum {} + | sort)"
python3 "$kit/export/merge-kit.py" "$sat" "$base" "$kit" >/dev/null && fail "merge-kit hid a conflict"
[[ "$(cd "$sat" && find . -type f -exec cksum {} + | sort)" == "$before" ]] \
  || fail "merge-kit wrote without --apply"
out="$(python3 "$kit/export/merge-kit.py" "$sat" "$base" "$kit" --apply 2>&1)" && fail "merge-kit hid a conflict"
grep -q Traceback <<<"$out" && fail "merge-kit crashed mid-apply: $out"
cmp -s "$sat/.agents/README.md" "$kit/.agents/README.md" || fail "merge-kit skipped a carrier update"
[[ "$(cat "$sat/.agents/playbooks/hostile-review.md")" == $'ONE\ntwo\nthree\nfour\nFIVE' ]] \
  || fail "merge-kit lost one side of a clean merge"
[[ ! -e "$sat/.agents/skills/qa-verifier/AGENTS.md" ]] || fail "merge-kit restored a satellite deletion"
[[ -e "$sat/.agents/test-codex.sh" ]] || fail "merge-kit skipped a carrier addition"
grep -q '^<<<<<<< satellite' "$sat/.agents/personas/mechanic.md" || fail "merge-kit hid a same-line conflict"
grep -q 'conflict: 2' <<<"$out" || fail "merge-kit miscounted conflicts: $out"
grep -q '\.agents/blocked/inner\.md' <<<"$out" || fail "merge-kit did not report a file blocking a kit directory"
[[ "$(cat "$sat/.agents/blocked")" == 'satellite file' ]] || fail "merge-kit overwrote a satellite file blocking a kit directory"
[[ ! -e "$sat/.agents/skills/perf-budget" ]] || fail "merge-kit restored a pruned skill"
[[ ! -e "$sat/.agents/mcp-servers/security-mcp" ]] || fail "merge-kit restored a pruned MCP bundle"
grep -q 'kept-deleted' <<<"$out" || fail "merge-kit did not report a pruned addition: $out"
[[ -x "$sat/.agents/rules/documentation.md" ]] || fail "merge-kit skipped a mode-only carrier change"
cmp -s "$sat/.agents/playbooks/crlf.md" <(printf 'A\r\nb\r\nc\r\nd\r\nE\r\n') \
  || fail "merge-kit lost CRLF line endings in a three-way merge"
[[ -L "$sat/.claude/skills/workloop" ]] || fail "merge-kit wrote through a linked directory"
[[ -e "$sat/.agents/hooks/lib/__pycache__/config.pyc" ]] || fail "merge-kit treated bytecode as kit content"

echo "Export checks passed."
