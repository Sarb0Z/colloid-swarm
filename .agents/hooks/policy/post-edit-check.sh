#!/usr/bin/env bash
# Engine-agnostic policy: lint / format / typecheck edited files.
#
# Input  (stdin JSON): {"project_dir": "...", "files": ["...", ...]}
# Output: exit 2 + stderr findings on issues; exit 0 otherwise.
#
# Scoped strictly to the provided file list — never sweeps the repo. Per
# language: Python -> ruff (lint+format) + pyright (types); TS/JS -> eslint
# (lint, autofix) + prettier (format) + tsc --noEmit (types, per workspace).
# Plus advisory scans on the added lines: tombstone narration + null-safety.
# Every external tool is optional: a missing binary is skipped silently.

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
print("yes" if pe.get("nullsafety_check", True) else "no")
PY
)"
enabled="$(printf '%s\n' "$cfg" | sed -n '1p')"
tombstone_check="$(printf '%s\n' "$cfg" | sed -n '2p')"
nullsafety_check="$(printf '%s\n' "$cfg" | sed -n '3p')"
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
proj="$(pwd -P)"

issues=""
ts_edited=""      # .ts/.tsx — typechecked by tsc, per workspace
js_ts_edited=""   # all JS/TS — linted by eslint, formatted by prettier
reformatted=""    # files prettier rewrote beyond the agent's own edit
py_edited=""      # .py — type-checked by pyright (ruff runs inline below)
skills_edited=""  # skills/<name>/*.md — frontmatter and layout, per skill

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
      py_edited+=$'\n'"$f"
      ;;
    *.ts|*.tsx)
      ts_edited+=$'\n'"$f"
      js_ts_edited+=$'\n'"$f"
      ;;
    *.js|*.jsx|*.mjs|*.cjs)
      js_ts_edited+=$'\n'"$f"
      ;;
    */skills/*/*.md)
      # Any file in a skill directory can break the skill's layout rules, so
      # the whole skill is revalidated from its SKILL.md.
      skill_md="${f%/skills/*}/skills/$(echo "${f#*/skills/}" | cut -d/ -f1)/SKILL.md"
      [[ -f "$skill_md" && "$skills_edited" != *"$skill_md"* ]] && skills_edited+=$'\n'"$skill_md"
      ;;
  esac
done <<< "$files"

# Agent Skills format: frontmatter validation plus reference-layout rules.
# Errors fail; the line-count and table-of-contents rules warn (see the script).
if [[ -n "$skills_edited" ]]; then
  linter="$proj/.agents/lint-skills.sh"
  if [[ -x "$linter" ]]; then
    if ! lint_out="$("$linter" $(echo "$skills_edited" | tr '\n' ' ') 2>&1)"; then
      issues+=$'\n'"[lint-skills]"$'\n'"$lint_out"$'\n'
    fi
  fi
fi

# TypeScript: each edited file is typechecked by its OWN workspace — the nearest
# ancestor holding a tsconfig.json (apps/*, packages/*), never a single hardcoded
# one. One tsc run per distinct workspace, errors scoped to the edited files.
# A workspace without a resolvable tsc is skipped silently.
if [[ -n "$ts_edited" ]]; then
  workspaces="$(TS_FILES="$ts_edited" PROJ="$proj" python3 <<'PY'
import os

proj = os.path.realpath(os.environ["PROJ"])
groups = {}
for p in os.environ["TS_FILES"].splitlines():
    p = p.strip()
    if not p:
        continue
    ap = os.path.realpath(p if os.path.isabs(p) else os.path.join(proj, p))
    if not (ap == proj or ap.startswith(proj + os.sep)):
        continue                       # outside the repo: not ours to check
    d = os.path.dirname(ap)
    while True:
        if os.path.isfile(os.path.join(d, "tsconfig.json")):
            groups.setdefault(d, []).append(os.path.relpath(ap, d))
            break
        if d == proj:
            break                      # no tsconfig anywhere above: skip
        d = os.path.dirname(d)

for ws, rels in groups.items():
    print("\t".join([ws] + rels))
