#!/usr/bin/env bash
# Firing tests for lint-skills.sh link rules: a link inside code is an example,
# a link in prose is a reference.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lint="$repo/.agents/lint-skills.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

skill() {  # <name> <SKILL.md body> -> skill directory
  local d="$scratch/$1"
  mkdir -p "$d"
  printf -- '---\nname: %s\ndescription: Probe the link rules.\n---\n\n%s\n' "$1" "$2" >"$d/SKILL.md"
  printf '%s' "$d"
}

d="$(skill fenced 'Use the format in [FORMAT.md](./FORMAT.md).')"
printf '# Format\n\n```md\n- [Ordering](./ORDERING.md): orders\n```\n' >"$d/FORMAT.md"
printf '# Ordering\n' >"$d/ORDERING.md"
"$lint" "$d/SKILL.md" >/dev/null || fail "a link inside a fenced sample was read as a reference link"
ok "a fenced sample document links nothing"

d="$(skill prose 'Use the format in [FORMAT.md](./FORMAT.md).')"
printf '# Format\n\nSee [Ordering](./ORDERING.md).\n' >"$d/FORMAT.md"
printf '# Ordering\n' >"$d/ORDERING.md"
out="$("$lint" "$d/SKILL.md")" && fail "a prose link between reference files passed"
[[ "$out" == *"only SKILL.md may link to a reference file"* ]] || fail "wrong error for a prose link: $out"
ok "a prose link between reference files still fails"

d="$(skill inline 'Write `[x](./MISSING.md)` to link a file.')"
"$lint" "$d/SKILL.md" >/dev/null || fail "a link inside inline code was checked for a target"
ok "an inline-code link is not checked for a target"

d="$(skill broken 'Read [it](./MISSING.md).')"
out="$("$lint" "$d/SKILL.md")" && fail "a dangling prose link passed"
[[ "$out" == *"link to './MISSING.md' does not resolve"* ]] || fail "wrong error for a dangling link: $out"
ok "a dangling prose link still fails"

# A tilde line does not close a backtick fence, so the first link stays inside
# the fence. The real closing fence ends it, so the second link is checked.
d="$(skill mixed $'```\n~~~\n[a](./GONE.md)\n```\n[b](./ALSO-GONE.md)')"
out="$("$lint" "$d/SKILL.md")" && fail "a link after the closing fence passed"
[[ "$out" == *"ALSO-GONE.md"* ]] || fail "a link after the closing fence was not checked: $out"
[[ "$out" != *"'./GONE.md'"* ]] || fail "a tilde line closed a backtick fence: $out"
ok "only a matching fence closes a fenced block"

d="$(skill bare 'A skill with no AGENTS.md beside it.')"
[[ ! -e "$d/AGENTS.md" ]] || fail "the probe skill unexpectedly has an AGENTS.md"
"$lint" "$d/SKILL.md" >/dev/null || fail "a skill without AGENTS.md was rejected"
ok "a skill needs no AGENTS.md"

d="$scratch/forked"
mkdir -p "$d"
printf -- '---\nname: forked\ndescription: Probe a forked-context skill.\ncontext: fork\n---\n\nBody.\n' >"$d/SKILL.md"
"$lint" "$d/SKILL.md" >/dev/null || fail "a skill with 'context: fork' frontmatter was rejected"
ok "context: fork frontmatter is accepted"
