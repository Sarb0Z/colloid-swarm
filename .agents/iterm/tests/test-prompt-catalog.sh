#!/usr/bin/env bash
# Tests for prompt-catalog. It runs as a copy inside a fixture repository, so
# the skills it lists are the fixture's; every call names a plist file as its
# domain, never iTerm2's own preferences; a stub pgrep says whether iTerm2 runs.
set -uo pipefail

IT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$T"' EXIT
fails=0

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fails=$((fails + 1)); }
eq() { # name expected actual
  if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi
}
nl=$'\n'

# --- the fixture -------------------------------------------------------------
FX=$T/fx
mkdir -p "$FX/.agents/iterm" "$T/home/.claude/skills" "$T/stub"
cp -R "$IT/bin" "$FX/.agents/iterm/bin"
cp "$IT/catalog.json" "$FX/.agents/iterm/catalog.json"
for s in alpha review-animations security-audit; do
  mkdir -p "$FX/.claude/skills/$s"
  : >"$FX/.claude/skills/$s/SKILL.md"
done
mkdir "$FX/.claude/skills/no-skill-file"
for s in alpha user-one; do
  mkdir -p "$T/home/.claude/skills/$s"
  : >"$T/home/.claude/skills/$s/SKILL.md"
done
export HOME=$T/home
# The stub pgrep exits with the number in $T/pgrep-rc: 0 while "iTerm2 runs", 1 when not.
cat >"$T/stub/pgrep" <<STUB
#!/usr/bin/env bash
[[ "\$*" == "-a -x iTerm2" ]] || { echo "pgrep stub: unexpected arguments: \$*" >&2; exit 3; }
exit "\$(cat "$T/pgrep-rc")"
STUB
chmod +x "$T/stub/pgrep"
export PATH=$T/stub:$PATH
echo 1 >"$T/pgrep-rc"

DOM=$T/prefs/iterm-test.plist
mkdir "$T/prefs"
EXPORTS=$HOME/.local/state/iterm-prompts
TODAY=$(date +%Y-%m-%d)
store() { defaults write "$DOM" CodeReviewSavedPrompts -data "$(printf '%s' "$1" | xxd -p | tr -d '\n')"; }
stored() { python3 -c 'import plistlib,subprocess,sys; sys.stdout.buffer.write(plistlib.loads(subprocess.run(["defaults","export",sys.argv[1],"-"],capture_output=True).stdout)["CodeReviewSavedPrompts"])' "$DOM"; }
names() { stored | python3 -c 'import json,sys; print("\n".join(p["name"] for p in json.load(sys.stdin)))'; }
text_of() { stored | python3 -c 'import json,sys; print(next(p["text"] for p in json.load(sys.stdin) if p["name"] == sys.argv[1]))' "$1"; }
catalog() { "$FX/.agents/iterm/bin/prompt-catalog" "$@" --domain "$DOM"; }

# The operator's two prompts (one with a field iTerm2 does not know), around an entry an earlier run made.
OWN1='{"name":"Default","uuid":"5B0C0E4E-0000-4000-8000-000000000001","text":"Review this.\nBe terse."}'
OWN2='{"name":"Mine · ünïcode","uuid":"5B0C0E4E-0000-4000-8000-000000000002","text":"#! inline\nmy own","extra":1}'
STALE='{"name":"Skill · removed-since","uuid":"colloid-prompt:skill:removed-since","text":"old"}'
BEFORE="[$OWN1,$STALE,$OWN2]"
store "$BEFORE"

EXPECTED="Default
Mine · ünïcode
Workflow · Answer
Workflow · Ship
Workflow · Operate
Workflow · Build
Workflow · Fix
Workflow · Write
Workflow · Spec
Workflow · Scaffold
Workflow · Verify
Workflow · Merge
Playbook · breadcrumb-burndown
Playbook · learning-report
Playbook · report-investigation
Playbook · report-implementation
Playbook · recurring-correction-mining
Playbook · move-project-directory
Review · Opus
Review · Sonnet
Skill · alpha
Skill · review-animations
Skill · security-audit
Skill · user-one"

# --- without --apply: shows, writes nothing ----------------------------------
out=$(catalog 2>&1); rc=$?
eq "dry run: rc" 0 "$rc"
eq "dry run: the list it would write, kept ones first" "$EXPECTED" "$(sed -E -n 's/^(kept     |generated)  //p' <<<"$out")"
eq "dry run: the operator's prompts are marked kept" "kept       Default${nl}kept       Mine · ünïcode" "$(grep '^kept' <<<"$out")"
eq "dry run: the stored list is unchanged" "$BEFORE" "$(stored)"
[[ ! -e $EXPORTS ]] && ok "dry run: no export" || bad "dry run exported"

