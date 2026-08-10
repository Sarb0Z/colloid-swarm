#!/usr/bin/env bash
# Contract tests for sync-claude-agents.sh --check, the drift gate on the
# generated output under .claude/ that the tree commits.
#
# The gate answers two questions, and a test for only the first is how it
# shipped blind: every path the script emits must match the tree, and the
# generated directories must hold nothing the script would not emit.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# A copy of the WORKING TREE, never the repository itself: the mutations below
# delete tracked links. Copied rather than `git archive HEAD`, which would judge
# the scripts under test against HEAD's inputs and HEAD's .claude/ — the defect
# class already recorded against test-export.sh.
#
# Tracked paths only, so the 250 MB of node_modules under .agents/mcp-servers
# stays out; the content still comes from the working tree, not the index.
fixture="$scratch/repo"
mkdir -p "$fixture"
( cd "$repo" && git ls-files -z -- .agents .claude | tar -cf - --null -T - ) \
  | tar -xf - -C "$fixture" \
  || fail 'could not build the fixture from tracked paths'
# The root .gitignore lives outside those two trees, so it has to be carried in
# deliberately. Without it `git add -A` tracks the settings.local.json that
# sync-mcp.sh writes, and the manifest correctly reports a file nothing
# generates — green only on a machine whose global ignore happens to cover it.
cp "$repo/.gitignore" "$fixture/.gitignore" || fail 'could not carry .gitignore into the fixture'
git -C "$fixture" init -q

