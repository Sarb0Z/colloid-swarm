#!/usr/bin/env bash
# Firing tests for the path-expressibility contract between edited-files.py and
# post-edit-check.sh: the file list travels newline-delimited and is regrouped
# tab-delimited downstream, so neither character can appear in a path. Both must
# be refused out loud. A silent skip is a gate reporting a pass it never ran.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
dir="$scratch/fixture"

# The policy resolves its repository from its own location and reads that
# repository's .agents/config.json, which can turn the gate off. Run a copy from
# inside the fixture with the gate explicitly on, so these cases assert the
# policy's behaviour rather than the configuration of whatever repository the
# suite happens to be running in.
mkdir -p "$dir/.agents/hooks/policy" "$dir/.agents/hooks/lib"
cp "$repo/.agents/hooks/policy/post-edit-check.sh" "$dir/.agents/hooks/policy/"
cp "$repo"/.agents/hooks/lib/*.py "$dir/.agents/hooks/lib/"
printf '{"hooks":{"post_edit_check":{"enabled":true}}}\n' > "$dir/.agents/config.json"
policy="$dir/.agents/hooks/policy/post-edit-check.sh"
proj="$(cd "$dir" && pwd -P)"

# Both files exist, so a refusal below is the guard firing and not the existence
# test skipping a name that was never there.
mkdir -p "$dir/src"
printf 'x = 1\n' > "$dir/bad"$'\n'"name.py"
printf 'x = 1\n' > "$dir/tab"$'\t'"name.py"
printf 'x = 1\n' > "$dir/src/app.py"

emit() {  # <json files array> -> the list post-edit-check.sh would read
  printf '{"project_dir":"%s","files":%s}' "$proj" "$1" \
    | python3 "$dir/.agents/hooks/lib/edited-files.py" "$proj"
}
run() {  # <json files array> -> sets rc, err
  set +e
  err="$(printf '{"project_dir":"%s","files":%s}' "$proj" "$1" \
    | POST_EDIT_MODE=check bash "$policy" 2>&1 >/dev/null)"
  rc=$?
  set -e
}

# An ordinary path is unchanged, and stays absolute — the marker below relies on
# every real entry being distinguishable by its leading separator.
list="$(emit '["src/app.py"]')"
[[ "$list" == "$proj/src/app.py" ]] || fail "an ordinary path must pass through unchanged, got: $list"
ok "an ordinary path is emitted absolute and unchanged"

# A newline cannot be said on a newline-delimited list. It must arrive as one
# marked line, never as two names that do not exist.
list="$(emit '["bad\nname.py"]')"
[[ "$(printf '%s' "$list" | wc -l | tr -d ' ')" == "0" ]] || fail "a newline path must not split into two lines"
[[ "$list" == '!'*'\n'* ]] || fail "a newline path must be marked, got: $list"
ok "a newline in a path is marked instead of split"

# The whole hook must then say so and block, the way it already does for a tab.
run '["bad\nname.py"]'
[[ $rc -eq 2 ]] || fail "a newline path must exit 2, got $rc"
[[ "$err" == *"newline in a filename"* ]] || fail "a newline path must name the reason, got: $err"
ok "post-edit-check refuses a newline path out loud"

run '["tab\tname.py"]'
[[ $rc -eq 2 ]] || fail "a tab path must exit 2, got $rc"
[[ "$err" == *"tab in a filename"* ]] || fail "a tab path must name the reason, got: $err"
ok "post-edit-check refuses a tab path out loud"

# The refusal must be specific to the unusable path, not a blanket failure: a
# usable sibling in the same payload still has to be checked.
run '["src/app.py"]'
[[ $rc -eq 0 ]] || fail "a clean payload must pass, got $rc: $err"
ok "a clean payload still passes"

# A monorepo hoists eslint to the root while each app keeps its own flat
# config. ESLint 9 looks for that config from its working directory, so a run
# from the binary's folder finds none, exits 2, and lints nothing. The stand-in
# below behaves the same way: no eslint.config.* in its cwd, no report.
mkdir -p "$dir/node_modules/.bin" "$dir/apps/web/src"
cat > "$dir/node_modules/.bin/eslint" <<'SH'
#!/usr/bin/env bash
ls eslint.config.* >/dev/null 2>&1 || exit 2
file="${@: -1}"
printf '[{"filePath":"%s","messages":[{"ruleId":"probe/flat-config-found","severity":2,"message":"linted from %s","line":1,"column":1}],"errorCount":1}]' "$file" "$PWD"
exit 1
SH
chmod +x "$dir/node_modules/.bin/eslint"
printf 'export default [];\n' > "$dir/apps/web/eslint.config.mjs"
printf 'export const x = 1;\n' > "$dir/apps/web/src/a.ts"
run '["apps/web/src/a.ts"]'
[[ "$err" == *"probe/flat-config-found"* ]] \
  || fail "a hoisted eslint must run from the workspace that holds the flat config, got: $err"
ok "a hoisted eslint lints a workspace file against that workspace's flat config"

# Dart: `dart format` rewrites in the write entry, and the analyzer reports in
# the check entry, from the package that owns the file — the nearest ancestor
# holding a pubspec.yaml. A Flutter package is analyzed by `flutter analyze`,
# which resolves the Flutter SDK that plain `dart analyze` cannot. The stubs log
# their arguments and working directory so the shape of each run is observable.
bin="$scratch/bin"; mkdir -p "$bin" "$dir/app/lib" "$dir/pkg/lib"
for tool in dart flutter; do
  cat > "$bin/$tool" <<'SH'
#!/usr/bin/env bash
tool="$(basename "$0")"
printf '%s %s | %s\n' "$tool" "$*" "$PWD" >> "$STUB_LOG_DIR/$tool.log"
[[ "$1" == analyze ]] && { printf '  error - %s - probe/dart-analyze-ran\n' "$tool"; exit 3; }
exit 0
SH
  chmod +x "$bin/$tool"
done
printf 'name: app\ndependencies:\n  flutter:\n    sdk: flutter\n' > "$dir/app/pubspec.yaml"
printf 'name: pkg\n' > "$dir/pkg/pubspec.yaml"
printf 'void main() {}\n' > "$dir/app/lib/main.dart"
printf 'void main() {}\n' > "$dir/pkg/lib/a.dart"
mkdir -p "$dir/app/.dart_tool" "$dir/pkg/.dart_tool"
printf '{}\n' > "$dir/app/.dart_tool/package_config.json"
printf '{}\n' > "$dir/pkg/.dart_tool/package_config.json"
run_dart() {  # <mode> <json files array> -> sets rc, err; PATH carries the stubs
  set +e
  err="$(printf '{"project_dir":"%s","files":%s}' "$proj" "$2" \
    | STUB_LOG_DIR="$scratch" PATH="$bin:$PATH" POST_EDIT_MODE="$1" bash "$policy" 2>&1 >/dev/null)"
  rc=$?
  set -e
}
: > "$scratch/dart.log"; : > "$scratch/flutter.log"
run_dart check '["app/lib/main.dart"]'
[[ $rc -eq 2 && "$err" == *"probe/dart-analyze-ran"* ]] || fail "a Flutter file must be analyzed, got rc=$rc: $err"
[[ "$(cat "$scratch/flutter.log")" == "flutter analyze --no-pub $proj/app/lib/main.dart | $proj/app" ]] \
  || fail "flutter analyze must run from the package on the edited file, got: $(cat "$scratch/flutter.log")"
[[ ! -s "$scratch/dart.log" ]] || fail "a Flutter package must not be analyzed by dart"
ok "a Flutter file is analyzed by flutter analyze --no-pub from its package"

run_dart check '["pkg/lib/a.dart"]'
[[ $rc -eq 2 && "$err" == *"probe/dart-analyze-ran"* ]] || fail "a Dart file must be analyzed, got rc=$rc: $err"
[[ "$(cat "$scratch/dart.log")" == "dart analyze $proj/pkg/lib/a.dart | $proj/pkg" ]] \
  || fail "dart analyze must run from the package on the edited file, got: $(cat "$scratch/dart.log")"
ok "a plain Dart file is analyzed by dart analyze from its package"

: > "$scratch/dart.log"
run_dart write '["pkg/lib/a.dart"]'
[[ $rc -eq 0 ]] || fail "the write entry must exit 0, got $rc: $err"
[[ "$(cat "$scratch/dart.log")" == "dart format $proj/pkg/lib/a.dart | $proj" ]] \
  || fail "write mode must run dart format on the edited file, got: $(cat "$scratch/dart.log")"
ok "write mode formats a Dart file and never analyzes it"

# An unresolved package is skipped with a note: analyzing it would run pub get.
mv "$dir/pkg/.dart_tool/package_config.json" "$scratch/pc.json"
: > "$scratch/dart.log"
run_dart check '["pkg/lib/a.dart"]'
[[ $rc -eq 0 ]] || fail "an unresolved package must not fail the hook, got rc=$rc: $err"
[[ "$err" == *"dart pub get"* ]] || fail "the skip must say to run dart pub get, got: $err"
[[ ! -s "$scratch/dart.log" ]] || fail "an unresolved package must not be analyzed"
mv "$dir/app/.dart_tool/package_config.json" "$scratch/pc.json"
run_dart check '["app/lib/main.dart"]'
[[ $rc -eq 0 && "$err" == *"flutter pub get"* ]] || fail "an unresolved Flutter package must be skipped with a note, got rc=$rc: $err"
ok "an unresolved package is skipped with a pub get note, exit-neutral"

# Without a Dart toolchain the language is skipped silently, like the others.
set +e
err="$(printf '{"project_dir":"%s","files":["app/lib/main.dart"]}' "$proj" \
  | PATH="/usr/bin:/bin" POST_EDIT_MODE=check /bin/bash "$policy" 2>&1 >/dev/null)"; rc=$?
set -e
[[ $rc -eq 0 && -z "$err" ]] || fail "a missing dart must be silent, got rc=$rc: $err"
ok "a missing Dart toolchain is skipped silently"

# ---------------------------------------------------------------------------
# A repository that configures a checker has asked for it. "Configured but
# could not run" and "ran but could not be read" are findings; "not configured"
# stays silent. Rows use the real tsc and pyright where they are installed
# (marked REAL) and stubs everywhere else (marked STUB); a real tool that is
# absent skips its rows out loud rather than passing them.
# ---------------------------------------------------------------------------
tools="$scratch/tools"; mkdir -p "$tools"
for real in tsc pyright node; do
  found="$(command -v "$real" 2>/dev/null || true)"
  [[ -n "$found" ]] && ln -s "$found" "$tools/$real"
done
have_real() { [[ -e "$tools/$1" ]]; }
skip() {
  [[ -z "${CI:-}" ]] || fail "$1 needs a real $2, and CI is set: install it rather than skip the row"
  printf 'SKIP  %s (needs a real %s)\n' "$1" "$2"
}

newfix() {  # <name> -> sets fx, fxproj: a fixture repository with its own copy of the policy
  fx="$scratch/$1"
  mkdir -p "$fx/.agents/hooks/policy" "$fx/.agents/hooks/lib" "$fx/src"
  cp "$repo/.agents/hooks/policy/post-edit-check.sh" "$fx/.agents/hooks/policy/"
  cp "$repo"/.agents/hooks/lib/*.py "$fx/.agents/hooks/lib/"
  printf '{"hooks":{"post_edit_check":{"enabled":true}}}\n' > "$fx/.agents/config.json"
  fxproj="$(cd "$fx" && pwd -P)"
}
fxrun() {  # <mode> <session> <json files array> -> sets rc, err; PATH holds only the real tools
  set +e
  err="$(printf '{"project_dir":"%s","session_id":"%s","files":%s}' "$fxproj" "$2" "$3" \
    | PATH="${fxpath:-$tools:/usr/bin:/bin}" POST_EDIT_MODE="$1" /bin/bash "$fx/.agents/hooks/policy/post-edit-check.sh" 2>&1 >/dev/null)"
  rc=$?
  set -e
}
stub() {  # <path> <body> -> an executable stub
  mkdir -p "$(dirname "$1")"
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$1"
  chmod +x "$1"
}
strip_of() { python3 "$repo/.agents/hooks/lib/readout.py" strip "$fxproj" "$1"; }

# --- node_modules linked to the main checkout (F22) ------------------------
main="$scratch/main"; mkdir -p "$main/src"
git -C "$main" init -q
printf 'export const x = 1;\n' > "$main/src/a.js"
git -C "$main" add -A
git -C "$main" -c user.name=t -c user.email=t@example.invalid commit -q -m base
mkdir -p "$main/node_modules/.bin"
cp "$dir/node_modules/.bin/eslint" "$main/node_modules/.bin/eslint"
lane="$scratch/lane"
git -C "$main" worktree add -q "$lane" -b lane-branch
lane="$(cd "$lane" && pwd -P)"
ln -s "$main/node_modules" "$lane/node_modules"
printf 'export default [];\n' > "$lane/eslint.config.mjs"
mkdir -p "$lane/.agents/hooks/policy" "$lane/.agents/hooks/lib"
cp "$repo/.agents/hooks/policy/post-edit-check.sh" "$lane/.agents/hooks/policy/"
cp "$repo"/.agents/hooks/lib/*.py "$lane/.agents/hooks/lib/"
printf '{"hooks":{"post_edit_check":{"enabled":true}}}\n' > "$lane/.agents/config.json"

rows="$(printf '%s\n' "$lane/src/a.js" | python3 "$repo/.agents/hooks/lib/js-groups.py" "$lane" "$main" eslint)"
[[ "$(printf '%s' "$rows" | grep -c .)" == "1" ]] || fail "a node_modules linked to the main checkout must form one group, got: $rows"
ok "js-groups accepts a node_modules linked to the main checkout of the same repository"

foreign="$scratch/foreign"; mkdir -p "$foreign/src"
git -C "$foreign" init -q
ln -s "$main/node_modules" "$foreign/node_modules"
printf 'export const x = 1;\n' > "$foreign/src/a.js"
rows="$(printf '%s\n' "$foreign/src/a.js" | python3 "$repo/.agents/hooks/lib/js-groups.py" "$(cd "$foreign" && pwd -P)" "$(cd "$foreign" && pwd -P)" eslint)"
[[ -z "$rows" ]] || fail "a node_modules linked into another repository must be refused, got: $rows"
ok "js-groups refuses a node_modules that resolves into a different repository"

set +e
err="$(printf '{"project_dir":"%s","session_id":"s","files":["src/a.js"]}' "$lane" \
  | PATH="$tools:/usr/bin:/bin" POST_EDIT_MODE=check /bin/bash "$lane/.agents/hooks/policy/post-edit-check.sh" 2>&1 >/dev/null)"; rc=$?
set -e
[[ $rc -eq 2 && "$err" == *"probe/flat-config-found"* ]] || fail "a lane with a linked node_modules must report an ESLint error, got rc=$rc: $err"
ok "STUB eslint: a lane worktree with a linked node_modules reports an ESLint error"

# A worktree of a bare repository has no main checkout: the first entry of
# `git worktree list` is the bare directory, so a node_modules linked into a
# sibling repository must stay refused.
repos="$scratch/repos"; mkdir -p "$repos/other/node_modules/.bin"
cp "$dir/node_modules/.bin/eslint" "$repos/other/node_modules/.bin/eslint"
git init -q --bare "$repos/proj.git"
seed="$scratch/seed"; git init -q "$seed"
git -C "$seed" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m base
git -C "$seed" push -q "$repos/proj.git" HEAD:refs/heads/main
git -C "$repos/proj.git" worktree add -q "$repos/proj-lane" main
barelane="$(cd "$repos/proj-lane" && pwd -P)"
ln -s "$repos/other/node_modules" "$barelane/node_modules"
printf 'export default [];\n' > "$barelane/eslint.config.mjs"; mkdir -p "$barelane/src"; printf 'export const x = 1;\n' > "$barelane/src/a.js"
mkdir -p "$barelane/.agents/hooks/policy" "$barelane/.agents/hooks/lib"
cp "$repo/.agents/hooks/policy/post-edit-check.sh" "$barelane/.agents/hooks/policy/"
cp "$repo"/.agents/hooks/lib/*.py "$barelane/.agents/hooks/lib/"
printf '{"hooks":{"post_edit_check":{"enabled":true}}}\n' > "$barelane/.agents/config.json"
set +e
err="$(printf '{"project_dir":"%s","session_id":"s","files":["src/a.js"]}' "$barelane" \
  | PATH="$tools:/usr/bin:/bin" POST_EDIT_MODE=check /bin/bash "$barelane/.agents/hooks/policy/post-edit-check.sh" 2>&1 >/dev/null)"; rc=$?
set -e
[[ "$err" != *"probe/flat-config-found"* && "$err" == *"[eslint] configured in eslint.config.mjs but not installed"* ]] \
  || fail "a worktree of a bare repository must not trust a sibling repository's node_modules, got rc=$rc: $err"
ok "a worktree of a bare repository refuses a node_modules linked into a sibling repository"

# --- ESLint with no report (F23) and a configured checker with no binary ---
newfix noreport
stub "$fx/node_modules/.bin/eslint" 'exit 2'
printf 'export default [];\n' > "$fx/eslint.config.mjs"
printf 'export const x = 1;\n' > "$fx/src/a.js"
fxrun check s1 '["src/a.js"]'
[[ $rc -eq 2 && "$err" == *"[eslint] exited 2 with no report"* ]] || fail "an eslint that exits 2 with no report must be named, got rc=$rc: $err"
ok "STUB eslint: exit 2 with no report is a finding, not a pass"

newfix configured
printf 'export default [];\n' > "$fx/eslint.config.mjs"
printf '{}\n' > "$fx/.prettierrc"
printf '{"compilerOptions":{"noEmit":true},"include":["src"]}\n' > "$fx/tsconfig.json"
printf '{}\n' > "$fx/pyrightconfig.json"
printf 'export const x = 1;\n' > "$fx/src/a.ts"
printf 'x = 1\n' > "$fx/src/a.py"
printf 'lockfileVersion: 9\n' > "$fx/pnpm-lock.yaml"
fxrun check s1 '["src/a.ts"]'
[[ "$err" == *"[eslint] configured in eslint.config.mjs but not installed: pnpm add -D eslint"* ]] || fail "ESLint config without eslint must be named with its install command, got: $err"
[[ "$err" == *"[prettier] configured in .prettierrc but not installed: pnpm add -D prettier"* ]] || fail "Prettier config without prettier must be named, got: $err"
[[ "$err" == *"[tsc] configured in tsconfig.json but not installed: pnpm add -D typescript"* ]] || fail "a tsconfig without tsc must be named, got: $err"
ok "a configured ESLint, Prettier and tsc with no binary are each named with an install command"

fxpath="/usr/bin:/bin" fxrun check s1 '["src/a.py"]'
[[ "$err" == *"[pyright] configured in pyrightconfig.json but not installed: uv tool install pyright"* ]] || fail "a pyright config without pyright must be named, got: $err"
ok "a configured pyright with no binary is named"

newfix dartcfg
mkdir -p "$fx/pkg/lib"
printf 'name: pkg\n' > "$fx/pkg/pubspec.yaml"
printf 'include: package:lints/recommended.yaml\n' > "$fx/pkg/analysis_options.yaml"
printf 'void main() {}\n' > "$fx/pkg/lib/a.dart"
fxrun check s1 '["pkg/lib/a.dart"]'
[[ "$err" == *"[dart] configured in pkg/analysis_options.yaml but not installed"* ]] || fail "a Dart analyzer config without a Dart SDK must be named, got: $err"
ok "a configured Dart analyzer with no SDK is named"

# --- ruff: both modes, and the once-per-session missing report -------------
newfix ruffcfg
printf '[tool.ruff]\nline-length = 100\n' > "$fx/pyproject.toml"
printf 'x = 1\n' > "$fx/src/a.py"
fxrun check s1 '["src/a.py"]'
[[ $rc -eq 2 && "$err" == *"[ruff] configured in pyproject.toml but not installed: uv add --dev ruff"* ]] \
  || fail "the first edit must name the missing ruff, got rc=$rc: $err"
[[ "$(strip_of s1)" == "checks: ruff missing" ]] || fail "the checks strip must name ruff, got: $(strip_of s1)"
fxrun check s1 '["src/a.py"]'
[[ $rc -eq 0 && -z "$err" ]] || fail "the second edit in the session must be quiet, got rc=$rc: $err"
[[ "$(strip_of s1)" == "checks: ruff missing" ]] || fail "the strip must stay while ruff is missing"
fxrun check s2 '["src/a.py"]'
[[ "$err" == *"[ruff] configured in pyproject.toml"* ]] || fail "a new session must hear about the missing ruff again, got: $err"
ok "a ruff config with no ruff names it on the first edit of a session, never on the second"

newfix ruffnone
printf 'x = 1\n' > "$fx/src/a.py"
fxrun check s1 '["src/a.py"]'
[[ $rc -eq 0 && -z "$err" ]] || fail "a repository with no ruff config must stay silent, got rc=$rc: $err"
[[ -z "$(strip_of s1)" ]] || fail "an unconfigured checker must not reach the readout"
ok "a repository that never configured ruff hears nothing"

newfix ruffstub
printf '[tool.ruff]\n' > "$fx/pyproject.toml"
printf 'x = 1\n' > "$fx/src/a.py"
stub "$fx/.venv/bin/ruff" 'printf "%s\n" "$*" >> "$STUB_LOG_DIR/ruff.log"
[[ "$1" == check && " $* " != *" --fix "* ]] && { printf "src/a.py:1:1: probe/ruff-check-ran\n"; exit 1; }
exit 0'
: > "$scratch/ruff.log"
set +e
err="$(printf '{"project_dir":"%s","session_id":"s1","files":["src/a.py"]}' "$fxproj" \
  | STUB_LOG_DIR="$scratch" PATH="$tools:/usr/bin:/bin" POST_EDIT_MODE=check /bin/bash "$fx/.agents/hooks/policy/post-edit-check.sh" 2>&1 >/dev/null)"; rc=$?
set -e
[[ $rc -eq 2 && "$err" == *"probe/ruff-check-ran"* ]] || fail "STUB ruff in check mode must report, got rc=$rc: $err"
! grep -q -e "--fix" -e "^format" "$scratch/ruff.log" || fail "check mode must not rewrite, got: $(cat "$scratch/ruff.log")"
: > "$scratch/ruff.log"
set +e
err="$(printf '{"project_dir":"%s","session_id":"s1","files":["src/a.py"]}' "$fxproj" \
  | STUB_LOG_DIR="$scratch" PATH="$tools:/usr/bin:/bin" POST_EDIT_MODE=write /bin/bash "$fx/.agents/hooks/policy/post-edit-check.sh" 2>&1 >/dev/null)"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "write mode must exit 0, got $rc: $err"
grep -q -- "check --fix" "$scratch/ruff.log" && grep -q "^format" "$scratch/ruff.log" || fail "write mode must run ruff check --fix and ruff format, got: $(cat "$scratch/ruff.log")"
ok "STUB ruff: check mode reports and rewrites nothing; write mode fixes and formats"

# the `checks` readout clears once ruff runs in that workspace
newfix ruffclear
printf '[tool.ruff]\n' > "$fx/pyproject.toml"
printf 'x = 1\n' > "$fx/src/a.py"
fxrun check s1 '["src/a.py"]'
[[ "$(strip_of s1)" == "checks: ruff missing" ]] || fail "setup: the strip must name ruff"
python3 "$fx/.agents/hooks/lib/readout.py" note "$fxproj" s1 | grep -q "ruff: configured in pyproject.toml, not installed: uv add --dev ruff" \
  || fail "the checks note must name the config and the install command"
stub "$fx/.venv/bin/ruff" 'exit 0'
fxrun check s1 '["src/a.py"]'
[[ -z "$(strip_of s1)" ]] || fail "the strip must clear once ruff runs, got: $(strip_of s1)"
ok "the checks readout names a missing checker with its install command, and clears once it runs"

# --- tsc: REAL ---------------------------------------------------------------
if have_real tsc; then
  newfix tsccaller
  mkdir -p "$fx/node_modules/.bin"; ln -s "$tools/tsc" "$fx/node_modules/.bin/tsc"
  printf '{"compilerOptions":{"strict":true,"module":"esnext","moduleResolution":"bundler","noEmit":true},"include":["src"]}\n' > "$fx/tsconfig.json"
  printf 'export function f(a: number): number { return a; }\n' > "$fx/src/lib.ts"
  printf 'import { f } from "./lib";\nexport const x = f(1);\n' > "$fx/src/caller.ts"
  fxrun check s1 '["src/lib.ts"]'
  [[ $rc -eq 0 && -z "$err" ]] || fail "a clean first run must pass and set the baseline, got rc=$rc: $err"
  printf 'export function f(a: number, b: number): number { return a + b; }\n' > "$fx/src/lib.ts"
  fxrun check s1 '["src/lib.ts"]'
  [[ $rc -eq 2 && "$err" == *"new errors outside the edited files"* && "$err" == *"src/caller.ts"* ]] \
    || fail "a signature change must report the error in the unedited caller, got rc=$rc: $err"
  fxrun check s1 '["src/lib.ts"]'
  [[ $rc -eq 0 && -z "$err" ]] || fail "the same caller error must be reported once, got rc=$rc: $err"
  printf 'export function f(a: number): number { return a; }\n' > "$fx/src/lib.ts"
  fxrun check s1 '["src/lib.ts"]'
  [[ $rc -eq 0 && -z "$err" ]] || fail "an error that goes away is not news, got rc=$rc: $err"
  ok "REAL tsc: a signature change reports the type error it causes in an unedited caller, once"

  printf 'export const bad: number = "s";\n' > "$fx/src/lib.ts"
  fxrun check s1 '["src/lib.ts"]'
  [[ $rc -eq 2 && "$err" == *"[tsc --noEmit]"* && "$err" == *"src/lib.ts"* ]] || fail "an error in the edited file must be reported, got rc=$rc: $err"
  ok "REAL tsc: an error in the edited file is reported"

  newfix tscbroken
  mkdir -p "$fx/node_modules/.bin"; ln -s "$tools/tsc" "$fx/node_modules/.bin/tsc"
  printf '{ "compilerOptions": ' > "$fx/tsconfig.json"
  printf 'export const a = 1;\n' > "$fx/src/a.ts"
  fxrun check s1 '["src/a.ts"]'
  [[ $rc -eq 2 && "$err" == *"tsconfig.json could not be read as a project"* ]] || fail "a broken tsconfig must be reported, got rc=$rc: $err"
  ok "REAL tsc: a broken tsconfig.json is a finding, not a pass"
else
  skip "tsc caller and broken-tsconfig rows" tsc
fi

newfix tscstub
printf '{"include":["src"]}\n' > "$fx/tsconfig.json"
printf 'export const a = 1;\n' > "$fx/src/a.ts"
stub "$fx/node_modules/.bin/tsc" 'printf "internal compiler fault\nsecond line\n"; exit 3'
fxrun check s1 '["src/a.ts"]'
[[ $rc -eq 2 && "$err" == *"[tsc] tsconfig.json exited 3 with no parsable output: internal compiler fault | second line"* ]] \
  || fail "STUB tsc: a non-zero exit with no parsable line must be reported with its first lines, got rc=$rc: $err"
ok "STUB tsc: a non-zero exit with no parsable output is reported with its first lines"

# --- pyright: REAL and STUB --------------------------------------------------
if have_real pyright; then
  newfix pyreal
  printf '{}\n' > "$fx/pyrightconfig.json"
  printf 'x: int = "s"\n' > "$fx/src/a.py"
  fxrun check s1 '["src/a.py"]'
  [[ $rc -eq 2 && "$err" == *"[pyright] (scoped to edited files)"* && "$err" == *"src/a.py:1"* ]] \
    || fail "REAL pyright must report a type error in the edited file, got rc=$rc: $err"
  ok "REAL pyright: a type error in the edited file is reported"
else
  skip "pyright type-error row" pyright
fi

newfix pystub
printf '{}\n' > "$fx/pyrightconfig.json"
printf 'x = 1\n' > "$fx/src/a.py"
stub "$fx/node_modules/.bin/pyright" 'echo "No configuration file found: bad pythonVersion" >&2; exit 2'
fxrun check s1 '["src/a.py"]'
[[ $rc -eq 2 && "$err" == *"[pyright] . exited 2 with no parsable output: No configuration file found: bad pythonVersion"* ]] \
  || fail "STUB pyright: stderr of an unreadable run must be kept and reported, got rc=$rc: $err"
ok "STUB pyright: an unreadable run is reported with its stderr"

# --- tsc baseline and caller logic, on a stub that prints a file --------------
# The stub prints $fx/tsc.out and exits 1 when it holds anything, so these rows
# run where tsc is not installed.
tsc_stub() {  # <fixture> -> installs the stub tsc
  stub "$1/node_modules/.bin/tsc" 'out="$(cat "$(dirname "$0")/../../tsc.out")"
[[ -z "$out" ]] && exit 0
printf "%s\n" "$out"; exit 1'
}
newfix tscswitch
tsc_stub "$fx"
printf '{"include":["src"]}\n' > "$fx/tsconfig.json"
printf 'export const a: number = "s";\n' > "$fx/src/a.ts"
printf 'export const b = 1;\n' > "$fx/src/b.ts"
printf "src/a.ts(1,14): error TS2322: Type 'string' is not assignable to type 'number'.\n" > "$fx/tsc.out"
fxrun check s1 '["src/b.ts"]'
[[ $rc -eq 0 && -z "$err" ]] || fail "the first run in a session sets the baseline silently, got rc=$rc: $err"
fxrun check s1 '["src/a.ts"]'
[[ $rc -eq 2 && "$err" == *"[tsc --noEmit]"* && "$err" != *"new errors outside"* ]] \
  || fail "an error in the edited file is reported as scoped, never as new, got rc=$rc: $err"
fxrun check s1 '["src/b.ts"]'
[[ $rc -eq 0 && -z "$err" ]] || fail "switching to a file whose neighbour already had an error must stay quiet, got rc=$rc: $err"
fxrun check s1 '["src/a.ts"]'
[[ $rc -eq 2 && "$err" != *"new errors outside"* ]] || fail "switching back must report the edited file's own error only, got rc=$rc: $err"
fxrun check s1 '["src/b.ts"]'
[[ $rc -eq 0 && -z "$err" ]] || fail "switching again must stay quiet, got rc=$rc: $err"
ok "STUB tsc: an error another file already had is not blamed on the edit that switches files"

newfix tsccallerstub
tsc_stub "$fx"
printf '{"include":["src"]}\n' > "$fx/tsconfig.json"
printf 'export const a = 1;\n' > "$fx/src/lib.ts"
: > "$fx/tsc.out"
fxrun check s1 '["src/lib.ts"]'
[[ $rc -eq 0 ]] || fail "setup: a clean run must pass, got rc=$rc: $err"
printf "src/caller.ts(2,18): error TS2554: Expected 2 arguments, but got 1.\n" > "$fx/tsc.out"
fxrun check s1 '["src/lib.ts"]'
[[ $rc -eq 2 && "$err" == *"new errors outside the edited files"* && "$err" == *"src/caller.ts"* ]] \
  || fail "STUB tsc: an error that appears in an unedited file must be reported, got rc=$rc: $err"
fxrun check s1 '["src/lib.ts"]'
[[ $rc -eq 0 && -z "$err" ]] || fail "STUB tsc: the same caller error must be reported once, got rc=$rc: $err"
: > "$fx/tsc.out"
fxrun check s1 '["src/lib.ts"]'
[[ $rc -eq 0 && -z "$err" ]] || fail "STUB tsc: an error that goes away is not news, got rc=$rc: $err"
printf "src/caller.ts(2,18): error TS2554: Expected 2 arguments, but got 1.\n" > "$fx/tsc.out"
fxrun check s2 '["src/lib.ts"]'
[[ $rc -eq 0 && -z "$err" ]] || fail "STUB tsc: a new session sets its own baseline silently, got rc=$rc: $err"
ok "STUB tsc: the caller rule reports a new outside error once, and a new session starts from its own baseline"

newfix tscbase
tsc_stub "$fx"
mkdir -p "$fx/pkg/src"
printf '{"extends":"../tsconfig.base.json","include":["src"]}\n' > "$fx/pkg/tsconfig.json"
printf 'export const a = 1;\n' > "$fx/pkg/src/a.ts"
printf "../tsconfig.base.json(1,21): error TS1005: '}' expected.\n" > "$fx/tsc.out"
fxrun check s1 '["pkg/src/a.ts"]'
[[ $rc -eq 2 && "$err" == *"pkg/tsconfig.json could not be read as a project"* && "$err" == *"tsconfig.base.json(1,21)"* ]] \
  || fail "STUB tsc: an error in an extended base tsconfig must be reported on the first run, got rc=$rc: $err"
ok "STUB tsc: a syntax error in a base tsconfig the leaf extends is a finding"

if have_real tsc; then
  newfix tscbasereal
  mkdir -p "$fx/node_modules/.bin" "$fx/pkg/src"; ln -s "$tools/tsc" "$fx/node_modules/.bin/tsc"
  printf '{ "compilerOptions": ' > "$fx/tsconfig.base.json"
  printf '{"extends":"../tsconfig.base.json","include":["src"]}\n' > "$fx/pkg/tsconfig.json"
  printf 'export const a = 1;\n' > "$fx/pkg/src/a.ts"
  fxrun check s1 '["pkg/src/a.ts"]'
  [[ $rc -eq 2 && "$err" == *"could not be read as a project"* ]] || fail "REAL tsc: a broken base tsconfig must be reported, got rc=$rc: $err"
  ok "REAL tsc: a broken base tsconfig that the leaf extends is a finding"
else
  skip "tsc base-tsconfig row" tsc
fi

# --- pyright: a config pyright cannot parse exits 3 with an empty report -----
if have_real pyright; then
  newfix pybroken
  printf '{ "typeCheckingMode": "strict", ' > "$fx/pyrightconfig.json"
  printf 'x = 1\n' > "$fx/src/a.py"
  fxrun check s1 '["src/a.py"]'
  [[ $rc -eq 2 && "$err" == *"[pyright] . exited 3"* && "$err" == *"could not be parsed"* ]] \
    || fail "REAL pyright: a pyrightconfig.json it cannot parse must be reported with stderr, got rc=$rc: $err"
  ok "REAL pyright: an unparsable pyrightconfig.json is reported with pyright's stderr"
else
  skip "pyright broken-config row" pyright
fi

# --- ESLint installed with no configuration in reach does not run -------------
newfix eslintnoconfig
stub "$fx/node_modules/.bin/eslint" 'exit 2'
printf 'export const x = 1;\n' > "$fx/src/a.js"
fxrun check s1 '["src/a.js"]'
[[ $rc -eq 0 && -z "$err" ]] || fail "an installed ESLint with no config in reach must not block the edit, got rc=$rc: $err"
ok "STUB eslint: installed with no configuration in reach, it does not run and does not block"

# --- a fixer that fails in write mode is an advisory --------------------------
newfix fixerfails
printf '[tool.ruff]\n' > "$fx/pyproject.toml"; printf 'x = 1\n' > "$fx/src/a.py"
printf 'export default [];\n' > "$fx/eslint.config.mjs"; printf '{}\n' > "$fx/.prettierrc"; printf 'export const a = 1;\n' > "$fx/src/a.js"
stub "$fx/.venv/bin/ruff" '[[ "$1" == check ]] && { echo "error: cannot parse pyproject" >&2; exit 2; }; exit 0'
stub "$fx/node_modules/.bin/prettier" 'echo "[error] Invalid configuration" >&2; exit 2'
stub "$fx/node_modules/.bin/eslint" 'echo "Oops! Something went wrong" >&2; exit 2'
set +e
out="$(printf '{"project_dir":"%s","files":["src/a.py","src/a.js"]}' "$fxproj" \
  | PATH="$tools:/usr/bin:/bin" POST_EDIT_MODE=write /bin/bash "$fx/.agents/hooks/policy/post-edit-check.sh" 2>&1)"; rc=$?
set -e
[[ $rc -eq 0 && "$out" == *"could not run to completion"* && "$out" == *"ruff check --fix src/a.py"* \
   && "$out" == *"prettier --write] exited 2"* && "$out" == *"eslint --fix] exited 2"* ]] \
  || fail "a fixer that exits with an error must be reported as an advisory that does not block, got rc=$rc: $out"
stub "$fx/.venv/bin/ruff" '[[ "$1" == check ]] && exit 1; exit 0'
stub "$fx/node_modules/.bin/prettier" 'exit 0'
stub "$fx/node_modules/.bin/eslint" 'exit 1'
set +e
out="$(printf '{"project_dir":"%s","files":["src/a.py","src/a.js"]}' "$fxproj" \
  | PATH="$tools:/usr/bin:/bin" POST_EDIT_MODE=write /bin/bash "$fx/.agents/hooks/policy/post-edit-check.sh" 2>&1)"; rc=$?
set -e
[[ $rc -eq 0 && "$out" != *"could not run to completion"* ]] || fail "violations left after --fix (exit 1) are not a fixer failure, got rc=$rc: $out"
ok "STUB ruff, prettier, eslint: a fixer that cannot run is an advisory in write mode; leftover violations (exit 1) are not"

# --- install commands follow the repository's own lockfile -------------------
python_fixture() {  # <name> <lockfile or empty> -> a ruff-configured fixture
  newfix "$1"
  printf '[tool.ruff]\n' > "$fx/pyproject.toml"
  printf 'x = 1\n' > "$fx/src/a.py"
  [[ -n "$2" ]] && printf '\n' > "$fx/$2"
  return 0
}
python_fixture lockuv uv.lock
fxrun check s1 '["src/a.py"]'
[[ "$err" == *"not installed: uv add --dev ruff"* ]] || fail "uv.lock must give uv add --dev, got: $err"
python_fixture lockpoetry poetry.lock
fxrun check s1 '["src/a.py"]'
[[ "$err" == *"not installed: poetry add --group dev ruff"* ]] || fail "poetry.lock must give poetry add --group dev, got: $err"
python_fixture lockreq ""
printf 'ruff==0.5.0\n' > "$fx/requirements-dev.txt"
fxrun check s1 '["src/a.py"]'
[[ "$err" == *"not installed: pip install -r requirements-dev.txt"* ]] || fail "a requirements file that lists ruff must be named, got: $err"
python_fixture lockreqmissing ""
printf 'flask\n' > "$fx/requirements.txt"
fxrun check s1 '["src/a.py"]'
[[ "$err" == *"not installed: add ruff to requirements.txt, then run \`pip install -r requirements.txt\`"* ]] \
  || fail "a requirements file without ruff must be named with what to add, got: $err"
ok "the Python install command follows uv.lock, poetry.lock or the requirements file, and names it"

newfix linkednm
mkdir -p "$scratch/emptynm"
ln -s "$scratch/emptynm" "$fx/node_modules"
printf 'export default [];\n' > "$fx/eslint.config.mjs"
printf 'export const a = 1;\n' > "$fx/src/a.js"
printf 'lockfileVersion: 9\n' > "$fx/pnpm-lock.yaml"
fxrun check s1 '["src/a.js"]'
[[ "$err" == *"pnpm add -D eslint --lockfile-only, then run \`.agents/provision.sh $fxproj\`"* ]] \
  || fail "a linked node_modules must be told the lockfile-only form and provision.sh, got: $err"
ok "in a tree whose node_modules is a link, the install command is the lockfile-only form plus provision.sh"

newfix monorepo
printf 'export default [];\n' > "$fx/eslint.config.mjs"
mkdir -p "$fx/apps/web/src" "$fx/apps/other/node_modules/.bin"
stub "$fx/apps/other/node_modules/.bin/eslint" 'exit 0'
printf 'export const a = 1;\n' > "$fx/apps/web/src/a.js"
fxrun check s1 '["apps/web/src/a.js"]'
[[ $rc -eq 2 && "$err" == *"[eslint] configured in eslint.config.mjs but not installed"* ]] \
  || fail "a root configuration covering a package beyond an installed linter's reach must be reported, got rc=$rc: $err"
ok "a package that a root ESLint configuration covers but no installed ESLint reaches is reported"

# --- the ledger and the readout --------------------------------------------
newfix noconfig
printf 'x = 1\n' > "$fx/src/a.py"; printf 'export const a = 1;\n' > "$fx/src/a.ts"; printf 'export const b = 1;\n' > "$fx/src/b.js"
mkdir -p "$fx/pkg/lib"; printf 'name: pkg\n' > "$fx/pkg/pubspec.yaml"; printf 'void main() {}\n' > "$fx/pkg/lib/a.dart"
fxrun check s1 '["src/a.py","src/a.ts","src/b.js","pkg/lib/a.dart"]'
[[ $rc -eq 0 && -z "$err" ]] || fail "a repository with no checker configured must stay silent, got rc=$rc: $err"
[[ ! -e "$fx/.agents/.readout" ]] || fail "no configuration must leave no state files, got: $(ls -A "$fx/.agents/.readout")"
ok "a repository that configures no checker gets no files in the readout folder"

newfix ledgerprune
printf '[tool.ruff]\n' > "$fx/pyproject.toml"
printf 'x = 1\n' > "$fx/src/a.py"
fxrun check s1 '["src/a.py"]'
[[ "$(strip_of s1)" == "checks: ruff missing" ]] || fail "setup: the strip must name ruff"
python3 -c 'import os,sys,time; t=time.time()-8*86400; os.utime(sys.argv[1], (t, t))' "$fx/.agents/.readout/checks-ledger"
python3 "$fx/.agents/hooks/lib/readout.py" prune "$fxproj"
[[ ! -e "$fx/.agents/.readout/checks-ledger" ]] || fail "setup: prune must have removed the week-old ledger"
stub "$fx/.venv/bin/ruff" 'exit 0'
fxrun check s1 '["src/a.py"]'
[[ -z "$(strip_of s1)" ]] || fail "a strip must clear once ruff runs even after prune removed the ledger, got: $(strip_of s1)"
ok "the checks strip clears once the checker runs, though prune removed the ledger"

newfix ledgerbad
printf '[tool.ruff]\n' > "$fx/pyproject.toml"
printf 'x = 1\n' > "$fx/src/a.py"
mkdir -p "$fx/.agents/.readout"
printf 'ruff\tonly-two-fields\nruff\tgone\tpyproject.toml\tuv sync\n' > "$fx/.agents/.readout/checks-ledger"
fxrun check s1 '["src/a.py"]'
[[ $rc -eq 2 && "$err" == *"[ruff] configured in pyproject.toml but not installed"* && "$err" != *"exited"* ]] \
  || fail "a ledger row of the wrong shape must not abort the checks, got rc=$rc: $err"
[[ "$(grep -c . "$fx/.agents/.readout/checks-ledger")" == "1" ]] || fail "bad and orphaned rows must be dropped from the ledger, got: $(cat "$fx/.agents/.readout/checks-ledger")"
ok "a malformed or orphaned ledger row is dropped and the checks still run"

newfix ledgercrash
printf '[tool.ruff]\n' > "$fx/pyproject.toml"
printf 'x = 1\n' > "$fx/src/a.py"
printf 'raise SystemExit("boom")\n' > "$fx/.agents/hooks/lib/checkers.py"
fxrun check s1 '["src/a.py"]'
[[ $rc -eq 2 && "$err" == *"checkers.py missing exited"* && "$err" == *"boom"* ]] \
  || fail "a crash of checkers.py must be a finding, got rc=$rc: $err"
ok "a failing checkers.py call is reported as a finding, not a silent abort"

newfix lockheld
tsc_stub "$fx"
printf '{"include":["src"]}\n' > "$fx/tsconfig.json"
printf 'export const a = 1;\n' > "$fx/src/a.ts"
: > "$fx/tsc.out"
mkdir -p "$fx/.agents/.readout"
rm -f "$scratch/held"
python3 -c '
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(2)' "$fx/.agents/.readout" "$scratch/held" &
holder=$!
for _ in $(seq 50); do [[ -e "$scratch/held" ]] && break; sleep 0.1; done
started="$(python3 -c 'import time; print(time.time())')"
fxrun check s1 '["src/a.ts"]'
elapsed="$(python3 -c 'import sys, time; print(time.time() - float(sys.argv[1]))' "$started")"
wait "$holder"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= 1.0 else 1)' "$elapsed" \
  || fail "the tsc baseline must wait for the readout folder's lock, finished after ${elapsed}s"
ls -A "$fx/.agents/.readout" | grep -q 'lock' && fail "the lock must not be a file prune can delete: $(ls -A "$fx/.agents/.readout")"
ok "the tsc baseline is read and replaced under a lock on the readout folder, not on a prunable file"

# --- the session id reaches the hook through the Claude normalizer ----------
newfix sessionflow
printf '[tool.ruff]\n' > "$fx/pyproject.toml"
printf 'x = 1\n' > "$fx/src/a.py"
set +e
printf '{"cwd":"%s","session_id":"sess-abc","hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"%s/src/a.py"}}' "$fxproj" "$fxproj" \
  | python3 "$repo/.agents/claude/normalize-hook.py" post-edit-check.sh "$fxproj" \
  | PATH="$tools:/usr/bin:/bin" POST_EDIT_MODE=check /bin/bash "$fx/.agents/hooks/policy/post-edit-check.sh" >/dev/null 2>&1
set -e
ls "$fx/.agents/.readout/" | grep -q '^checks-seen--sess-abc--' \
  || fail "the session id must travel from a Claude payload through the normalizer into the hook, got: $(ls "$fx/.agents/.readout/" 2>&1)"
ok "a Claude-shaped payload carries its session id through the normalizer into the hook"

printf '\nALL PASS\n'
