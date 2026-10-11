#!/usr/bin/env bash
# Verify check-stack-packs.py: the gate that keeps a stack pack out of a
# repository that does not run that stack.
#
# The gate is the whole selection mechanism. The export carries every pack and
# chooses none, so a transplant that forgets to strip one ships framework rules
# at a repository with no such framework — silently, because a rule that loads
# is indistinguishable from a rule that belongs. Every case below drives the
# real script against a fixture repository.
set -euo pipefail
# A caller such as `git rebase -x` exports these; the git calls below must
# reach only their own temporary repositories.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/stack packs.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

pass=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { pass=$((pass + 1)); printf 'ok    %s\n' "$*"; }

# The packs the fixtures need. A satellite carries only the packs it runs, so
# copying whatever this repository happens to hold would make the suite pass in
# the carrier and fail everywhere else — for the one reason the carrier model
# calls correct. Any pack the repository stripped is written from the table
# below instead, carrying the same globs the real pack does, so the collision
# between stack-nextjs and stack-expo is tested wherever this runs.
pack() {
  local name="$1" paths="$2" detect="$3"
  if [[ -f "$repo/.agents/rules/stack-$name.md" ]]; then
    cp "$repo/.agents/rules/stack-$name.md" "$dir/.agents/rules/"
    return
  fi
  { printf -- '---\npaths:\n'
    printf "  - '%s'\n" $paths
    printf 'detect:\n'
    printf "  - '%s'\n" $detect
    printf -- '---\nfixture\n'
  } > "$dir/.agents/rules/stack-$name.md"
}

# A fixture repository holding the packs and whatever stack files are named.
# `--template=` keeps the operator's init.templateDir out: a global commit hook
# would otherwise run inside the fixture and abort this suite under `set -e`.
build() {
  local dir="$scratch/$1"; shift
  rm -rf "$dir"; mkdir -p "$dir/.agents/rules"
  cp "$repo/.agents/check-stack-packs.py" "$dir/.agents/"
  pack nextjs '**/app/**/*.tsx **/app/**/*.ts **/src/app/**/*.tsx **/src/app/**/*.ts **/next.config.* **/middleware.ts' '**/next.config.*'
  pack expo   '**/app/**/*.tsx **/src/app/**/*.tsx **/app.config.* **/eas.json **/metro.config.*' '**/app.json **/app.config.* **/eas.json'
  pack nestjs '**/src/**/*.module.ts **/src/**/*.controller.ts **/src/main.ts' '**/nest-cli.json'
  pack rails  '**/app/**/*.rb **/config/**/*.rb' '**/config/routes.rb **/Gemfile'
  pack flutter '**/*.dart **/pubspec.yaml **/analysis_options.yaml' '**/pubspec.yaml'
  printf '{}' > "$dir/.agents/config.json.example"
  local path
  for path in "$@"; do
    mkdir -p "$dir/$(dirname "$path")"
    printf 'fixture\n' > "$dir/$path"
  done
  git -C "$dir" init -q --template=
  git -C "$dir" add -A
  printf '%s' "$dir"
}

run() { ( cd "$1" && ./.agents/check-stack-packs.py 2>&1 ); }
rc()  { ( cd "$1" && ./.agents/check-stack-packs.py >/dev/null 2>&1 ); }

# --- The carrier is exempt ---------------------------------------------------
# Colloid holds every pack on purpose and matches none of them. Without the
# exemption the source repository fails its own gate on every run.
carrier="$(build carrier)"
python3 -c 'import json,sys; json.dump({"stack_packs": {"carrier": True}}, open(sys.argv[1], "w"))' \
  "$carrier/.agents/config.json.example"
git -C "$carrier" add -A
rc "$carrier" || fail 'the carrier must pass with every pack and no matching file'
[[ "$(run "$carrier")" == *carrier* ]] || fail 'the carrier must say why it passed'
ok 'carrier repository is exempt'

# --- A satellite running one stack ------------------------------------------
# The key is absent here, which is what export-scaffold.py leaves behind.
#
# `app/(tabs)/index.tsx` is deliberate: it matches the `paths:` globs of BOTH
# stack-nextjs and stack-expo, which is the collision `detect:` exists to
# settle. A fixture holding only shallow files would let a gate reading
# `paths:` pass this suite.
sat="$(build satellite next.config.js app/page.tsx 'app/(tabs)/index.tsx')"
rc "$sat" && fail 'a repository holding packs it does not run must fail'
report="$(run "$sat" || true)"
for stack in expo nestjs rails; do
  [[ "$report" == *"stack-$stack.md"* ]] || fail "the report must name stack-$stack.md"
done
[[ "$report" != *"stack-nextjs.md"* ]] || fail 'the pack this repository runs must not be named'
[[ "$report" == *"git rm"* ]] || fail 'the report must carry the command that fixes it'
ok 'a stale pack is named, and the matching one is not'

