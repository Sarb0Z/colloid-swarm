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
# resolves fine, so no broken-link test finds it. The generator may delete them
# because git can give them back.
orphan() {
  local name="$1"; shift
  "$@" || fail "could not apply mutation: $name"
  git -C "$fixture" add -A >/dev/null 2>&1
  git -C "$fixture" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm "$name" >/dev/null 2>&1 \
    || fail "could not commit mutation: $name"
  if gate; then fail "--check passed on a tracked path the plan does not emit: $name"; fi
  sync || fail "the generator must repair: $name"
  # The manifest is the index, so a deletion still reads as tracked until it is
  # staged — the gate is right to keep reporting until the removal is recorded.
  if gate; then fail "the gate cleared before the removal was staged: $name"; fi
  git -C "$fixture" add -A >/dev/null 2>&1
  git -C "$fixture" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm "repair $name" >/dev/null 2>&1
  gate || fail "the generator did not repair: $name"
}
orphan 'link to an unknown skill' ln -sfn "../../.agents/skills/$skill" "$fixture/.claude/skills/ghost"
orphan 'tracked dangling link'    ln -sfn ../../.agents/skills/absent "$fixture/.claude/skills/gone"
orphan 'orphan agent definition'  cp "$fixture/.claude/agents/researcher.md" "$fixture/.claude/agents/orphan.md"
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
  || fail 'committing an operator subagent must not forfeit it to the prune'
grep -q 'my own subagent' "$fixture/.claude/agents/my-helper.md" \
  || fail 'the operator subagent was overwritten'
gate || fail 'a committed operator subagent must not read as drift'
git -C "$fixture" rm -q -f .claude/agents/my-helper.md >/dev/null 2>&1
git -C "$fixture" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm unmine >/dev/null 2>&1

# MANAGED is the only thing keeping the prune out of the rest of .claude/. A
# plain file is already protected by the banner rule, so testing with one proves
# nothing — it takes a tracked symlink, which `ours()` accepts, sitting outside
# the three managed directories.
ln -sfn ../../.agents/claude/README.md "$fixture/.claude/hooks/legacy.md"
git -C "$fixture" add -A >/dev/null 2>&1
git -C "$fixture" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm legacy >/dev/null 2>&1
sync >/dev/null 2>&1 || true
[[ -L "$fixture/.claude/hooks/legacy.md" ]] \
  || fail 'the prune escaped the managed directories and deleted a tracked link'
git -C "$fixture" rm -q -f .claude/hooks/legacy.md >/dev/null 2>&1
git -C "$fixture" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm unlegacy >/dev/null 2>&1
gate || fail 'the gate must clear once the unmanaged link is removed'

# Every way reading .agents/skills can fail must stop the run, because each one
# otherwise yields an empty plan and an empty plan authorises deleting every
# link. `chmod 111` is only one of four; the other three shipped once already.
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

# "What git can give back" means what git already holds. A tracked path the plan
# does not emit, carrying an uncommitted edit, is not recoverable by deleting it
# and running `git checkout --` — that restores the last commit, not the edit.
# Carries the banner, so it is ours and otherwise prunable — which is what makes
# the uncommitted-edit guard the only thing protecting it.
cp "$fixture/.claude/agents/researcher.md" "$fixture/.claude/agents/extra.md"
git -C "$fixture" add -A >/dev/null 2>&1
git -C "$fixture" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm extra >/dev/null 2>&1
printf '\nLOCAL EDIT\n' >> "$fixture/.claude/agents/extra.md"
sync >/dev/null 2>&1 || true
[[ -f "$fixture/.claude/agents/extra.md" ]] \
  || fail 'the prune destroyed an uncommitted edit git cannot restore'
grep -q 'LOCAL EDIT' "$fixture/.claude/agents/extra.md" \
  || fail 'the prune replaced an uncommitted edit with the committed blob'
git -C "$fixture" checkout -- .claude/agents/extra.md >/dev/null 2>&1
sync >/dev/null 2>&1 || true
[[ -f "$fixture/.claude/agents/extra.md" ]] && fail 'a clean generated orphan must be pruned'
git -C "$fixture" add -A >/dev/null 2>&1
git -C "$fixture" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm unextra >/dev/null 2>&1
gate || fail 'the gate must clear once the pruned orphan is staged'

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
[[ -L "$fixture/.claude/skills/removed" ]] && fail 'a tracked dangling link must still be pruned'
git -C "$fixture" add -A >/dev/null 2>&1
git -C "$fixture" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm unremoved >/dev/null 2>&1

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

# Model routing comes from the tracked example. A local config.json cannot
# override it, and silence there reads as "my edit worked".
python3 - "$fixture/.agents/config.json" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"models": {"researcher": "opus"}}, f)
PY
warning="$(cd "$fixture" && .agents/sync-claude-agents.sh 2>&1 >/dev/null)"
[[ "$warning" == *"researcher"* ]] || fail 'an ignored config.json model must warn'
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