PY
)"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ws="${line%%$'\t'*}"
    ws_rels="${line#*$'\t'}"

    if [[ -x "$ws/node_modules/.bin/tsc" ]]; then
      tsc_bin="$ws/node_modules/.bin/tsc"
    elif [[ -x "$proj/node_modules/.bin/tsc" ]]; then
      tsc_bin="$proj/node_modules/.bin/tsc"
    else
      continue                         # no typechecker installed: silent skip
    fi

    tsc_raw="$(cd "$ws" && "$tsc_bin" --noEmit --incremental --tsBuildInfoFile .tsbuildinfo-claude 2>&1 || true)"
    [[ -z "$tsc_raw" ]] && continue

    scoped="$(HOOK_INPUT="$tsc_raw" TS_RELS="$ws_rels" python3 <<'PY'
import os
raw = os.environ["HOOK_INPUT"]
rels = [r for r in os.environ["TS_RELS"].split("\t") if r]
# tsc reports paths relative to the tsconfig dir, which is also its cwd here.
keep = [line for line in raw.splitlines() if any(r in line for r in rels)]
print("\n".join(keep))
PY
)"

    if [[ -n "$scoped" ]]; then
      ws_label="${ws#$proj/}"
      issues+=$'\n'"[tsc --noEmit] $ws_label (scoped to edited files)"$'\n'"$scoped"$'\n'
    fi
  done <<< "$workspaces"
fi

# Prettier + ESLint: the JS/TS analogue of the ruff pass above. Prettier --write
# formats (like ruff format — deterministic, safe to apply). ESLint is
# report-only: unlike ruff, its --fix reaches past formatting (import pruning,
# let->const, plugin rewrites) and could rewrite the file under the agent
# mid-edit, so we surface errors and let the agent fix them. Config resolution is
# eslint/prettier's own job; a root-hoisted binary is used (skipped if absent).
if [[ -n "$js_ts_edited" ]]; then
  jsfiles=()
  while IFS= read -r jf; do [[ -n "$jf" ]] && jsfiles+=("$jf"); done <<< "$js_ts_edited"

  # A file that was already clean reformats to itself. A file that was not gets
  # rewritten whole, and that diff can dwarf the edit the agent actually made —
  # so record which files moved and say so, rather than changing them in silence.
  if [[ -x "$proj/node_modules/.bin/prettier" ]]; then
    pre_dirty="$("$proj/node_modules/.bin/prettier" --list-different "${jsfiles[@]}" 2>/dev/null || true)"
    "$proj/node_modules/.bin/prettier" --write --log-level silent "${jsfiles[@]}" >/dev/null 2>&1 || true
    [[ -n "$pre_dirty" ]] && reformatted="$(printf '%s\n' "$pre_dirty" | sed "s|^$proj/||")"
  fi

  # --format json, not unix: ESLint 9 moved `unix` out of core, so asking for it
  # exits 2 with an empty stdout — indistinguishable from "no errors found" to a
  # reader that only greps stdout. json is core and stable across both majors.
  if [[ -x "$proj/node_modules/.bin/eslint" ]]; then
    eslint_raw="$("$proj/node_modules/.bin/eslint" --format json "${jsfiles[@]}" 2>/dev/null || true)"
    eslint_errs="$(HOOK_INPUT="$eslint_raw" PROJ="$proj" python3 <<'EPY' || true
import json, os
try:
    results = json.loads(os.environ["HOOK_INPUT"] or "[]")
except Exception:
    raise SystemExit(0)
proj = os.environ["PROJ"]
for r in results:
    f = r.get("filePath", "")
    if f.startswith(proj + os.sep):
        f = f[len(proj) + 1:]
    for m in r.get("messages", []):
        if m.get("severity") != 2:
            continue
        rule = m.get("ruleId") or "parse-error"
        print(f"{f}:{m.get('line', 0)}:{m.get('column', 0)}: {m.get('message', '')} [{rule}]")
EPY
)"
    if [[ -n "$eslint_errs" ]]; then
      issues+=$'\n'"[eslint] (scoped to edited files; errors only)"$'\n'"$eslint_errs"$'\n'
    fi
  fi
fi

# Python type gate: ruff is lint/format only — it does no type inference, so
# None-flow, wrong-arg-type, and missing-return bugs pass it. Pyright fills that.
if [[ -n "$py_edited" ]]; then
  pyfiles=()
  while IFS= read -r pf; do [[ -n "$pf" ]] && pyfiles+=("$pf"); done <<< "$py_edited"

  pyright_bin=""
  if [[ -x "$proj/node_modules/.bin/pyright" ]]; then
    pyright_bin="$proj/node_modules/.bin/pyright"
  elif command -v pyright >/dev/null 2>&1; then
    pyright_bin="pyright"
  fi

  if [[ -n "$pyright_bin" ]]; then
    pyright_raw="$("$pyright_bin" --outputjson "${pyfiles[@]}" 2>/dev/null || true)"
    if [[ -n "$pyright_raw" ]]; then
      scoped="$(HOOK_INPUT="$pyright_raw" PROJ="$proj" python3 <<'PY'
