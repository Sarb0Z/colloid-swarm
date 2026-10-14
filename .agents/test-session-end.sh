#!/usr/bin/env bash
# Firing tests for worktree teardown: teardown-gate.sh records each worktree a
# tool call creates, lists it as due after a push, and session-end.sh removes
# it when the session ends — saving unsaved work first, and leaving locked,
# occupied, nested and other sessions' worktrees alone.
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
cd "$scratch"

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
$wl init t0 --objective o --acceptance a --repo "$R" >/dev/null
bash_call "$R" "$wl init t0 --objective o --acceptance a --repo $R | tail -1"
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
git -C "$R" worktree add -q "$R/.claude/worktrees/agent-a1b2" -b worktree-agent-a1b2
gate "$(printf '{"hook_event_name":"SubagentStart","cwd":"%s","session_id":"s1","agent_id":"a1b2"}' "$R/.claude/worktrees/agent-a1b2")"
[[ "$(recorded "$R/.claude/worktrees/agent-a1b2")" == 1 ]] || fail "an isolated cell's worktree was not recorded"
gate "$(printf '{"hook_event_name":"SubagentStart","cwd":"%s","session_id":"s1"}' "$scratch/wt-operator")"
[[ "$(recorded "$scratch/wt-operator")" == 0 ]] || fail "a cell started in someone's worktree recorded it"
ok "EnterWorktree and an isolated cell's worktree are recorded from the payload's folder"

