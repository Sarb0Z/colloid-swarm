#!/usr/bin/env bash
# Firing test for port-public.py: every leak class it gates fails a build on
# its own, and a clean fixture ports deterministically.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

tool="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/port-public.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/port-public-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "test-port-public: $*" >&2; exit 1; }
pass=0

# The operator's machine: one product folder holding one repository whose
# remote names an owner, an identity registry, and a satellite registry.
machine="$work/machine"
mkdir -p "$machine/projects/AcmeCo/acme-api"
git -C "$machine/projects/AcmeCo/acme-api" init -q
git -C "$machine/projects/AcmeCo/acme-api" remote add origin https://github.com/acme-org/acme-api.git
printf '{"identities": {"work": {"github_org": ["acme-org"]}}}\n' > "$machine/identities.json"
printf '| [AcmeCo](AcmeCo/README.md) | billing |\n' > "$machine/registry.md"

commit() {  # commit <repo> <identity> <message>
  local name="${2% <*}" email="${2##*<}"
  GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="${email%>}" GIT_COMMITTER_NAME="$name" \
    GIT_COMMITTER_EMAIL="${email%>}" git -C "$1" commit -q -m "$3"
}

# A private repository that ports cleanly: client names in a file and a commit
# message, a work identity, and a dropped folder.
fixture() {
  local repo="$work/$1"
  mkdir -p "$repo/.agents/public" "$repo/secret"
  git -C "$repo" init -q -b main
  printf '## Verification\n\n```sh\ntrue\n```\n' > "$repo/.agents/AGENTS.md"
  cat > "$repo/.agents/public/port.json" <<JSON
{
  "branch": "main",
  "drop": ["secret/", ".agents/public/satellites.txt", ".agents/public/port.json"],
  "allow": [".agents/", "README.md", "notes/"],
  "binaries": [],
  "authors": ["Dev <dev@example.com>"],
  "mailmap": ["Dev <dev@example.com> Work <work@acme.example>"],
  "sources": {"projects": "$machine/projects", "identities": "$machine/identities.json",
              "registry": "$machine/registry.md"},
  "own": [],
  "common_words": ["Beacon"],
  "debt_not_pointers": [],
  "reviewed": []
}
JSON
  printf 'AcmeCo==>product-a\nacme-api==>product-a-api\nacme-org==>org-a\nwork@acme.example==>dev@example.com\n-home-work-==>-home-dev-\n' \
    > "$repo/.agents/public/satellites.txt"
  printf 'Deployed for AcmeCo through acme-api.\nLogs land in /tmp/-home-work-projects-x.\n' > "$repo/README.md"
  printf 'client inventory\n' > "$repo/secret/inventory.txt"
  git -C "$repo" add -A
  commit "$repo" "Work <work@acme.example>" "feat: wire the acme-api client for AcmeCo"
  printf '%s\n' "$repo"
}

expect_fail() {  # expect_fail <label> <pattern> <repo>
  local out
  if out="$(python3 "$tool" --repo "$3" build "$work/out-$1" 2>&1)"; then
    fail "$1: build passed; expected it to fail on $2"
  fi
  grep -q -- "$2" <<<"$out" || fail "$1: build failed without naming $2: $out"
  compgen -G "$work/out-$1" >/dev/null || compgen -G "$work/.out-$1.partial-*" >/dev/null \
    && fail "$1: a failed build left a copy of the history behind"
  pass=$((pass + 1))
}

# A clean fixture ports: names replaced, folder dropped, identity mapped.
repo="$(fixture clean)"
python3 "$tool" --repo "$repo" build "$work/out-clean" >/dev/null
out="$work/out-clean"
git -C "$out" log --all --format='%an <%ae> %cn <%ce> %B' | grep -qiE 'acme|work@' \
  && fail "clean: a name or the work identity survived in the history"
