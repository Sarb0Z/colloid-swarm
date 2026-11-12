#!/usr/bin/env bash
# Firing tests for the owed-work flags (hooks/lib/owed.py), the suite runner
# (suite.sh) and the suite/CI reconciliation (lint-suite.py).
#
# Seams under test:
#   owed.py over a fixture repository with edit-record and commit-record files
#     and review records: catches each flag's transitions (reviewed, changed
#     since review, unreviewed; suite stale and passed; clean-up present and
#     gone); misses the real hook's attribution of shell-written files.
#   suite.sh's pass record: catches a stale pass read as current; misses a
#     suite that passes vacuously.
#   suite.sh's copy of the checkout: catches a check that writes relative to
#     its script or CLAUDE_PROJECT_DIR; misses an absolute path to the checkout.
#   suite.sh's temporary home: catches a write under `~`; misses a lookup that
#     skips HOME.
#   suite.sh's settings check: catches a check that rewrites the checkout's
#     core.* or extensions.* settings; misses every other absolute write.
#   suite.sh's check of the copy's tree: catches a check that writes a tracked
#     or untracked unignored file; misses one that writes only ignored files.
#   lint-suite.py against a fixture ci.yml and the real one: catches a check
#     in one list and not the other; misses a CI step whose failure is ignored.
#   lint-suite.py's test walk and reach over a fixture git repository: catches
#     a test file no listed check names on a non-comment line, at any depth,
#     and a stale allowlist entry; misses a test whose name appears in a
#     reached file but is never run (a string, an echo, a branch not taken).
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

