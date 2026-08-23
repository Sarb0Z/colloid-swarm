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

# --- After the transplant strips them ---------------------------------------
git -C "$sat" rm -qf .agents/rules/stack-expo.md .agents/rules/stack-nestjs.md \
                     .agents/rules/stack-rails.md
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

# --- Every shipped pack declares both keys ----------------------------------
for pack in "$repo/.agents/rules/"stack-*.md; do
  grep -q '^detect:' "$pack" || fail "$(basename "$pack") declares no detect:"
  grep -q '^paths:' "$pack"  || fail "$(basename "$pack") declares no paths:"
done
ok 'every shipped pack declares paths: and detect:'

printf '\nstack-pack gate checks passed (%d).\n' "$pass"
