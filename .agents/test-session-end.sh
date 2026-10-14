#!/usr/bin/env bash
# Firing tests for worktree teardown: teardown-gate.sh records each worktree a
# tool call makes, lists it as due after a push, and session-end.sh removes it
# when the session ends — saving unsaved work first, and leaving locked,
# occupied and foreign worktrees alone.
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

# A repository carrying the scaffold pieces the hooks and the controller run.
R="$scratch/repo"
mkdir -p "$R/.agents/hooks" "$R/.agents/claude" "$R/src"
cp -R "$repo/.agents/hooks/lib" "$repo/.agents/hooks/policy" "$R/.agents/hooks/"
cp "$repo/.agents/workloop.py" "$repo/.agents/workloop_git.py" "$repo/.agents/workloop_docker.py" \
   "$repo/.agents/provision.sh" "$R/.agents/"
cp "$repo/.agents/claude/adapter.sh" "$repo/.agents/claude/normalize-hook.py" "$R/.agents/claude/"
mkdir -p "$R/.claude/hooks" && ln -s ../../.agents/claude/adapter.sh "$R/.claude/hooks/adapter.sh"
printf '.agents/\n.claude/\n*.log\n' > "$R/.gitignore"
printf 'one\n' > "$R/src/app.txt"
git -C "$R" init -q -b main
git -C "$R" add .gitignore src
git -C "$R" commit -qm init
records="$R/.agents/worktrees/.records"

