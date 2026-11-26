#!/usr/bin/env bash
# Firing test for leak_gate.py through the real hooks: pre-commit, commit-msg
# and pre-push each refuse a private name, a spelling variant stays refused
# until its reviewed id is listed, and a missing or malformed leak list behaves
# as documented. Every name below is invented.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate="$here/leak_gate.py"
hooks="$here/../.githooks"
work="$(mktemp -d "${TMPDIR:-/tmp}/leak-gate-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "test-leak-gate: $*" >&2; exit 1; }
pass=0

# Nothing from the operator's git or leak-list configuration reaches the test.
export HOME="$work/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export COLLOID_LEAK_DIR="$work/leaks"
mkdir -p "$HOME"

refuses() {  # refuses <label> <expected text> <command...>
  local label=$1 needle=$2 out; shift 2
  if out=$("$@" 2>&1); then fail "$label: expected a refusal, the command succeeded: $out"; fi
  [[ "$out" == *"$needle"* ]] || fail "$label: output lacks \`$needle\`: $out"
  pass=$((pass + 1))
}
allows() {  # allows <label> <command...>
  local label=$1 out; shift
  out=$("$@" 2>&1) || fail "$label: expected success, got: $out"
  pass=$((pass + 1))
}

# The leak list: one private name, one common word, one allowed author, and a
# machine whose only project folder is already classified.
machine="$work/machine"
mkdir -p "$machine/projects/acme-billing"
printf '{"identities": {}}\n' > "$machine/identities.json"
printf '| [acme-billing](acme-billing/README.md) | billing |\n' > "$machine/registry.md"
write_config() {  # write_config <reviewed ids, as JSON list contents>
  mkdir -p "$COLLOID_LEAK_DIR"
  printf '# private name ==> public replacement\nacme-billing==>billing-app\n' > "$COLLOID_LEAK_DIR/satellites.txt"
  cat > "$COLLOID_LEAK_DIR/port.json" <<JSON
{
  "authors": ["Dev <dev@example.com>"],
  "own": [],
  "common_words": ["Beacon"],
  "reviewed": [$1],
  "sources": {"projects": "$machine/projects", "identities": "$machine/identities.json",
              "registry": "$machine/registry.md"},
  "drop": ["ignored/"]
}
JSON
}
write_config ''

# A repository wired to the real hooks, with one clean commit made as the allowed author.
repo_count=0
fixture() {  # fixture <name>
  local repo="$work/$1"
  git init -q -b main "$repo"
  git -C "$repo" config user.name Dev
  git -C "$repo" config user.email dev@example.com
  git -C "$repo" config core.hooksPath "$hooks"
  printf 'hello\n' > "$repo/readme.txt"
  git -C "$repo" add readme.txt
  git -C "$repo" commit -q -m "chore: start"
  printf '%s\n' "$repo"
}
unhooked() { git -c core.hooksPath=/dev/null "$@"; }   # make history the hooks would have refused

# 1. A staged private name is refused by pre-commit, naming file and line.
r=$(fixture staged)
printf 'first\nbilled through acme-billing today\n' > "$r/notes.md"
git -C "$r" add notes.md
refuses "pre-commit private name" 'notes.md:2: `acme-billing`' git -C "$r" commit -q -m "docs: notes"
[[ "$(git -C "$r" rev-list --count HEAD)" == 1 ]] || fail "the refused commit was created anyway"
# A private name is not reviewable: its line's reviewed id changes nothing, and it is no "unreviewed" variant.
write_config '"9db5f9b6c8a92edf"'
out=$(git -C "$r" commit -q -m "docs: notes" 2>&1) && fail "a listed id let a private name through"
[[ "$out" == *'notes.md:2: `acme-billing`'* && "$out" != *unreviewed* ]] || fail "private name finding was: $out"
write_config ''
# A name in a path is refused too, as `path <path>`.
git -C "$r" rm -q --cached notes.md
printf 'x\n' > "$r/acme-billing-notes.txt"
git -C "$r" add acme-billing-notes.txt
refuses "pre-commit private path" 'path acme-billing-notes.txt:1: `acme-billing`' git -C "$r" commit -q -m "docs: notes"

