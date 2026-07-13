#!/usr/bin/env bash
# Engine-agnostic policy: lint / format / typecheck edited files.
#
# Input  (stdin JSON): {"project_dir": "...", "files": ["...", ...]}
# Output: exit 2 + stderr findings on issues; exit 0 otherwise.
#
# Scoped strictly to the provided file list — never sweeps the repo.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cfg_path="$repo/.agents/config.json"
cfg="$(CFG_PATH="$cfg_path" python3 <<'PY'
import json, os
cfg = {}
try:
    with open(os.environ["CFG_PATH"], encoding="utf-8") as f: cfg = json.load(f)
except Exception: pass
pe = cfg.get("hooks", {}).get("post_edit_check", {})
print("yes" if pe.get("enabled", True) else "no")
print("yes" if pe.get("tombstone_check", True) else "no")
PY
)"
enabled="$(printf '%s\n' "$cfg" | sed -n '1p')"
tombstone_check="$(printf '%s\n' "$cfg" | sed -n '2p')"
[[ "$enabled" == "no" ]] && exit 0

input="$(cat)"

proj="$(HOOK_INPUT="$input" python3 <<'PY'
import json, os
d = json.loads(os.environ["HOOK_INPUT"] or "{}")
print(d.get("project_dir", ""))
PY
)"

files="$(HOOK_INPUT="$input" python3 <<'PY'
import json, os
d = json.loads(os.environ["HOOK_INPUT"] or "{}")
seen = set()
for p in d.get("files") or []:
    if isinstance(p, str) and p and p not in seen:
        seen.add(p)
        print(p)
PY
)"

[[ -z "$files" ]] && exit 0
[[ -z "$proj" ]] && proj="$PWD"
cd "$proj"

issues=""
ran_tsc=false
ts_edited=""

while IFS= read -r f; do
  [[ -z "$f" || ! -f "$f" ]] && continue
  rel="${f#$proj/}"

  case "$f" in
    *.py)
      if command -v ruff >/dev/null 2>&1; then
        ruff check --fix --force-exclude --quiet "$f" >/dev/null 2>&1 || true
        ruff format --force-exclude --quiet "$f" >/dev/null 2>&1 || true
        if ! check_out="$(ruff check --force-exclude --quiet --output-format=concise "$f" 2>&1)"; then
          issues+=$'\n'"[ruff] $rel"$'\n'"$check_out"$'\n'
        fi
      fi
      ;;
    *.ts|*.tsx)
      ts_edited+=$'\n'"$f"
      if [[ "$ran_tsc" == "false" && -x "frontend/node_modules/.bin/tsc" ]]; then
        ran_tsc=true
        tsc_raw="$(cd frontend && ./node_modules/.bin/tsc --noEmit --incremental --tsBuildInfoFile .tsbuildinfo-claude 2>&1 || true)"
        if [[ -n "$tsc_raw" ]]; then
          scoped="$(HOOK_INPUT="$tsc_raw" TS_FILES="$ts_edited" python3 <<'PY'
import os
raw = os.environ["HOOK_INPUT"]
edited = [p.strip() for p in os.environ["TS_FILES"].splitlines() if p.strip()]
rels = []
for p in edited:
    p = p.replace("\\", "/")
    i = p.find("/frontend/")
    if i >= 0:
        rels.append(p[i + len("/frontend/"):])
    elif p.startswith("frontend/"):
        rels.append(p[len("frontend/"):])
    else:
        rels.append(p.split("/")[-1])
keep = [line for line in raw.splitlines() if any(r and r in line for r in rels)]
print("\n".join(keep))
PY
)"
          if [[ -n "$scoped" ]]; then
            issues+=$'\n'"[tsc --noEmit] (scoped to edited files)"$'\n'"$scoped"$'\n'
          fi
        fi
      fi
      ;;
  esac
done <<< "$files"

# Tombstones: diary/changelog narration added in this edit. Advisory only —
# the standing rationale belongs in .agents/debt-log.md, not inline. Scans the
# additions vs HEAD (no mid-session commits, by policy) so pre-existing history
# comments aren't re-flagged.
tombstones=""
if [[ "$tombstone_check" == "yes" ]]; then
  tombstones="$(FILES="$files" PROJ="$proj" python3 <<'PY' || true
import os, re, subprocess

proj = os.environ["PROJ"]
files = [f for f in os.environ["FILES"].splitlines() if f.strip()]

