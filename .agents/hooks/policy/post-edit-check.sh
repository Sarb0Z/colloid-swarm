#!/usr/bin/env bash
# Engine-agnostic policy: lint / format / typecheck edited files.
#
# Input  (stdin JSON): {"project_dir": "...", "files": ["...", ...]}
# Scoped strictly to the provided file list — never sweeps the repo. Every
# external tool is optional: a missing binary is skipped silently. The hosts
# wire this to their editor tools only, so a file written through a shell
# redirect is not linted. debt: colloid-shell-writes-skip-post-edit
#
# Two modes, wired as two hook entries, split by whether the work rewrites the
# tree. $POST_EDIT_MODE selects one:
#
#   write  — every fixer and formatter (ruff --fix, ruff format, prettier
#            --write, eslint --fix), then the advisory scans on the added
#            lines. Exits 0 always and reports through additionalContext, so an
#            advisory never rides the channel that carries type failures.
#            This entry MUST stay synchronous: a formatter running in the
#            background can read a file, be overtaken by the agent's next edit,
#            and write the pre-edit content back over it.
#   check  — gates that only report: ruff check, eslint, tsc --noEmit per workspace,
#            pyright per environment, and the skill-format linter. Exits 2 with
#            the findings on stderr. Nothing here rewrites a file the agent
#            edited, so this is the entry that runs in the background under
#            asyncRewake, where the slow typecheckers cost the session nothing.
#            Nothing caps how many run at once. debt: colloid-post-edit-no-process-cap
#
# Default is `check`: an engine that wires one entry gets the gate, not the
# formatter.
#
# The two entries run concurrently, so `check` can read a file `write` is still
# formatting. Nothing is lost, because `check` rewrites nothing — but a file
# caught mid-rewrite can be reported as a syntax error that does not exist. The
# next edit clears it, and the alternative (serialising the entries) is not
# something a hook can ask the host for.

set -euo pipefail

mode="${POST_EDIT_MODE:-check}"
if [[ "$mode" != "write" && "$mode" != "check" ]]; then
  echo "post-edit-check: POST_EDIT_MODE must be 'write' or 'check', got '$mode'" >&2
  exit 1
fi

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="$repo/.agents/hooks/lib"
cfg="$(python3 "$lib/config.py" "$repo/.agents/config.json" \
  hooks.post_edit_check.enabled=true \
  hooks.post_edit_check.tombstone_check=true \
  hooks.post_edit_check.nullsafety_check=true)"
enabled="$(printf '%s\n' "$cfg" | sed -n '1p')"
tombstone_check="$(printf '%s\n' "$cfg" | sed -n '2p')"
nullsafety_check="$(printf '%s\n' "$cfg" | sed -n '3p')"
[[ "$enabled" == "no" ]] && exit 0

# The payload is read once and piped onward. A single edit can carry hundreds of
# kilobytes, and an environment past ARG_MAX aborts the hook with E2BIG — which
# turns the gate off on exactly the largest changes.
input="$(cat)"

proj="$(printf '%s' "$input" | python3 "$lib/payload.py" project_dir)"

[[ -z "$proj" ]] && proj="$PWD"
cd "$proj"
proj="$(pwd -P)"