grep -q 'product-a through product-a-api' "$out/README.md" || fail "clean: README was not rewritten"
grep -q -- '-home-dev-projects-x' "$out/README.md" || fail "clean: a name with hyphen edges was not rewritten"
[[ ! -e "$out/secret" ]] || fail "clean: a dropped folder shipped"
[[ -z "$(git -C "$out" remote)" ]] || fail "clean: the public copy keeps a remote to the private repository"
pass=$((pass + 1))

# The same inputs give the same hashes, so a second port fast-forwards.
git init -q --bare "$work/published.git"
python3 "$tool" --repo "$repo" build "$work/out-first" --against "$work/published.git" > "$work/first.log"
grep -q 'first publication' "$work/first.log" || fail "first publication: an empty remote was not reported as one"
python3 "$tool" --repo "$repo" build "$work/out-again" --against "$out" > "$work/again.log"
[[ "$(git -C "$out" rev-parse HEAD)" == "$(git -C "$work/out-again" rev-parse HEAD)" ]] \
  || fail "determinism: two ports of one history differ"
grep -q 'fast-forward from' "$work/again.log" || fail "determinism: --against did not report a fast-forward"
pass=$((pass + 1))

# A name on the machine that nobody classified.
repo="$(fixture unclassified)"
mkdir -p "$machine/projects/ZetaCorp"
expect_fail unclassified "nobody classified" "$repo"
rmdir "$machine/projects/ZetaCorp"

# A deploy server reached by a non-GitHub remote is a name too.
repo="$(fixture server)"
git -C "$machine/projects/AcmeCo/acme-api" remote add deploy root@203.0.113.9:/srv/acme-api
expect_fail server "203.0.113.9" "$repo"
git -C "$machine/projects/AcmeCo/acme-api" remote remove deploy

# A name source that is missing stops the build instead of reading as empty.
repo="$(fixture missing-source)"
mv "$machine/registry.md" "$machine/registry.md.away"
expect_fail missing-source "name source \`registry\`" "$repo"
mv "$machine/registry.md.away" "$machine/registry.md"

# A spelling of a name the list does not carry, and a common word in lower case.
repo="$(fixture variant)"
printf 'Acme Co ships it.\n' >> "$repo/README.md"
git -C "$repo" add -A && commit "$repo" "Dev <dev@example.com>" "docs: credit the client"
expect_fail variant "\`Acme Co\` unreviewed" "$repo"
repo="$(fixture lowercase-word)"
printf 'cd ~/projects/beacon\n' >> "$repo/README.md"
git -C "$repo" add -A && commit "$repo" "Dev <dev@example.com>" "docs: add the path"
expect_fail lowercase-word "\`beacon\` unreviewed" "$repo"

# The port replays one branch, so it builds only from that branch.
repo="$(fixture off-branch)"
git -C "$repo" checkout -q -b feature
expect_fail off-branch "HEAD is on \`feature\`" "$repo"

# A name in a file path, which text replacement never rewrites.
repo="$(fixture path-name)"
mkdir -p "$repo/notes" && printf 'meeting\n' > "$repo/notes/acme-api-sync.md"
git -C "$repo" add -A && commit "$repo" "Dev <dev@example.com>" "docs: add sync notes"
expect_fail path-name 'path notes/acme-api-sync.md:1: `acme-api`' "$repo"

# Client content that never names the client, outside the allowed prefixes.
repo="$(fixture outside-allow)"
mkdir -p "$repo/misc" && printf 'host 10.0.0.4 db-primary\n' > "$repo/misc/servers.txt"
git -C "$repo" add -A && commit "$repo" "Dev <dev@example.com>" "chore: add server list"
expect_fail outside-allow "path misc/servers.txt: not under an allowed prefix" "$repo"

# A binary the gate cannot read.
repo="$(fixture binary)"
printf 'PK\0\0zip' > "$repo/.agents/bundle.bin"
git -C "$repo" add -A && commit "$repo" "Dev <dev@example.com>" "chore: add bundle"
expect_fail binary "binary content the gate cannot read" "$repo"