# --- A nested Flutter app counts as the stack -------------------------------
# food-app keeps its app at app/mobile_app/pubspec.yaml, two levels down.
flut="$(build flutter-app app/mobile_app/pubspec.yaml app/mobile_app/lib/main.dart)"
report="$(run "$flut" || true)"
[[ "$report" != *"stack-flutter.md"* ]] || fail 'a nested pubspec.yaml must satisfy the Flutter pack'
[[ "$report" == *"stack-nextjs.md"* ]] || fail 'a Flutter app must not satisfy the Next.js pack'
bare="$(build no-flutter next.config.js)"
[[ "$(run "$bare" || true)" == *"stack-flutter.md"* ]] || fail 'a repository with no pubspec.yaml must be told to drop the Flutter pack'
ok 'a pubspec.yaml selects the Flutter pack, and its absence flags it'

# --- After the transplant strips them ---------------------------------------
git -C "$sat" rm -qf .agents/rules/stack-expo.md .agents/rules/stack-nestjs.md \
                     .agents/rules/stack-rails.md .agents/rules/stack-flutter.md
rc "$sat" || fail 'the gate must pass once the stale packs are gone'
ok 'stripping the stale packs turns the gate green'

# --- A monorepo package counts as the stack -------------------------------
# A marker glob anchored at the root misses `apps/web/next.config.ts`, and the
# gate then tells the operator to delete a pack the repository runs. That is
# the expensive direction of this check: a false positive removes guidance.
mono="$(build monorepo apps/web/next.config.ts 'apps/web/app/page.tsx')"
report="$(run "$mono" || true)"
[[ "$report" != *"stack-nextjs.md"* ]] \
  || fail 'a Next.js app under apps/ must satisfy the Next.js pack'
ok 'a marker inside a monorepo package is found'

# --- The scaffold's own files select no stack -------------------------------
# Every satellite carries `.agents/mcp-servers/*/tsconfig.json`. Read as a
# marker, it keeps the TypeScript pack alive in a repository with no
# TypeScript, which is the stale pack this gate exists to remove.
vendored="$(build vendored .agents/mcp-servers/research-mcp/tsconfig.json next.config.js)"
dir="$vendored"; pack typescript '**/*.ts **/*.tsx' '**/tsconfig.json'
git -C "$vendored" add -A
[[ "$(run "$vendored" || true)" == *"stack-typescript.md"* ]] \
  || fail 'a tsconfig.json under .agents/ must not satisfy the TypeScript pack'
printf '{}\n' > "$vendored/tsconfig.json"; git -C "$vendored" add -A
[[ "$(run "$vendored" || true)" != *"stack-typescript.md"* ]] \
  || fail "the repository's own tsconfig.json must satisfy the TypeScript pack"
ok 'a marker under .agents/ selects no stack; one outside it does'

# --- detect: is required ----------------------------------------------------
# `paths:` says when a rule loads; `detect:` says whether the stack is here.
# Expo Router and the Next.js App Router both own `app/**/*.tsx`, so a gate
# reading `paths:` alone passes a pack it should have flagged.
nodetect="$(build nodetect next.config.js)"
python3 - "$nodetect/.agents/rules/stack-rails.md" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(re.sub(r"detect:\n(  - .*\n)+", "", text, count=1))
PY
git -C "$nodetect" add -A
rc "$nodetect" && fail 'a pack with no detect: markers must stop the run'
# The refusal, not the stale report. Both mention `detect:`, and asserting on
# the shared word passes whether the guard fired or the pack merely matched
# nothing — a vacuous check that certifies an absent guard.
[[ "$(run "$nodetect" || true)" == *"declares no marker globs"* ]] \
  || fail 'a missing detect: must be refused, not reported as a stale pack'
ok 'a pack without detect: markers is refused'

# --- paths: is required -----------------------------------------------------
nopaths="$(build nopaths next.config.js)"
python3 - "$nopaths/.agents/rules/stack-rails.md" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(re.sub(r"paths:\n(  - .*\n)+", "", text, count=1))
PY
git -C "$nopaths" add -A
rc "$nopaths" && fail 'a pack with no paths: globs must stop the run'
[[ "$(run "$nopaths" || true)" == *"declares no scoping globs"* ]] \
  || fail 'a missing paths: must be refused, not reported as a stale pack'
ok 'a pack without paths: globs is refused'

# --- detect-deps: a dependency alone keeps a pack ----------------------------
# MongoDB, an ORM or a client SDK leaves no signature file, so a pack can also
# be kept by a name in a tracked manifest. Each fixture holds only that
# manifest plus the one pack under test, so the verdict is about the manifest.
dbpack() {
  local dir="$scratch/$1"; shift
  rm -rf "$dir"; mkdir -p "$dir/.agents/rules"
  cp "$repo/.agents/check-stack-packs.py" "$dir/.agents/"
  printf '{}' > "$dir/.agents/config.json.example"
  { printf -- '---\npaths:\n  - %s\n' "'**/migrations/**'"
    printf "detect:\n  - '**/migrations/**'\ndetect-deps:\n"
    printf "  - '%s'\n" pypi:motor pypi:sqlalchemy npm:@prisma/client gem:pg pypi:django
    printf -- '---\nfixture\n'
  } > "$dir/.agents/rules/stack-database.md"
  local entry
  for entry in "$@"; do
    mkdir -p "$dir/$(dirname "${entry%%=*}")"
    printf '%b' "${entry#*=}" > "$dir/${entry%%=*}"
  done
  git -C "$dir" init -q --template=
  git -C "$dir" add -A
  printf '%s' "$dir"
}
kept()  { [[ "$(run "$1" || true)" != *"stack-database.md"* ]]; }