# One place decides what counts as a file this hook checks, so the groupers
# below never re-answer the question and never disagree about it. The rule and
# its reasoning are in ../lib/edited-files.py.
files="$(printf '%s' "$input" | python3 "$lib/edited-files.py" "$proj")"

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
#
# The cache is one `<key>\t<dir>\t<bin>` row per resolved key in a plain string,
# not an associative array: stock macOS ships bash 3.2, which has neither. A
# miss is cached too, as an empty binary — the walk that produced it is the
# expensive part. Every lookup is parameter expansion, so it costs no fork.
py_tool_cache=""
resolve_py_tool() {
  local name="$1" dir="$2" candidate key rest row
  PY_TOOL_DIR=""; PY_TOOL_BIN=""
  key="$name:$dir"
  rest="${py_tool_cache#*$'\n'"$key"$'\t'}"
  if [[ "$rest" != "$py_tool_cache" ]]; then
    row="${rest%%$'\n'*}"
    PY_TOOL_DIR="${row%%$'\t'*}"
    PY_TOOL_BIN="${row#*$'\t'}"
    [[ -z "$PY_TOOL_BIN" ]] && return 1
    return 0
  fi
  while :; do
    # node_modules/.bin too: pyright ships as an npm package, and a workspace
    # install of it is as invisible from the root as a nested virtualenv.
    for candidate in .venv/bin venv/bin node_modules/.bin; do
      if [[ -x "$dir/$candidate/$name" ]] && in_repo "$dir/$candidate/$name"; then
        PY_TOOL_DIR="$dir"; PY_TOOL_BIN="$dir/$candidate/$name"
        py_tool_cache+=$'\n'"$key"$'\t'"$PY_TOOL_DIR"$'\t'"$PY_TOOL_BIN"
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
    py_tool_cache+=$'\n'"$key"$'\t'$'\t'
    return 1
  fi
  py_tool_cache+=$'\n'"$key"$'\t'"$PY_TOOL_DIR"$'\t'"$PY_TOOL_BIN"
  return 0
}

issues=""
ts_edited=""      # .ts/.tsx — typechecked by tsc, per workspace
js_ts_edited=""   # all JS/TS — linted by eslint, formatted by prettier
reformatted=""    # files a fixer rewrote beyond the agent's own edit
py_edited=""      # .py — type-checked by pyright (ruff runs inline below)
skills_edited=""  # skills/<name>/*.md — frontmatter and layout, per skill

# Every fixer rewrites files, and the agent's next Edit carries an old_string
# that predates the rewrite. Checksum around the whole pass rather than asking
# each tool what it changed: ruff, prettier and eslint report that differently
# or not at all, and one measurement cannot disagree with itself.
sums() {
  local f
  while IFS= read -r f; do
    [[ -f "$f" ]] && printf '%s\t%s\n' "$(cksum < "$f")" "$f"
  done <<< "$1"
}
before_sums=""
[[ "$mode" == "write" ]] && before_sums="$(sums "$files")"