# 2. A separator variant is refused until its reviewed id is listed.
r=$(fixture variant)
printf 'Acme Billing ships\nuses acme_billing here\n' > "$r/v.txt"
git -C "$r" add v.txt
refuses "variant with a space" 'v.txt:1: `Acme Billing` unreviewed (reviewed id ef984f5d509d1ae3)' git -C "$r" commit -q -m "docs: v"
refuses "variant with an underscore" 'v.txt:2: `acme_billing` unreviewed (reviewed id 8ff191141531791a)' git -C "$r" commit -q -m "docs: v"
write_config '"ef984f5d509d1ae3"'
refuses "one of two variants reviewed" 'v.txt:2' git -C "$r" commit -q -m "docs: v"
write_config '"ef984f5d509d1ae3", "8ff191141531791a"'
allows "both variants reviewed" git -C "$r" commit -q -m "docs: v"
write_config ''

# 3. A message with a private name is refused by commit-msg, and the leak is the reason printed.
r=$(fixture message)
printf 'clean\n' > "$r/clean.txt"
git -C "$r" add clean.txt
refuses "commit-msg private name" 'message:1: `acme-billing`' git -C "$r" commit -q -m "fix: acme-billing hook"
refuses "commit-msg names the finding count" '1 finding(s)' git -C "$r" commit -q -m "fix: acme-billing hook"
refuses "commit-msg on a fixup message" 'message:1: `acme-billing`' git -C "$r" commit -q -m "fixup! acme-billing hook"
refuses "commit-msg common word" 'message:1: `Beacon` unreviewed (reviewed id 40a7292c948dc7e1)' git -C "$r" commit -q -m "Beacon rules"
[[ "$(git -C "$r" rev-list --count HEAD)" == 1 ]] || fail "a refused message still produced a commit"
# `git commit -v` appends the diff below the scissors line; a removed leak there is not the message.
printf 'chore: drop a leak\n\n# ------------------------ >8 ------------------------\n-owed to acme-billing\n' > "$work/verbose-message"
allows "diff below the scissors line" python3 "$gate" message "$work/verbose-message"
write_config '"40a7292c948dc7e1"'
allows "reviewed message" git -C "$r" commit -q -m "Beacon rules"
[[ "$(git -C "$r" log -1 --format=%B)" == *"Authored-By: Dev <dev@example.com>"* ]] \
  || fail "the commit-msg hook no longer adds its Authored-By trailer"
write_config ''

# 4. A push is gated on every new commit, not only the tip.
bare="$work/remote.git"
git init -q --bare -b main "$bare"
r=$(fixture push)
git -C "$r" remote add origin "$bare"
allows "clean first push" git -C "$r" push -q origin main
printf 'ok\n' > "$r/a.txt"
git -C "$r" add a.txt
git -C "$r" commit -q -m "feat: a"
printf 'owed to acme-billing\n' > "$r/old.txt"
git -C "$r" add old.txt
unhooked -C "$r" commit -q -m "feat: old"
dirty_sha=$(git -C "$r" rev-parse --short=12 HEAD)
printf 'tip\n' > "$r/tip.txt"
git -C "$r" add tip.txt
git -C "$r" commit -q -m "feat: tip"
refuses "dirty older commit" "commit $dirty_sha old.txt:1: \`acme-billing\`" git -C "$r" push -q origin main
remote_tip=$(git -C "$bare" rev-parse main)
[[ "$remote_tip" == "$(git -C "$r" rev-parse HEAD~3)" ]] || fail "the refused push still updated the remote"
git -C "$r" reset -q --hard HEAD~3
printf 'next\n' > "$r/b.txt"
git -C "$r" add b.txt
git -C "$r" commit -q -m "feat: b"
allows "clean range" git -C "$r" push -q origin main
git -C "$r" checkout -q -b topic
printf 'owed to acme-billing\n' > "$r/topic.txt"
git -C "$r" add topic.txt
unhooked -C "$r" commit -q -m "feat: topic"
refuses "new branch with one dirty commit" 'topic.txt:1: `acme-billing`' git -C "$r" push -q origin topic
git -C "$r" checkout -q main
git -C "$r" branch -q scratch
allows "clean new branch" git -C "$r" push -q origin scratch
allows "branch deletion" git -C "$r" push -q origin :scratch

# 5. An author outside `authors` is refused, at commit time and at push time.
r=$(fixture author)
printf 'clean\n' > "$r/c.txt"
git -C "$r" add c.txt
refuses "pre-commit author" 'identity `Mallory <mallory@example.org>` is not in port.json `authors`' \
  git -C "$r" -c user.name=Mallory -c user.email=mallory@example.org commit -q -m "feat: c"