bash_call "$R" "$wl init t1 --objective o --acceptance a --repo $R"
bash_call "$R" "$wl add-lane t1 l1 --worker w --path src"
lane="$R/.agents/worktrees/t1/l1"
[[ -d "$lane" && "$(recorded "$lane")" == 1 ]] || fail "add-lane was not recorded"
grep -q '"run": "t1", "state"' "$records"/*.jsonl || fail "the run was not recorded with its lead"
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
printf 'noise\n' > "$scratch/wt-dirty/build.log"
printf 'lane work\n' > "$lane/src/lane.txt"
for name in locked claude-dead claude-live busy here nested ignored-nested; do bash_call "$R" "git worktree add -q ../wt-$name -b $name"; done
git -C "$R" worktree lock "$scratch/wt-locked" --reason "keep for review"
sleep 300 >/dev/null 2>&1 & gone=$!
gone_start="$(utc_start "$gone")"; kill "$gone"; wait "$gone" 2>/dev/null || true
git -C "$R" worktree lock "$scratch/wt-claude-dead" --reason "claude session claude-dead (pid $gone start $gone_start)"
sleep 300 >/dev/null 2>&1 & sleepers+=($!)
git -C "$R" worktree lock "$scratch/wt-claude-live" --reason "claude session claude-live (pid ${sleepers[0]} start $(utc_start "${sleepers[0]}"))"
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

start=$(python3 -c 'import time; print(time.time())')
end_session other "$scratch/wt-here"
elapsed=$(python3 -c "import time; print('%.2f' % (time.time() - $start))")
[[ -n "${SESSION_END_TEST_VERBOSE:-}" ]] && printf '%s\n' "$report"
[[ ! -e "$scratch/wt-clean" ]] || fail "a clean worktree must be removed: $report"
git -C "$R" rev-parse -q --verify refs/heads/clean >/dev/null && fail "a merged branch must be deleted"
[[ ! -e "$R/.claude/worktrees/feat" && ! -e "$R/.claude/worktrees/agent-a1b2" ]] || fail "EnterWorktree and cell worktrees must go: $report"
ok "a clean worktree is removed at the session end, its merged branch deleted (${elapsed}s for all)"
[[ ! -e "$scratch/wt-here" ]] || fail "the worktree the hook runs in must not read busy from lsof itself: $report"
ok "the worktree the session-end hook runs in is removed: lsof does not count itself"
[[ ! -e "$scratch/wt-dirty" && "$(git -C "$R" show saved/wt-dirty:src/app.txt)" == two ]] || fail "a dirty worktree must be saved, then removed: $report"
[[ "$(git -C "$R" show saved/wt-dirty:src/untracked.txt)" == new ]] || fail "the saved branch lacks the untracked file"
git -C "$R" cat-file -e saved/wt-dirty:build.log 2>/dev/null && fail "the saved branch must not carry ignored files"
ok "a dirty worktree is committed to saved/<name>, ignored files left out, then removed"
[[ ! -e "$lane" && "$(git -C "$R" show saved/l1:src/lane.txt)" == "lane work" ]] || fail "the run's lane must be saved and removed: $report"
python3 -c "import json,sys; sys.exit('t1' in json.load(open('$R/.agents/.workloop-state.json'))['runs'])" || fail "the run must be closed"
ok "a workloop run ends with its lead: lanes saved and removed, the run closed"
[[ ! -e "$scratch/other-made" && -d "$scratch/other-wt" ]] || fail "this session's worktree in another repository goes; an unrecorded one there stays: $report"
ok "a worktree this session made in another repository goes at its end; that repository's others stay"
[[ ! -e "$scratch/wt-claude-dead" ]] || fail "Claude Code's lock of an ended session must not keep its worktree: $report"
[[ -d "$scratch/wt-claude-live" && "$report" == *"kept $scratch/wt-claude-live: it is locked (claude session"* ]] || fail "a running session's Claude lock keeps it: $report"
[[ -d "$scratch/wt-locked" && "$report" == *"kept $scratch/wt-locked: it is locked (keep for review)"* ]] || fail "a locked worktree must stay: $report"
ok "Claude Code's session lock keeps a worktree only while its session runs; any other lock keeps it"
[[ -d "$scratch/wt-busy" && "$report" == *"kept $scratch/wt-busy: process ${sleepers[1]} is working in it"* ]] || fail "a busy worktree must stay: $report"
[[ -d "$scratch/wt-nested/vendor/.git" && "$report" == *"kept $scratch/wt-nested: it holds a nested repository"* ]] || fail "a nested repository must keep its worktree: $report"
[[ -f "$scratch/wt-ignored-nested/deps.log/inner/file.txt" && "$report" == *"kept $scratch/wt-ignored-nested: it holds a nested repository"* ]] \
  || fail "a repository inside an ignored folder must never be parked: $report"
[[ -d "$scratch/wt-s2b" && -f "$records/s2.jsonl" && -d "$scratch/wt-s2" ]] || fail "another session's worktrees must stay"
[[ "$(recorded "$scratch/wt-busy")" == 1 && "$(recorded "$scratch/wt-locked")" == 0 ]] || fail "busy stays recorded for the next sweep; locked does not"
ok "occupied, nested, ignored-nested and other sessions' worktrees stay, each named"

# ── without lsof every worktree reads busy ──────────────────────────────────
bash_call "$R" 'git worktree add -q ../wt-nolsof -b nolsof'
report="$(printf '{"hook_event_name":"SessionEnd","reason":"other","session_id":"s1"}' \
  | PATH=/opt/homebrew/bin:/usr/bin:/bin CLAUDE_PROJECT_DIR="$R" bash "$R/.claude/hooks/adapter.sh" session-end.sh 2>&1)"
[[ -d "$scratch/wt-nolsof" && "$report" == *"kept $scratch/wt-nolsof: lsof is missing or failed"* ]] || fail "a missing lsof must keep the worktree: $report"
ok "a missing lsof keeps the worktree rather than reading it empty"

# ── EnterWorktree at /exit: the answer to Claude Code's prompt stands ───────
rm -f "$records"/s1.jsonl
for name in kept answered-none; do
  calls=$((calls + 1))
  tool PreToolUse "$R" EnterWorktree "{\"name\":\"$name\"}"
  git -C "$R" worktree add -q "$R/.claude/worktrees/$name" -b "worktree-$name"
  tool PostToolUse "$R/.claude/worktrees/$name" EnterWorktree "{\"name\":\"$name\"}"
done
me="$(cd "$R/.agents/hooks/lib" && python3 -c 'import worktree_records as w; print(w.host()[0])')"
git -C "$R" worktree lock "$R/.claude/worktrees/answered-none" --reason "claude session answered-none (pid $me start $(utc_start "$me"))"
printf 'x\n' > "$R/.claude/worktrees/kept/x.txt"
end_session prompt_input_exit
[[ -f "$R/.claude/worktrees/kept/x.txt" && "$report" == *"kept $R/.claude/worktrees/kept: kept at Claude Code's exit prompt"* ]] \
  || fail "a worktree the operator kept at the exit prompt must stay: $report"
[[ ! -e "$R/.claude/worktrees/answered-none" ]] || fail "one still under this session's own lock was never answered for, so it goes: $report"
[[ "$(recorded "$R/.claude/worktrees/kept")" == 0 ]] || fail "the kept worktree's record must go"
ok "after /exit, a worktree kept at Claude Code's prompt stays; one under the ending session's own lock goes"

# ── /clear ends the conversation's worktrees; a live writer keeps its run ──
bash_call "$R" "$wl init t2 --objective o --acceptance a --repo $R"
bash_call "$R" "$wl add-lane t2 l2 --worker w --path src"
$wl claim t2 l2 --agent cellA >/dev/null
printf 'cellA\tgeneral-purpose\tp1\n' > "$R/.agents/.writers-live-s1"
bash_call "$R" 'git worktree add -q ../wt-clear -b clear'
end_session clear
[[ ! -e "$scratch/wt-clear" ]] || fail "/clear must end the conversation's worktrees: $report"
[[ -d "$R/.agents/worktrees/t2/l2" && "$report" == *"kept workloop run t2: lane l2's writer cell cellA is still live"* ]] || fail "a live writer keeps its run: $report"
grep -q '"type": "ended"' "$records/s1.jsonl" || fail "what stays must be marked ended for the next sweep"
rm "$R/.agents/.writers-live-s1"
sweep_out="$(cd "$R/.agents/hooks/lib" && python3 worktree_sweep.py sweep "$R" s9 "$R/.agents/workloop.py")"
[[ ! -e "$R/.agents/worktrees/t2/l2" && "$sweep_out" == *"closed workloop run t2"* ]] || fail "the next sweep must take the run once the cell ended: $sweep_out"
ok "/clear ends the conversation's worktrees; a run with a live writer stays until the next sweep after it"

# ── a failed save stops the removal ──────────────────────────────────────────
git -C "$R" config user.useConfigOnly true
bash_call "$R" 'git worktree add -q ../wt-nosave -b nosave'
printf 'x\n' > "$scratch/wt-nosave/src/x.txt"
(
  unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  export HOME="$scratch/home" XDG_CONFIG_HOME="$scratch/home" GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME"
  end_session other
  printf '%s' "$report" > "$scratch/nosave"
)
[[ -f "$scratch/wt-nosave/src/x.txt" ]] || fail "a worktree whose save failed must stay: $(cat "$scratch/nosave")"
grep -q "kept $scratch/wt-nosave: its unsaved work could not be committed" "$scratch/nosave" || fail "the failed save must be named: $(cat "$scratch/nosave")"
ok "a worktree whose unsaved work cannot be committed stays"

printf 'PASS: session-end worktree teardown\n'