while IFS= read -r f; do
  [[ -z "$f" ]] && continue

  # edited-files.py emits absolute paths, and marks a path it cannot express on
  # a newline-delimited list with a leading "!" instead. Refuse it the same way
  # a tab is refused below, because the alternative is the silent drop.
  if [[ "$f" != /* ]]; then
    [[ "$mode" == "check" ]] &&
      issues+=$'\n'"[skipped] no checker can run on this path — a newline in a filename splits the list this hook reads. Rename it: ${f#!}"$'\n'
    continue
  fi

  [[ -f "$f" ]] || continue
  rel="${f#$proj/}"

  # Every per-workspace grouping below is tab-delimited, so a tab inside a path
  # would split into two names that do not exist — every tool would fail, the
  # failure would be swallowed, and the gate would pass having checked nothing.
  # Refuse the file loudly instead; a silent skip is the bug being avoided.
  if [[ "$f" == *$'\t'* ]]; then
    [[ "$mode" == "check" ]] &&
      issues+=$'\n'"[skipped] no checker can run on this path — a tab in a filename splits every per-workspace grouping below. Rename it: $rel"$'\n'
    continue
  fi

  case "$f" in
    *.py)
      if resolve_py_tool ruff "${f%/*}"; then
        ruff_bin="$PY_TOOL_BIN"
        if [[ "$mode" == "write" ]]; then
          "$ruff_bin" check --fix --force-exclude --quiet "$f" >/dev/null 2>&1 || true
          "$ruff_bin" format --force-exclude --quiet "$f" >/dev/null 2>&1 || true
        elif ! check_out="$("$ruff_bin" check --force-exclude --quiet --output-format=concise "$f" 2>&1)"; then
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
if [[ "$mode" == "check" && -n "$skills_edited" ]]; then
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
if [[ "$mode" == "check" && -n "$ts_edited" ]]; then
  workspaces="$(printf '%s' "$ts_edited" | python3 "$lib/ts-workspaces.py" "$proj")"

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

    # No --incremental: two background checks from consecutive edits would
    # write one build-info file concurrently, and a torn one makes the next run
    # report errors that are not there. This entry is off the critical path, so
    # a cold typecheck costs the session nothing.
    tsc_raw="$(cd "$ws" && "$tsc_bin" --noEmit -p "$ws_config" 2>&1 || true)"
    [[ -z "$tsc_raw" ]] && continue

    # tsc reports paths relative to the tsconfig dir, which is also its cwd here.
    ts_patterns=()
    IFS=$'\t' read -r -a ts_rel_list <<< "$ws_rels"
    for ts_rel in "${ts_rel_list[@]}"; do
      [[ -n "$ts_rel" ]] && ts_patterns+=(-e "$ts_rel")
    done
    scoped=""
    [[ ${#ts_patterns[@]} -gt 0 ]] &&
      scoped="$(printf '%s\n' "$tsc_raw" | grep -F "${ts_patterns[@]}" || true)"

    if [[ -n "$scoped" ]]; then
      ws_label="${ws#$proj/}/$ws_config"
      issues+=$'\n'"[tsc --noEmit] $ws_label (scoped to edited files)"$'\n'"$scoped"$'\n'
    fi
  done <<< "$workspaces"
fi

# Prettier + ESLint: the JS/TS analogue of the ruff pass above. Both fix in
# `write` mode and both report in `check` mode, which is the same rule ruff
# follows — one policy for every tool, so no reader has to remember which of
# them rewrites files. eslint --fix reaches past formatting (import pruning,
# let->const, plugin rewrites), which is precisely why it belongs in the
# synchronous entry rather than the background one. Config resolution is
# eslint/prettier's own job; this only has to find a binary that can run.
if [[ -n "$js_ts_edited" ]]; then
  # bun and npm both install a workspace's own devDependencies inside that
  # workspace, so a monorepo holds one eslint per app and a root that holds
  # none. Resolving from the root alone gives a gate that reports success
  # having run nothing. Group the edited files by the nearest
  # node_modules/.bin holding the tool, and run one pass per binary; a file
  # with no binary above it is skipped, as before.
  js_groups() {
    printf '%s' "$js_ts_edited" | python3 "$lib/js-groups.py" "$proj" "$1"
  }

  if [[ "$mode" == "write" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      prettier_bin="${line%%$'\t'*}"
      IFS=$'\t' read -r -a jsfiles <<< "${line#*$'\t'}"
      # Stay in $proj: prettier finds its config from each file's own path, so
      # the workspace's .prettierrc applies either way.
      "$prettier_bin" --write --log-level silent "${jsfiles[@]}" >/dev/null 2>&1 || true
    done <<< "$(js_groups prettier)"

    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      eslint_bin="${line%%$'\t'*}"
      IFS=$'\t' read -r -a jsfiles <<< "${line#*$'\t'}"
      (cd "${eslint_bin%/node_modules/.bin/*}" && "$eslint_bin" --fix "${jsfiles[@]}") >/dev/null 2>&1 || true
    done <<< "$(js_groups eslint)"
  else
    # --format json, not unix: ESLint 9 moved `unix` out of core, so asking for
    # it exits 2 with an empty stdout — indistinguishable from "no errors found"
    # to a reader that only greps stdout. json is core and stable across both
    # majors.
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
      eslint_errs="$(printf '%s' "$eslint_raw" | python3 "$lib/tool-errors.py" eslint "$proj" || true)"
      if [[ -n "$eslint_errs" ]]; then
        issues+=$'\n'"[eslint] (scoped to edited files; errors only)"$'\n'"$eslint_errs"$'\n'
      fi
    done <<< "$(js_groups eslint)"
  fi
fi

# Python type gate: ruff is lint/format only — it does no type inference, so
# None-flow, wrong-arg-type, and missing-return bugs pass it. Pyright fills that.
if [[ "$mode" == "check" && -n "$py_edited" ]]; then
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
      scoped="$(printf '%s' "$pyright_raw" | python3 "$lib/tool-errors.py" pyright "$proj")"
      [[ -n "$scoped" ]] && issues+=$'\n'"[pyright] (scoped to edited files)"$'\n'"$scoped"$'\n'
    fi
  done <<< "$(printf '%s' "$py_pairs" | cut -f1,2 | sort -u)"
fi

if [[ "$mode" == "write" ]]; then
  after_sums="$(sums "$files")"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case $'\n'"$before_sums"$'\n' in
      *$'\n'"$line"$'\n'*) ;;                       # unchanged
      *) reformatted+="${line#*$'\t'}"$'\n' ;;
    esac
  done <<< "$after_sums"
  reformatted="${reformatted%$'\n'}"
fi

# Tombstones: diary/changelog narration added in this edit. Advisory only —
# the standing rationale belongs in .agents/debt-log.md, not inline. Scans the
# additions vs HEAD (no mid-session commits, by policy) so pre-existing history
# comments aren't re-flagged.
tombstones=""
if [[ "$mode" == "write" && "$tombstone_check" == "yes" ]]; then
  tombstones="$(printf '%s' "$files" | python3 "$lib/added-scan.py" tombstones "$proj" || true)"
fi

# Null-safety: high-signal patterns tsc is blind to by construction — a cast
# silences strictNullChecks, and parsed JSON is typed `any`. Advisory, scoped to
# the lines this edit added (like tombstones), so legit pre-existing casts don't
# nag. Deliberately narrow: false misses beat crying wolf on every `!`.
nullsafety=""
if [[ "$mode" == "write" && "$nullsafety_check" == "yes" && -n "$js_ts_edited" ]]; then
  nullsafety="$(printf '%s' "$js_ts_edited" | python3 "$lib/added-scan.py" nullsafety "$proj" || true)"
fi

if [[ "$mode" == "check" ]]; then
  [[ -z "$issues" ]] && exit 0
  cat >&2 <<EOF
Post-edit checks found issues — fix them before moving on. These are
scoped to the files you just edited; pre-existing issues elsewhere are
suppressed.
$issues
EOF
  exit 2
fi

# write mode from here. Advisories never block: they leave through
# additionalContext at exit 0, so the exit-2 channel carries type and lint
# failures alone and keeps meaning what it says.
advisories=""

if [[ -n "$tombstones" ]]; then
  advisories+="Advisory — possible tombstone comment(s) in your additions. Comments and docs
describe the code as it is now, not its history; the diff already records the
change. Move any standing rationale to .agents/debt-log.md and reference it
inline as \`debt: <id>\`, then delete the narration. If a flagged line is
legitimate present-tense prose, leave it and continue.
$tombstones
"
fi

if [[ -n "$nullsafety" ]]; then
  advisories+="
Advisory — possible null-safety gaps in your additions. tsc is blind to these (a
cast silences it; parsed JSON is \`any\`). Prefer validating the shape or
narrowing the type over asserting it. If a flagged line is a deliberate,
proven-safe assertion, leave it and continue.
$nullsafety
"
fi

if [[ -n "$reformatted" ]]; then
  advisories+="
Advisory — a formatter rewrote these files after your edit (ruff, prettier or
eslint --fix). Their contents no longer match what you wrote, so an Edit whose
old_string predates this will fail. Re-read the file before your next edit,
check the diff before you describe it, and say so if the reformatting is larger
than your own change.
$reformatted
"
fi

[[ -z "$advisories" ]] && exit 0
printf '%s' "$advisories" | python3 "$lib/emit-context.py" PostToolUse
exit 0