fx="$scratch/fx"
key=4242
session=sess-owed
mkdir -p "$fx/.agents/hooks/lib" "$fx/docs/reviews"
cp "$repo"/.agents/hooks/lib/*.py "$fx/.agents/hooks/lib/"
cp "$repo/.agents/suite.sh" "$fx/.agents/suite.sh"
cat > "$fx/.agents/policy.json" <<'JSON'
{"owed": {"critical_paths": ["AGENTS.md", ".agents/hooks/**"], "suite": "bash .agents/fake-suite.sh"}}
JSON
printf '#!/usr/bin/env bash\n[[ -f "$(dirname "$0")/../suite-should-pass" ]]\n' > "$fx/.agents/fake-suite.sh"
touch "$fx/suite-should-pass"
printf '# contract\n' > "$fx/AGENTS.md"
printf 'x\n' > "$fx/app.txt"
printf '.agents/.readout/\n.agents/.wrap-*\n.agents/.teardown-pending-*\n.agents/.sources-ledger\n*.ign\n' > "$fx/.gitignore"
g() { git -C "$fx" -c user.name=t -c user.email=t@t "$@"; }
g init -q -b main
g add -A && g commit -qm base
base="$(g rev-parse HEAD)"

owed() { python3 "$fx/.agents/hooks/lib/owed.py" "$@" --repo "$fx"; }
show() { owed show --session "$session" --key "$key"; }
strip() { show | sed -n 1p; }
note() { show | tail -n +2; }
commit_as_session() {  # <message>: commit everything and record it as the session's
  g add -A && g commit -qm "$1"
  g rev-parse HEAD >> "$fx/.agents/.wrap-commits-$key"
}
edit_record() { printf '1\t%s\n' "$1" >> "$fx/.agents/.wrap-edits-$key"; }

# ── nothing owed ────────────────────────────────────────────────────────────
[[ -z "$(strip)" ]] || fail "a fresh session owes nothing: $(strip)"
owed write --session "$session" --key "$key"
[[ -f "$fx/.agents/.readout/owed--$session.json" ]] || fail "write must store owed--<session>.json"
[[ -z "$(python3 "$fx/.agents/hooks/lib/readout.py" strip "$fx" "$session")" ]] || fail "an empty owed strip must show nothing"
ok "a session with no records owes nothing and its readout is empty"

# ── review ──────────────────────────────────────────────────────────────────
printf 'other session\n' >> "$fx/AGENTS.md"
g add -A && g commit -qm "another session's critical edit"
[[ -z "$(strip)" ]] || fail "another session's commit raised a flag: $(strip)"
ok "history and other sessions' commits raise no flag"

printf 'app change\n' >> "$fx/app.txt"
commit_as_session "non-critical"
[[ "$(strip)" != *review* ]] || fail "a non-critical file raised review: $(strip)"
ok "a committed file off the critical list raises no review flag"

mkdir -p "$fx/.agents/hooks/policy"
printf 'one\n' > "$fx/.agents/hooks/policy/h.sh"
printf 'session line\n' >> "$fx/AGENTS.md"
commit_as_session "critical work"
[[ "$(strip)" == "owed: review 2"* ]] || fail "two unreviewed critical files: $(strip)"
note | grep -q "AGENTS.md (unreviewed)" || fail "the note must name the file: $(note)"
ok "an unreviewed critical-path file raises review and is named"

line="$(owed review-line "$base..HEAD")"
[[ "$line" == *"unreviewed: "*"AGENTS.md"* && "$line" == *".agents/hooks/policy/h.sh"* ]] || fail "review-line: $line"
ok "review-line names the unreviewed critical files a range carries"

reviewed_tip="$(g rev-parse HEAD)"
printf '# Review\nCovers: %s..%s\n' "$base" "$reviewed_tip" > "$fx/docs/reviews/2026-11-12-round.md"
g add -A && g commit -qm "review record"
[[ "$(strip)" != *review* ]] || fail "a covering record must clear review: $(strip)"
[[ -z "$(owed review-line "$base..$reviewed_tip")" ]] || fail "review-line must be empty once covered"
ok "a record covering the content clears review and the push line"

printf 'fixup\n' >> "$fx/AGENTS.md"
commit_as_session "fixup folded in"
[[ "$(strip)" == "owed: review 1"* ]] || fail "a fix after review: $(strip)"
note | grep -q "AGENTS.md (changed since review)" || fail "state must read changed since review: $(note)"
ok "content that moved after review shows changed since review"

new_tip="$(g rev-parse HEAD)"
printf '# Review\nCovers: %s..%s\n' "$base" "$new_tip" > "$fx/docs/reviews/2026-11-12-round.md"
[[ "$(strip)" != *review* ]] || fail "moving the record's tip must clear review: $(strip)"
ok "moving the record's tip clears changed since review"

printf '# Review\nCovers: %s..deadbeefdeadbeef\n' "$base" > "$fx/docs/reviews/2026-11-12-round.md"
[[ "$(strip)" == "owed: review"* ]] || fail "an unresolvable tip covers nothing: $(strip)"
note | grep -q "record git cannot resolve: docs/reviews/2026-11-12-round.md" || fail "the record must be named: $(note)"
ok "a record whose tip git cannot resolve covers nothing and is named"
printf '# Review\nCovers: %s..%s\n' "$base" "$new_tip" > "$fx/docs/reviews/2026-11-12-round.md"

# A record covers a file only when its range touched the file: this range
# touches app.txt alone, so the hook committed before it stays unreviewed.
printf 'two\n' > "$fx/.agents/hooks/policy/h2.sh"
commit_as_session "second hook"
hook_commit="$(g rev-parse HEAD)"
printf 'more\n' >> "$fx/app.txt"
commit_as_session "app only"
printf '# Review\nCovers: %s..%s\n' "$hook_commit" "$(g rev-parse HEAD)" > "$fx/docs/reviews/2026-11-12-app.md"
note | grep -q "h2.sh (unreviewed)" || fail "a record whose range never touched the hook must not cover it: $(note)"
ok "a record covers a file only when its range touched it"

printf '# Review\nCovers: %s..HEAD\n' "$base" > "$fx/docs/reviews/2026-11-12-app.md"
note | grep -q "h2.sh (unreviewed)" || fail "a HEAD tip must cover nothing: $(note)"
note | grep -q "record git cannot resolve: docs/reviews/2026-11-12-app.md (Covers: $base..HEAD)" || fail "a HEAD tip must be named: $(note)"
printf '# Review\nCovers: %s..%s\n' "$base" "${hook_commit:0:6}" > "$fx/docs/reviews/2026-11-12-app.md"
note | grep -q "h2.sh (unreviewed)" || fail "a six-digit tip must cover nothing: $(note)"
printf '# Review\nCovers: %s..%s\n' "${base:0:7}" "${hook_commit:0:7}" > "$fx/docs/reviews/2026-11-12-app.md"
note | grep -q "h2.sh (unreviewed)" && fail "a seven-digit hash is a record end: $(note)"
ok "a record end must be a hexadecimal object name of at least seven digits"
rm "$fx/docs/reviews/2026-11-12-app.md"

line="$(python3 - "$fx" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/.agents/hooks/lib")
import owed
print(owed.review_line(sys.argv[1], "HEAD", limit=2))
PY
)"
[[ "$line" == *"Only the newest 2 commits were read."* ]] || fail "a bounded read must say so: $line"
[[ "$(owed push-line)" == *"h2.sh"* ]] || fail "push-line on a repository with no remote: $(owed push-line)"
ok "a push with no remote reads a bounded history and says so"

# ── suite ───────────────────────────────────────────────────────────────────
rm -f "$fx/.agents/.wrap-commits-$key" "$fx/.agents/.wrap-edits-$key"
edit_record app.txt
[[ "$(strip)" == "owed: suite" ]] || fail "no recorded pass with a written path must raise suite: $(strip)"
ok "suite is owed while no pass is recorded"

( cd "$fx" && .agents/suite.sh ) || fail "suite.sh must pass on the fixture"
[[ -z "$(strip)" ]] || fail "a pass must clear suite: $(strip)"
ok "a passing suite.sh clears suite"

printf 'later\n' >> "$fx/app.txt"
[[ "$(strip)" == "owed: suite" ]] || fail "an edit after the pass must bring suite back: $(strip)"
note | grep -q "app.txt" || fail "the note must name the changed path: $(note)"
ok "the next edit returns suite"

printf 'unrelated\n' > "$fx/other.txt"
( cd "$fx" && .agents/suite.sh )
printf 'unrelated 2\n' >> "$fx/other.txt"
[[ -z "$(strip)" ]] || fail "a path the session did not write must not raise suite: $(strip)"
ok "a path this session did not write raises nothing"

rm -f "$fx/suite-should-pass"
printf 'again\n' >> "$fx/app.txt"
if ( cd "$fx" && .agents/suite.sh ) >/dev/null 2>&1; then fail "suite.sh must fail when the suite fails"; fi
[[ "$(strip)" == "owed: suite" ]] || fail "a failing suite must not record a pass: $(strip)"
touch "$fx/suite-should-pass"
( cd "$fx" && .agents/suite.sh )
ok "a failing suite records no pass"

# A Stop reads the written paths only: it writes no objects, and a path git
# ignores is not owed to the suite.
objects() { g count-objects -v | awk '/^count:/ {print $2}'; }
printf 'after pass\n' >> "$fx/app.txt"
printf 'x\n' > "$fx/scratch.ign"
edit_record scratch.ign
before="$(objects)"
[[ "$(strip)" == "owed: suite" ]] || fail "an edit after the pass, with an ignored path written: $(strip)"
[[ "$(objects)" == "$before" ]] || fail "a Stop wrote objects: $before -> $(objects)"
note | grep -q "scratch.ign" && fail "an ignored path must not be owed to the suite: $(note)"
( cd "$fx" && .agents/suite.sh )
ok "a Stop hashes the written paths without writing objects and skips ignored ones"

# ── suite.sh runs the checks in a copy under a temporary home ───────────────
# Each row swaps the fixture's suite for a probe and puts the passing one back.
cp "$fx/.agents/fake-suite.sh" "$scratch/fake-suite.pass"
copy_of() { sed -n 's/^suite.sh: checks run in //p' <<<"$1"; }

probe="suite-probe-$$.ign"
real_home="$HOME"
cat > "$fx/.agents/fake-suite.sh" <<SH
#!/usr/bin/env bash
printf 'x\n' > .agents/.sources-ledger
printf 'x\n' > "\$HOME/$probe"
printf 'x\n' > "\$CLAUDE_PROJECT_DIR/$probe"
printf '%s\n' "\$(pwd -P)" "\$HOME" "\$CLAUDE_PROJECT_DIR" > "$scratch/where"
SH
out="$(cd "$fx" && .agents/suite.sh 2>&1)" || fail "suite.sh with the probe suite: $out"
escaped=""
for f in "$fx/.agents/.sources-ledger" "$fx/$probe" "$real_home/$probe"; do
  if [[ -e "$f" ]]; then escaped+=" $f"; rm -f "$f"; fi
done
[[ -z "$escaped" ]] || fail "probes written outside the copy and the temporary home:$escaped"
copy="$(copy_of "$out")"
{ read -r cwd; read -r home; read -r project; } < "$scratch/where"
[[ -n "$copy" && "$copy" != "$(cd "$fx" && pwd -P)" ]] || fail "suite.sh must print a copy's path: $out"
[[ "$cwd" == "$copy" && "$project" == "$copy" ]] || fail "the checks ran in $cwd with CLAUDE_PROJECT_DIR $project, not the copy $copy"
[[ "$home" != "$real_home" && "$(dirname "$home")" == "$(dirname "$copy")" ]] || fail "HOME $home is not a temporary home beside the copy $copy"
[[ ! -e "$(dirname "$copy")" ]] || fail "the scratch folder $(dirname "$copy") outlived the run"
ok "suite.sh runs the checks in a copy under a temporary home, and nothing they write reaches the checkout or the real home"
cp "$scratch/fake-suite.pass" "$fx/.agents/fake-suite.sh"

printf 'gone\n' > "$fx/gone.txt"
g add -- gone.txt && g commit -qm "a file to delete"
rm "$fx/gone.txt"
printf 'untracked\n' > "$fx/untracked.txt"
printf 'staged\n' > "$fx/staged.txt" && g add -- staged.txt
ln -s app.txt "$fx/link"
printf 'ignored\n' > "$fx/x.ign"
cat > "$fx/.agents/fake-suite.sh" <<SH
#!/usr/bin/env bash
cp app.txt "$scratch/copy-app.txt"
{
  [[ -f untracked.txt ]] && echo untracked
  [[ -e gone.txt ]] || echo deleted
  [[ -L link ]] && echo "link -> \$(readlink link)"
  [[ -f staged.txt ]] && echo staged
  [[ -e x.ign ]] || echo "no ignored file"
} > "$scratch/copy-files"
git status --porcelain > "$scratch/copy-status"
git remote > "$scratch/copy-remote"
SH
out="$(cd "$fx" && .agents/suite.sh 2>&1)" || fail "suite.sh with the copy probe: $out"
cmp -s "$fx/app.txt" "$scratch/copy-app.txt" || fail "the copy must carry the uncommitted edit of app.txt"
[[ "$(cat "$scratch/copy-files")" == $'untracked\ndeleted\nlink -> app.txt\nstaged\nno ignored file' ]] || fail "the copy's files: $(cat "$scratch/copy-files")"
[[ "$(g status --porcelain)" == "$(cat "$scratch/copy-status")" ]] || fail "git status in the copy: $(cat "$scratch/copy-status") against the fixture's $(g status --porcelain)"
[[ "$(cat "$scratch/copy-status")" == *"A  staged.txt"* && "$(cat "$scratch/copy-status")" == *" D gone.txt"* ]] || fail "the copy's index must be the fixture's: $(cat "$scratch/copy-status")"
[[ ! -s "$scratch/copy-remote" ]] || fail "the copy must have no remote: $(cat "$scratch/copy-remote")"
ok "the copy carries the uncommitted edit, untracked file, deletion, symlink and index, no ignored file, and no remote"
g rm -q --cached -- staged.txt
rm "$fx/untracked.txt" "$fx/staged.txt" "$fx/link" "$fx/x.ign"
g checkout -q -- gone.txt
cp "$scratch/fake-suite.pass" "$fx/.agents/fake-suite.sh"

# Every way a git setting reaches a check from outside the temporary home
# carries a credential helper here, and the global ones a second identity.
mkdir -p "$scratch/xdg/git"
printf '[credential]\n\thelper = from-system\n' > "$scratch/system.gitconfig"
printf '[credential]\n\thelper = from-global\n[user]\n\temail = global@example.invalid\n' > "$scratch/global.gitconfig"
printf '[credential]\n\thelper = from-xdg\n[user]\n\temail = xdg@example.invalid\n' > "$scratch/xdg/git/config"
cat > "$fx/.agents/fake-suite.sh" <<SH
#!/usr/bin/env bash
{
  git config user.email
  printf 'helper=%s\n' "\$(git config --get-all credential.helper)"
  printf 'GH_TOKEN=%s GITHUB_TOKEN=%s\n' "\${GH_TOKEN-unset}" "\${GITHUB_TOKEN-unset}"
} > "$scratch/identity"
SH
out="$(cd "$fx" && GIT_CONFIG_SYSTEM="$scratch/system.gitconfig" GIT_CONFIG_GLOBAL="$scratch/global.gitconfig" \
  XDG_CONFIG_HOME="$scratch/xdg" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=from-env \
  GH_TOKEN=leak GITHUB_TOKEN=leak .agents/suite.sh 2>&1)" || fail "suite.sh with the identity probe: $out"
[[ "$(cat "$scratch/identity")" == $'suite@colloid.invalid\nhelper=\nGH_TOKEN=unset GITHUB_TOKEN=unset' ]] || fail "a check's git identity, credential helper and tokens: $(cat "$scratch/identity")"
ok "a check sees the suite identity, no credential helper and no GitHub token"
cp "$scratch/fake-suite.pass" "$fx/.agents/fake-suite.sh"

pass="$fx/.agents/.readout/suite-pass"
rm -f "$pass"
printf '#!/usr/bin/env bash\ngit -C "%s" config core.bare true\n' "$fx" > "$fx/.agents/fake-suite.sh"
status=0; out="$(cd "$fx" && .agents/suite.sh 2>&1)" || status=$?
g config --unset core.bare
[[ "$status" == 1 && "$out" == *"core.bare"* ]] || fail "a check that sets the checkout's core.bare must fail the run and name it (exit $status): $out"
[[ ! -e "$pass" ]] || fail "a run that changed core.bare recorded a pass"
printf '#!/usr/bin/env bash\ngit -C "%s" config branch.main.vscode-merge-base origin/main\n' "$fx" > "$fx/.agents/fake-suite.sh"
out="$(cd "$fx" && .agents/suite.sh 2>&1)" || fail "a branch setting written during the run must not fail it: $out"
g config --unset branch.main.vscode-merge-base
[[ -s "$pass" ]] || fail "a run that changed only a branch setting must record a pass"
ok "a check that changes the checkout's core or extensions settings fails the run and records no pass; a branch setting does not"

rm -f "$pass"
printf '#!/usr/bin/env bash\nprintf "changed\\n" >> app.txt\nprintf "x\\n" > made-in-copy.txt\n' > "$fx/.agents/fake-suite.sh"
status=0; out="$(cd "$fx" && .agents/suite.sh 2>&1)" || status=$?
[[ "$status" == 1 && "$out" == *"app.txt"* && "$out" == *"made-in-copy.txt"* ]] || fail "a check that writes the copy's files must fail the run and name them (exit $status): $out"
[[ ! -e "$pass" && ! -e "$fx/made-in-copy.txt" ]] || fail "a run that changed the copy recorded a pass or wrote the checkout"
ok "a check that writes a tracked or untracked file of the copy fails the run, names the files and records no pass"

# A suite whose check leaves a child running, started as its own job so it
# takes an interrupt the way a terminal sends one.
printf '#!/usr/bin/env bash\nsleep 300 &\necho "$!" > "%s/child"\nwait\n' "$scratch" > "$fx/.agents/fake-suite.sh"
start_suite() {  # <log>: start suite.sh in the background, wait for its check's child
  rm -f "$scratch/child"
  set -m; (cd "$fx" && exec .agents/suite.sh) >"$1" 2>&1 & suite_pid=$!; set +m
  for _ in $(seq 100); do [[ -s "$scratch/child" ]] && break; sleep 0.1; done
  [[ -s "$scratch/child" ]] || fail "the check never started: $(cat "$1")"
  child="$(cat "$scratch/child")"
}
ended() {  # <pid>: true once the process is gone, polling for up to 10 s
  for _ in $(seq 100); do ps -p "$1" >/dev/null || return 0; sleep 0.1; done
  return 1
}
stop_leftovers() {  # what a run that failed this row left running
  kill -KILL "$suite_pid" 2>/dev/null || true
  local group; group="$(ps -o pgid= -p "$child" | tr -d ' ')" || true
  [[ -n "$group" ]] && kill -KILL -- "-$group" 2>/dev/null || true
}
start_suite "$scratch/int.log"
kill -INT "$suite_pid"
if ! ended "$suite_pid" || ! ended "$child"; then stop_leftovers; fail "an interrupt must end suite.sh and its check's child: $(cat "$scratch/int.log")"; fi
wait "$suite_pid" 2>/dev/null && fail "an interrupted run must not exit 0"
left="$(dirname "$(copy_of "$(cat "$scratch/int.log")")")"
[[ "$left" != . && ! -e "$left" ]] || fail "an interrupted run left its scratch folder $left"
ok "an interrupt stops the checks' process group and removes the scratch folder"

start_suite "$scratch/kill.log"
kill -KILL "$suite_pid"; wait "$suite_pid" 2>/dev/null || true
stop_leftovers
left="$(dirname "$(copy_of "$(cat "$scratch/kill.log")")")"
[[ "$left" != . && -d "$left" ]] || fail "a killed run must leave its scratch folder for this row to sweep: $left"
cp "$scratch/fake-suite.pass" "$fx/.agents/fake-suite.sh"
( cd "$fx" && .agents/suite.sh ) >/dev/null || fail "suite.sh after a killed run"
[[ ! -e "$left" ]] || { rm -rf "$left"; fail "the next run must sweep the scratch folder a killed run left: $left"; }
ok "the next run sweeps a scratch folder a killed run left"

# ── report ──────────────────────────────────────────────────────────────────
owed raise report --session "$session" --key "$key"
[[ "$(strip)" == "owed: report" ]] || fail "raised report: $(strip)"
owed clear report 2>"$scratch/err" && fail "clear with no session and no --all must refuse"
grep -q -- "--all" "$scratch/err" || fail "the refusal must name --all: $(cat "$scratch/err")"
[[ "$(strip)" == "owed: report" ]] || fail "a refused clear must leave the flag: $(strip)"
# A host that sets no session id expands "$CLAUDE_CODE_SESSION_ID" to nothing.
owed clear report --session "" 2>/dev/null && fail "clear with an empty session must refuse"
[[ "$(strip)" == "owed: report" ]] || fail "an empty session must leave the flag: $(strip)"
owed raise report --session other --key 9999
owed clear report --session "$session" --key "$key"
[[ -z "$(strip)" && -f "$fx/.agents/.readout/owed-report--9999" ]] || fail "clear with a session must clear only that session's"
owed clear report --all
[[ ! -e "$fx/.agents/.readout/owed-report--9999" ]] || fail "clear --all must clear every session's report"
# session-wrap.sh raises under the shell's cksum of the session id; a
# playbook clears with the session id alone.
owed raise report --session sess-b --key "$(printf '%s' sess-b | cksum | tr -d ' ')"
owed clear report --session sess-b
[[ -z "$(ls "$fx/.agents/.readout" | grep '^owed-report--')" ]] || fail "clear --session must find the flag session-wrap raised: $(ls "$fx/.agents/.readout")"
ok "report is raised; clear takes one session or --all, and refuses neither or an empty session"

for tier in diff large investigation; do
  owed raise report --session "$session" --key "$key" --tier "$tier"
  [[ "$(strip)" == "owed: report" ]] || fail "report with tier $tier: $(strip)"
  case "$tier" in
    diff) want=".agents/playbooks/diff-wrap.md" ;;
    large) want="hostile-review.md" ;;
    investigation) want=".agents/playbooks/report-investigation.md" ;;
  esac
  note | grep -q "$want" || fail "the $tier report note must name $want: $(note)"
  [[ "$tier" == diff ]] && { note | grep -q "hostile-review.md" && fail "the diff tier names no hostile review: $(note)"; }
  owed clear report --session "$session" --key "$key"
done
ok "the report note names the tier crossed and the playbooks to run"

# Pairing mode (hooks.learning_report.enabled) raises `learning` beside `report`.
owed raise report --session "$session" --key "$key" --tier diff
[[ "$(strip)" == "owed: report" ]] || fail "pairing off must raise only report: $(strip)"
owed clear report --session "$session" --key "$key"
printf '{"hooks":{"learning_report":{"enabled":true}}}\n' > "$fx/.agents/config.json"
owed raise report --session "$session" --key "$key" --tier diff
[[ "$(strip)" == "owed: report · learning" ]] || fail "pairing on must raise learning beside report: $(strip)"
note | grep -q ".agents/playbooks/learning-report.md" || fail "the learning note must name its playbook: $(note)"
owed clear learning --session "$session" --key "$key"
[[ "$(strip)" == "owed: report" ]] || fail "clear learning must clear only learning: $(strip)"
owed clear report --session "$session" --key "$key"
owed raise report --session "$session" --key "$key" --tier investigation
[[ "$(strip)" == "owed: report" ]] || fail "an investigation report carries no learning report: $(strip)"
owed clear report --session "$session" --key "$key"
rm "$fx/.agents/config.json"
ok "learning is raised beside report only with pairing on, and clear learning clears it"

# ── clean-up ────────────────────────────────────────────────────────────────
printf 'docker\twaiting\t-\tpostgres container\n#blocked\n' > "$fx/.agents/.teardown-pending-$session"
printf 'scratch\n' > "$fx/new-file.txt"
edit_record new-file.txt
[[ "$(strip)" == "owed: suite · cleanup 2" ]] || fail "ledger entry and untracked file: $(strip)"
note | grep -q "docker: postgres container" || fail "ledger resource must be named: $(note)"
note | grep -q "untracked: new-file.txt" || fail "untracked file must be named: $(note)"
rm "$fx/.agents/.teardown-pending-$session" "$fx/new-file.txt"
[[ -z "$(strip)" ]] || fail "clean-up must clear itself: $(strip)"
ok "clean-up counts ledger resources and untracked files, and clears when they are gone"

# colloid-only
# ── the carrier's critical paths ────────────────────────────────────────────
# Each pattern names tracked files, and none names a symlink: an edit lands in
# the canonical target, so a pattern on a link never fires.
python3 - "$repo" <<'PY' || fail "owed.critical_paths in policy.json"
import json, subprocess, sys
repo = sys.argv[1]
sys.path.insert(0, repo + "/.agents/hooks/lib")
import owed
tracked = {}
for row in subprocess.run(["git", "-C", repo, "ls-files", "-s"], capture_output=True, text=True, check=True).stdout.splitlines():
    meta, _, path = row.partition("\t")
    tracked[path] = meta.split()[0]
bad = []
for pattern in json.load(open(repo + "/.agents/policy.json"))["owed"]["critical_paths"]:
    rx = owed.glob_regex(pattern)
    hits = [p for p in tracked if rx.match(p)]
    if not hits:
        bad.append(f"{pattern} matches no tracked file")
    bad += [f"{pattern} matches the symlink {p}" for p in hits if tracked[p] == "120000"]
if bad:
    print("\n".join(bad), file=sys.stderr)
    sys.exit(1)
PY
ok "every critical-path pattern names tracked files and no symlink"

# ── check-all.sh: a listed script that is missing ───────────────────────────
mkdir -p "$scratch/car/.agents"
awk '/^LIST$/ {skip = 0} !skip {print} /cat <<.LIST.$/ {skip = 1; print ".agents/missing-check.sh"}' \
  "$repo/.agents/check-all.sh" > "$scratch/car/.agents/check-all.sh"
chmod +x "$scratch/car/.agents/check-all.sh"
out="$("$scratch/car/.agents/check-all.sh" 2>&1)" || fail "a satellite must skip a missing script: $out"
[[ "$out" == *"(absent here, skipped)"* ]] || fail "a satellite's skip must be named: $out"
touch "$scratch/car/.agents/export-scaffold.py"
out="$("$scratch/car/.agents/check-all.sh" 2>&1)" && fail "the carrier must fail on a missing script: $out"
[[ "$out" == *"(listed but missing)"* ]] || fail "the carrier's failure must name the script: $out"
ok "check-all.sh fails a missing script in the carrier"

# ── lint-suite ──────────────────────────────────────────────────────────────
lint() { python3 "$repo/.agents/lint-suite.py" --script "$1" --ci "$2" 2>&1; }
cat > "$scratch/check-all.sh" <<'SH'
checks() {
  cat <<'LIST'
python3 .agents/a.py
.agents/test-b.sh
python3 .agents/port-public.py check
python3 demo/check-inventory.py
LIST
}
SH
cat > "$scratch/ci.yml" <<'YML'
jobs:
  x:
    steps:
      - name: A
        run: python3 .agents/a.py
      - name: B
        run: .agents/test-b.sh | tee b.log
      - name: P
        run: |
          pip install thing
          python3 .agents/port-public.py check
      - name: Clean
        run: .agents/check-clean-tree.sh
      - name: Embed
        run: python3 demo/embed-src.py
      - name: Inventory
        run: python3 demo/check-inventory.py
YML
out="$(lint "$scratch/check-all.sh" "$scratch/ci.yml")" || fail "agreeing lists must pass: $out"
ok "lint-suite passes when the lists agree, with the CI-only steps named"

sed -i.bak '/test-b.sh/d' "$scratch/ci.yml"
out="$(lint "$scratch/check-all.sh" "$scratch/ci.yml")" && fail "a check missing from CI must fail"
[[ "$out" == *".agents/test-b.sh: in check-all.sh but not run by ci.yml"* ]] || fail "wrong message: $out"
ok "lint-suite fails a check the script has and CI lacks"

printf '      - name: Extra\n        run: .agents/test-extra.sh\n' >> "$scratch/ci.yml"
printf '      - name: B\n        run: .agents/test-b.sh\n' >> "$scratch/ci.yml"
out="$(lint "$scratch/check-all.sh" "$scratch/ci.yml")" && fail "a check missing from the script must fail"
[[ "$out" == *".agents/test-extra.sh: run by ci.yml but not in check-all.sh"* ]] || fail "wrong message: $out"
ok "lint-suite fails a check CI has and the script lacks"

python3 "$repo/.agents/lint-suite.py" >/dev/null || fail "the real script and ci.yml disagree"
ok "the real check-all.sh and ci.yml agree"

# Every test file must be listed or called by a listed check. The fixture tree
# is a git repository so the walk sees tracked, untracked and ignored files.
tt="$scratch/tt"
mkdir -p "$tt/.agents/node_modules/p" "$tt/.agents/worktrees/w" "$tt/.agents/mcp-servers/m" "$tt/.agents/sub"
printf '.agents/ignored/\n' > "$tt/.gitignore"
mkdir -p "$tt/.agents/ignored"
printf 'checks() {\n  cat <<'"'"'LIST'"'"'\n.agents/test-b.sh\nLIST\n}\n' > "$tt/.agents/check-all.sh"
printf '#!/usr/bin/env bash\n.agents/sub/test-mid.sh\n' > "$tt/.agents/test-b.sh"
printf '#!/usr/bin/env bash\n.agents/test-leaf.py\n' > "$tt/.agents/sub/test-mid.sh"
printf 'x\n' > "$tt/.agents/test-leaf.py"
for f in .agents/node_modules/p/test-n.sh .agents/worktrees/w/test-w.sh .agents/mcp-servers/m/test-m.sh .agents/ignored/test-i.sh; do printf 'x\n' > "$tt/$f"; done
git -C "$tt" init -q -b main && git -C "$tt" add -A
treelint() { python3 "$repo/.agents/lint-suite.py" --script "$tt/.agents/check-all.sh" --ci "$scratch/ci.yml" --root "$tt" 2>&1; }
# the shared fixture ci.yml was edited above; give this check an agreeing one
printf 'jobs:\n  x:\n    steps:\n      - run: .agents/test-b.sh\n      - run: .agents/check-clean-tree.sh\n      - run: python3 demo/embed-src.py\n' > "$scratch/ci.yml"
out="$(treelint)" || fail "a listed test, tests called one and two levels down, and skipped folders must pass: $out"
[[ "$out" == *"3 test files reached"* ]] || fail "the reached count must be 3: $out"
ok "lint-suite reaches tests listed or called two levels down, and skips ignored and vendored folders"

printf 'x\n' > "$tt/.agents/test-x.sh"
out="$(treelint)" && fail "an untracked, unignored, unreached test must fail"
[[ "$out" == *".agents/test-x.sh: test file is neither listed in check-all.sh nor called by a listed check"* ]] || fail "wrong message: $out"
ok "lint-suite fails a test nobody lists or calls, even untracked"

printf '#!/usr/bin/env bash\n# .agents/test-x.sh\n' > "$tt/.agents/sub/test-mid.sh"
out="$(treelint)" && fail "a test named only in a comment must fail"
[[ "$out" == *"test-x.sh: test file is neither"* ]] || fail "wrong message: $out"
printf '#!/usr/bin/env bash\n.agents/test-leaf.py\n.agents/test-x.sh\n' > "$tt/.agents/sub/test-mid.sh"
out="$(treelint)" || fail "a test called on a non-comment line must pass: $out"
ok "lint-suite counts only non-comment lines as calls"

# the allowlist: a reason lets an unlisted test pass; a stale entry fails
allowlint() {  # <allowlist json> <lint args...>: the real module with UNLISTED_TESTS set, no source rewritten
  ALLOW="$1" python3 - "${@:2}" 2>&1 <<'PY'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("lint_suite", os.environ["LINT"])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.UNLISTED_TESTS.update(json.loads(os.environ["ALLOW"]))
sys.exit(mod.main(sys.argv[1:]))
PY
}
export LINT="$repo/.agents/lint-suite.py"
treeargs=(--script "$tt/.agents/check-all.sh" --ci "$scratch/ci.yml" --root "$tt")
printf '#!/usr/bin/env bash\n# nothing\n' > "$tt/.agents/sub/test-mid.sh"
out="$(allowlint '{".agents/test-x.sh": "r", ".agents/test-leaf.py": "r"}' "${treeargs[@]}")" || fail "allowlisted unlisted tests must pass: $out"
[[ "$out" == *"2 test files reached"* ]] || fail "the count is the reached tests, not every walked one: $out"
out="$(allowlint '{".agents/test-x.sh": "r", ".agents/test-gone.sh": "r"}' "${treeargs[@]}")" && fail "an entry for a missing test must fail"
[[ "$out" == *"UNLISTED_TESTS entry .agents/test-gone.sh no longer describes an unlisted test"* ]] || fail "gone entry unreported: $out"
printf '#!/usr/bin/env bash\n.agents/test-leaf.py\n' > "$tt/.agents/sub/test-mid.sh"
out="$(allowlint '{".agents/test-x.sh": "r", ".agents/test-leaf.py": "r"}' "${treeargs[@]}")" && fail "an entry for a reached test must fail"
[[ "$out" == *"UNLISTED_TESTS entry .agents/test-leaf.py no longer describes an unlisted test"* ]] || fail "reached entry unreported: $out"
[[ "$out" != *"test-x.sh"* ]] || fail "a valid entry must not be reported: $out"
ok "lint-suite lets an allowlisted test pass, counts only reached tests, and fails an entry that no longer describes an unlisted test"

# the lint is a listed check and its own allowlist names tests: that text is not a call
ttl="$scratch/ttl"
cp -R "$tt" "$ttl"
printf '"""the lint"""\nUNLISTED_TESTS = {".agents/test-x.sh": "r"}\n' > "$ttl/.agents/lint-suite.py"
printf 'checks() {\n  cat <<'"'"'LIST'"'"'\n.agents/test-b.sh\npython3 .agents/lint-suite.py\nLIST\n}\n' > "$ttl/.agents/check-all.sh"
printf '#!/usr/bin/env bash\n.agents/test-leaf.py\n' > "$ttl/.agents/sub/test-mid.sh"
git -C "$ttl" add -A
printf 'jobs:\n  x:\n    steps:\n      - run: .agents/test-b.sh\n      - run: python3 .agents/lint-suite.py\n      - run: .agents/check-clean-tree.sh\n      - run: python3 demo/embed-src.py\n' > "$scratch/ci-lint.yml"
out="$(allowlint '{".agents/test-x.sh": "r"}' --script "$ttl/.agents/check-all.sh" --ci "$scratch/ci-lint.yml" --root "$ttl")" || fail "the lint's own allowlist line must not read as a call to the test it names: $out"
ok "lint-suite does not read its own file as a caller"

# a root git cannot read fails with git's own message, not a traceback
mkdir "$scratch/nogit"
out="$(python3 "$repo/.agents/lint-suite.py" --script "$tt/.agents/check-all.sh" --ci "$scratch/ci.yml" --root "$scratch/nogit" 2>&1)" && fail "a root that is no git repository must fail"
[[ "$out" == "lint-suite: $scratch/nogit: "* && "$out" != *Traceback* ]] || fail "wrong message: $out"
ok "lint-suite reports a root git cannot read in one line"

# naming the default script explicitly keeps the tree check on the real tree
out="$(python3 "$repo/.agents/lint-suite.py" --script "$repo/.agents/check-all.sh" 2>&1)" || fail "the real tree must pass: $out"
[[ "$out" == *"test files reached"* ]] || fail "naming the default script must keep the tree check on: $out"
ok "lint-suite checks the real tree when the default script is named explicitly"

# /colloid-only
