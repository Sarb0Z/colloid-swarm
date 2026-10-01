#!/usr/bin/env bash
# Firing tests for the path-expressibility contract between edited-files.py and
# post-edit-check.sh: the file list travels newline-delimited and is regrouped
# tab-delimited downstream, so neither character can appear in a path. Both must
# be refused out loud. A silent skip is a gate reporting a pass it never ran.
set -euo pipefail

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

printf '\nALL PASS\n'