# --- --apply while iTerm2 runs: refused --------------------------------------
echo 0 >"$T/pgrep-rc"
err=$(catalog --apply 2>&1 >/dev/null); rc=$?
[[ $rc -eq 1 && $err == *"iTerm2 is running"* && $err == *"Nothing was written."* ]] && ok "apply while iTerm2 runs: refused" || bad "apply while running (rc=$rc): $err"
eq "apply while iTerm2 runs: the stored list is unchanged" "$BEFORE" "$(stored)"
[[ ! -e $EXPORTS ]] && ok "apply while iTerm2 runs: no export" || bad "refused apply exported"
echo 2 >"$T/pgrep-rc"
err=$(catalog --apply 2>&1 >/dev/null); rc=$?
[[ $rc -eq 1 && $err == *"cannot tell whether iTerm2 runs"* ]] && ok "pgrep fails: refused" || bad "pgrep fails (rc=$rc): $err"
eq "pgrep fails: the stored list is unchanged" "$BEFORE" "$(stored)"

# --- --apply -----------------------------------------------------------------
echo 1 >"$T/pgrep-rc"
out=$(catalog --apply 2>&1); rc=$?
eq "apply: rc" 0 "$rc"
eq "apply: the export holds the list as it was, byte for byte" "$BEFORE" "$(cat "$EXPORTS/$TODAY.json" 2>&1)"
eq "apply: names in menu order, the operator's first, the stale entry gone" "$EXPECTED" "$(names)"
eq "apply: the operator's prompts are unchanged, unknown field included" \
  '{"name": "Default", "uuid": "5B0C0E4E-0000-4000-8000-000000000001", "text": "Review this.\nBe terse."} {"name": "Mine · ünïcode", "uuid": "5B0C0E4E-0000-4000-8000-000000000002", "text": "#! inline\nmy own", "extra": 1}' \
  "$(stored | python3 -c 'import json,sys; p=json.load(sys.stdin); print(json.dumps(p[0], ensure_ascii=False), json.dumps(p[1], ensure_ascii=False))')"
eq "apply: every other entry has name, uuid, text and a prefixed id of its own" "22 22 True" \
  "$(stored | python3 -c 'import json,sys; g=json.load(sys.stdin)[2:]; ids=[p["uuid"] for p in g]; print(len(g), len(set(ids)), all(sorted(p)==["name","text","uuid"] and p["uuid"].startswith("colloid-prompt:") for p in g))')"
eq "workflow entry: inline, ending with the task line" "#! inline${nl}Workflow: Build.${nl}<replace this line with the task>" "$(text_of 'Workflow · Build')"
eq "playbook entry" "#! inline playbook=learning-report${nl}Follow .agents/playbooks/learning-report.md." "$(text_of 'Playbook · learning-report')"
eq "playbook entry that needs a task" "#! inline playbook=move-project-directory${nl}Follow .agents/playbooks/move-project-directory.md.${nl}<replace this line with the task>" "$(text_of 'Playbook · move-project-directory')"
eq "review entries" "#! background model=opus kind=review|#! background model=sonnet kind=review" "$(text_of 'Review · Opus')|$(text_of 'Review · Sonnet')"
eq "skill outside catalog.json's background list: inline" "#! inline skill=alpha${nl}Use the alpha skill: read its SKILL.md and follow it." "$(text_of 'Skill · alpha')"
eq "skill in catalog.json's background list: background on its model" "#! background model=sonnet skill=review-animations${nl}Use the review-animations skill: read its SKILL.md and follow it." "$(text_of 'Skill · review-animations')"
# security-audit writes a report file, so it runs in the lead's turn: a background cell only reads.
eq "skill that writes a report file: inline" "#! inline skill=security-audit${nl}Use the security-audit skill: read its SKILL.md and follow it." "$(text_of 'Skill · security-audit')"
eq "catalog.json: the background skills are the two that only read and return findings" \
  '{"review-animations": "sonnet", "web-design-guidelines": "sonnet"}' \
  "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["background_skills"], sort_keys=True))' "$IT/catalog.json")"
