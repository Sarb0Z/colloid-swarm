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

[[ -z "$proj" ]] && proj="$PWD"
cd "$proj"
proj="$(pwd -P)"

# One place decides what counts as a file this hook checks, so the groupers
# below never re-answer the question and never disagree about it.
#
# Engines send different shapes: Claude Code absolute paths, the Codex adapter
# paths relative to the project. Both become absolute here, or the walk upward
# starts nowhere and every checker resolves from the root.
#
# In scope means inside the repository either literally or after following
# symlinks — a workspace symlinked out of the tree is still this repository's to
# check. The literal form travels onward, so the walk stays within the names the
# agent actually edited rather than jumping to wherever they happen to live.
files="$(HOOK_INPUT="$input" PROJ="$proj" python3 <<'PY'
import json, os
d = json.loads(os.environ["HOOK_INPUT"] or "{}")
proj = os.environ["PROJ"]
real_proj = os.path.realpath(proj)
seen = set()
for p in d.get("files") or []:
    if not isinstance(p, str) or not p:
        continue
    ap = os.path.abspath(os.path.join(proj, p))
    if not ap.startswith(proj + os.sep):
        # $proj is physical (pwd -P) while an engine may send the path through a
        # symlink — /tmp for /private/tmp is the everyday one. Re-express it
        # under $proj rather than dropping it, so that every walk upward below
        # has a terminator it will actually reach.
        rp = os.path.realpath(ap)
        if not rp.startswith(real_proj + os.sep):
            continue                   # outside the repo: not ours to check
        ap = proj + rp[len(real_proj):]
    if ap not in seen:
        seen.add(ap)
        print(ap)
PY
)"

[[ -z "$files" ]] && exit 0