# Whichever skill the repository actually installs. Satellites carry a different
# set, and a hardcoded name turns a missing fixture into a false failure blaming
# the gate.
skill=""
for d in "$fixture"/.agents/skills/*/; do
  [[ -d "$d" ]] || continue
  skill="$(basename "$d")"
  break
done
[[ -n "$skill" ]] || fail 'no skill installed under .agents/skills — nothing to exercise'

sync()  { ( cd "$fixture" && .agents/sync-claude-agents.sh >/dev/null 2>&1 ); }
gate()  { ( cd "$fixture" && .agents/sync-claude-agents.sh --check >/dev/null 2>&1 ); }
# Stderr only: the drift report goes there, and stdout carries generator noise.
report() { ( cd "$fixture" && { .agents/sync-claude-agents.sh --check >/dev/null; } 2>&1 ); }
commit_fixture() {
  git -C "$fixture" add -A >/dev/null 2>&1
  git -C "$fixture" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false \
    commit -qm "$1" >/dev/null 2>&1 || true
}

sync || fail 'the generator must succeed on a clean fixture'
# The gate compares against `git ls-files .claude`, so the fixture has to have a
# commit. A repository that tracks no .claude paths at all is a supported
# shape too — the gate says so on stderr and checks content only.
git -C "$fixture" add -A >/dev/null 2>&1
git -C "$fixture" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm fixture >/dev/null 2>&1 \
  || fail 'could not commit the fixture'
gate || fail 'the gate must pass immediately after a generator run'

# Each mutation is a way the tree drifts from its inputs. The gate must reject
# every one; `sync` restores the fixture between cases.
mutate() {
  local name="$1"; shift
  "$@" || fail "could not apply mutation: $name"
  if gate; then fail "--check passed on drift: $name"; fi
  sync || fail "the generator must repair: $name"
  gate || fail "the generator did not repair: $name"
}

mutate 'deleted skill rule link'  rm -f "$fixture/.claude/rules/$skill.md"
mutate 'deleted skill link'       rm -f "$fixture/.claude/skills/$skill"
mutate 'deleted adapter link'     rm -f "$fixture/.claude/hooks/adapter.sh"
mutate 'repointed link'           ln -sfn ../.agents/claude/README.md "$fixture/.claude/settings.json"

# A path git tracks that the plan does not emit: a skill removed while its links
# stayed committed. The manifest is the only thing that sees these — the first
# resolves fine, so no broken-link test finds it.
#
# This script deletes nothing, so the gate must name the path AND the command
# that removes it, and the generator must leave it exactly where it is.
orphan() {
  local name="$1" rel="$2"; shift 2
  "$@" || fail "could not apply mutation: $name"
  commit_fixture "$name"
  if gate; then fail "--check passed on a tracked path the plan does not emit: $name"; fi
  [[ "$(report || true)" == *"git rm $rel"* ]] \
    || fail "the report named no remedy for: $name"
  sync || fail "the generator must still succeed alongside: $name"
  [[ -e "$fixture/$rel" || -L "$fixture/$rel" ]] \
    || fail "the generator deleted a path it does not own: $name"
  git -C "$fixture" rm -q -f "$rel" >/dev/null 2>&1 || fail "could not git rm: $name"
  commit_fixture "remove $name"
  gate || fail "the gate did not clear after git rm: $name"
}
orphan 'link to an unknown skill' .claude/skills/ghost \
  ln -sfn "../../.agents/skills/$skill" "$fixture/.claude/skills/ghost"
orphan 'tracked dangling link'    .claude/skills/gone \
  ln -sfn ../../.agents/skills/absent "$fixture/.claude/skills/gone"
orphan 'orphan agent definition'  .claude/agents/orphan.md \
  cp "$fixture/.claude/agents/researcher.md" "$fixture/.claude/agents/orphan.md"
# Claude Code supports hand-written project subagents, so .claude/agents is not
# exclusively generated. Ownership is the GENERATED banner, not tracking state:
# an operator's definition survives whether or not they committed it, and the
# gate must not call it drift either.
printf 'my own subagent\n' > "$fixture/.claude/agents/my-helper.md"
sync >/dev/null || fail 'the generator must succeed alongside an operator file'
[[ -f "$fixture/.claude/agents/my-helper.md" ]] \
  || fail 'the generator deleted an untracked operator file in .claude/agents'
gate || fail 'an untracked operator file must not read as drift'

git -C "$fixture" add -A >/dev/null 2>&1
git -C "$fixture" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm mine >/dev/null 2>&1
sync >/dev/null || fail 'the generator must succeed alongside a committed operator file'
[[ -f "$fixture/.claude/agents/my-helper.md" ]] \
  || fail 'committing an operator subagent must not forfeit it'
grep -q 'my own subagent' "$fixture/.claude/agents/my-helper.md" \
  || fail 'the operator subagent was overwritten'
gate || fail 'a committed operator subagent must not read as drift'
git -C "$fixture" rm -q -f .claude/agents/my-helper.md >/dev/null 2>&1
git -C "$fixture" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm unmine >/dev/null 2>&1

# MANAGED decides which tracked-but-unplanned paths are the operator's to keep
# and which are reported. A tracked link outside it is not an operator file, so
# the gate must name it; a banner-less file inside it must stay silent.
ln -sfn ../../.agents/claude/README.md "$fixture/.claude/hooks/legacy.md"
commit_fixture legacy
if gate; then fail 'the gate ignored a tracked link outside the managed directories'; fi
sync >/dev/null 2>&1 || true
[[ -L "$fixture/.claude/hooks/legacy.md" ]] \
  || fail 'the generator deleted a tracked link it does not own'
git -C "$fixture" rm -q -f .claude/hooks/legacy.md >/dev/null 2>&1
commit_fixture unlegacy
gate || fail 'the gate must clear once the unmanaged link is removed'

# Every way reading .agents/skills can fail must stop the run. An empty plan no
# longer authorises deleting anything, but it would still make the gate report
# all 28 links as stale and tell the operator to `git rm` them.
count_links() { find "$fixture/.claude/skills" "$fixture/.claude/rules" -type l 2>/dev/null | wc -l | tr -d ' '; }
skills_intact() {
  local label="$1" before after
  before="$(count_links)"
  sync >/dev/null 2>&1 || true
  after="$(count_links)"
  [[ "$before" == "$after" ]] || fail "$label swept the links: $before -> $after"
}
saved="$scratch/skills-backup"
cp -R "$fixture/.agents/skills" "$saved"

rm -rf "$fixture/.agents/skills"
skills_intact 'an absent .agents/skills'
printf 'x' > "$fixture/.agents/skills"
skills_intact 'a regular file at .agents/skills'
rm -f "$fixture/.agents/skills"
ln -s /nonexistent-skills-target "$fixture/.agents/skills"
skills_intact 'a broken symlink at .agents/skills'
rm -f "$fixture/.agents/skills"
# Pointed at a *different* skill set, which is the hazard: following the link
# would wire foreign skills in as trusted and prune the real ones. A symlink to
# an identical copy proves nothing.
mkdir -p "$scratch/foreign/impostor"
printf -- '---\nname: impostor\ndescription: x\n---\n' > "$scratch/foreign/impostor/AGENTS.md"
ln -s "$scratch/foreign" "$fixture/.agents/skills"
skills_intact 'a symlinked .agents/skills'
rm -f "$fixture/.agents/skills"
# Readable and empty is the one case os.listdir cannot refuse on its own.
mkdir -p "$fixture/.agents/skills"
skills_intact 'an empty .agents/skills'
rmdir "$fixture/.agents/skills"
cp -R "$saved" "$fixture/.agents/skills"
# Skipped as root, which ignores the mode bits.
if [[ "$(id -u)" != "0" ]]; then
  chmod 111 "$fixture/.agents/skills"
  skills_intact 'an unreadable .agents/skills'
  chmod 755 "$fixture/.agents/skills"
fi
sync >/dev/null
gate || fail 'the fixture must be repairable after the skills-directory cases'

# --- Guards that no case above turns red -------------------------------------
# Each of the three below survived removal with this suite still green, which is
# what `test-mutation.py` reports. A guard nothing exercises is a guard nobody
# can change safely.

# --check compares against `git ls-files .claude`. Outside a work tree there is
# no manifest, so refusing is the only honest answer: proceeding would grade
# content against an empty path set and call a half-synced tree clean.
nogit="$scratch/nogit"
rm -rf "$nogit"
cp -R "$fixture" "$nogit" || fail 'could not copy the fixture for the work-tree case'
rm -rf "$nogit/.git"
if ( cd "$nogit" && .agents/sync-claude-agents.sh --check >/dev/null 2>&1 ); then
  fail '--check passed outside a git work tree, where it has no manifest'
fi
[[ "$( ( cd "$nogit" && .agents/sync-claude-agents.sh --check 2>&1 >/dev/null ) || true)" == *'work tree'* ]] \
  || fail '--check refused outside a work tree without saying why'

# The manifest's other direction: a skill added and synced, its links never
# committed. Both links resolve, so no broken-link case sees it — only the
# plan-minus-tracked comparison does.
mkdir -p "$fixture/.agents/skills/newcomer"
printf -- '---\nname: newcomer\ndescription: x\n---\n' > "$fixture/.agents/skills/newcomer/SKILL.md"
printf '# Newcomer\n' > "$fixture/.agents/skills/newcomer/AGENTS.md"
sync || fail 'the generator must emit links for a new skill'
if gate; then fail '--check passed with generated links the tree does not track'; fi
[[ "$(report || true)" == *'generated, not tracked'* ]] \
  || fail '--check did not name the generated paths the tree does not track'
commit_fixture newcomer
gate || fail 'the gate must clear once the new skill links are committed'

# A real directory where a link belongs. `ln -sfn` and os.symlink both place the
# link *inside* it rather than replacing it, so the generator must refuse the
# path instead of silently producing .claude/skills/<name>/<name>.
rm -f "$fixture/.claude/skills/$skill"
mkdir -p "$fixture/.claude/skills/$skill"
if ( cd "$fixture" && .agents/sync-claude-agents.sh >/dev/null 2>&1 ); then
  fail 'the generator succeeded with a real directory at a generated link path'
fi
[[ "$( ( cd "$fixture" && .agents/sync-claude-agents.sh 2>&1 >/dev/null ) || true)" == *'(directory)'* ]] \
  || fail 'the generator did not name the directory that blocked it'
rmdir "$fixture/.claude/skills/$skill"
sync || fail 'the generator must repair once the directory is gone'
gate || fail 'the gate must clear after the blocked-path case'

# "What git can give back" means what git already holds. A tracked path the plan
# does not emit, carrying an uncommitted edit, is not recoverable by deleting it
# and running `git checkout --` — that restores the last commit, not the edit.
# Carries the banner, so it is ours — and still not the generator's to delete.
# A local edit is the case that made deleting tempting: `git checkout --` would
# return the committed blob, not the edit, so the restore hint would have lied.
cp "$fixture/.claude/agents/researcher.md" "$fixture/.claude/agents/extra.md"
commit_fixture extra
printf '\nLOCAL EDIT\n' >> "$fixture/.claude/agents/extra.md"
sync >/dev/null 2>&1 || true
[[ -f "$fixture/.claude/agents/extra.md" ]] \
  || fail 'the generator destroyed an uncommitted edit git cannot restore'
grep -q 'LOCAL EDIT' "$fixture/.claude/agents/extra.md" \
  || fail 'the generator replaced an uncommitted edit with the committed blob'
git -C "$fixture" checkout -- .claude/agents/extra.md >/dev/null 2>&1
sync >/dev/null 2>&1 || true
[[ -f "$fixture/.claude/agents/extra.md" ]] \
  || fail 'the generator deleted a clean tracked orphan instead of reporting it'
[[ "$(report || true)" == *"git rm .claude/agents/extra.md"* ]] \
  || fail 'the report named no remedy for a tracked orphan'
git -C "$fixture" rm -q -f .claude/agents/extra.md >/dev/null 2>&1
commit_fixture unextra
gate || fail 'the gate must clear once the orphan is removed by hand'

# An operator subagent sharing a registry name. `researcher` is the name Claude
# Code's own docs use in examples, so the collision is likely rather than
# contrived, and the file is untracked — overwriting it destroys it outright.
printf 'MY OWN RESEARCHER SUBAGENT\n' > "$fixture/.claude/agents/researcher.md"
sync >/dev/null 2>&1 || true
grep -q 'MY OWN RESEARCHER SUBAGENT' "$fixture/.claude/agents/researcher.md" \
  || fail 'the generator overwrote an operator file at a generated name'
git -C "$fixture" checkout -- .claude/agents/researcher.md >/dev/null 2>&1
sync >/dev/null

# An untracked broken link is the operator's work in progress; .agents/AGENTS.md
# reads a broken link as a missing canonical file, not as a symlink to sweep.
ln -sfn ../../my-local-skills/wip "$fixture/.claude/skills/wip"
ln -sfn ../personas/draft.md "$fixture/.claude/agents/draft.md"
sync >/dev/null 2>&1 || true
[[ -L "$fixture/.claude/skills/wip" && -L "$fixture/.claude/agents/draft.md" ]] \
  || fail 'the prune deleted an untracked dangling link the operator created'
rm -f "$fixture/.claude/skills/wip" "$fixture/.claude/agents/draft.md"

# ...but a link git already holds is still this script's to clean up.
ln -sfn ../../.agents/skills/removed "$fixture/.claude/skills/removed"
git -C "$fixture" add -A >/dev/null 2>&1
git -C "$fixture" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm removed >/dev/null 2>&1
sync >/dev/null 2>&1 || true
[[ -L "$fixture/.claude/skills/removed" ]] \
  || fail 'the generator deleted a tracked dangling link instead of reporting it'
git -C "$fixture" rm -q -f .claude/skills/removed >/dev/null 2>&1
commit_fixture unremoved

# An uncommitted edit to a tracked link. Deleting it loses the edit — the
# committed target is what `git checkout --` returns, not the operator's change.
# Nothing that deletes may run without consulting the uncommitted-edit guard.
ln -sfn "../../.agents/skills/$skill" "$fixture/.claude/skills/alias"
git -C "$fixture" add -A >/dev/null 2>&1
git -C "$fixture" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm alias >/dev/null 2>&1
ln -sfn ../../.agents/skills/wip-not-yet-created "$fixture/.claude/skills/alias"
sync >/dev/null 2>&1 || true
[[ -L "$fixture/.claude/skills/alias" ]] \
  || fail 'an uncommitted edit to a tracked link was deleted despite the guard'
[[ "$(readlink "$fixture/.claude/skills/alias")" == *wip-not-yet-created ]] \
  || fail 'the uncommitted edit was reverted to the committed target'
git -C "$fixture" checkout -- .claude/skills/alias >/dev/null 2>&1
git -C "$fixture" rm -q -f .claude/skills/alias >/dev/null 2>&1
git -C "$fixture" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm unalias >/dev/null 2>&1

# The generator and the gate must converge: after a sync, --check passes. An
# operator's untracked broken link is theirs, so reporting it wedges CI red with
# no repair the generator is willing to make.
ln -sfn ../../my-local-skills/wip "$fixture/.claude/skills/wip2"
sync >/dev/null 2>&1 || true
gate || fail 'an untracked dangling link left --check unclearable after a sync'
rm -f "$fixture/.claude/skills/wip2"

# A file the gate cannot read is not evidence that it is the operator's. Three
# outcomes must not collapse onto the reassuring one. Skipped as root.
if [[ "$(id -u)" != "0" ]]; then
  cp "$fixture/.claude/agents/researcher.md" "$fixture/.claude/agents/unreadable.md"
  git -C "$fixture" add -A >/dev/null 2>&1
  git -C "$fixture" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm unreadable >/dev/null 2>&1
  chmod 000 "$fixture/.claude/agents/unreadable.md"
  if gate; then chmod 644 "$fixture/.claude/agents/unreadable.md"; fail 'the gate went green on a tracked file it could not read'; fi
  chmod 644 "$fixture/.claude/agents/unreadable.md"
  git -C "$fixture" rm -q -f .claude/agents/unreadable.md >/dev/null 2>&1
  git -C "$fixture" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm ununreadable >/dev/null 2>&1
fi

printf '\nTAMPERED\n' >> "$fixture/.claude/agents/researcher.md"
if gate; then fail '--check passed on a hand-edited agent definition'; fi
sync >/dev/null

# One run must name every class of drift. Reporting the agent file and stopping
# leaves the operator fixing one class per CI round.
printf '\nTAMPERED\n' >> "$fixture/.claude/agents/researcher.md"
rm -f "$fixture/.claude/rules/$skill.md"
# `|| true`: the gate exits 1 here by design, and set -e would take the
# assignment down with it before the report could be read.
both="$(report || true)"
[[ "$both" == *"researcher.md"* ]] || fail 'the report omitted the stale agent definition'
[[ "$both" == *"rules/$skill.md"* ]] || fail 'a stale agent definition suppressed the symlink report'
sync >/dev/null
gate || fail 'the generator did not repair the combined case'

# --check must not touch the tree, or CI's clean-tree assertion is measuring the
# gate rather than the suites. Snapshot in Python: `stat -f` is BSD-only and
# this suite runs on the Linux runner too.
snapshot() {
  ( cd "$fixture" && python3 - <<'PY'
import hashlib, os
for root, dirs, files in os.walk(".claude", followlinks=False):
    dirs.sort()
    for name in sorted(dirs + files):
        path = os.path.join(root, name)
        if os.path.islink(path):
            print(path, "->", os.readlink(path))
        elif os.path.isfile(path):
            with open(path, "rb") as handle:
                print(path, hashlib.sha256(handle.read()).hexdigest())
        else:
            print(path, "dir")
PY
  )
}
before="$(snapshot)"
gate || fail 'the gate must pass before the read-only check'
after="$(snapshot)"
[[ "$before" == "$after" ]] || fail '--check modified .claude/'

# Subagent routing comes from the tracked example. A local config.json cannot
# override it, and silence there reads as "my edit worked".
python3 - "$fixture/.agents/config.json" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"subagents": {"researcher": {"model": "opus"}}}, f)
PY
warning="$(cd "$fixture" && .agents/sync-claude-agents.sh 2>&1 >/dev/null)"
[[ "$warning" == *"researcher"* ]] || fail 'an ignored config.json subagent must warn'

# A `models` block is the shape every config.json predating the `subagents` key
# still has. Nothing reads it, and a file that overrides the example per key
# gives an operator every reason to believe otherwise.
python3 - "$fixture/.agents/config.json" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"models": {"researcher": "opus"}}, f)
PY
warning="$(cd "$fixture" && .agents/sync-claude-agents.sh 2>&1 >/dev/null)"
[[ "$warning" == *"models"* ]] || fail 'a dead config.json models block must warn'
printf '{}' > "$fixture/.agents/config.json"

# A frontmatter key the script cannot emit is silent otherwise: it sits in
# config, no line is written, and the cell runs on the default.
python3 - "$fixture/.agents/config.json.example" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
data.setdefault("subagents", {}).setdefault("researcher", {})["maxTurns"] = 5
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
PY
if ( cd "$fixture" && .agents/sync-claude-agents.sh >/dev/null 2>&1 ); then
  fail 'a subagent field the script cannot emit must stop the run'
fi
git -C "$fixture" checkout -- .agents/config.json.example 2>/dev/null \
  || fail 'could not restore the fixture config'
grep -q 'model: sonnet' "$fixture/.claude/agents/researcher.md" \
  || fail 'routing must follow config.json.example, not the local config'

# A persona mid-merge would be copied verbatim into a live system prompt, and
# the gate would certify it: the output does match the input.
cp "$fixture/.agents/personas/researcher.md" "$scratch/persona-backup"
{ printf '<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> other\n'; } >> "$fixture/.agents/personas/researcher.md"
if sync; then fail 'a persona holding conflict markers must not reach an agent definition'; fi
grep -q '<<<<<<<' "$fixture/.claude/agents/researcher.md" \
  && fail 'conflict markers were written into the generated definition'
cp "$scratch/persona-backup" "$fixture/.agents/personas/researcher.md"
sync >/dev/null

# A malformed config is a typo the operator must see, not a silent default.
printf '%s\n' '{ broken' > "$fixture/.agents/config.json"
if sync; then fail 'a malformed config.json must fail the sync, not pass silently'; fi

echo "sync-claude-agents drift gate checks passed."