eq "user skill: inline" "#! inline skill=user-one${nl}Use the user-one skill: read its SKILL.md and follow it." "$(text_of 'Skill · user-one')"
[[ $out == *"to restore it: defaults write $DOM CodeReviewSavedPrompts -data"*"$EXPORTS/$TODAY.json"* ]] && ok "apply: prints the restore command" || bad "apply output: $out"

# The same old list again on the same day needs no second export.
after=$(stored)
store "$BEFORE"
catalog --apply >/dev/null 2>&1
eq "apply over a list already exported today: no second export" "$TODAY.json" "$(ls "$EXPORTS")"
eq "apply over a list already exported today: the same result" "$after" "$(stored)"

# --- a second --apply changes nothing ----------------------------------------
out=$(catalog --apply 2>&1); rc=$?
[[ $rc -eq 0 && $out == *"unchanged:"* ]] && ok "second apply: says unchanged" || bad "second apply (rc=$rc): $out"
eq "second apply: the stored list is the same" "$after" "$(stored)"
eq "second apply: no second export" "$TODAY.json" "$(ls "$EXPORTS")"
echo 0 >"$T/pgrep-rc"
out=$(catalog --apply 2>&1); rc=$?
eq "nothing to write while iTerm2 runs: no refusal" 0 "$rc"
echo 1 >"$T/pgrep-rc"

# --- a new skill, after the operator added and reordered in the app -----------
mkdir "$FX/.claude/skills/beta"
: >"$FX/.claude/skills/beta/SKILL.md"
OWN3='{"name":"Added in the app","uuid":"5B0C0E4E-0000-4000-8000-000000000003","text":"x"}'
MIXED=$(stored | python3 -c 'import json,sys; p=json.load(sys.stdin); print(json.dumps([p[5], p[1], json.loads(sys.argv[1])] + p[2:5] + p[6:] + [p[0]], ensure_ascii=False))' "$OWN3")
store "$MIXED"
out=$(catalog --apply 2>&1); rc=$?
eq "new skill: rc" 0 "$rc"
eq "new skill: the operator's prompts first in their own order, then the groups, the new skill in place" \
  "Mine · ünïcode${nl}Added in the app${nl}Default${nl}${EXPECTED#*ünïcode$nl}" "$(names | sed 's/^Skill · beta$//' | sed '/^$/d')"
eq "new skill: listed between alpha and review-animations" "Skill · alpha${nl}Skill · beta${nl}Skill · review-animations" "$(names | grep -A2 '^Skill · alpha$')"
eq "new skill: a second export of the day holds the list as it then was" "$MIXED" "$(cat "$EXPORTS/$TODAY-2.json" 2>&1)"
eq "new skill: the first export is untouched" "$BEFORE" "$(cat "$EXPORTS/$TODAY.json")"

# --- refusals at the store ---------------------------------------------------
DOM=$T/prefs/empty.plist
defaults write "$DOM" Other -string x
err=$(catalog --apply 2>&1 >/dev/null); rc=$?
[[ $rc -eq 1 && $err == *"holds no CodeReviewSavedPrompts"* ]] && ok "no saved prompts yet: refused, so iTerm2 still seeds its Default" || bad "no key (rc=$rc): $err"
[[ $(defaults export "$DOM" - | grep -c CodeReviewSavedPrompts) == 0 ]] && ok "no saved prompts yet: the key stays absent" || bad "the key was written"
defaults write "$DOM" CodeReviewSavedPrompts -data "$(printf 'not json' | xxd -p)"
err=$(catalog --apply 2>&1 >/dev/null); rc=$?
[[ $rc -eq 1 && $err == *"is not the JSON list iTerm2 writes"* ]] && ok "stored bytes that are not JSON: refused" || bad "not JSON (rc=$rc): $err"
defaults write "$DOM" CodeReviewSavedPrompts -data "$(printf '{"name":"not a list"}' | xxd -p | tr -d '\n')"
err=$(catalog --apply 2>&1 >/dev/null); rc=$?
[[ $rc -eq 1 && $err == *"is not a list of prompts"* ]] && ok "stored JSON that is not a list: refused" || bad "not a list (rc=$rc): $err"
err=$("$FX/.agents/iterm/bin/prompt-catalog" --frobnicate --domain "$DOM" 2>&1 >/dev/null); rc=$?
[[ $rc -eq 2 && $err == *"prompt-catalog --apply"* ]] && ok "unknown argument: usage" || bad "unknown argument (rc=$rc)"

((fails == 0)) && echo "prompt-catalog tests passed" || { echo "$fails prompt-catalog tests failed" >&2; exit 1; }