# The walk resolves a directory, but what runs is a binary, and once a symlink
# is involved those are different questions: a directory inside the repository
# can point anywhere. Judge the binary, after following links. Failing this is
# not a reason to stop climbing — a workspace symlinked out of the tree should
# still be checked, by the nearest binary the repository does own, which the
# caller finds by continuing upward.
in_repo() {
  local resolved
  resolved="$(cd "${1%/*}" 2>/dev/null && pwd -P)" || return 1
  [[ "$resolved" == "$proj" || "$resolved" == "$proj"/* ]]
}

# A Python repository usually keeps its tools in a virtualenv rather than on
# PATH, and a session that has not activated it would otherwise get a gate that
# reports success having run nothing. Resolve repo-local first, like tsc — and
# like tsc, walk up from the edited file, because a monorepo puts the environment
# beside the package it serves (apps/api/.venv) rather than at the root. Every
# path arriving here is already absolute and already in scope.
#
# Sets PY_TOOL_DIR and PY_TOOL_BIN rather than printing them: this runs once per
# edited file, and a command substitution per call costs a fork the answer almost
# never changes across. PY_TOOL_DIR is the working directory the tool must run
# in — pyright reads its interpreter and config from there, so a batch spanning
# two packages needs one run per environment.
declare -A py_tool_cache=()
resolve_py_tool() {
  local name="$1" dir="$2" candidate key
  PY_TOOL_DIR=""; PY_TOOL_BIN=""
  key="$name:$dir"
  if [[ -n "${py_tool_cache[$key]+set}" ]]; then
    [[ -z "${py_tool_cache[$key]}" ]] && return 1
    PY_TOOL_DIR="${py_tool_cache[$key]%%$'\t'*}"
    PY_TOOL_BIN="${py_tool_cache[$key]#*$'\t'}"
    return 0
  fi
  while :; do
    # node_modules/.bin too: pyright ships as an npm package, and a workspace
    # install of it is as invisible from the root as a nested virtualenv.
    for candidate in .venv/bin venv/bin node_modules/.bin; do
      if [[ -x "$dir/$candidate/$name" ]] && in_repo "$dir/$candidate/$name"; then
        PY_TOOL_DIR="$dir"; PY_TOOL_BIN="$dir/$candidate/$name"
        py_tool_cache[$key]="$PY_TOOL_DIR"$'\t'"$PY_TOOL_BIN"
        return 0
      fi
    done
    [[ "$dir" == "$proj" ]] && break
    dir="${dir%/*}"
    [[ -z "$dir" ]] && dir="$proj"
  done
  # Only once the repository has nothing to offer: an activated environment, then
  # PATH. Proximity outranks $VIRTUAL_ENV rather than the reverse, because a
  # short-circuit here would collapse a batch spanning two packages onto one
  # interpreter — and an activated environment is a developer's normal state, so
  # that collapse would be the common case rather than the corner.
  if [[ -n "${VIRTUAL_ENV:-}" && -x "$VIRTUAL_ENV/bin/$name" ]]; then
    PY_TOOL_DIR="$proj"; PY_TOOL_BIN="$VIRTUAL_ENV/bin/$name"
  elif command -v "$name" >/dev/null 2>&1; then
    PY_TOOL_DIR="$proj"; PY_TOOL_BIN="$name"
  else
    py_tool_cache[$key]=""
    return 1
  fi
  py_tool_cache[$key]="$PY_TOOL_DIR"$'\t'"$PY_TOOL_BIN"
  return 0
}

issues=""
ts_edited=""      # .ts/.tsx — typechecked by tsc, per workspace
js_ts_edited=""   # all JS/TS — linted by eslint, formatted by prettier
reformatted=""    # files prettier rewrote beyond the agent's own edit
py_edited=""      # .py — type-checked by pyright (ruff runs inline below)
skills_edited=""  # skills/<name>/*.md — frontmatter and layout, per skill

while IFS= read -r f; do
  [[ -z "$f" || ! -f "$f" ]] && continue
  rel="${f#$proj/}"

  # Every per-workspace grouping below is tab-delimited, so a tab inside a path
  # would split into two names that do not exist — every tool would fail, the
  # failure would be swallowed, and the gate would pass having checked nothing.
  # Refuse the file loudly instead; a silent skip is the bug being avoided.
  if [[ "$f" == *$'\t'* ]]; then
    issues+=$'\n'"[skipped] no checker can run on this path — a tab in a filename splits every per-workspace grouping below. Rename it: $rel"$'\n'
    continue
  fi

  case "$f" in
    *.py)
      if resolve_py_tool ruff "${f%/*}"; then
        ruff_bin="$PY_TOOL_BIN"
        "$ruff_bin" check --fix --force-exclude --quiet "$f" >/dev/null 2>&1 || true
        "$ruff_bin" format --force-exclude --quiet "$f" >/dev/null 2>&1 || true
        if ! check_out="$("$ruff_bin" check --force-exclude --quiet --output-format=concise "$f" 2>&1)"; then
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
    */.agents/skills/*/*.md)
      # Any file in a skill can break that skill's layout rules. The linter
      # resolves each path to its owning SKILL.md, so no derivation here.
      skills_edited+=$'\n'"$f"
      ;;
  esac
done <<< "$files"

# Agent Skills format: frontmatter validation plus reference-layout rules.
# Paths travel newline-delimited in the environment so spaces survive.
# Unlike the external toolchain above, a missing linter is NOT skipped: it is
# repo-internal, so its absence means the gate did not run, which is a
# different thing from the gate passing.
if [[ -n "$skills_edited" ]]; then
  linter="$proj/.agents/lint-skills.sh"
  if [[ ! -x "$linter" ]]; then
    issues+=$'\n'"[lint-skills] cannot run: $linter is missing or not executable."$'\n'"Skill format was not validated. Restore it (chmod +x) rather than proceeding."$'\n'
  elif ! lint_out="$(LINT_SKILLS_PATHS="$skills_edited" "$linter" 2>&1)"; then
    issues+=$'\n'"[lint-skills]"$'\n'"$lint_out"$'\n'
  fi
fi

# TypeScript: each edited file is typechecked by its OWN workspace — the nearest
# ancestor holding a tsconfig.json (apps/*, packages/*), never a single hardcoded
# one. One tsc run per distinct workspace, errors scoped to the edited files.
# A workspace without a resolvable tsc is skipped silently.
if [[ -n "$ts_edited" ]]; then
  workspaces="$(TS_FILES="$ts_edited" PROJ="$proj" python3 <<'PY'
import json, os, re

proj = os.path.realpath(os.environ["PROJ"])


def read_config(path):
    """tsconfig permits comments and trailing commas; json does not."""
    try:
        with open(path, encoding="utf-8") as handle:
            raw = handle.read()
    except OSError:
        return {}
    raw = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)
    raw = re.sub(r"(^|\s)//[^\n]*", r"\1", raw)
    raw = re.sub(r",(\s*[}\]])", r"\1", raw)
    try:
        value = json.loads(raw)
    except ValueError:
        return {}
    return value if isinstance(value, dict) else {}


def literal_prefix(pattern):
    """The leading path of an include pattern, up to its first wildcard."""
    return re.split(r"[*?]", pattern, maxsplit=1)[0].rstrip("/")


def covers(config_dir, config, target_file):
    """Length of the longest include prefix that claims the file, else None."""
    rel = os.path.relpath(target_file, config_dir)
    if rel.startswith(os.pardir):
        return None
    for entry in config.get("files") or []:
        if os.path.normpath(entry) == os.path.normpath(rel):
            return len(rel)
    for pattern in config.get("exclude") or []:
        prefix = literal_prefix(pattern)
        if prefix and (rel == prefix or rel.startswith(prefix + os.sep)):
            return None
    best = None
    for pattern in config.get("include") or ["**/*"]:
        prefix = literal_prefix(pattern)
        if not prefix or rel == prefix or rel.startswith(prefix + os.sep):
            best = max(best or 0, len(prefix))
    return best


def project_for(workspace, target_file):
    """Pick the tsconfig that actually typechecks this file.

    A Vite or React workspace usually keeps `tsconfig.json` as a solution file
    -- `{"files": [], "references": [...]}`. tsc run against it reads no source,
    so the gate would report success having checked nothing. Where the nearest
    config declares no inputs of its own, follow its references and take the
    project whose include prefix claims the file most specifically.
    """
    config_path = os.path.join(workspace, "tsconfig.json")
    config = read_config(config_path)
    references = config.get("references") or []
    if not references:
        return "tsconfig.json"
    if (config.get("files") or config.get("include")) and \
            covers(workspace, config, target_file) is not None:
        return "tsconfig.json"
    best, best_score = None, -1
    for reference in references:
        path = reference.get("path") if isinstance(reference, dict) else None
        if not isinstance(path, str):
            continue
        candidate = os.path.normpath(os.path.join(workspace, path))
        if os.path.isdir(candidate):
            candidate = os.path.join(candidate, "tsconfig.json")
        if not os.path.isfile(candidate):
            continue
        score = covers(os.path.dirname(candidate), read_config(candidate), target_file)
        if score is not None and score > best_score:
            best, best_score = os.path.relpath(candidate, workspace), score
    return best or "tsconfig.json"


groups = {}
for ap in os.environ["TS_FILES"].splitlines():
    if not ap:
        continue                       # already absolute and already in scope
    d = os.path.dirname(ap)
    while True:
        if os.path.isfile(os.path.join(d, "tsconfig.json")):
            groups.setdefault((d, project_for(d, ap)), []).append(os.path.relpath(ap, d))
            break
        if d == proj or d == os.path.dirname(d):
            break                      # no tsconfig anywhere above: skip
        d = os.path.dirname(d)

for (ws, config), rels in groups.items():
    print("\t".join([ws, config] + rels))
PY
)"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ws="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    ws_config="${rest%%$'\t'*}"
    ws_rels="${rest#*$'\t'}"

    if [[ -x "$ws/node_modules/.bin/tsc" ]]; then
      tsc_bin="$ws/node_modules/.bin/tsc"
    elif [[ -x "$proj/node_modules/.bin/tsc" ]]; then
      tsc_bin="$proj/node_modules/.bin/tsc"
    else
      continue                         # no typechecker installed: silent skip
    fi

    tsc_raw="$(cd "$ws" && "$tsc_bin" --noEmit -p "$ws_config" --incremental --tsBuildInfoFile .tsbuildinfo-claude 2>&1 || true)"
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
      ws_label="${ws#$proj/}/$ws_config"
      issues+=$'\n'"[tsc --noEmit] $ws_label (scoped to edited files)"$'\n'"$scoped"$'\n'
    fi
  done <<< "$workspaces"
fi

# Prettier + ESLint: the JS/TS analogue of the ruff pass above. Prettier --write
# formats (like ruff format — deterministic, safe to apply). ESLint is
# report-only: unlike ruff, its --fix reaches past formatting (import pruning,
# let->const, plugin rewrites) and could rewrite the file under the agent
# mid-edit, so we surface errors and let the agent fix them. Config resolution is
# eslint/prettier's own job; this only has to find a binary that can run.
if [[ -n "$js_ts_edited" ]]; then
  # bun and npm both install a workspace's own devDependencies inside that
  # workspace, so a monorepo holds one eslint per app and a root that holds
  # none. Resolving from the root alone gives a gate that reports success
  # having run nothing. Group the edited files by the nearest
  # node_modules/.bin holding the tool, and run one pass per binary; a file
  # with no binary above it is skipped, as before.
  js_groups() {
    JS_FILES="$js_ts_edited" PROJ="$proj" TOOL="$1" python3 <<'PY'
import os
proj, tool = os.environ["PROJ"], os.environ["TOOL"]
real_proj = os.path.realpath(proj)
groups = {}
for ap in os.environ["JS_FILES"].splitlines():
    if not ap:
        continue                       # already absolute and already in scope
    d = os.path.dirname(ap)
    while True:
        candidate = os.path.join(d, "node_modules", ".bin", tool)
        # Same rule the shell's in_repo applies: judge the directory holding the
        # binary, never the binary's own link target. A .bin entry is a symlink
        # by construction and pnpm's can point into a store outside the project,
        # so following it would disarm the gate for every pnpm repository. What
        # must stay inside the repository is the directory, because that is what
        # a symlinked workspace can move. Keep climbing when it does not.
        holder = os.path.realpath(os.path.dirname(candidate))
        if os.access(candidate, os.X_OK) and (holder == real_proj or holder.startswith(real_proj + os.sep)):
            groups.setdefault(candidate, []).append(ap)
            break
        if d == proj or d == os.path.dirname(d):
            break                      # no install anywhere above: skip
        d = os.path.dirname(d)
for binary, files in groups.items():
    print("\t".join([binary] + files))
PY
  }

  # A file that was already clean reformats to itself. A file that was not gets
  # rewritten whole, and that diff can dwarf the edit the agent actually made —
  # so record which files moved and say so, rather than changing them in silence.
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    prettier_bin="${line%%$'\t'*}"
    IFS=$'\t' read -r -a jsfiles <<< "${line#*$'\t'}"
    # Stay in $proj. Prettier finds its config from each file's own path, so the
    # workspace's .prettierrc applies either way — and --list-different prints
    # relative to the working directory, so running elsewhere would label
    # apps/web/src/a.js and apps/api/src/a.js both as src/a.js.
    pre_dirty="$("$prettier_bin" --list-different "${jsfiles[@]}" 2>/dev/null || true)"
    "$prettier_bin" --write --log-level silent "${jsfiles[@]}" >/dev/null 2>&1 || true
    [[ -n "$pre_dirty" ]] && reformatted+="$pre_dirty"$'\n'
  done <<< "$(js_groups prettier)"
  reformatted="${reformatted%$'\n'}"

  # --format json, not unix: ESLint 9 moved `unix` out of core, so asking for it
  # exits 2 with an empty stdout — indistinguishable from "no errors found" to a
  # reader that only greps stdout. json is core and stable across both majors.
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    eslint_bin="${line%%$'\t'*}"
    IFS=$'\t' read -r -a jsfiles <<< "${line#*$'\t'}"
    # Keep the exit status. ESLint exits 2 with empty stdout when it cannot
    # resolve a config, which a stdout-only reader cannot tell apart from a
    # clean run — the same trap the --format note above describes, one level up.
    eslint_rc=0
    eslint_raw="$(cd "${eslint_bin%/node_modules/.bin/*}" && "$eslint_bin" --format json "${jsfiles[@]}" 2>/dev/null)" || eslint_rc=$?
    if [[ "$eslint_rc" -ne 0 && -z "$eslint_raw" ]]; then
      issues+=$'\n'"[eslint] exited $eslint_rc with no report — ${eslint_bin#$proj/} could not run (most often no resolvable config). Nothing was linted."$'\n'
      continue
    fi
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
  done <<< "$(js_groups eslint)"
fi

# Python type gate: ruff is lint/format only — it does no type inference, so
# None-flow, wrong-arg-type, and missing-return bugs pass it. Pyright fills that.
if [[ -n "$py_edited" ]]; then
  # pyright takes its interpreter from the environment it runs in, so one binary
  # cannot serve a batch that spans two packages: run it against the wrong
  # virtualenv and every third-party import is reportMissingImports at error
  # severity — a blocking false positive, which is worse than no gate. Group the
  # files by resolved environment and run one pass per group, from that
  # environment's own directory so its pyproject/pyrightconfig is the one read.
  py_pairs=""
  while IFS= read -r pf; do
    [[ -z "$pf" ]] && continue
    resolve_py_tool pyright "${pf%/*}" || continue
    py_pairs+="$PY_TOOL_DIR"$'\t'"$PY_TOOL_BIN"$'\t'"$pf"$'\n'
  done <<< "$py_edited"

  while IFS=$'\t' read -r py_ws pyright_bin; do
    [[ -z "$pyright_bin" ]] && continue
    pyfiles=()
    while IFS=$'\t' read -r w b pf; do
      [[ "$w" == "$py_ws" && "$b" == "$pyright_bin" ]] && pyfiles+=("$pf")
    done <<< "$py_pairs"
    [[ ${#pyfiles[@]} -eq 0 ]] && continue

    # cwd settles which pyrightconfig.json / [tool.pyright] applies. It does not
    # settle the interpreter: with no pythonPath configured pyright takes
    # `python` from PATH, and it ignores $VIRTUAL_ENV by design. Left alone, a
    # package's own environment is never consulted and every third-party import
    # comes back missing at error severity — a gate that blocks on nothing.
    py_interp=""
    case "$pyright_bin" in
      */.venv/bin/pyright|*/venv/bin/pyright)
        [[ -x "${pyright_bin%/pyright}/python" ]] && py_interp="${pyright_bin%/pyright}/python" ;;
      *)
        [[ -x "$py_ws/.venv/bin/python" ]] && py_interp="$py_ws/.venv/bin/python" ;;
    esac
    if [[ -n "$py_interp" ]]; then
      pyright_raw="$(cd "$py_ws" && "$pyright_bin" --pythonpath "$py_interp" --outputjson "${pyfiles[@]}" 2>/dev/null || true)"
    else
      pyright_raw="$(cd "$py_ws" && "$pyright_bin" --outputjson "${pyfiles[@]}" 2>/dev/null || true)"
    fi
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
  done <<< "$(printf '%s' "$py_pairs" | cut -f1,2 | sort -u)"
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