gate() {  # <cwd> <normalized payload json> -> stdout; sets rc and err
  set +e
  out="$(cd "$1" && printf '%s' "$2" | bash "$R/.agents/hooks/policy/teardown-gate.sh" 2>"$scratch/err")"
  rc=$?
  set -e
  err="$(<"$scratch/err")"
}
bash_call() {  # <cwd> <command>: runs the command, then hands it to the gate
  (cd "$1" && eval "$2") >/dev/null 2>&1 || true
  gate "$1" "$(printf '{"project_dir":"%s","event":"PostToolUse","session_id":"s1","tool_name":"Bash","tool_input":{"command":%s}}' \
    "$R" "$(printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")"
}
stop() {
  gate "$R" "$(printf '{"project_dir":"%s","event":"Stop","session_id":"s1","stop_hook_active":false}' "$R")"
}
end_session() {  # through the Claude adapter, as the SessionEnd registration runs it
  # The adapter passes the policy no session id; Claude Code's environment does.
  report="$(printf '{"hook_event_name":"SessionEnd","reason":"prompt_input_exit","session_id":"s1","cwd":"%s"}' "$R" \
    | CLAUDE_CODE_SESSION_ID=s1 CLAUDE_PROJECT_DIR="$R" bash "$R/.claude/hooks/adapter.sh" session-end.sh 2>&1)"
}
recorded() { cat "$records"/*.jsonl 2>/dev/null | grep -c "\"path\": \"$1\"" || true; }

# ── made by git worktree add, and recorded ───────────────────────────────────
bash_call "$R" 'git worktree add -q ../wt-clean -b clean'
[[ "$(recorded "$scratch/wt-clean")" == 1 ]] || fail "git worktree add was not recorded: $(cat "$records"/*.jsonl 2>&1)"
[[ "$out" == *"Made a worktree: $scratch/wt-clean"* ]] || fail "no reminder for the new worktree: $out"
# A relative path after a cd resolves where the shell ran it.
bash_call "$R/src" 'cd .. && git worktree add -q ../wt-dirty -b dirty'
[[ "$(recorded "$scratch/wt-dirty")" == 1 ]] || fail "a worktree added after a cd was not recorded"
# Mentioning the command makes nothing.
bash_call "$R" 'echo "git worktree add ../nothing"'
[[ "$(recorded "$scratch/nothing")" == 0 ]] || fail "an echo was recorded"
ok "git worktree add is recorded, with its path resolved where it ran"

# ── made by EnterWorktree and by an isolated Agent cell ──────────────────────
git -C "$R" worktree add -q "$R/.claude/worktrees/feat" -b worktree-feat
gate "$R/.claude/worktrees/feat" "$(printf '{"project_dir":"%s","event":"PostToolUse","session_id":"s1","tool_name":"EnterWorktree","tool_input":{"name":"feat"}}' "$R")"
[[ "$(recorded "$R/.claude/worktrees/feat")" == 1 ]] || fail "EnterWorktree was not recorded"
git -C "$R" worktree add -q "$R/.claude/worktrees/agent-a1b2" -b worktree-agent-a1b2
gate "$R/.claude/worktrees/agent-a1b2" "$(printf '{"project_dir":"%s","event":"SubagentStart","session_id":"s1"}' "$R")"
[[ "$(recorded "$R/.claude/worktrees/agent-a1b2")" == 1 ]] || fail "an isolated cell's worktree was not recorded"
# Entering an existing worktree by path makes nothing; nor does a cell started
# in a worktree Claude did not make for it.
gate "$scratch/wt-clean" "$(printf '{"project_dir":"%s","event":"PostToolUse","session_id":"s1","tool_name":"EnterWorktree","tool_input":{"path":"%s"}}' "$R" "$scratch/wt-clean")"
gate "$scratch/wt-clean" "$(printf '{"project_dir":"%s","event":"SubagentStart","session_id":"s1"}' "$R")"
[[ "$(recorded "$scratch/wt-clean")" == 1 ]] || fail "entering an existing worktree recorded it again"
ok "EnterWorktree and an isolated cell's worktree are recorded"

# ── made by workloop.py add-lane, with its run ───────────────────────────────
wl="python3 $R/.agents/workloop.py --state $R/.agents/.workloop-state.json"
bash_call "$R" "$wl init t1 --objective o --acceptance a --repo $R"
bash_call "$R" "$wl add-lane t1 l1 --worker w --path src"
lane="$R/.agents/worktrees/t1/l1"
[[ -d "$lane" ]] || fail "add-lane made no worktree"
[[ "$(recorded "$lane")" == 1 ]] || fail "add-lane was not recorded"
grep -q '"run": "t1", "state"' "$records"/*.jsonl || fail "the run was not recorded with its lead"
ok "workloop.py add-lane is recorded, and its run with this session as lead"

# ── due once a push follows ─────────────────────────────────────────────────
stop
[[ "$rc" -eq 0 ]] || fail "a worktree before any push must not block: $err"
bash_call "$R" 'git push --dry-run origin main'
stop
[[ "$rc" -eq 0 ]] || fail "a dry-run push made worktrees due: $err"
gate "$R" "$(printf '{"project_dir":"%s","event":"PostToolUse","session_id":"s1","tool_name":"Bash","tool_input":{"command":"git push origin main"}}' "$R")"
stop
[[ "$rc" -eq 2 ]] || fail "a push must make the worktrees due"
[[ "$err" == *"git worktree remove $scratch/wt-clean"* ]] || fail "the block must name git worktree remove: $err"
[[ "$err" == *"workloop.py teardown t1"* ]] || fail "the block must name workloop.py teardown for a lane: $err"
ok "a push makes recorded worktrees due, naming git worktree remove or workloop.py teardown"

# ── the end of the session ───────────────────────────────────────────────────
printf 'two\n' > "$scratch/wt-dirty/src/app.txt"
printf 'new\n' > "$scratch/wt-dirty/src/untracked.txt"
printf 'noise\n' > "$scratch/wt-dirty/build.log"
printf 'lane work\n' > "$lane/src/lane.txt"
# A worktree someone locked, one a process works in, and another repository's.
bash_call "$R" 'git worktree add -q ../wt-locked -b locked'
git -C "$R" worktree lock "$scratch/wt-locked" --reason "keep for review"
bash_call "$R" 'git worktree add -q ../wt-busy -b busy'
(cd "$scratch/wt-busy" && exec sleep 120) >/dev/null 2>&1 &
sleepers+=($!)
O="$scratch/other"
git init -q -b main "$O" && git -C "$O" commit -q --allow-empty -m init
git -C "$O" worktree add -q "$scratch/other-wt" -b side
# Another session of this repository made one too; this session's end leaves it.
git -C "$R" worktree add -q "$scratch/wt-s2" -b s2
gate "$R" "$(printf '{"project_dir":"%s","event":"PostToolUse","session_id":"s2","tool_name":"Bash","tool_input":{"command":"git worktree add -q ../wt-s2 -b s2"}}' "$R")"
[[ -f "$records/s2.jsonl" ]] || fail "the second session's worktree was not recorded"
for _ in $(seq 50); do lsof -a -p "${sleepers[0]}" -d cwd >/dev/null 2>&1 && break; sleep 0.1; done

start=$(python3 -c 'import time; print(time.time())')
end_session
elapsed=$(python3 -c "import time; print('%.2f' % (time.time() - $start))")
[[ -n "${SESSION_END_TEST_VERBOSE:-}" ]] && printf '%s\n' "$report"
[[ ! -e "$scratch/wt-clean" ]] || fail "a clean worktree must be removed at the session end: $report"
git -C "$R" rev-parse -q --verify refs/heads/clean >/dev/null && fail "a merged branch must be deleted"
[[ ! -e "$R/.claude/worktrees/feat" && ! -e "$R/.claude/worktrees/agent-a1b2" ]] || fail "EnterWorktree and cell worktrees must go: $report"
ok "a clean worktree is removed at the session end, its merged branch deleted (${elapsed}s for all)"

[[ ! -e "$scratch/wt-dirty" ]] || fail "a dirty worktree must be removed once saved: $report"
[[ "$(git -C "$R" show saved/wt-dirty:src/app.txt)" == two ]] || fail "the saved branch lacks the tracked change"
[[ "$(git -C "$R" show saved/wt-dirty:src/untracked.txt)" == new ]] || fail "the saved branch lacks the untracked file"
git -C "$R" cat-file -e saved/wt-dirty:build.log 2>/dev/null && fail "the saved branch must not carry ignored files"
[[ "$report" == *"saved/wt-dirty"* ]] || fail "the report must name the saved branch: $report"
ok "a dirty worktree is committed to saved/<name>, ignored files left out, then removed"

[[ ! -e "$lane" ]] || fail "the run's lane must be removed: $report"
python3 -c "import json,sys; sys.exit('t1' in json.load(open('$R/.agents/.workloop-state.json'))['runs'])" \
  || fail "the run the session led must be closed"
[[ "$(git -C "$R" show saved/l1:src/lane.txt)" == "lane work" ]] || fail "the lane's unsaved work must be saved: $report"
ok "a workloop run ends with its lead: lanes saved and removed, the run closed"

[[ -d "$scratch/wt-locked" ]] || fail "a locked worktree must stay"
[[ "$report" == *"kept $scratch/wt-locked: it is locked (keep for review)"* ]] || fail "the locked worktree must be named: $report"
[[ -d "$scratch/wt-busy" ]] || fail "a worktree a process works in must stay"
[[ "$report" == *"kept $scratch/wt-busy: process ${sleepers[0]} is working in it"* ]] || fail "the busy worktree must be named: $report"
[[ -d "$scratch/other-wt" ]] || fail "another repository's worktree must stay"
[[ -d "$scratch/wt-s2" && -f "$records/s2.jsonl" ]] || fail "another session's worktree and record must stay"
[[ "$(recorded "$scratch/wt-busy")" == 1 && "$(recorded "$scratch/wt-locked")" == 0 ]] \
  || fail "the busy worktree stays recorded for the next sweep; the locked one does not: $(cat "$records"/*.jsonl)"
ok "locked, occupied, foreign and other sessions' worktrees stay, each named"

# ── a failed save stops the removal ──────────────────────────────────────────
git -C "$R" config user.useConfigOnly true
bash_call "$R" 'git worktree add -q ../wt-nosave -b nosave'
printf 'x\n' > "$scratch/wt-nosave/src/x.txt"
(
  unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  export HOME="$scratch/home" XDG_CONFIG_HOME="$scratch/home" GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME"
  printf '{"hook_event_name":"SessionEnd","cwd":"%s"}' "$R" \
    | CLAUDE_CODE_SESSION_ID=s1 CLAUDE_PROJECT_DIR="$R" bash "$R/.claude/hooks/adapter.sh" session-end.sh 2>"$scratch/nosave"
)
[[ -f "$scratch/wt-nosave/src/x.txt" ]] || fail "a worktree whose save failed must stay: $(cat "$scratch/nosave")"
grep -q "kept $scratch/wt-nosave: its unsaved work could not be committed" "$scratch/nosave" || fail "the failed save must be named: $(cat "$scratch/nosave")"
ok "a worktree whose unsaved work cannot be committed stays"

printf 'PASS: session-end worktree teardown\n'