d="$(dbpack npm-dep 'web/package.json={"dependencies":{"@prisma/client":"^6.0.0"}}\n')"
kept "$d" || fail 'a dependency in package.json must keep the pack'
d="$(dbpack npm-peer 'package.json={"peerDependencies":{"@prisma/client":"*"}}\n')"
kept "$d" || fail 'a peerDependencies entry must keep the pack'
d="$(dbpack none 'package.json={"dependencies":{"react":"19"}}\n')"
kept "$d" && fail 'a manifest naming no marker must leave the pack stale'
report="$(run "$d" || true)"
[[ "$report" == *"detect-deps:"*"npm:@prisma/client"* ]] \
  || fail 'the stale report must name the dependency markers'
ok 'package.json dependencies keep a pack, and their absence flags it'

d="$(dbpack ecosystem 'package.json={"dependencies":{"motor":"1.0.0"}}\n')"
kept "$d" && fail 'npm motor must not satisfy pypi:motor'
d="$(dbpack ecosystem-py 'requirements.txt=motor==3.6.0\n')"
kept "$d" || fail 'pypi motor must satisfy pypi:motor'
d="$(dbpack ecosystem-gem 'Gemfile=gem "motor"\n')"
kept "$d" && fail 'a gem motor must not satisfy pypi:motor'
ok 'a dependency name is scoped to its ecosystem'

d="$(dbpack pep503 'requirements-dev.txt=# tools\n-r base.txt\nSQLAlchemy[asyncio]>=2.0 ; python_version > "3.9"\n')"
kept "$d" || fail 'SQLAlchemy with extras and a marker must match sqlalchemy'
d="$(dbpack pep621 'pyproject.toml=[project]\nname = "x"\ndependencies = ["Django>=5.0"]\n')"
kept "$d" || fail 'a PEP 621 dependency must keep the pack'
d="$(dbpack pep621-extra 'pyproject.toml=[project]\nname = "x"\n[project.optional-dependencies]\ndb = ["SQL_Alchemy==2"]\n')"
kept "$d" && fail 'SQL_Alchemy is a different project from sqlalchemy'
d="$(dbpack dep-group 'pyproject.toml=[dependency-groups]\ndev = ["sqlalchemy>=2", {include-group = "lint"}]\n')"
kept "$d" || fail 'a [dependency-groups] entry must keep the pack'
d="$(dbpack poetry-group 'pyproject.toml=[tool.poetry.group.db.dependencies]\nSQLAlchemy = "^2.0"\n')"
kept "$d" || fail 'a Poetry group dependency must keep the pack'
d="$(dbpack poetry 'pyproject.toml=[tool.poetry.dependencies]\npython = "^3.12"\nrequests = "*"\n')"
kept "$d" && fail 'a Poetry table naming no marker must leave the pack stale'
d="$(dbpack gemfile 'Gemfile=source "https://rubygems.org"\ngem "pg", "~> 1.5"\n')"
kept "$d" || fail 'a Gemfile gem must keep the pack'
ok 'Python names fold per PEP 503, and pyproject, Poetry, groups and Gemfile are read'

d="$(dbpack vendored '.agents/mcp-servers/x/package.json={"dependencies":{"@prisma/client":"6"}}\n')"
kept "$d" && fail 'a manifest under .agents/ must select no stack'
d="$(dbpack file-glob 'db/migrations/001.sql=select 1\n')"
kept "$d" || fail 'a detect: glob must still keep the pack with no manifest'
ok 'manifests under .agents/ are ignored, and detect: still works alone'

d="$(dbpack badjson 'package.json={not json')"
rc "$d" && fail 'an unreadable manifest must stop the run'
[[ "$(run "$d" || true)" == *"not valid JSON"* ]] || fail 'an unreadable manifest must be named'
ok 'a malformed manifest fails loudly'

d="$(dbpack nodetect-deps 'package.json={"dependencies":{"@prisma/client":"6"}}\n')"
python3 - "$d/.agents/rules/stack-database.md" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(re.sub(r"detect:\n(  - .*\n)+", "", text, count=1))
PY
git -C "$d" add -A
rc "$d" && fail 'detect-deps: alone must not replace detect:'
[[ "$(run "$d" || true)" == *"declares no marker globs"* ]] \
  || fail 'a pack with only detect-deps: must be refused'
ok 'detect: stays required beside detect-deps:'

# --- Every shipped pack declares both keys ----------------------------------
for pack in "$repo/.agents/rules/"stack-*.md; do
  grep -q '^detect:' "$pack" || fail "$(basename "$pack") declares no detect:"
  grep -q '^paths:' "$pack"  || fail "$(basename "$pack") declares no paths:"
done
ok 'every shipped pack declares paths: and detect:'

printf '\nstack-pack gate checks passed (%d).\n' "$pass"