# An identity the mailmap does not map.
repo="$(fixture identity)"
printf 'more\n' >> "$repo/README.md"
git -C "$repo" add -A && commit "$repo" "Other <other@elsewhere.example>" "docs: extend"
expect_fail identity "identity \`Other <other@elsewhere.example>\`" "$repo"

# A common word stays only once its use is reviewed.
repo="$(fixture common-word)"
printf 'Beacon ships the export.\n' >> "$repo/README.md"
git -C "$repo" add -A && commit "$repo" "Dev <dev@example.com>" "docs: name the exporter"
expect_fail common-word "unreviewed (reviewed id" "$repo"
id="$({ python3 "$tool" --repo "$repo" build "$work/out-common-word-2" 2>&1 || true; } | sed -n 's/.*reviewed id \([0-9a-f]*\).*/\1/p' | head -1)"
python3 - "$repo/.agents/public/port.json" "$id" <<'PY'
import json, sys
path, key = sys.argv[1:]
config = json.load(open(path))
config["reviewed"].append(key)
json.dump(config, open(path, "w"))
PY
git -C "$repo" add -A && commit "$repo" "Dev <dev@example.com>" "chore: review the exporter's name"
python3 "$tool" --repo "$repo" build "$work/out-common-word-3" >/dev/null \
  || fail "common-word: a reviewed use still failed the build"
pass=$((pass + 1))

# A scratch copy a killed build left behind is removed by the next build.
repo="$(fixture killed)"
mkdir -p "$work/.out-killed.partial-x/copy" && printf 'unfiltered\n' > "$work/.out-killed.partial-x/copy/leak"
python3 "$tool" --repo "$repo" build "$work/out-killed" >/dev/null
compgen -G "$work/.out-killed.partial-*" >/dev/null && fail "killed: a stale scratch copy survived the next build"
pass=$((pass + 1))

# A terminated build removes its scratch copy.
repo="$(fixture terminated)"
python3 "$tool" --repo "$repo" build "$work/out-terminated" >/dev/null 2>&1 &
until compgen -G "$work/.out-terminated.partial-*" >/dev/null || ! kill -0 $! 2>/dev/null; do :; done
kill -TERM $! || fail "terminated: the build ended before it could be signalled"
status=0; wait $! || status=$?
[[ $status -ne 0 ]] || fail "terminated: the build finished before the signal landed"
compgen -G "$work/.out-terminated.partial-*" >/dev/null && fail "terminated: the scratch copy survived SIGTERM"
pass=$((pass + 1))

# Uncommitted work never reaches a port.
repo="$(fixture dirty)"
printf 'draft\n' >> "$repo/README.md"
expect_fail dirty "uncommitted changes" "$repo"

# A generated starter goes stale when the code it serves changes.
repo="$(fixture stale)"
printf '# Debt log\n\n### x-one\n\n- **Condition** — c.\n\n### x-two\n\n- **Condition** — d.\n' > "$repo/.agents/debt-log.md"
printf '# debt: x-one\n' > "$repo/.agents/tool.sh"
git -C "$repo" add -A
python3 "$tool" --repo "$repo" check >/dev/null 2>&1 && fail "stale: check passed with no generated debt log"
python3 "$tool" --repo "$repo" refresh >/dev/null
python3 "$tool" --repo "$repo" check >/dev/null || fail "stale: check failed right after refresh"
grep -q '^### x-one' "$repo/.agents/public/tree/.agents/debt-log.md" || fail "stale: the cited entry is missing"
grep -q '^### x-two' "$repo/.agents/public/tree/.agents/debt-log.md" && fail "stale: an uncited entry shipped"
printf '# debt: x-two\n' >> "$repo/.agents/tool.sh"
python3 "$tool" --repo "$repo" check >/dev/null 2>&1 && fail "stale: check passed after a new pointer"
printf '# debt: x-three\n' >> "$repo/.agents/tool.sh"
{ python3 "$tool" --repo "$repo" refresh 2>&1 || true; } | grep -q "lacks: \['x-three'\]" \
  || fail "stale: a pointer to a missing entry was not refused"
pass=$((pass + 1))

echo "port-public: $pass scenarios passed"
