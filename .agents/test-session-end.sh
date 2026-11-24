#!/usr/bin/env bash
# Firing tests for worktree teardown: teardown-gate.sh records each worktree a
# tool call creates with its source branch, lists it as due after a push;
# session-end.sh marks the session ended; the hourly check removes a dead
# session's worktree once merged into its source branch and flags every other
# one with the operator's three answers, leaving locked, occupied, nested and
# other sessions' worktrees alone.
set -euo pipefail
# A caller such as `git rebase -x` exports these; the git calls below must
# reach only their own temporary repositories.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(cd "$(mktemp -d)" && pwd -P)"
sleepers=()
cleanup() {
  for pid in "${sleepers[@]+"${sleepers[@]}"}"; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$scratch"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
# The recording session's process is this shell. Under `docker exec` every
# ancestor is a shell, which the records pass over, so none would be found.
export CLAUDE_PID=$$
cd "$scratch"

# A repository carrying the scaffold pieces the hooks and the controller run.
R="$scratch/repo"
mkdir -p "$R/.agents/hooks" "$R/.agents/claude" "$R/src"
cp -R "$repo/.agents/hooks/lib" "$repo/.agents/hooks/policy" "$R/.agents/hooks/"
cp "$repo"/.agents/workloop*.py "$repo/.agents/provision.sh" "$R/.agents/"
mkdir -p "$R/.agents/skills/workloop" && cp "$repo/.agents/skills/workloop/working-practice.md" "$R/.agents/skills/workloop/"
cp "$repo/.agents/claude/adapter.sh" "$repo/.agents/claude/normalize-hook.py" "$R/.agents/claude/"
mkdir -p "$R/.claude/hooks" && ln -s ../../.agents/claude/adapter.sh "$R/.claude/hooks/adapter.sh"
printf '.agents/\n.claude/\n*.log\nnode_modules/\n__pycache__/\n' > "$R/.gitignore"
printf 'one\n' > "$R/src/app.txt"
git -C "$R" init -q -b main
git -C "$R" add .gitignore src
git -C "$R" commit -qm init
records="$R/.agents/worktrees/.records"
O="$scratch/other"
git init -q -b main "$O" && git -C "$O" commit -q --allow-empty -m init

calls=0
json() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
gate() {  # <payload json> through the Claude adapter, from an unrelated folder -> out, rc, err
  set +e
  out="$(printf '%s' "$1" | CLAUDE_PROJECT_DIR="$R" bash "$R/.claude/hooks/adapter.sh" teardown-gate.sh 2>"$scratch/err")"
  rc=$?
  set -e
  err="$(<"$scratch/err")"
}
tool() {  # <event> <cwd> <tool> <tool_input json> [session]
  gate "$(printf '{"hook_event_name":"%s","cwd":"%s","session_id":"%s","tool_name":"%s","tool_input":%s,"tool_use_id":"t%s"}' \
    "$1" "$2" "${5:-s1}" "$3" "$4" "$calls")"
}
bash_call() {  # <cwd> <command> [session]: PreToolUse, the command, PostToolUse
  calls=$((calls + 1))
  local input; input="{\"command\":$(json "$2")}"
  tool PreToolUse "$1" Bash "$input" "${3:-s1}"
  (cd "$1" && eval "$2") >/dev/null 2>&1 || true
  tool PostToolUse "$1" Bash "$input" "${3:-s1}"
}
stop() {  # [agent_id]
  gate "$(printf '{"hook_event_name":"%s","cwd":"%s","session_id":"s1","stop_hook_active":false,"agent_id":"%s"}' \
    "$([[ -n "${1:-}" ]] && echo SubagentStop || echo Stop)" "$R" "${1:-}")"
}
end_session() {  # <reason> [cwd]: the SessionEnd registration, payload first
  report="$(cd "${2:-$scratch}" && printf '{"hook_event_name":"SessionEnd","reason":"%s","session_id":"s1","cwd":"%s"}' "$1" "$R" \
    | CLAUDE_CODE_SESSION_ID=not-this-one CLAUDE_PROJECT_DIR="$R" bash "$R/.claude/hooks/adapter.sh" session-end.sh 2>&1)"
}
recorded() { cat "$records"/*.jsonl 2>/dev/null | grep -c "\"path\": \"$1\"" || true; }
utc_start() {  # <pid>: its start as Claude Code writes it into a lock, in UTC
  python3 -c 'import sys,time; f="%a %b %d %H:%M:%S %Y"; print(time.strftime(f, time.gmtime(time.mktime(time.strptime(" ".join(sys.argv[1].split()), f)))))' \
    "$(ps -o lstart= -p "$1")"
}

# ── recorded when made, and only what the call made ─────────────────────────
bash_call "$R" 'git worktree add -q ../wt-clean -b clean'
[[ "$(recorded "$scratch/wt-clean")" == 1 ]] || fail "git worktree add was not recorded: $(cat "$records"/*.jsonl 2>&1)"
[[ "$out" == *"Made a worktree: $scratch/wt-clean"* ]] || fail "no reminder for the new worktree: $out"
bash_call "$R/src" 'cd .. && git worktree add -q ../wt-dirty -b dirty'
[[ "$(recorded "$scratch/wt-dirty")" == 1 ]] || fail "a worktree added after a cd was not recorded"
bash_call "$R" 'echo "git worktree add ../nothing"'
[[ "$(recorded "$scratch/nothing")" == 0 ]] || fail "an echo was recorded"
ok "git worktree add is recorded, with its path resolved where it ran"

git -C "$R" worktree add -q "$scratch/wt-operator" -b operator
bash_call "$R" 'git worktree add -q ../wt-operator -b again | tail -1'
[[ "$(recorded "$scratch/wt-operator")" == 0 ]] || fail "a failed add adopted the operator's worktree"
wl="python3 $R/.agents/workloop.py --state $R/.agents/.workloop-state.json"
$wl init t0 --objective o --acceptance a --repo "$R" --verify true >/dev/null
bash_call "$R" "$wl init t0 --objective o --acceptance a --repo $R --verify true | tail -1"
grep -q '"run": "t0"' "$records"/*.jsonl && fail "a failed init adopted another session's run"
git -C "$R" worktree add -q "$scratch/wt-nosnap" -b nosnap
calls=$((calls + 1))
tool PostToolUse "$R" Bash "{\"command\":$(json 'git worktree add -q ../wt-nosnap -b nosnap')}"
[[ "$(recorded "$scratch/wt-nosnap")" == 0 ]] || fail "a call with no snapshot recorded a worktree"
ok "only what the call created is recorded: a failed add or init adopts nothing"

calls=$((calls + 1))
tool PreToolUse "$R" EnterWorktree '{"name":"feat"}'
git -C "$R" worktree add -q "$R/.claude/worktrees/feat" -b worktree-feat
tool PostToolUse "$R/.claude/worktrees/feat" EnterWorktree '{"name":"feat"}'
[[ "$(recorded "$R/.claude/worktrees/feat")" == 1 ]] || fail "EnterWorktree was not recorded from the payload's cwd"
grep -q "\"path\": \"$R/.claude/worktrees/feat\", \"source\": \"main\"" "$records/s1.jsonl" || fail "EnterWorktree must record the branch checked out where it ran: $(cat "$records/s1.jsonl")"
grep -q "\"path\": \"$scratch/wt-clean\", \"source\": \"main\"" "$records/s1.jsonl" || fail "git worktree add without a start point must record the branch checked out where it ran"
git -C "$R" worktree add -q "$R/.claude/worktrees/agent-a1b2" -b worktree-agent-a1b2
gate "$(printf '{"hook_event_name":"SubagentStart","cwd":"%s","session_id":"s1","agent_id":"a1b2"}' "$R/.claude/worktrees/agent-a1b2")"
[[ "$(recorded "$R/.claude/worktrees/agent-a1b2")" == 1 ]] || fail "an isolated cell's worktree was not recorded"
gate "$(printf '{"hook_event_name":"SubagentStart","cwd":"%s","session_id":"s1"}' "$scratch/wt-operator")"
[[ "$(recorded "$scratch/wt-operator")" == 0 ]] || fail "a cell started in someone's worktree recorded it"
ok "EnterWorktree and an isolated cell's worktree are recorded from the payload's folder"

bash_call "$R" "$wl init t1 --objective o --acceptance a --repo $R --verify true"
bash_call "$R" "$wl add-lane t1 l1 --worker w --path src"
lane="$R/.agents/worktrees/t1/l1"
[[ -d "$lane" && "$(recorded "$lane")" == 1 ]] || fail "add-lane was not recorded"
grep -q '"run": "t1", .*"type": "run"' "$records"/*.jsonl || fail "the run was not recorded with its lead"
# t6 is a finished one-writer run: its lane worked in the checkout, and its composed
# test leaves a marker whenever it runs, so a session end that ran it would show.
# Its commit lands on main before t5 integrates, so t5's integration composes on
# main's current tip and no later commit moves the base under it.
mark6="$scratch/ran-t6"
worktrees_before="$(git -C "$R" worktree list --porcelain | grep '^worktree ')"
bash_call "$R" "$wl init t6 --objective o --acceptance a --repo $R --verify 'touch $mark6' --lane solo --worker w --path notes"
grep -q '"run": "t6", .*"type": "run"' "$records"/*.jsonl || fail "init --lane was not recorded with its lead"
[[ "$(git -C "$R" worktree list --porcelain | grep '^worktree ')" == "$worktrees_before" ]] || fail "init --lane made a worktree"
$wl claim t6 solo --agent cell6 >/dev/null
mkdir -p "$R/notes" && printf 'solo\n' > "$R/notes/solo.txt" && git -C "$R" add -- notes/solo.txt && git -C "$R" commit -qm solo
$wl submit t6 solo --evidence ok >/dev/null
$wl review t6 solo --reference src/app.txt#ok --result accept --tip "$(git -C "$R" rev-parse HEAD)" >/dev/null
$wl check t6 >/dev/null 2>&1 || true  # blocked by QA, still missing; the test ran
[[ -f "$mark6" && ! -e "$R/.agents/worktrees/t6/verify" ]] || fail "check did not run the one-writer run's composed test in a verify worktree removed after its pass"
$wl qa t6 --evidence ok >/dev/null
rm "$mark6"
$wl check t6 --recorded >/dev/null || fail "the one-writer fixture does not pass check --recorded: $($wl check t6 --recorded 2>&1)"
ok "a one-writer run is recorded with its lead; check runs its composed test in the checkout"
# t5 is finished, `check` passes; t1 stays unfinished, its lane never claimed.
bash_call "$R" "$wl init t5 --objective o --acceptance a --repo $R --verify true"
bash_call "$R" "$wl add-lane t5 l5 --worker w --path docs"
done5="$R/.agents/worktrees/t5/l5"
$wl claim t5 l5 --agent cell5 >/dev/null
mkdir -p "$done5/docs" && printf 'r\n' > "$done5/docs/r.md"
git -C "$done5" add docs && git -C "$done5" commit -qm l5
$wl submit t5 l5 --evidence ok >/dev/null
$wl review t5 l5 --reference docs/r.md#ok --result accept --tip "$(git -C "$done5" rev-parse HEAD)" >/dev/null
$wl qa t5 --evidence ok >/dev/null
$wl integrate t5 >/dev/null 2>&1 || fail "the finished run's fixture does not integrate: $($wl integrate t5 2>&1)"
$wl check t5 >/dev/null || fail "the finished run's fixture does not pass check: $($wl check t5 2>&1)"
bash_call "$R" "git -C $O worktree add -q $scratch/other-made -b made"
[[ "$(recorded "$scratch/other-made")" == 1 ]] || fail "a worktree made in another repository was not recorded"
ok "add-lane is recorded with its run, and a worktree made in another repository"

# ── due once a push follows; a cell's stop leaves the lead's worktrees ──────
stop; [[ "$rc" -eq 0 ]] || fail "a worktree before any push must not block: $err"
bash_call "$R" 'git push --dry-run origin main'
stop; [[ "$rc" -eq 0 ]] || fail "a dry-run push made worktrees due: $err"
calls=$((calls + 1)); tool PostToolUse "$R" Bash '{"command":"git push origin main"}'
stop cell-7
[[ "$rc" -eq 0 ]] || fail "a cell's stop must not answer for the lead's worktrees: $err"
grep -qx '#blocked' "$R/.agents/.teardown-pending-s1" && fail "a cell's stop must not spend the lead's block"
stop
[[ "$rc" -eq 2 && "$err" == *"git worktree remove $scratch/wt-clean"* && "$err" == *"workloop.py teardown t1"* ]] \
  || fail "a push must make the worktrees due, naming their removal: $err"
ok "a push makes recorded worktrees due for the lead; a cell's stop skips them"

# ── the end of the session ───────────────────────────────────────────────────
printf 'two\n' > "$scratch/wt-dirty/src/app.txt"
printf 'new\n' > "$scratch/wt-dirty/src/untracked.txt"
mkdir -p "$scratch/wt-dirty/node_modules/dep" "$scratch/wt-dirty/src/__pycache__"
printf 'noise\n' > "$scratch/wt-dirty/node_modules/dep/index.js"
printf 'noise\n' > "$scratch/wt-dirty/src/__pycache__/app.cpython-313.pyc"
bash_call "$R" 'git worktree add -q ../wt-keeplog -b keeplog'
printf 'secret\n' > "$scratch/wt-keeplog/run.log"
printf 'lane work\n' > "$lane/src/lane.txt"
printf 'done work\n' > "$done5/docs/extra.txt"
for name in locked claude-dead claude-live agent-dead agent-live busy here nested ignored-nested nm-nested skip bisect \
    build-holder build-repo mc-holder; do
  bash_call "$R" "git worktree add -q ../wt-$name -b $name"
done
git init -q "$scratch/wt-nm-nested/node_modules/vendored"
# Build output is no package folder: what lies under build/ keeps its holder.
printf 'build/\n' >> "$R/.git/info/exclude"
git -C "$R" worktree add -q "$scratch/wt-build-holder/build/inner" -b build-inner
printf 'inner work\n' > "$scratch/wt-build-holder/build/inner/work.txt"
git init -q "$scratch/wt-build-repo/build/vendored" && git -C "$scratch/wt-build-repo/build/vendored" commit -q --allow-empty -m unpushed
# A worktree inside node_modules that git records in another case, as `git
# worktree repair` with a mis-cased path leaves it.
mc_inner=""
if [[ -d "$scratch/WT-MC-HOLDER" ]]; then
  git -C "$R" worktree add -q "$scratch/wt-mc-holder/node_modules/inner" -b mc-inner
  printf '%s/.git\n' "$scratch/WT-MC-HOLDER/node_modules/inner" \
    > "$(git -C "$scratch/wt-mc-holder/node_modules/inner" rev-parse --absolute-git-dir)/gitdir"
  mc_inner="$scratch/wt-mc-holder/node_modules/inner/work.txt" && printf 'inner work\n' > "$mc_inner"
fi
git -C "$scratch/wt-skip" update-index --skip-worktree src/app.txt && printf 'hidden edit\n' > "$scratch/wt-skip/src/app.txt"
git -C "$scratch/wt-bisect" bisect start -q 2>/dev/null || git -C "$scratch/wt-bisect" bisect start >/dev/null
git -C "$R" worktree lock "$scratch/wt-locked" --reason "keep for review"
sleep 300 >/dev/null 2>&1 & gone=$!
gone_start="$(utc_start "$gone")"; kill "$gone"; wait "$gone" 2>/dev/null || true
git -C "$R" worktree lock "$scratch/wt-claude-dead" --reason "claude session claude-dead (pid $gone start $gone_start)"
sleep 300 >/dev/null 2>&1 & sleepers+=($!)
git -C "$R" worktree lock "$scratch/wt-claude-live" --reason "claude session claude-live (pid ${sleepers[0]} start $(utc_start "${sleepers[0]}"))"
git -C "$R" worktree lock "$scratch/wt-agent-dead" --reason "claude agent ag1 (pid $gone)"
git -C "$R" worktree lock "$scratch/wt-agent-live" --reason "claude agent ag2 (pid ${sleepers[0]})"
(cd "$scratch/wt-busy" && exec sleep 120) >/dev/null 2>&1 & sleepers+=($!)
git init -q "$scratch/wt-nested/vendor"
mkdir -p "$scratch/wt-ignored-nested/deps.log" && git init -q "$scratch/wt-ignored-nested/deps.log/inner"
printf 'inner work\n' > "$scratch/wt-ignored-nested/deps.log/inner/file.txt"
git -C "$O" worktree add -q "$scratch/other-wt" -b side
git -C "$R" worktree add -q "$scratch/wt-s2" -b s2
calls=$((calls + 1))
tool PreToolUse "$R" Bash "{\"command\":$(json 'git worktree add -q ../wt-s2b -b s2b')}" s2
git -C "$R" worktree add -q "$scratch/wt-s2b" -b s2b
tool PostToolUse "$R" Bash "{\"command\":$(json 'git worktree add -q ../wt-s2b -b s2b')}" s2
for _ in $(seq 50); do lsof -a -p "${sleepers[1]}" -d cwd >/dev/null 2>&1 && break; sleep 0.1; done

end_session other
[[ -z "$report" && -d "$scratch/wt-clean" ]] || fail "the session end must remove nothing and say nothing: $report"
[[ "$(tail -1 "$records/s1.jsonl")" == *'"reason": "other"'*'"type": "end"'* ]] || fail "the session end must mark the record ended: $(tail -1 "$records/s1.jsonl")"
ok "the session end only marks its record ended; nothing is removed then"
stamp="$R/.agents/worktrees/.dead-session-check"
check() {  # [cwd] [VAR=value ...]: the hourly dead-session check, made due -> report
  local where="${1:-$scratch}"; shift || true
  rm -f "$stamp"
  report="$(cd "$where" && env "$@" python3 "$R/.agents/hooks/lib/worktree_sweep.py" check "$R" s9 "$R/.agents/workloop.py")"
}
answer() {  # <worktree> keep|--save|--discard -> answered
  if [[ "$2" == keep ]]; then answered="$(python3 "$R/.agents/hooks/lib/worktree_sweep.py" keep "$1")"
  else answered="$(python3 "$R/.agents/hooks/lib/worktree_sweep.py" remove "$1" "$2")"; fi
}
start=$(python3 -c 'import time; print(time.time())')
check "$scratch/wt-here"
elapsed=$(python3 -c "import time; print('%.2f' % (time.time() - $start))")
[[ -n "${SESSION_END_TEST_VERBOSE:-}" ]] && printf '%s\n' "$report"
[[ ! -e "$scratch/wt-clean" ]] || fail "a clean merged worktree must be removed: $report"
git -C "$R" rev-parse -q --verify refs/heads/clean >/dev/null && fail "a merged branch must be deleted"
[[ "$report" == *"removed $scratch/wt-clean: its work is merged into main; branch clean deleted, main contains it"* ]] || fail "the removal must name the source branch: $report"
[[ ! -e "$R/.claude/worktrees/feat" && ! -e "$R/.claude/worktrees/agent-a1b2" ]] || fail "EnterWorktree and cell worktrees must go: $report"
ok "the check removes a dead session's merged, clean worktree, its branch deleted once its source contains it (${elapsed}s for all)"
[[ ! -e "$scratch/wt-here" ]] || fail "the worktree the check runs in must not read busy from lsof itself: $report"
ok "the worktree the check's own process runs in is removed: lsof does not count itself"
[[ -d "$scratch/wt-dirty" && "$report" == *"dead session s1 left $scratch/wt-dirty: 0 commits not in main, 2 uncommitted files, ignored: none. Ask the operator"* ]] \
  || fail "a dirty worktree must stay and be flagged, package folders and tool caches not counted: $report"
[[ "$report" == *"keep it (asked again in a week): \`python3 $R/.agents/hooks/lib/worktree_sweep.py keep $scratch/wt-dirty\`; save and remove: \`python3 $R/.agents/hooks/lib/worktree_sweep.py remove $scratch/wt-dirty --save\`; discard: \`python3 $R/.agents/hooks/lib/worktree_sweep.py remove $scratch/wt-dirty --discard\`"* ]] \
  || fail "the flag must name the three answers as commands: $report"
git -C "$R" rev-parse -q --verify refs/heads/saved/wt-dirty >/dev/null && fail "nothing may be saved unasked"
answer "$scratch/wt-dirty" --save
[[ ! -e "$scratch/wt-dirty" && "$(git -C "$R" show saved/wt-dirty:src/app.txt)" == two ]] || fail "save and remove must save, then remove: $answered"
[[ "$(git -C "$R" show saved/wt-dirty:src/untracked.txt)" == new ]] || fail "the saved branch lacks the untracked file"
git -C "$R" cat-file -e saved/wt-dirty:node_modules/dep/index.js 2>/dev/null && fail "the saved branch must not carry ignored files"
ok "a dirty worktree is flagged with its three answers, never saved unasked; save and remove commits it to saved/<name>, package folders and tool caches left out"
[[ -f "$scratch/wt-keeplog/run.log" && "$report" == *"dead session s1 left $scratch/wt-keeplog: 0 commits not in main, 0 uncommitted files, ignored: run.log."* ]] \
  || fail "a merged worktree holding an ignored file that would not come back must stay, flagged with the file: $report"
answer "$scratch/wt-keeplog" --save
[[ -f "$scratch/wt-keeplog/run.log" && "$answered" == *"kept $scratch/wt-keeplog: it holds ignored files that would not come back (run.log)"* ]] \
  || fail "save and remove must keep a worktree whose ignored files would be lost: $answered"
ok "a merged worktree holding an ignored file that would not come back is flagged naming it, and save and remove keeps it"
[[ -d "$done5" && "$report" == *"dead session s1 left $done5: 1 commits not in main, 1 uncommitted files, ignored: none."* ]] || fail "a finished run's unmerged lane must be flagged: $report"
[[ "$report" == *"save and remove: \`python3 $R/.agents/workloop.py --state $R/.agents/.workloop-state.json park t5 l5\`"* ]] || fail "a lane's save and remove must be the controller's park: $report"
python3 -c "import json,sys; sys.exit('t5' not in json.load(open('$R/.agents/.workloop-state.json'))['runs'])" || fail "a run with a flagged lane must stay open"
ok "a run's unmerged lane is flagged, its save and remove naming park; the run stays open"
python3 -c "import json,sys; sys.exit('t6' in json.load(open('$R/.agents/.workloop-state.json'))['runs'])" || fail "the finished one-writer run must be closed: $report"
[[ ! -e "$mark6" && "$report" == *"closed workloop run t6"* ]] || fail "the check must close a one-writer run from recorded results, never running its test: $report"
[[ "$(git -C "$R" show HEAD:notes/solo.txt)" == solo ]] || fail "closing a one-writer run must leave the checkout's commits"
ok "a finished one-writer run of a dead session closes through abandon without its composed test running; the checkout keeps its work"
[[ -f "$lane/src/lane.txt" && "$report" == *"dead session s1 left $lane: 0 commits not in main, 1 uncommitted files"* ]] || fail "an unfinished run's dirty lane must be flagged: $report"
ok "an unfinished run's lane holding work is flagged and stays"
[[ ! -e "$scratch/other-made" && -d "$scratch/other-wt" ]] || fail "this session's worktree in another repository goes; an unrecorded one there stays: $report"
ok "a worktree this session made in another repository goes once merged; that repository's others stay"
[[ ! -e "$scratch/wt-claude-dead" ]] || fail "Claude Code's lock of an ended session must not keep its worktree: $report"
[[ -d "$scratch/wt-claude-live" && "$report" == *"kept $scratch/wt-claude-live: it is locked (claude session"* ]] || fail "a running session's Claude lock keeps it: $report"
[[ -d "$scratch/wt-locked" && "$report" == *"kept $scratch/wt-locked: it is locked (keep for review)"* ]] || fail "a locked worktree must stay: $report"
ok "Claude Code's session lock keeps a worktree only while its session runs; any other lock keeps it"
[[ ! -e "$scratch/wt-agent-dead" ]] || fail "Claude Code's agent lock of a dead process must not keep its worktree: $report"
[[ -d "$scratch/wt-agent-live" && "$report" == *"kept $scratch/wt-agent-live: it is locked (claude agent ag2"* ]] || fail "a live agent lock keeps it: $report"
ok "Claude Code's 'claude agent <id> (pid N)' lock is read like its session lock"
[[ "$(git -C "$scratch/wt-skip" show HEAD:src/app.txt)" == one && "$(cat "$scratch/wt-skip/src/app.txt")" == "hidden edit" ]] || fail "a skip-worktree edit must survive: $report"
[[ "$report" == *"kept $scratch/wt-skip: it holds skip-worktree or assume-unchanged files"* ]] || fail "the skip-worktree worktree must be named: $report"
[[ -d "$scratch/wt-bisect" && "$report" == *"kept $scratch/wt-bisect: a BISECT_LOG operation is in progress"* ]] || fail "a bisect in progress must keep its worktree: $report"
ok "a worktree with hidden index flags or an operation in progress stays: a save cannot carry them"
[[ ! -e "$scratch/wt-nm-nested" ]] || fail "a repository inside node_modules must not keep its worktree: $report"
ok "the nested-repository walk skips rebuildable folders"
[[ -d "$scratch/wt-busy" && "$report" == *"kept $scratch/wt-busy: process ${sleepers[1]} is working in it"* ]] || fail "a busy worktree must stay: $report"
[[ -d "$scratch/wt-nested/vendor/.git" && "$report" == *"kept $scratch/wt-nested: it holds a nested repository"* ]] || fail "a nested repository must keep its worktree: $report"
[[ -f "$scratch/wt-ignored-nested/deps.log/inner/file.txt" && "$report" == *"kept $scratch/wt-ignored-nested: it holds a nested repository"* ]] \
  || fail "a repository inside an ignored folder must never be parked: $report"
[[ -d "$scratch/wt-s2b" && -f "$records/s2.jsonl" && -d "$scratch/wt-s2" ]] || fail "another session's worktrees must stay"
[[ "$(recorded "$scratch/wt-busy")" == 1 && "$(recorded "$scratch/wt-locked")" == 0 ]] || fail "busy stays recorded for the next sweep; locked does not"
ok "occupied, nested, ignored-nested and other sessions' worktrees stay, each named"
[[ -f "$scratch/wt-build-holder/build/inner/work.txt" && "$report" == *"kept $scratch/wt-build-holder: another worktree lies inside it"* ]] \
  || fail "a worktree holding another under build/ must stay: $report"
[[ -d "$scratch/wt-build-repo/build/vendored/.git" && "$report" == *"kept $scratch/wt-build-repo: it holds a nested repository"* ]] \
  || fail "a repository inside build/ must keep its worktree: $report"
if [[ -n "$mc_inner" ]]; then
  [[ -f "$mc_inner" && "$report" == *"kept $scratch/wt-mc-holder: another worktree lies inside it"* ]] \
    || fail "a worktree added through a mis-cased path must keep its holder: $report"
fi
ok "build output keeps what lies in it: a worktree or a repository under build/, and an inner worktree git names in another case"

# ── without a working lsof every worktree reads busy ────────────────────────
# macOS keeps lsof in /usr/sbin, so this PATH hides it there; Linux keeps it in
# /usr/bin beside everything else, so an lsof that fails stands in for it.
mkdir -p "$scratch/failing-lsof" && printf '#!/bin/sh\nexit 1\n' > "$scratch/failing-lsof/lsof" && chmod +x "$scratch/failing-lsof/lsof"
for path in /opt/homebrew/bin:/usr/bin:/bin "$scratch/failing-lsof:$PATH"; do
  if [[ "$path" == /opt/* ]] && PATH="$path" command -v lsof >/dev/null; then
    printf 'note: lsof is on %s here, so only a failing lsof is tried\n' "$path"
    continue
  fi
  bash_call "$R" 'git worktree add -q ../wt-nolsof -b nolsof'
  end_session other
  check "$scratch" PATH="$path"
  [[ -d "$scratch/wt-nolsof" && "$report" == *"kept $scratch/wt-nolsof: lsof is missing or failed"* ]] || fail "an lsof missing from $path or failing must keep the worktree: $report"
  git -C "$R" worktree remove "$scratch/wt-nolsof" && git -C "$R" branch -qD nolsof
done
ok "a missing or failing lsof keeps the worktree rather than reading it empty"

# ── EnterWorktree at /exit: the answer to Claude Code's prompt stands ───────
rm -f "$records"/s1.jsonl
# Entered in this order; Claude Code asks keep-or-remove only for the last.
for name in left-earlier answered-none kept; do
  calls=$((calls + 1))
  tool PreToolUse "$R" EnterWorktree "{\"name\":\"$name\"}"
  git -C "$R" worktree add -q "$R/.claude/worktrees/$name" -b "worktree-$name"
  tool PostToolUse "$R/.claude/worktrees/$name" EnterWorktree "{\"name\":\"$name\"}"
done
me="$(cd "$R/.agents/hooks/lib" && python3 -c 'import worktree_records as w; print(w.host()[0])')"
git -C "$R" worktree lock "$R/.claude/worktrees/answered-none" --reason "claude session answered-none (pid $me start $(utc_start "$me"))"
printf 'x\n' > "$R/.claude/worktrees/kept/x.txt"
end_session prompt_input_exit
check
[[ -f "$R/.claude/worktrees/kept/x.txt" && "$report" == *"kept $R/.claude/worktrees/kept: kept at Claude Code's exit prompt"* ]] \
  || fail "a worktree the operator kept at the exit prompt must stay: $report"
[[ ! -e "$R/.claude/worktrees/answered-none" ]] || fail "one still under this session's own lock was never answered for, so it goes: $report"
[[ "$(recorded "$R/.claude/worktrees/kept")" == 0 ]] || fail "the kept worktree's record must go"
[[ ! -e "$R/.claude/worktrees/left-earlier" ]] || fail "an earlier worktree the session left, unlocked, was never answered for: $report"
ok "after /exit, the last worktree entered and kept at Claude Code's prompt stays; earlier ones and one under the ending session's own lock go"

# ── /clear ends a session: the hourly check removes what is merged into the source branch, flags the rest
# Acceptance rows 24 and 25: three worktrees cut from staging, which main never gains.
rm -f "$records"/s1.jsonl
git -C "$R" branch staging main
for name in st-merged st-ahead st-dirty; do bash_call "$R" "git worktree add -q ../$name -b $name staging"; done
grep -q "\"path\": \"$scratch/st-merged\", \"source\": \"staging\"" "$records/s1.jsonl" || fail "the start point -b names must be recorded as the source branch: $(cat "$records/s1.jsonl")"
printf 'm\n' > "$scratch/st-merged/m.txt" && git -C "$scratch/st-merged" add m.txt && git -C "$scratch/st-merged" commit -qm merged
git -C "$R" update-ref refs/heads/staging "$(git -C "$scratch/st-merged" rev-parse HEAD)"
printf 'a\n' > "$scratch/st-ahead/a.txt" && git -C "$scratch/st-ahead" add a.txt && git -C "$scratch/st-ahead" commit -qm ahead
printf 'edit\n' >> "$scratch/st-dirty/src/app.txt"
end_session clear
check
[[ ! -e "$scratch/st-merged" && "$report" == *"removed $scratch/st-merged: its work is merged into staging; branch st-merged deleted, staging contains it"* ]] \
  || fail "a worktree merged into its source branch must go with its branch: $report"
git -C "$R" merge-base --is-ancestor staging main && fail "the fixture's main must lack staging's commit"
[[ -d "$scratch/st-ahead" && "$report" == *"dead session s1 left $scratch/st-ahead: 1 commits not in staging, 0 uncommitted files, ignored: none."* ]] \
  || fail "a worktree with a commit not in staging must stay, flagged naming staging: $report"
[[ -d "$scratch/st-dirty" && "$report" == *"dead session s1 left $scratch/st-dirty: 0 commits not in staging, 1 uncommitted files, ignored: none."* ]] \
  || fail "a worktree with an uncommitted edit must stay, flagged naming staging: $report"
mtime() { python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$1"; }
checked="$(mtime "$stamp")"
again="$(python3 "$R/.agents/hooks/lib/worktree_sweep.py" check "$R" s9 "$R/.agents/workloop.py")"
[[ -z "$again" && "$(mtime "$stamp")" == "$checked" && -d "$scratch/st-ahead" ]] || fail "a second check within the hour must do nothing: $again"
ok "after /clear the check removes the worktree merged into staging with its branch, flags the two holding work naming staging, and runs once an hour"
answer "$scratch/st-ahead" keep
check
[[ "$report" != *"left $scratch/st-ahead:"* && "$report" == *"left $scratch/st-dirty:"* && -d "$scratch/st-ahead" ]] || fail "a kept worktree must not be asked about again within the week: $report"
python3 - "$records/.kept.json" "$scratch/st-ahead" <<'PY'
import json, sys, time
data = json.load(open(sys.argv[1])); data[sys.argv[2]] = int(time.time()) - 8 * 86400; json.dump(data, open(sys.argv[1], "w"))
PY
check
[[ "$report" == *"left $scratch/st-ahead:"* ]] || fail "a keep older than a week must be asked about again: $report"
answer "$scratch/st-dirty" --save
[[ ! -e "$scratch/st-dirty" && "$(git -C "$R" show saved/st-dirty:src/app.txt)" == $'one\nedit' ]] || fail "save and remove must keep the edit on saved/st-dirty: $answered"
answer "$scratch/st-ahead" --discard
[[ ! -e "$scratch/st-ahead" && "$answered" == *"branch st-ahead deleted"* ]] && ! git -C "$R" rev-parse -q --verify refs/heads/st-ahead >/dev/null \
  || fail "discard must remove the worktree and its branch: $answered"
check
[[ "$report" != *st-* ]] || fail "answered worktrees must not be asked about again: $report"
ok "keep holds the question off for a week; save and remove commits the edit to saved/<name>; discard drops worktree and branch"
sweep() {  # [session] [workloop.py] [source]
  sweep_out="$(cd "$R/.agents/hooks/lib" && python3 worktree_sweep.py sweep "$R" "${1:-s9}" "${3:-startup}" "${2:-$R/.agents/workloop.py}")"
}
bash_call "$R" 'git worktree add -q ../st-resumed -b st-resumed'
printf 'draft\n' > "$scratch/st-resumed/draft.txt"
end_session other
sweep s1 "" resume
rm -f "$stamp"; sweep
[[ -d "$scratch/st-resumed" && "$sweep_out" != *st-resumed* ]] || fail "a resumed session's worktrees must not read dead: $sweep_out"
ok "a resume of the same session stamps its record again, so its worktrees are never dead"
# Acceptance row 26: a lane cut from mvp/roadmap, merged there and not into main.
git -C "$R" branch mvp/roadmap main
bash_call "$R" "$wl init tr --objective o --acceptance a --repo $R --verify true"
bash_call "$R" "$wl add-lane tr lr --worker w --path src"
lr="$R/.agents/worktrees/tr/lr"
lr_branch="$(git -C "$lr" symbolic-ref --short HEAD)"
printf 'road\n' > "$lr/src/road.txt" && git -C "$lr" add src/road.txt && git -C "$lr" commit -qm road
git -C "$R" update-ref refs/heads/mvp/roadmap "$(git -C "$lr" rev-parse HEAD)"
python3 - "$R/.agents/.workloop-state.json" <<'PY'
import json, sys
path = sys.argv[1]; data = json.load(open(path)); data["runs"]["tr"]["base_branch"] = "mvp/roadmap"; json.dump(data, open(path, "w"))
PY
end_session clear
check
[[ ! -e "$lr" && "$report" == *"removed $lr: its work is merged into mvp/roadmap; branch $lr_branch deleted, mvp/roadmap contains it"* ]] \
  || fail "a lane merged into its run's source branch must be judged against it, not main: $report"
[[ "$report" == *"closed workloop run tr: git lists none of its worktrees"* ]] || fail "a run whose lanes all went must close through abandon: $report"
$wl status tr >/dev/null 2>&1 && fail "the run must leave the live state"
git -C "$R" merge-base --is-ancestor "$(git -C "$R" rev-parse mvp/roadmap)" main && fail "main must not have gained the lane's commit"
ok "a lane is judged merged against its run's source branch mvp/roadmap, removed, and its run closed through abandon"
# Acceptance row 9: a lane whose writer's transcript grew within the last minute.
bash_call "$R" "$wl init tc --objective o --acceptance a --repo $R --verify true"
bash_call "$R" "$wl add-lane tc lc --worker w --path src"
lc="$R/.agents/worktrees/tc/lc"
$wl claim tc lc --agent agfixture >/dev/null
printf 'w\n' > "$lc/src/w.txt"
transcript="$scratch/claude/projects/p/sess/subagents/agent-agfixture.jsonl"
mkdir -p "${transcript%/*}" && printf '{}\n' > "$transcript"
end_session clear
check "$scratch" CLAUDE_CONFIG_DIR="$scratch/claude"
[[ -d "$lc" && "$report" != *"$lc"* ]] || fail "a run whose writer's transcript grew within the minute must be neither removed nor flagged: $report"
touch -t 202601010000 "$transcript"
mkdir -p "$R/.agents/.readout"
python3 - "$R/.agents/.readout/.agent-deaths-cache" "$transcript" <<'PY'
import json, os, sys
stat = os.stat(sys.argv[2])
json.dump({"agents": {"agfixture": {"transcript": sys.argv[2], "file": [stat.st_size, stat.st_mtime_ns], "state": "running"}}}, open(sys.argv[1], "w"))
PY
check "$scratch" CLAUDE_CONFIG_DIR="$scratch/claude"
[[ -d "$lc" && "$report" != *"$lc"* ]] || fail "a run whose writer the death reader judged running must be held: $report"
python3 - "$R/.agents/.readout/.agent-deaths-cache" <<'PY'
import json, sys
data = json.load(open(sys.argv[1])); data["agents"]["agfixture"]["state"] = "lost"; json.dump(data, open(sys.argv[1], "w"))
PY
check "$scratch" CLAUDE_CONFIG_DIR="$scratch/claude"
[[ -d "$lc" && "$report" == *"dead session s1 left $lc: 0 commits not in main, 1 uncommitted files"* ]] || fail "once its writer is quiet and judged lost, the lane is flagged: $report"
ok "a run with an agent that may still be working is neither removed nor flagged; once it reads lost, its lane is flagged"
# Acceptance row 8: a merged lane holding an ignored .env.
printf '.env\n' >> "$R/.git/info/exclude"
bash_call "$R" "$wl init te --objective o --acceptance a --repo $R --verify true"
bash_call "$R" "$wl add-lane te le --worker w --path src"
le="$R/.agents/worktrees/te/le"
printf 'KEY=1\n' > "$le/.env"
end_session clear
check
[[ -f "$le/.env" && "$report" == *"dead session s1 left $le: 0 commits not in main, 0 uncommitted files, ignored: .env."* ]] \
  || fail "a merged lane holding an ignored .env must stay, flagged naming .env: $report"
ok "a merged lane holding an ignored .env stays and its dead session line names .env"
# A checkout that is not on disk may be on an unmounted disk, so the sweep never drops its run.
git clone -q "$R" "$scratch/gone-clone"
bash_call "$R" "$wl init tg --objective o --acceptance a --repo $scratch/gone-clone --verify true"
bash_call "$R" "$wl add-lane tg lg --worker w --path src"
rm -rf "$scratch/gone-clone"
end_session other
check
[[ "$report" == *"left alone with their worktrees: "*"tg"* && "$report" != *"closed workloop run tg"* ]] \
  || fail "the check must keep and name a run whose checkout is not on disk: $report"
$wl status tg >/dev/null 2>&1 || fail "the check dropped a run whose checkout is not on disk: $report"
$wl abandon tg --checkout-gone >/dev/null
ok "a run whose checkout is not on disk outlives the check and is named"
# An empty mount point inside another repository is not that repository: git
# listing none of the run's worktrees there says nothing about the run.
mkdir -p "$scratch/home-repo/mnt"; printf 'dotfiles\n' > "$scratch/home-repo/f"
git -C "$scratch/home-repo" init -q && git -C "$scratch/home-repo" add -A && git -C "$scratch/home-repo" -c user.email=t@e.com -c user.name=t commit -qm home
git clone -q "$R" "$scratch/home-repo/mnt/disk"
$wl init um --objective o --acceptance a --repo "$scratch/home-repo/mnt/disk" --verify true >/dev/null
$wl add-lane um ul --worker w --workspace "$scratch/um-lane" --path src >/dev/null
mv "$scratch/home-repo/mnt/disk" "$scratch/disk-away"; mkdir "$scratch/home-repo/mnt/disk"
sweep
[[ "$sweep_out" != *"closed workloop run um"* && "$sweep_out" == *"left alone with their worktrees: "*"um"* ]] \
  || fail "the sweep dropped a run whose checkout is an empty mount point inside another repository: $sweep_out"
$wl status um >/dev/null 2>&1 || fail "the sweep dropped the mount point's run from state: $sweep_out"
rmdir "$scratch/home-repo/mnt/disk"; mv "$scratch/disk-away" "$scratch/home-repo/mnt/disk"
$wl abandon um >/dev/null
rm -rf "$scratch/home-repo"
ok "an unled run whose checkout is an empty mount point inside another repository is kept and named"
# A one-writer run no session leads has no worktree for git to list; it stays and is named,
# before and after its composed test passed (whose verify worktree is gone again).
$wl init ow --objective o --acceptance a --repo "$R" --verify true --lane solo --worker w --path src >/dev/null
sweep
[[ "$sweep_out" == *"left alone with their worktrees: "*"ow"* && "$sweep_out" != *"closed workloop run ow"* ]] || fail "an unowned one-writer run must stay and be named: $sweep_out"
$wl claim ow solo --agent cell-ow >/dev/null
printf 'ow\n' >> "$R/src/app.txt" && git -C "$R" add -- src/app.txt && git -C "$R" commit -qm ow
$wl submit ow solo --evidence ok >/dev/null && $wl review ow solo --reference src/app.txt#ok --result accept --tip "$(git -C "$R" rev-parse HEAD)" >/dev/null
$wl check ow >/dev/null 2>&1 || true  # the test passes and is recorded; QA is still missing
python3 -c "import json,sys; v=json.load(open('$R/.agents/.workloop-state.json'))['runs']['ow']['verified']; sys.exit(v['result'] != 'pass')" || fail "the one-writer fixture's test did not pass"
[[ ! -e "$R/.agents/worktrees/ow/verify" ]] || fail "a passing check left its verify worktree"
sweep
[[ "$sweep_out" == *"left alone with their worktrees: "*"ow"* && "$sweep_out" != *"closed workloop run ow"* ]] || fail "an unowned one-writer run with a passing test and no QA must stay and be named: $sweep_out"
python3 -c "import json,sys; sys.exit('ow' not in json.load(open('$R/.agents/.workloop-state.json'))['runs'])" || fail "the sweep dropped a one-writer run after its test passed"
$wl abandon ow >/dev/null
ok "a one-writer run with no recorded lead stays through the sweep, before and after its test passed: nothing on disk is its to lose"
# A read-only fan-out no session leads (no --verify, cells only) closes once every
# cell is back, or once its cells went out before the 24-hour hold; a run with
# --verify whose scouts are back still waits for its lane.
$wl init fo --objective o --acceptance a --repo "$R" >/dev/null
$wl add-cell fo a --role research --model haiku >/dev/null; $wl add-cell fo b --role review --model haiku >/dev/null
$wl init pre --objective o --acceptance a --repo "$R" --verify true >/dev/null
$wl add-cell pre scout --role research --model haiku >/dev/null; $wl returned pre scout --result reply >/dev/null
sweep
[[ "$sweep_out" == *"left alone with their worktrees: "*"fo"*"pre"* && "$sweep_out" != *"closed workloop run fo"* ]] || fail "a fan-out with a cell out must stay and be named: $sweep_out"
$wl returned fo a --result reply >/dev/null; $wl returned fo b --failed x >/dev/null
sweep
[[ "$sweep_out" == *"closed workloop run fo: every cell is back"* && "$sweep_out" == *"left alone with their worktrees: "*"pre"* && "$sweep_out" != *"closed workloop run pre"* ]] || fail "a fan-out whose cells are back must close, and a --verify run with no lane must stay: $sweep_out"
python3 -c "import json,sys; r=json.load(open('$R/.agents/.workloop-state.json'))['runs']; sys.exit('fo' in r or 'pre' not in r)" || fail "the sweep dropped the wrong run"
[[ -d "$R/.agents/worktrees/pre/.workloop" ]] || fail "the close took another run's briefs"
# the close judges the run again on a fresh read: a cell added since the sweep read it keeps the run
$wl init late --objective o --acceptance a --repo "$R" >/dev/null
$wl add-cell late a --role research --model haiku >/dev/null; $wl returned late a --result reply >/dev/null
stale="$(python3 -c "import json; print(json.dumps(json.load(open('$R/.agents/.workloop-state.json'))['runs']['late']))")"
$wl add-cell late b --role research --model haiku >/dev/null
late_out="$(cd "$R/.agents/hooks/lib" && python3 - "$R" "$stale" <<'PY'
import importlib.util, json, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("worktree_runs", "worktree_runs.py"); rn = importlib.util.module_from_spec(spec); spec.loader.exec_module(rn)
rn.wr.runs_in = lambda state: {"late": json.loads(sys.argv[2])}  # the read before the lock, from before cell b
print("\n".join(rn.unowned_runs(Path(sys.argv[1]), set(), Path(sys.argv[1]) / ".agents/workloop.py")))
PY
)"
[[ "$late_out" == *"left alone with their worktrees: late"* && "$late_out" != *"closed workloop run late"* ]] || fail "the close dropped a fan-out a cell joined after the sweep read it: $late_out"
python3 -c "import json,sys; sys.exit('late' not in json.load(open('$R/.agents/.workloop-state.json'))['runs'])" || fail "the run with a cell out was dropped from state"
[[ -f "$R/.agents/worktrees/late/.workloop/cells/b.md" ]] || fail "the kept run lost its briefs"
$wl returned late b --result reply >/dev/null
$wl init old --objective o --acceptance a --repo "$R" >/dev/null
$wl add-cell old a --role research --model haiku >/dev/null; $wl add-cell old b --role research --model haiku >/dev/null
python3 - "$R/.agents/.workloop-state.json" <<'PY'
import json, sys, time
path = sys.argv[1]; s = json.load(open(path))
s["runs"]["old"]["cells"]["a"]["out_since"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 25 * 3600))
json.dump(s, open(path, "w"))
PY
sweep
[[ "$sweep_out" != *"closed workloop run old"* ]] || fail "a fan-out with one cell out within the hold must stay: $sweep_out"
python3 - "$R/.agents/.workloop-state.json" <<'PY'
import json, sys, time
path = sys.argv[1]; s = json.load(open(path))
s["runs"]["old"]["cells"]["b"]["out_since"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 25 * 3600))
json.dump(s, open(path, "w"))
PY
sweep
[[ "$sweep_out" == *"closed workloop run old: its cells went out over 24 hours ago"* ]] || fail "a fan-out whose cells all went out past the hold must close: $sweep_out"
$wl status old >/dev/null 2>&1 && fail "the closed fan-out must leave the live state"
$wl abandon pre >/dev/null
! grep -q strptime "$repo/.agents/hooks/lib/worktree_runs.py" || fail "worktree_runs.py parses the controller's stamps itself instead of importing workloop_size's parse"
! grep -q 'del data\["runs"\]' "$repo/.agents/hooks/lib/worktree_runs.py" || fail "worktree_runs.py deletes runs from state itself instead of closing them through abandon"
ok "a lead-less fan-out closes through abandon once every cell is back or every cell is out past the hold, read by the digest's own stamp parse; a --verify run with no lane yet stays"

# ── a resumed session claims its records even while another start sweeps ───
# Rewrites s1's record with the dead process as its host, and drops its resumes.
age() {
  python3 - "$records/s1.jsonl" "$gone" "$gone_start" <<'PY'
import json, sys
path, pid, start = sys.argv[1], int(sys.argv[2]), sys.argv[3]
out = []
for line in open(path):
    entry = json.loads(line) if line.strip() else None
    if entry is None or entry.get("type") == "host":
        continue
    entry.pop("start", None)
    out.append(entry if entry.get("type") == "end" else dict(entry, host=[pid, start]))
open(path, "w").write("".join(json.dumps(e, sort_keys=True) + "\n" for e in out))
PY
}
bash_call "$R" "$wl init t7 --objective o --acceptance a --repo $R --verify true"
end_session other
age
lockfile="$(git -C "$R" rev-parse --path-format=absolute --git-common-dir)/colloid-sweep.lock"
python3 -c 'import fcntl,sys,time; f=open(sys.argv[1],"w"); fcntl.flock(f,fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(30)' \
  "$lockfile" "$scratch/locked" & holder=$!
for _ in $(seq 50); do [[ -e "$scratch/locked" ]] && break; sleep 0.1; done
sweep s1
kill "$holder"; wait "$holder" 2>/dev/null || true
[[ "$sweep_out" == *"Another session start is sweeping"* ]] || fail "the held lock must skip the sweep: $sweep_out"
live_last() {  # <record>: its last host is a live process
  (cd "$R/.agents/hooks/lib" && python3 -c 'import sys, worktree_records as w; sys.exit(not w.alive(w.last_host(w.load(__import__("pathlib").Path(sys.argv[1])))))' "$1")
}
live_last "$records/s1.jsonl" || fail "the skipped start must re-host its records under a live process: $(tail -2 "$records/s1.jsonl")"
# Another sweep holds the record itself: the resumed start writes a new one beside the claim.
age
sleep 300 >/dev/null 2>&1 & claimer=$!
mv "$records/s1.jsonl" "$records/.s1.jsonl.sweep-$claimer"
python3 -c 'import fcntl,sys,time; f=open(sys.argv[1],"w"); fcntl.flock(f,fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(30)' \
  "$lockfile" "$scratch/locked2" & holder=$!
for _ in $(seq 50); do [[ -e "$scratch/locked2" ]] && break; sleep 0.1; done
sweep s1
kill "$holder" "$claimer"; wait "$holder" "$claimer" 2>/dev/null || true
[[ -f "$records/s1.jsonl" ]] && live_last "$records/s1.jsonl" || fail "a resumed start must re-host a record another sweep holds: $sweep_out"
# The claimer died: the next sweep folds its claim back, and the resumed host stays last.
sweep s9
[[ ! -e "$records/.s1.jsonl.sweep-$claimer" ]] && live_last "$records/s1.jsonl" \
  || fail "folding a dead claim back must leave the resumed host last: $(tail -3 "$records/s1.jsonl")"
ok "a resumed session re-hosts its records even when another start holds the sweep or the record; a folded-back claim keeps it live"
age
(cd "$R/.agents/hooks/lib" && python3 - "$records/s1.jsonl" "$R/.agents/workloop.py" <<'PY') || fail "a sweep must give back a record whose session resumed before the claim"
import pathlib, sys, time, worktree_records as w, worktree_sweep as s
record = pathlib.Path(sys.argv[1])
w.append(record.parent, "s1", [dict({"type": "host", "at": int(time.time())}, **w.stamp())])
before = record.read_text()
lines = s.close(record, pathlib.Path(sys.argv[2]))
claims = list(record.parent.glob(".s1.jsonl.*"))
sys.exit(bool(lines) or bool(claims) or record.read_text() != before)
PY
ok "a sweep that finds the session alive after its claim gives the records back untouched"
# The session resumes while the sweep holds its claim: a stub check re-hosts the record midway.
bash_call "$R" 'git worktree add -q ../wt-resumed -b resumed'
printf 'work\n' > "$scratch/wt-resumed/work.txt"
age
cat > "$scratch/stub-workloop.py" <<PY
import sys, time
sys.path.insert(0, "$R/.agents/hooks/lib")
import worktree_records as w
from pathlib import Path
if "check" in sys.argv:
    w.append(Path("$records"), "s1", [dict({"type": "host", "at": int(time.time())}, **w.stamp())])
    sys.exit(0)
sys.exit("stub workloop: " + " ".join(sys.argv[1:]))
PY
rm -f "$stamp"; sweep s9 "$scratch/stub-workloop.py"
[[ "$sweep_out" == *"kept workloop run t7: its session resumed during this sweep"* \
  && "$sweep_out" == *"kept $scratch/wt-resumed: its session resumed during this sweep"* && -d "$scratch/wt-resumed" ]] \
  || fail "a session resumed during the sweep keeps its runs and worktrees: $sweep_out"
live_last "$records/s1.jsonl" || fail "what the sweep wrote back must carry the resumed host: $(tail -2 "$records/s1.jsonl")"
ok "a session resumed during the sweep keeps its runs and worktrees, written back under its live host"

# ── an unreadable state file keeps its run ──────────────────────────────────
alt="$scratch/alt/.workloop-state.json"; mkdir -p "$scratch/alt"
bash_call "$R" "python3 $R/.agents/workloop.py --state $alt init t9 --objective o --acceptance a --repo $R --verify true"
bash_call "$R" "python3 $R/.agents/workloop.py --state $alt add-lane t9 l9 --worker w --path docs"
l9="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runs"]["t9"]["lanes"]["l9"]["workspace"])' "$alt")"
[[ -d "$l9" ]] || fail "the t9 lane was not made"
printf '{"runs": ' > "$alt"
end_session other
check
[[ -d "$l9" && "$report" == *"kept workloop run t9: its state file $alt is unreadable"* ]] || fail "an unreadable state file must keep the run at the check: $report"
age; check
[[ -d "$l9" && "$report" == *"kept workloop run t9: its state file $alt is unreadable"* ]] || fail "after its process is gone, an unreadable state file still keeps the run: $report"
ok "a state file that does not parse keeps its run and lanes, never read as empty"

# ── Codex and Kimi record through their own adapters ────────────────────────
# Kimi is optional: only repositories that wire the engine carry .kimi/.
kimi=""; [[ -f "$repo/.kimi/hooks/adapter.sh" ]] && kimi=yes
mkdir -p "$R/.agents/codex" "$R/.codex/hooks"
cp "$repo/.agents/codex/adapter.sh" "$repo/.agents/codex/normalize-hook.py" "$R/.agents/codex/"
ln -s ../../.agents/codex/adapter.sh "$R/.codex/hooks/adapter.sh"
if [[ -n "$kimi" ]]; then
  mkdir -p "$R/.kimi/hooks"
  cp "$repo/.kimi/hooks/adapter.sh" "$repo/.kimi/hooks/normalize-hook.py" "$R/.kimi/hooks/"
fi
host_call() {  # <host> <session> <command> [tool_use_id]: PreToolUse, the command, PostToolUse
  local input; input="{\"command\":$(json "$3")}"
  for event in PreToolUse PostToolUse; do
    [[ "$event" == PostToolUse ]] && { (cd "$R" && eval "$3") >/dev/null 2>&1 || true; }
    printf '{"hook_event_name":"%s","cwd":"%s","session_id":"%s","tool_name":"Bash","tool_input":%s%s}' \
      "$event" "$R" "$2" "$input" "${4:+,\"tool_use_id\":\"$4\"}" | (cd "$R" && bash "$R/.$1/hooks/adapter.sh" teardown-gate.sh) >/dev/null 2>&1 || true
  done
}
host_call codex cx1 'git worktree add -q ../wt-codex -b codex' call-c1
host_call codex cx1 "$wl init t3 --objective o --acceptance a --repo $R --verify true" call-c2
[[ "$(grep -c "\"path\": \"$scratch/wt-codex\"" "$records/cx1.jsonl" 2>/dev/null)" == 1 ]] || fail "Codex must record git worktree add once: $(cat "$records"/cx1.jsonl 2>&1)"
[[ "$(grep -c '"run": "t3"' "$records/cx1.jsonl")" == 1 ]] || fail "Codex must record workloop.py init once"
if [[ -n "$kimi" ]]; then
  host_call kimi km1 'git worktree add -q ../wt-kimi -b kimi'
  host_call kimi km1 "$wl init t4 --objective o --acceptance a --repo $R --verify true"
  [[ "$(grep -c "\"path\": \"$scratch/wt-kimi\"" "$records/km1.jsonl" 2>/dev/null)" == 1 ]] || fail "Kimi must record git worktree add once: $(cat "$records"/km1.jsonl 2>&1)"
  [[ "$(grep -c '"run": "t4"' "$records/km1.jsonl")" == 1 ]] || fail "Kimi must record workloop.py init once"
fi
ok "Codex${kimi:+ and Kimi} record git worktree add and workloop.py init once each, through their adapters"
python3 - "$repo/.agents/codex/hooks.json" "${kimi:+$repo/.kimi/config.toml.example}" <<'PY' || fail "Codex${kimi:+ and Kimi} must register teardown-gate.sh on PreToolUse for Bash"
import json, re, sys
codex = json.load(open(sys.argv[1]))["hooks"].get("PreToolUse", [])
in_codex = any(group.get("matcher") == "Bash" and any(h["command"].endswith('adapter.sh\\" teardown-gate.sh') or
               h["command"].endswith('adapter.sh" teardown-gate.sh') for h in group["hooks"]) for group in codex)
in_kimi = True
if sys.argv[2]:
    blocks = re.split(r"^\[\[hooks\]\]", open(sys.argv[2]).read(), flags=re.M)
    in_kimi = any('event = "PreToolUse"' in b and 'matcher = "Bash"' in b and "teardown-gate.sh" in b for b in blocks)
sys.exit(not (in_codex and in_kimi))
PY
ok "Codex${kimi:+ and Kimi} register the snapshot PreToolUse"

# ── a config that hides untracked files hides nothing from the save ─────────
# With status.showUntrackedFiles=no, `git status` prints nothing and `git
# worktree remove` without --force deletes the untracked file.
git -C "$R" config status.showUntrackedFiles no
bash_call "$R" 'git worktree add -q ../wt-hidden -b hidden'
printf 'notes\n' > "$scratch/wt-hidden/notes.txt"
end_session other
check
[[ -d "$scratch/wt-hidden" && "$report" == *"left $scratch/wt-hidden: 0 commits not in main, 1 uncommitted files"* ]] || fail "an untracked file the config hides must keep and flag its worktree: $report"
answer "$scratch/wt-hidden" --save
git -C "$R" config --unset status.showUntrackedFiles
[[ "$(git -C "$R" show saved/wt-hidden:notes.txt 2>/dev/null)" == notes ]] || fail "an untracked file the config hides must be saved: $answered"
ok "an untracked file hidden by status.showUntrackedFiles=no is flagged, and saved before the removal"

# ── a failed save stops the removal ──────────────────────────────────────────
git -C "$R" config user.useConfigOnly true
bash_call "$R" 'git worktree add -q ../wt-nosave -b nosave'
printf 'x\n' > "$scratch/wt-nosave/src/x.txt"
(
  unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  export HOME="$scratch/home" XDG_CONFIG_HOME="$scratch/home" GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME"
  answer "$scratch/wt-nosave" --save
  printf '%s' "$answered" > "$scratch/nosave"
)
[[ -f "$scratch/wt-nosave/src/x.txt" ]] || fail "a worktree whose save failed must stay: $(cat "$scratch/nosave")"
grep -q "kept $scratch/wt-nosave: its unsaved work could not be committed" "$scratch/nosave" || fail "the failed save must be named: $(cat "$scratch/nosave")"
ok "a worktree whose unsaved work cannot be committed stays"

# ── a session's start, whatever the zone and locale ─────────────────────────
# A stamp keeps `host`, [pid, start text in the writer's zone and locale], which
# code from before `start` reads, and gains `start`. The expected start is read
# here without process_start.py: on Linux the boot id and field 22 of
# /proc/<pid>/stat, elsewhere the C-locale UTC `ps` start in seconds. These
# sweeps run over a repository of their own, so only these records are judged.
U="$scratch/u5"
git init -q -b main "$U" && printf '.agents/\n*.log\n' > "$U/.gitignore" && git -C "$U" add .gitignore && git -C "$U" commit -qm init
u5records="$U/.agents/worktrees/.records" && mkdir -p "$u5records"
lib="$R/.agents/hooks/lib"
linux=""; [[ "$(uname)" == Linux ]] && linux=yes
u5_sweep() {  # [VAR=value ...]: one session-start sweep of $U under those variables, its check due -> u5_out, u5_err
  rm -f "$U/.agents/worktrees/.dead-session-check"
  u5_out="$(cd "$lib" && env "$@" python3 worktree_sweep.py sweep "$U" u5-sweeper startup "$R/.agents/workloop.py" 2>"$scratch/u5-err")"
  u5_err="$(<"$scratch/u5-err")"
}
u5_wt() { git -C "$U" worktree add -q "$scratch/u5-$1" -b "u5-$1"; }
text_of() { ps -o lstart= -p "$1" | awk '{$1=$1};1'; }
start_of() {  # <pid> [seconds | ticks | boot]: the pid's start as a record holds it, optionally moved off
  if [[ -n "$linux" ]]; then
    python3 - "$(cat /proc/sys/kernel/random/boot_id)" "$(awk '{print $22}' "/proc/$1/stat")" "${2:-}" <<'PY'
import json, sys
boot, ticks, move = sys.argv[1], int(sys.argv[2]), sys.argv[3]
print(json.dumps({"boot": "00000000-0000-4000-8000-000000000000" if move == "boot" else boot,
                  "ticks": ticks + 1 if move == "ticks" else ticks}))
PY
  else
    python3 - "$(LC_ALL=C TZ=UTC ps -o lstart= -p "$1")" "${2:-0}" <<'PY'
import calendar, json, sys, time
print(json.dumps({"epoch": calendar.timegm(time.strptime(sys.argv[1].strip(), "%a %b %d %H:%M:%S %Y")) + int(sys.argv[2])}))
PY
  fi
}
hand() {  # <session> <worktree> <pid> <host text> [start json]: a record stamped by hand
  printf '{"type": "worktree", "path": "%s", "by": "git worktree add", "host": [%s, "%s"]%s, "at": %s}\n' \
    "$scratch/u5-$2" "$3" "$4" "${5:+, \"start\": $5}" "$(date +%s)" > "$u5records/$1.jsonl"
}
sleep 300 >/dev/null 2>&1 & sleepers+=($!); live=$!

u5_wt zone
(cd "$lib" && TZ=Asia/Karachi python3 -c 'import sys, worktree_records as w; w.record(sys.argv[1], "zone", [{"type": "worktree", "path": sys.argv[2], "by": "git worktree add"}])' \
  "$U" "$scratch/u5-zone")
python3 - "$u5records/zone.jsonl" "$$" "$(TZ=Asia/Karachi ps -o lstart= -p $$ | awk '{$1=$1};1')" "$(start_of $$)" <<'PY' \
  || fail "a worktree recorded now must carry its host text as before and a start in this host's form: $(cat "$u5records/zone.jsonl")"
import json, sys
entry = json.loads(open(sys.argv[1]).read())
sys.exit(entry["host"] != [int(sys.argv[2]), sys.argv[3]] or entry.get("start") != json.loads(sys.argv[4]))
PY
ok "a worktree recorded now is stamped with its host text as before and a start in this host's form"

printf '{"type": "host", "host": [%s, "%s"], "at": %s}\n' $$ "$(text_of $$)" "$(date +%s)" > "$u5records/u5-sweeper.jsonl"
u5_sweep TZ=America/New_York
[[ -d "$scratch/u5-zone" && -f "$u5records/zone.jsonl" ]] || fail "a live session's record and worktree must stay through a sweep in another zone: $u5_out $u5_err"
python3 - "$u5records/u5-sweeper.jsonl" "$$" "$(start_of $$)" <<'PY' || fail "the sweeping session's own stamp must carry its start: $(tail -1 "$u5records/u5-sweeper.jsonl")"
import json, sys
last = json.loads(open(sys.argv[1]).read().splitlines()[-1])
sys.exit(last["type"] != "host" or last["host"][0] != int(sys.argv[2]) or last.get("start") != json.loads(sys.argv[3]))
PY
if [[ "$(LC_ALL=de_DE.UTF-8 TZ=UTC ps -o lstart= -p $$)" == "$(LC_ALL=C TZ=UTC ps -o lstart= -p $$)" ]]; then
  printf 'note: LC_ALL=de_DE.UTF-8 leaves ps output as in the C locale here, so the sweep in that locale is skipped\n'
else
  u5_sweep TZ=UTC LC_ALL=de_DE.UTF-8
  [[ -d "$scratch/u5-zone" && -f "$u5records/zone.jsonl" ]] || fail "a live session's record and worktree must stay through a sweep in another locale: $u5_out $u5_err"
fi
ok "a live session keeps its record and worktree through sweeps in another zone and locale; the sweeper's own stamp carries its start"

# Written in another zone than the sweep's, the host text never matches, so the
# start alone decides.
karachi="$(TZ=Asia/Karachi ps -o lstart= -p "$live" | awk '{$1=$1};1')"
if [[ -n "$linux" ]]; then
  for name in exact ticks boot; do u5_wt "$name"; done
  hand exact exact "$live" "$karachi" "$(start_of "$live")"
  hand ticks ticks "$live" "$karachi" "$(start_of "$live" ticks)"
  hand boot boot "$live" "$karachi" "$(start_of "$live" boot)"
  kept=(exact) ended=(ticks boot) on="equal to the process's" off="of another tick count or boot"
else
  for name in near early far; do u5_wt "$name"; done
  hand near near "$live" "$karachi" "$(start_of "$live" 3)"
  hand early early "$live" "$karachi" "$(start_of "$live" -3)"
  hand far far "$live" "$karachi" "$(start_of "$live" -6)"
  kept=(near early) ended=(far) on="3 s either side of the process's" off="6 s off"
fi
u5_sweep TZ=America/New_York
for name in "${kept[@]}"; do
  [[ -d "$scratch/u5-$name" && -f "$u5records/$name.jsonl" ]] || fail "the live $name record must keep its worktree and record: $u5_out $u5_err"
done
for name in "${ended[@]}"; do
  [[ ! -e "$scratch/u5-$name" && ! -e "$u5records/$name.jsonl" ]] || fail "a $name start that is not the process's must read gone: $u5_out $u5_err"
done
ok "a recorded start $on reads live and one $off reads gone, where the host text was written in another zone"

# Hooks from before `start` write back what a sweep keeps as `dict(e, host=...)`:
# a session that resumed during that sweep gets its new process's host beside the
# start of the one that ended. The host text, equal to ps here, reads it live, and
# the sweep writes the stamp again with the process's own start.
sleep 300 >/dev/null 2>&1 & sleepers+=($!); resumer=$!
u5_wt resumed-pair
if [[ -n "$linux" ]]; then ended_start="$(start_of "$live" ticks)"; else ended_start="$(start_of "$live" -3600)"; fi
hand resumed-pair resumed-pair "$resumer" "$(text_of "$resumer")" "$ended_start"
u5_sweep
[[ -d "$scratch/u5-resumed-pair" && -f "$u5records/resumed-pair.jsonl" ]] \
  || fail "a live process's host text beside another process's start must keep its record and worktree: $u5_out $u5_err"
python3 - "$u5records/resumed-pair.jsonl" "$resumer" "$(text_of "$resumer")" "$(start_of "$resumer")" <<'PY' \
  || fail "the sweep must write that stamp again with the process's own start: $(cat "$u5records/resumed-pair.jsonl")"
import json, sys
lines = [json.loads(line) for line in open(sys.argv[1]).read().splitlines()]
sys.exit(not (len(lines) == 2 and lines[-1] == {"type": "host", "host": [int(sys.argv[2]), sys.argv[3]], "start": json.loads(sys.argv[4])}))
PY
u5_sweep
[[ "$(wc -l < "$u5records/resumed-pair.jsonl")" -eq 2 ]] || fail "a mended stamp must not be written again: $(cat "$u5records/resumed-pair.jsonl")"
ok "a live process's host text beside another process's start reads live, and the sweep writes it again with its own start, once"

# What a sweep writes back goes under the session's stamp: its start with it, and
# none where that stamp has none, whatever start the entry carried before.
sleep 300 >/dev/null 2>&1 & ghost=$!; ghost_text="$(text_of "$ghost")"; ghost_start="$(start_of "$ghost")"
kill "$ghost"; wait "$ghost" 2>/dev/null || true
for name in carry drop; do u5_wt "$name"; printf 'kept\n' > "$scratch/u5-$name/run.log"; done
hand carry carry "$ghost" "$ghost_text" "$ghost_start"
hand drop drop "$ghost" "$ghost_text" "$ghost_start"
printf '{"type": "host", "host": [%s, "%s"], "at": %s}\n' "$ghost" "$ghost_text" "$(date +%s)" >> "$u5records/drop.jsonl"
u5_sweep
python3 - "$u5records" "$ghost" "$ghost_text" "$ghost_start" <<'PY' || fail "the entries a sweep writes back must carry the session's stamp and only its start: $(cat "$u5records"/carry.jsonl "$u5records"/drop.jsonl 2>&1)"
import json, sys
from pathlib import Path
folder, host, start = Path(sys.argv[1]), [int(sys.argv[2]), sys.argv[3]], json.loads(sys.argv[4])
carry = [json.loads(line) for line in (folder / "carry.jsonl").read_text().splitlines()]
drop = [json.loads(line) for line in (folder / "drop.jsonl").read_text().splitlines()]
sys.exit(not (len(carry) == len(drop) == 1 and carry[0]["host"] == host == drop[0]["host"]
              and carry[0].get("start") == start and "start" not in drop[0]))
PY
ok "what a sweep writes back carries the session's stamp: its start where it has one, none where it has none"

# A start that cannot be told keeps its record, and one stderr line names the pid.
sleep 300 >/dev/null 2>&1 & sleepers+=($!); murky=$!
u5_wt murky
if [[ -n "$linux" ]]; then other='{"epoch": 1}'; else other='{"boot": "b", "ticks": 1}'; fi
hand murky murky "$murky" "$(text_of "$murky")" "$other"
u5_sweep
[[ -d "$scratch/u5-murky" && -f "$u5records/murky.jsonl" ]] || fail "a start in another host's form must keep its record: $u5_out $u5_err"
[[ "$(grep -c "pid $murky " <<<"$u5_err")" == 1 ]] || fail "one stderr line must name the pid whose start cannot be told: $u5_err"
if [[ -n "$linux" ]]; then
  printf 'note: Linux reads a start from /proc, not ps, so the row for a ps start that does not parse is skipped\n'
else
  sleep 300 >/dev/null 2>&1 & sleepers+=($!); garbled=$!
  u5_wt garbled
  hand garbled garbled "$garbled" "$(text_of "$garbled")" "$(start_of "$garbled")"
  # A claim a killed sweep left beside that stamp stays for a sweep that can tell,
  # and the worktree it names counts as recorded: idle a day, clean and merged, the
  # heal would otherwise remove it.
  u5_wt claimed
  GIT_COMMITTER_DATE=2026-01-01T00:00:00 GIT_AUTHOR_DATE=2026-01-01T00:00:00 git -C "$scratch/u5-claimed" commit -q --allow-empty -m claimed
  git -C "$U" merge -q --ff-only u5-claimed
  find "$scratch/u5-claimed" "$U/.git/worktrees/u5-claimed" -exec touch -h -t 202601010000 {} +
  printf '{"type": "worktree", "path": "%s", "by": "git worktree add", "host": [%s, "x"]}\n' "$scratch/u5-claimed" "$gone" \
    > "$u5records/.garbled.jsonl.sweep-$gone"
  mkdir -p "$scratch/u5-ps"
  printf '#!/usr/bin/env bash\n[[ "$*" == "-o lstart= -p %s" ]] && { echo "not a date"; exit 0; }\nexec %s "$@"\n' "$garbled" "$(command -v ps)" \
    > "$scratch/u5-ps/ps" && chmod +x "$scratch/u5-ps/ps"
  u5_sweep PATH="$scratch/u5-ps:$PATH"
  [[ -d "$scratch/u5-garbled" && -f "$u5records/garbled.jsonl" && "$u5_out" != *removed* ]] \
    || fail "a ps start that does not parse must keep the record and read no session gone: $u5_out $u5_err"
  [[ "$(grep -c "pid $garbled " <<<"$u5_err")" == 1 && "$u5_err" == *"ps gives 'not a date'"* ]] || fail "one stderr line must name the pid ps gave no start for: $u5_err"
  [[ -f "$u5records/.garbled.jsonl.sweep-$gone" ]] && ! grep -q u5-claimed "$u5records/garbled.jsonl" \
    || fail "a dead sweep's claim must stay while the stamp beside it cannot be told: $(ls -A "$u5records")"
  [[ -d "$scratch/u5-claimed" && "$u5_out" != *u5-claimed* ]] || fail "a worktree named only in a kept claim must count as recorded, not be judged by the heal: $u5_out"
fi
ok "a start that cannot be told keeps its record, and on macOS a dead sweep's claim beside it, and names its pid on stderr once"

# A stamp with no start, as hooks from before it write one: read as before, its
# text exactly against ps here, and written again with its start once it reads live.
sleep 300 >/dev/null 2>&1 & sleepers+=($!); old=$!
sleep 300 >/dev/null 2>&1 & finished=$!; finished_text="$(text_of "$finished")"
kill "$finished"; wait "$finished" 2>/dev/null || true
u5_wt text-live; u5_wt text-gone
hand text-live text-live "$old" "$(text_of "$old")"
hand text-gone text-gone "$finished" "$finished_text"
u5_sweep
[[ -d "$scratch/u5-text-live" && ! -e "$scratch/u5-text-gone" && ! -e "$u5records/text-gone.jsonl" ]] \
  || fail "a text-only stamp must read live for its running process and gone for a finished one: $u5_out $u5_err"
python3 - "$u5records/text-live.jsonl" "$old" "$(text_of "$old")" "$(start_of "$old")" <<'PY' \
  || fail "a live text-only stamp must be written again with its start, dating no resume: $(cat "$u5records/text-live.jsonl")"
import json, sys
lines = [json.loads(line) for line in open(sys.argv[1]).read().splitlines()]
sys.exit(not (len(lines) == 2 and lines[-1] == {"type": "host", "host": [int(sys.argv[2]), sys.argv[3]], "start": json.loads(sys.argv[4])}))
PY
u5_sweep
[[ "$(wc -l < "$u5records/text-live.jsonl")" -eq 2 ]] || fail "a stamp written with its start must not be written again: $(cat "$u5records/text-live.jsonl")"
ok "a text-only stamp reads live for its running process and is written again with its start, once; for a finished pid it reads gone"

# A start that cannot be read at all, from a /proc entry that refuses, a ps that
# does not answer in time or no ps, reads cannot tell, with one stderr line naming
# the pid and the cause; a Claude Code lock whose pid ps cannot read holds. Each
# case runs on either host by setting the reader's platform and timeout.
mkdir -p "$scratch/u5-proc/900001" "$scratch/u5-proc/sys/kernel/random" "$scratch/u5-slow-ps" "$scratch/u5-no-ps"
printf 'b\n' > "$scratch/u5-proc/sys/kernel/random/boot_id"
printf '900001 (sleep) S 1\n' > "$scratch/u5-proc/900001/stat" && chmod 000 "$scratch/u5-proc/900001/stat"
printf '#!/usr/bin/env bash\nsleep 3\n' > "$scratch/u5-slow-ps/ps" && chmod +x "$scratch/u5-slow-ps/ps"
[[ "$(id -u)" == 0 ]] && printf 'note: root reads a file at mode 0, so the unreadable /proc case is skipped\n'
python3 - "$lib" "$scratch" "$(id -u)" 2>"$scratch/u5-read-err" <<'PY' || fail "a start that cannot be read must read cannot tell and a lock hold: $(cat "$scratch/u5-read-err")"
import importlib.util, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("worktree_removal", f"{sys.argv[1]}/worktree_removal.py")
rm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rm)
wr, ps, scratch, path = rm.wr, rm.wr.ps, Path(sys.argv[2]), os.environ["PATH"]
got = {}
if sys.argv[3] != "0":
    ps.LINUX, ps.PROC = True, scratch / "u5-proc"
    got["/proc refuses"] = wr.stamp_state({"host": [900001, "x"], "start": {"boot": "b", "ticks": 1}})
ps.LINUX, ps.PS_SECONDS = False, 0.5
os.environ["PATH"] = f"{scratch / 'u5-slow-ps'}:{path}"
got["ps too slow"] = wr.stamp_state({"host": [900002, "x"], "start": {"epoch": 1}})
os.environ["PATH"] = str(scratch / "u5-no-ps")
got["no ps"] = wr.stamp_state({"host": [900003, "x"], "start": {"epoch": 1}})
got["lock, no ps"] = rm.claude_lock_ended("claude session s1 (pid 900004 start Thu Jan  1 00:00:00 2026)", None)
want = dict({key: ps.CANNOT_TELL for key in got}, **{"lock, no ps": False})
sys.exit(f"{got}; want {want}" if got != want else 0)
PY
for cause in "900002 still runs: ps could not be run (.*timed out" "900003 still runs: ps could not be run (.*No such file" "900004 still runs: ps could not be run (.*No such file"; do
  [[ "$(grep -c "pid $cause" "$scratch/u5-read-err")" == 1 ]] || fail "one stderr line must name the pid and the cause ($cause): $(cat "$scratch/u5-read-err")"
done
if [[ "$(id -u)" != 0 ]]; then
  [[ "$(grep -c "pid 900001 still runs: its /proc entry does not read (.*Permission denied" "$scratch/u5-read-err")" == 1 ]] \
    || fail "one stderr line must name the pid /proc refused and why: $(cat "$scratch/u5-read-err")"
fi
ok "a start /proc refuses, a ps too slow or no ps reads cannot tell with one stderr line naming the pid and the cause; a lock then holds"

# Claude Code's lock names its session's start as C-locale UTC text: within the
# 5 s slack of the pid's start it holds, beyond it the session has ended, and a
# start that does not parse holds.
python3 - "$lib" "$live" "$(LC_ALL=C TZ=UTC ps -o lstart= -p "$live" | awk '{$1=$1};1')" <<'PY' || fail "Claude Code's lock must hold within 5 s of its pid's start and end beyond it"
import calendar, importlib.util, sys, time
spec = importlib.util.spec_from_file_location("worktree_removal", f"{sys.argv[1]}/worktree_removal.py")
rm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rm)
pid, start = sys.argv[2], calendar.timegm(time.strptime(sys.argv[3], "%a %b %d %H:%M:%S %Y"))
ended = lambda text: rm.claude_lock_ended(f"claude session s1 (pid {pid} start {text})", None)
got = {off: ended(time.strftime("%a %b %d %H:%M:%S %Y", time.gmtime(start + off))) for off in (-3, 3, -6, 6)}
got["not a date"] = ended("not a date")
want = {-3: False, 3: False, -6: True, 6: True, "not a date": False}
sys.exit(f"ended by the lock's start: {got}; want {want}" if got != want else 0)
PY
ok "Claude Code's lock holds while its start lies within 5 s of its pid's, ends beyond that, and holds when its start does not parse"

printf 'PASS: session-end worktree teardown\n'