# High-precision: phrasings that narrate a change rather than describe present
# behavior. Kept tight on purpose — a false miss beats nagging on legit prose.
PHRASES = re.compile(r'''(?ix)
    \b(
      previously | formerly | no\s+longer |
      used\s+to(\s+be)? |
      was\s+(previously\s+|formerly\s+)?(refactored|renamed|removed|replaced|changed|moved|deprecated) |
      refactored\s+(this|the|from|to|out|into) |
      changed\s+(this|the|it|these)?\s*from |
      renamed\s+(this|the|it|from) |
      moved\s+(this|the|it)\s+(from|to|out) |
      replaced\s+(the\s+)?old |
      instead\s+of\s+the\s+old |
      prior\s+to\s+this\s+(change|refactor) |
      as\s+part\s+of\s+(the\s+)?refactor |
      legacy\s+(behaviou?r|version|impl|code|path)
    )\b
    | \bTODO\b[^\n]*\b(19|20)\d\d\b
''')

# Only flag lines that read as comments (any line, in prose docs).
CODE_COMMENT = re.compile(r'(^\s*(//|\#|\*|/\*|<!--|--|;))|(//|/\*|<!--|\#\s)')
DOC_EXT = (".md", ".mdx", ".markdown", ".rst", ".txt")

# Files whose whole job is to narrate history — exempt, or they nag on every edit.
SKIP_NAMES = re.compile(r'^(CHANGELOG|CHANGES|HISTORY|RELEASES?|NEWS|MIGRATION|UPGRADING)(\.|$)', re.I)

# A banned phrase inside double-quotes/backticks is a citation (defining or
# discussing the word), not narration — strip those spans before matching so this
# rule and its own docs don't trip it, while bare `// previously returned X`
# still does. Apostrophes (it's, user's) are NOT treated as delimiters: prose
# apostrophes far outnumber single-quoted comment strings, and a `'...'` pair
# straddling a banned phrase would silently hide a real tombstone.
QUOTED = re.compile(r'"[^"]*"|`[^`]*`')

def rel_of(f):
    return f[len(proj) + 1:] if f.startswith(proj + "/") else f

def added_lines(f):
    rel = rel_of(f)
    try:
        d = subprocess.run(["git", "-C", proj, "diff", "HEAD", "-U0", "--", rel],
                           capture_output=True, text=True, timeout=10)
        if d.returncode == 0 and d.stdout.strip():
            return [ln[1:] for ln in d.stdout.splitlines()
                    if ln.startswith("+") and not ln.startswith("+++")]
        if d.returncode == 0:
            tracked = subprocess.run(
                ["git", "-C", proj, "ls-files", "--error-unmatch", "--", rel],
                capture_output=True, text=True, timeout=10)
            if tracked.returncode != 0:  # untracked new file: scan it whole
                with open(f, encoding="utf-8", errors="replace") as fh:
                    return fh.read().splitlines()
    except Exception:
        pass
    return []

hits, seen = [], set()
for f in files:
    if not os.path.isfile(f) or SKIP_NAMES.match(os.path.basename(f)):
        continue
    is_doc = f.lower().endswith(DOC_EXT)
    for ln in added_lines(f):
        if not (is_doc or CODE_COMMENT.search(ln)):
            continue
        if not PHRASES.search(QUOTED.sub(" ", ln)):
            continue
        entry = f"{rel_of(f)}: {ln.strip()[:120]}"
        if entry not in seen:
            seen.add(entry)
            hits.append(entry)

for h in hits[:12]:
    print(h)
PY
)"
fi

if [[ -n "$issues" ]]; then
  cat >&2 <<EOF
Post-edit checks found issues — fix them before moving on. These are
scoped to the files you just edited; pre-existing issues elsewhere are
suppressed.
$issues
EOF
fi

if [[ -n "$tombstones" ]]; then
  cat >&2 <<EOF

Advisory (not a correctness gate) — possible tombstone comment(s) in your
additions. Comments and docs describe the code as it is now, not its history;
the diff already records the change. Move any standing rationale to
.agents/debt-log.md and reference it inline as \`debt: <id>\`, then delete the
narration. If a flagged line is legitimate present-tense prose, leave it and
continue — this does not block.
$tombstones
EOF
fi

[[ -n "$issues" || -n "$tombstones" ]] && exit 2
exit 0
