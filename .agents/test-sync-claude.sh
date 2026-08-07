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
fixture="$scratch/repo"
mkdir -p "$fixture"
tar -cf - -C "$repo" .agents .claude | tar -xf - -C "$fixture"
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
mutate 'dangling skill link'      ln -sfn ../../.agents/skills/absent "$fixture/.claude/skills/ghost"

# Reported, never deleted. The emitted set is built by side effect of the link
# loop, so an unreadable input yields an empty set — safe to report against,
# unsafe to delete against. These stay until a human removes them.
report_only() {
  local name="$1"; shift
  "$@" || fail "could not apply mutation: $name"
  if gate; then fail "--check passed on drift: $name"; fi
  sync >/dev/null || fail "the generator must still succeed: $name"
  if gate; then fail "the generator silently deleted it instead of reporting: $name"; fi
}
# Resolves, so a broken-link test never sees it — only the emitted set does.
report_only 'link to an unknown skill' ln -sfn "../../.agents/skills/$skill" "$fixture/.claude/skills/ghost"
rm -f "$fixture/.claude/skills/ghost"
report_only 'orphan agent definition'  cp "$fixture/.claude/agents/researcher.md" "$fixture/.claude/agents/orphan.md"
rm -f "$fixture/.claude/agents/orphan.md"
gate || fail 'removing the orphans by hand must clear the gate'

# An operator's own subagent definition is not this script's to delete. It is
# untracked, so a prune is unrecoverable.
printf 'my own subagent\n' > "$fixture/.claude/agents/my-helper.md"
sync >/dev/null || fail 'the generator must succeed alongside an operator file'
[[ -f "$fixture/.claude/agents/my-helper.md" ]] \
  || fail 'the generator deleted an untracked operator file in .claude/agents'
rm -f "$fixture/.claude/agents/my-helper.md"

# An unreadable skills directory must not read as "zero skills" and take every
# link with it. Skipped as root, which ignores the mode bits.
if [[ "$(id -u)" != "0" ]]; then
  links_before="$(find "$fixture/.claude/skills" "$fixture/.claude/rules" -type l | wc -l | tr -d ' ')"
  chmod 111 "$fixture/.agents/skills"
  sync >/dev/null 2>&1 || true
  chmod 755 "$fixture/.agents/skills"
  links_after="$(find "$fixture/.claude/skills" "$fixture/.claude/rules" -type l | wc -l | tr -d ' ')"
  [[ "$links_before" == "$links_after" ]] \
    || fail "an unreadable .agents/skills deleted links: $links_before -> $links_after"
  sync >/dev/null
fi

printf '\nTAMPERED\n' >> "$fixture/.claude/agents/researcher.md"
if gate; then fail '--check passed on a hand-edited agent definition'; fi
sync >/dev/null

# One run must name every class of drift. Reporting the agent file and stopping
# leaves the operator fixing one class per CI round.
printf '\nTAMPERED\n' >> "$fixture/.claude/agents/researcher.md"
rm -f "$fixture/.claude/rules/pentesting.md"
# `|| true`: the gate exits 1 here by design, and set -e would take the
# assignment down with it before the report could be read.
both="$(report || true)"
[[ "$both" == *"researcher.md"* ]] || fail 'the report omitted the stale agent definition'
[[ "$both" == *"rules/pentesting.md"* ]] || fail 'a stale agent definition suppressed the symlink report'
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

# A malformed config is a typo the operator must see, not a silent default.
printf '%s\n' '{ broken' > "$fixture/.agents/config.json"
if sync; then fail 'a malformed config.json must fail the sync, not pass silently'; fi

echo "sync-claude-agents drift gate checks passed."