import json, os
try:
    d = json.loads(os.environ["HOOK_INPUT"])
except Exception:
    raise SystemExit(0)
proj = os.environ["PROJ"]
for diag in d.get("generalDiagnostics", []):
    if diag.get("severity") != "error":
        continue
    f = diag.get("file", "")
    if f.startswith(proj + os.sep):
        f = f[len(proj) + 1:]
    line = diag.get("range", {}).get("start", {}).get("line", 0) + 1
    msg = (diag.get("message", "") or "").splitlines()[0]
    print(f"{f}:{line}: {msg}")
PY
)"
      [[ -n "$scoped" ]] && issues+=$'\n'"[pyright] (scoped to edited files)"$'\n'"$scoped"$'\n'
    fi
  fi
fi

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

# Null-safety: high-signal patterns tsc is blind to by construction — a cast
# silences strictNullChecks, and parsed JSON is typed `any`. Advisory, scoped to
# the lines this edit added (like tombstones), so legit pre-existing casts don't
# nag. Deliberately narrow: false misses beat crying wolf on every `!`.
nullsafety=""
if [[ "$nullsafety_check" == "yes" && -n "$js_ts_edited" ]]; then
  nullsafety="$(FILES="$js_ts_edited" PROJ="$proj" python3 <<'PY' || true
import os, re, subprocess

proj = os.environ["PROJ"]
files = [f for f in os.environ["FILES"].splitlines() if f.strip()]

PATS = [
    (re.compile(r'\bas\s+(any|unknown)\b'),
     "cast to any/unknown launders the type — tsc can't see past it"),
    (re.compile(r'[\w\)\]]\!(?=[.\[(])'),
     "non-null `!` assertion proves nothing at runtime — guard instead"),
    (re.compile(r'\b(JSON\.parse|await\s+[\w.]+\.json)\s*\('),
     "parsed data is `any` — validate its shape before use"),
]

# Strip quoted spans (double, single, backtick) before matching so a string
# literal that merely mentions "as any" or "JSON.parse(...)" isn't flagged as
# real code — prettier may have rewritten "…" to '…', so single quotes count too.
# Safe here because comment-leading lines are already skipped above.
QUOTED = re.compile(r'"[^"]*"|`[^`]*`' + r"|'[^']*'")

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
            if tracked.returncode != 0:
                with open(f, encoding="utf-8", errors="replace") as fh:
                    return fh.read().splitlines()
    except Exception:
        pass
    return []

hits, seen = [], set()
for f in files:
    if not os.path.isfile(f):
        continue
    rel = rel_of(f)
    for ln in added_lines(f):
        s = ln.strip()
        if s.startswith(("//", "*", "/*")):
            continue
        probe = QUOTED.sub(" ", ln)
        for pat, msg in PATS:
            if pat.search(probe):
                key = f"{rel}: {msg}"
                if key not in seen:
                    seen.add(key)
                    hits.append((key, s[:100]))
                break

for key, src in hits[:10]:
    print(f"{key}\n    {src}")
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

if [[ -n "$nullsafety" ]]; then
  cat >&2 <<EOF

Advisory (not a correctness gate) — possible null-safety gaps in your additions.
tsc is blind to these (a cast silences it; parsed JSON is \`any\`). Prefer
validating the shape or narrowing the type over asserting it. If a flagged line
is a deliberate, proven-safe assertion, leave it and continue — this does not block.
$nullsafety
EOF
fi

if [[ -n "$reformatted" ]]; then
  cat >&2 <<EOF

Advisory (not a correctness gate) — prettier reformatted these files, which were
not formatted before your edit. Their diff now contains changes you did not
make. Check the diff before you describe it, and say so if the reformatting is
larger than your own change.
$reformatted
EOF
fi

[[ -n "$issues" || -n "$tombstones" || -n "$nullsafety" || -n "$reformatted" ]] && exit 2
exit 0