git -C "$r" remote add origin "$bare"
unhooked -C "$r" -c user.name=Mallory -c user.email=mallory@example.org commit -q -m "feat: c"
refuses "pre-push author" 'identity `Mallory <mallory@example.org>` is not in port.json `authors`' git -C "$r" push -q origin HEAD:refs/heads/author

# 6. With no config folder the hooks pass and one stderr line says nothing was checked.
r=$(fixture absent)
printf 'billed through acme-billing\n' > "$r/n.txt"
git -C "$r" add n.txt
absent="$(cd "$work" && pwd)/no-such-folder"   # Path() collapses the `//` a trailing-slash TMPDIR leaves in $work
note=$(cd "$r" && COLLOID_LEAK_DIR="$absent" python3 "$gate" staged 2>&1 >/dev/null)
[[ "$note" == "leak-gate: no leak list was found at $absent; nothing was checked" ]] || fail "absent-folder note was: $note"
allows "commit with no leak list" env COLLOID_LEAK_DIR="$absent" git -C "$r" commit -q -m "docs: n"
git -C "$r" remote add origin "$bare"
allows "push with no leak list" env COLLOID_LEAK_DIR="$absent" git -C "$r" push -q origin HEAD:refs/heads/absent
# The default folder is ~/.config/colloid when the variable is unset.
printf 'billed through acme-billing\n' > "$r/d.txt"
git -C "$r" add d.txt
refuses "default folder is read" 'd.txt:1: `acme-billing`' bash -c \
  'cd "$1" && unset COLLOID_LEAK_DIR && mkdir -p "$HOME/.config" && cp -R "$2" "$HOME/.config/colloid" && python3 "$3" staged' _ "$r" "$COLLOID_LEAK_DIR" "$gate"
rm -rf "$HOME/.config"

# 7. A malformed list refuses with its file and line number.
r=$(fixture malformed)
printf 'x\n' > "$r/x.txt"
git -C "$r" add x.txt
cp "$COLLOID_LEAK_DIR/satellites.txt" "$work/satellites.good"
printf '# note\nacme-billing==>billing-app\nforgot the arrow\n' > "$COLLOID_LEAK_DIR/satellites.txt"
refuses "row without an arrow" 'satellites.txt:3: write `name==>replacement`' git -C "$r" commit -q -m "feat: x"
printf 'acme-billing==>bad replacement!\n' > "$COLLOID_LEAK_DIR/satellites.txt"
refuses "unsafe replacement" 'satellites.txt:1: write `name==>replacement`' git -C "$r" commit -q -m "feat: x"
cp "$work/satellites.good" "$COLLOID_LEAK_DIR/satellites.txt"
cp "$COLLOID_LEAK_DIR/port.json" "$work/port.good"
printf '{\n  "authors": [\n' > "$COLLOID_LEAK_DIR/port.json"
refuses "bad JSON" 'port.json:3:' git -C "$r" commit -q -m "feat: x"
cp "$work/port.good" "$COLLOID_LEAK_DIR/port.json"
allows "restored list" git -C "$r" commit -q -m "feat: x"

# 8. history audits every commit, including a name in a file deleted two commits back.
r=$(fixture history-clean)
allows "history of a clean repository" python3 "$gate" history "$r"
r=$(fixture history-dirty)
printf 'owed to acme-billing\n' > "$r/gone.txt"
git -C "$r" add gone.txt
unhooked -C "$r" commit -q -m "feat: gone"
dirty_sha=$(git -C "$r" rev-parse --short=12 HEAD)
git -C "$r" rm -q gone.txt
unhooked -C "$r" commit -q -m "chore: drop gone"
printf 'more\n' > "$r/more.txt"
git -C "$r" add more.txt
unhooked -C "$r" commit -q -m "feat: more"
refuses "history with a deleted leak" "commit $dirty_sha gone.txt:1: \`acme-billing\`" python3 "$gate" history "$r"

# 9. classify reports a machine name in no list, and is quiet once it is listed.
mkdir -p "$machine/projects/zeta-labs"
refuses "unclassified folder" 'name `zeta-labs` is on this machine' python3 "$gate" classify
refuses "pre-push classify" 'name `zeta-labs` is on this machine' git -C "$(fixture classify)" push -q "$bare" HEAD:refs/heads/classify
printf 'zeta-labs==>labs-a\n' >> "$COLLOID_LEAK_DIR/satellites.txt"
allows "classified folder" python3 "$gate" classify

echo "test-leak-gate: $pass checks passed"
