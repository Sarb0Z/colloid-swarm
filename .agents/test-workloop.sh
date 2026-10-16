#!/usr/bin/env bash
set -euo pipefail
# A caller such as `git rebase -x` exports these; the git calls below must
# reach only their own temporary repositories.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
state="$scratch/state.json"
work="$scratch/work"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }
# Capture then grep: a `| grep -q` under pipefail fails when grep exits on the
# first match and the writer takes SIGPIPE.
expect() { local pat="$1"; shift; local out; out="$("$@" 2>&1)" || true; grep -q -- "$pat" <<<"$out" || fail "expected '$pat' from: $* — got: $out"; }

# A recording npm so provision.sh runs its real path without a registry.
mkdir -p "$scratch/bin"
cat > "$scratch/bin/npm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NPM_LOG:?}"
exit 0
EOF
chmod +x "$scratch/bin/npm"
export PATH="$scratch/bin:$PATH" NPM_LOG="$scratch/npm.log"

# A recording docker so reaping is observed without a daemon: `ps -aq` with a
# colloid label filter answers with canned ids, everything else is logged.
cat > "$scratch/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
case "$*" in
  "ps -aq --filter label=colloid.run="*"--filter label=colloid.lane="*) printf 'c1\nc2\n' ;;
  "network ls -q --filter label=colloid.run="*) printf 'n1\n' ;;
  "ps -aq --filter label=com.docker.compose.project=res-plain") printf 'compose1\n' ;;
  "ps -aq --filter label=com.docker.compose.project=res-x") printf 'stranger\n' ;;
  "volume ls -q --filter label=colloid.run=res --filter label=colloid.lane=plain") printf 'v1\n' ;;
  "volume rm -f v1") echo "volume is in use" >&2; exit 1 ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$scratch/bin/docker"
export DOCKER_LOG="$scratch/docker.log"

git init -q "$work"
git -C "$work" config user.email test@example.com
git -C "$work" config user.name test
mkdir -p "$work/src" "$work/tests"
printf 'base\n' > "$work/src/app.txt"
printf '{"name":"fixture","lockfileVersion":3}\n' > "$work/package-lock.json"
printf 'node_modules/\n' > "$work/.gitignore"
git -C "$work" add . && git -C "$work" commit -qm base
base="$(git -C "$work" rev-parse HEAD)"
tool=(python3 "$repo/.agents/workloop.py" --state "$state")
# `brief` prints a short dispatch prompt and writes the full brief to a file
# in the lane's worktree; this prints that file.
full_brief() { local out file; out="$("${tool[@]}" brief "$@")"; file="$(sed -n 's/^Read the full brief at \(.*\) before anything else.*$/\1/p' <<<"$out")"; [[ -f "$file" ]] || fail "brief wrote no file: $out"; cat "$file"; }
commit() { git -C "$1" add -A && git -C "$1" -c user.email=t@e.com -c user.name=t commit -qm "$2"; }
# A main lane stages by path: the checkout may hold others' uncommitted work.
commit_paths() { git -C "$1" add -- "${@:3}" && git -C "$1" -c user.email=t@e.com -c user.name=t commit -qm "$2"; }
tip_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runs"][sys.argv[2]]["lanes"][sys.argv[3]].get("tip") or "")' "$state" "$1" "$2"; }
# An accepting review names the commit it read, as the reviewer brief prints it.
accept() { local run="$1" lane="$2" ref="$3"; shift 3; "${tool[@]}" review "$run" "$lane" --reference "$ref" --result accept --tip "$(tip_of "$run" "$lane")" "$@"; }
# The parallel-writers gate's reading of a dispatch prompt (line 9 of writers-payload.py),
# with the current state copied under the project root it reads from, then removed.
gate_kind() {  # <project root> <prompt>
  mkdir -p "$1/.agents"; cp "$state" "$1/.agents/.workloop-state.json"
  python3 -c 'import json,sys; print(json.dumps({"project_dir": sys.argv[1], "event": "PreToolUse", "tool_name": "Agent", "tool_input": {"prompt": sys.argv[2]}}))' "$1" "$2" | python3 "$repo/.agents/hooks/lib/writers-payload.py" | sed -n 9p
  rm -f "$1/.agents/.workloop-state.json"
}

# ── base is pinned, verify is guarded ────────────────────────────────────────
"${tool[@]}" --event-id init-demo init demo --objective 'prove coordination' --acceptance 'all lanes reviewed and QA observed' --repo "$work" --base HEAD --verify 'grep -q change src/app.txt'
expect 'replayed event' "${tool[@]}" --event-id init-demo init demo --objective 'ignored replay' --acceptance ignored --repo "$work" --verify true
expect '\-\-lane needs --verify' "${tool[@]}" init noverify --objective x --acceptance y --repo "$work" --lane solo --worker implementer --path src
if "${tool[@]}" status noverify >/dev/null 2>&1; then fail 'a refused init --lane without --verify left the run in state'; fi
python3 - "$state" <<'EOF'
import json, re, sys
base = json.load(open(sys.argv[1]))["runs"]["demo"]["base"]
assert re.fullmatch(r"[0-9a-f]{40}", base), base
EOF
ok "init resolves --base HEAD to a commit SHA and requires --verify with --lane"
if "${tool[@]}" init pushy --objective x --acceptance y --repo "$work" --verify 'git push origin main' 2>/dev/null; then fail 'a publishing verify command was accepted'; fi
if "${tool[@]}" init nuke --objective x --acceptance y --repo "$work" --verify 'rm -rf /' 2>/dev/null; then fail 'a destructive verify command was accepted'; fi
ok "verify commands pass the destructive and publish guards"

# ── single lane: add-lane creates and provisions the worktree ────────────────
lane="$scratch/lane-impl"
"${tool[@]}" add-lane demo implementation --worker implementer --workspace "$lane" --path src --path tests --path docs
[[ -d "$lane/src" ]] || fail 'add-lane did not create the worktree'
[[ "$(git -C "$lane" symbolic-ref --short HEAD)" == "demo/implementation" ]] || fail 'lane branch is not <run>/<lane>'
grep -q 'ci --ignore-scripts' "$NPM_LOG" || fail 'add-lane did not provision the worktree'
ok "add-lane creates the worktree on its own branch and provisions it"

"${tool[@]}" claim demo implementation --agent worker-1
printf 'change\n' >> "$lane/src/app.txt"
if "${tool[@]}" submit demo implementation --evidence 'uncommitted' 2>/dev/null; then fail 'submit accepted uncommitted work'; fi
ok "submit refuses a dirty worktree"
commit "$lane" change
"${tool[@]}" submit demo implementation --evidence 'unit test passed'
mkdir -p "$lane/docs/reviews"
printf 'review evidence\n' > "$lane/docs/reviews/demo.md"
commit "$lane" review
if "${tool[@]}" review demo implementation --reference docs/reviews/missing.md#pass --result reopen --severity P1 2>/dev/null; then fail 'missing review reference was accepted'; fi
"${tool[@]}" review demo implementation --reference docs/reviews/demo.md#pass --result reopen --severity P1 --message 'add coverage'
if "${tool[@]}" qa demo --evidence nope 2>/dev/null; then fail 'QA passed a reopened lane'; fi
"${tool[@]}" ack demo implementation --agent worker-1
mkdir -p "$lane/tests"; printf 'test\n' > "$lane/tests/app.txt"
commit "$lane" tests
"${tool[@]}" submit demo implementation --evidence 'unit and regression tests passed'
accept demo implementation docs/reviews/demo.md#accepted
"${tool[@]}" qa demo --evidence 'independent scenario passed'
expect 'integration:missing' "${tool[@]}" check demo
expect 'PASS: integrated implementation' "${tool[@]}" integrate demo --workspace "$scratch/integration-demo"
expect PASS "${tool[@]}" check demo
expect $'implementation\treviewed' "${tool[@]}" status demo
ok "a single worktree lane's composed test runs through integrate before check passes"

# ── lanes default to .agents/worktrees inside the checkout ───────────────────
real_work="$(cd "$work" && pwd -P)"
"${tool[@]}" init unignored --objective x --acceptance y --repo "$work" --verify true
expect "does not ignore .agents/worktrees/" "${tool[@]}" add-lane unignored one --worker implementer --path src
"${tool[@]}" abandon unignored --discard-branches >/dev/null
ok "a checkout that does not ignore .agents/worktrees/ is warned at add-lane"
printf '.agents/worktrees/\n' >> "$work/.gitignore"; commit "$work" 'ignore nested worktrees'
"${tool[@]}" init nest --objective x --acceptance y --repo "$work" --verify 'test -f src/app.txt && test -f tests/t.txt' --shared docs/shared
out="$("${tool[@]}" add-lane nest one --worker implementer --path src --path docs/one 2>&1)" || fail "default add-lane failed: $out"
[[ "$out" != *WARNING* ]] || fail "an ignored worktree folder was warned about: $out"
"${tool[@]}" add-lane nest two --worker implementer --path tests --path docs/two >/dev/null 2>&1
n1="$real_work/.agents/worktrees/nest/one"; n2="$real_work/.agents/worktrees/nest/two"
[[ -f "$n1/src/app.txt" && "$(git -C "$n1" rev-parse --show-toplevel)" == "$n1" ]] || fail "the default lane is not a worktree at $n1"
[[ "$(git -C "$n1" symbolic-ref --short HEAD)" == "nest/one" ]] || fail "the default lane is not on nest/one"
[[ -z "$(git -C "$work" status --porcelain --untracked-files=all)" ]] || fail "nested lanes dirty the checkout: $(git -C "$work" status --porcelain)"
expect "Workspace: $n1 " full_brief nest one
ok "add-lane without --workspace places the lane at .agents/worktrees/<run>/<lane>, and git status stays clean"

# a workspace under /tmp is refused, naming the default; unless the checkout itself lies there
python3 - "$repo/.agents" <<'PY' || fail "the /tmp rule is wrong"
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import workloop
assert workloop.temporary(Path("/tmp/x")) and workloop.temporary(Path("/private/tmp/a/b")), "a /tmp path is not temporary"
assert not workloop.temporary(Path("/tmpfoo/x")) and not workloop.temporary(Path("/home/u/repo")), "a non-/tmp path is temporary"
for value in ("/tmp/lane", "/private/tmp/lane"):
    try:
        workloop.workspace_for(value, Path("/home/u/repo"), "r", "l", "lane")
        raise AssertionError(f"{value} was accepted beside a checkout outside /tmp")
    except SystemExit as exc:
        assert "/home/u/repo/.agents/worktrees/r/l" in str(exc), exc
assert workloop.workspace_for("/private/tmp/lane", Path("/private/tmp/repo"), "r", "l", "lane") == Path("/private/tmp/lane").resolve()
PY
# A checkout that itself lives in a temporary folder (mktemp on Linux CI, or
# $TMPDIR on macOS) may keep its lanes there, so only check the refusal outside one.
if python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import workloop; from pathlib import Path; sys.exit(workloop.temporary(Path(sys.argv[2]).resolve()))' "$repo/.agents" "$real_work"; then
  expect "lies in a temporary folder, which the system clears; omit --workspace to use the default $real_work/.agents/worktrees/nest/three" \
    "${tool[@]}" add-lane nest three --worker implementer --workspace "/tmp/colloid-lane-$$" --path lib
  [[ ! -e "/tmp/colloid-lane-$$" ]] || fail "a refused /tmp workspace was created"
fi
ok "a lane workspace under /tmp is refused, naming the default"

# widen grows owned paths and refuses another lane's or a shared path
expect 'widened lane .one.: owned + lib' "${tool[@]}" widen nest one --path ./lib/
expect $'one\tready\tpending=0\timplementer\tsrc, docs/one, lib' "${tool[@]}" status nest
expect "paths overlap lane 'two'" "${tool[@]}" widen nest one --path tests/extra.txt
expect 'overlap a shared path' "${tool[@]}" widen nest one --path docs/shared/a.md
expect 'overlap a shared path' "${tool[@]}" widen nest one --path docs
expect 'already covers src/deep' "${tool[@]}" widen nest one --path src/deep
expect 'is a full checkout; --also widens a sparse' "${tool[@]}" widen nest one --also tests
expect 'widen needs --path or --also' "${tool[@]}" widen nest one
expect $'one\tready\tpending=0\timplementer\tsrc, docs/one, lib' "${tool[@]}" status nest
ok "widen adds an owned path, refuses another lane's or a shared path, and reports what it changed"
"${tool[@]}" init nestsp --objective x --acceptance y --repo "$work" --verify true
"${tool[@]}" add-lane nestsp sp --worker implementer --path brand-new --sparse >/dev/null 2>&1
nsp="$real_work/.agents/worktrees/nestsp/sp"
[[ -f "$nsp/package-lock.json" && ! -e "$nsp/src" ]] || fail "the sparse lane is wrong before widen: $(ls "$nsp")"
expect 'widened lane .sp.: owned + gen; cone + gen, src' "${tool[@]}" widen nestsp sp --path gen --also src
[[ -f "$nsp/src/app.txt" ]] || fail "widen --also did not check src out in the sparse lane"
expect 'Sparse cone: brand-new, gen, src' full_brief nestsp sp
mkdir -p "$nsp/gen"; printf 'g\n' > "$nsp/gen/g.txt"; git -C "$nsp" add gen/g.txt || fail "a widened cone directory could not be staged"
expect 'already covers src/deep' "${tool[@]}" widen nestsp sp --also src/deep
"${tool[@]}" abandon nestsp --discard-branches >/dev/null
ok "widen of a sparse lane adds the directories to its cone and checks them out"

# integrate defaults to .agents/worktrees/<run>/integration
for l in one two; do
  d="$real_work/.agents/worktrees/nest/$l"; "${tool[@]}" claim nest "$l" --agent "$l"
  mkdir -p "$d/tests" "$d/docs/$l"; [[ $l == one ]] && printf 'n\n' >> "$d/src/app.txt" || printf 't\n' > "$d/tests/t.txt"
  printf 'r\n' > "$d/docs/$l/r.md"; commit "$d" "$l"
  "${tool[@]}" submit nest "$l" --evidence ok; accept nest "$l" "docs/$l/r.md#ok"
done
if python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import workloop; from pathlib import Path; sys.exit(workloop.temporary(Path(sys.argv[2]).resolve()))' "$repo/.agents" "$real_work"; then
  expect "integration workspace /tmp/colloid-int-$$ lies in a temporary folder, which the system clears; omit --workspace to use the default $real_work/.agents/worktrees/nest/integration" \
    "${tool[@]}" integrate nest --workspace "/tmp/colloid-int-$$"
fi
expect "PASS: integrated one, two in $real_work/.agents/worktrees/nest/integration" "${tool[@]}" integrate nest
[[ -z "$(git -C "$work" status --porcelain --untracked-files=all)" ]] || fail "the nested integration dirties the checkout: $(git -C "$work" status --porcelain)"
"${tool[@]}" qa nest --evidence ok
expect 'removed 3 worktree(s)' "${tool[@]}" teardown nest
[[ ! -e "$real_work/.agents/worktrees/nest" ]] || fail "teardown left a nested worktree or the run's folder: $(ls -R "$real_work/.agents/worktrees/nest")"
[[ ! -e "$real_work/.agents/worktrees/nestsp" && ! -e "$real_work/.agents/worktrees/unignored" ]] || fail "abandon left a run's folder"
ok "integrate without --workspace composes at .agents/worktrees/<run>/integration and refuses /tmp; teardown removes the nested worktrees"

# ── a lockfile change after provisioning refuses the claim ───────────────────
"${tool[@]}" init stale --objective x --acceptance y --repo "$work" --verify true
stale_lane="$scratch/lane-stale"
"${tool[@]}" add-lane stale one --worker implementer --workspace "$stale_lane" --path src
printf '{"name":"fixture","lockfileVersion":3,"changed":true}\n' > "$stale_lane/package-lock.json"
if "${tool[@]}" claim stale one --agent worker-9 2>/dev/null; then fail 'claim ignored a changed lockfile'; fi
: > "$NPM_LOG"
"${tool[@]}" provision stale one
grep -q 'ci --ignore-scripts' "$NPM_LOG" || fail 'provision did not reinstall'
"${tool[@]}" claim stale one --agent worker-9
ok "a changed lockfile blocks claim until provision reruns"

# an add-lane cut off between its worktree and its install leaves no branch on the lane
"${tool[@]}" init nobranch --objective x --acceptance y --repo "$work" --verify true
nb_lane="$scratch/lane-nobranch"
"${tool[@]}" add-lane nobranch one --worker implementer --workspace "$nb_lane" --path src >/dev/null 2>&1
python3 - "$state" <<'EOF'
import json, sys
data = json.load(open(sys.argv[1]))
data["runs"]["nobranch"]["lanes"]["one"]["branch"] = None
json.dump(data, open(sys.argv[1], "w"))
EOF
"${tool[@]}" provision nobranch one >/dev/null
"${tool[@]}" claim nobranch one --agent worker-nb
printf 'nb\n' >> "$nb_lane/src/app.txt"; printf 'r\n' > "$nb_lane/src/nb.md"; commit "$nb_lane" nb
"${tool[@]}" submit nobranch one --evidence ok
accept nobranch one src/nb.md#ok
out="$("${tool[@]}" integrate nobranch --workspace "$scratch/integration-nobranch" 2>&1)" || fail "integrate refused a lane that provision healed: $out"
[[ "$out" == *"PASS: integrated one"* ]] || fail "integrate did not pass: $out"
ok "provision records a lane's branch when add-lane was cut off before it did"

# ── ownership, attention, stale release ───────────────────────────────────────
"${tool[@]}" init ownership --objective x --acceptance y --repo "$work" --verify true
own="$scratch/lane-own"
"${tool[@]}" add-lane ownership one --worker implementer --workspace "$own" --path src
if "${tool[@]}" add-lane ownership two --worker implementer --workspace "$scratch/lane-two" --path src/app.txt 2>/dev/null; then fail 'overlapping paths were accepted'; fi
"${tool[@]}" claim ownership one --agent worker-2
mkdir -p "$own/docs/reviews"
printf 'attention evidence\n' > "$own/docs/reviews/attention.md"
expect 'does not claim to interrupt' "${tool[@]}" attention ownership one --severity P0 --message 'pause' --reference docs/reviews/attention.md#p0
"${tool[@]}" release-stale ownership one --reason 'lost worker'
if "${tool[@]}" claim ownership one --agent worker-3 2>/dev/null; then fail 'stale release erased pending attention'; fi
"${tool[@]}" ack ownership one --agent worker-2
ok "ownership, attention, and stale release hold"

# ── concurrent add-lane, shared worktree refused ─────────────────────────────
"${tool[@]}" init concurrent --objective x --acceptance y --repo "$work" --verify true
("${tool[@]}" add-lane concurrent first --worker implementer --workspace "$scratch/lane-c1" --path src >/dev/null 2>&1) &
("${tool[@]}" add-lane concurrent second --worker implementer --workspace "$scratch/lane-c2" --path tests >/dev/null 2>&1) &
wait
expect $'first\tready' "${tool[@]}" status concurrent
expect $'second\tready' "${tool[@]}" status concurrent
"${tool[@]}" claim concurrent first --agent worker-3
"${tool[@]}" init shared --objective x --acceptance y --repo "$work" --verify true
"${tool[@]}" add-lane shared a --worker implementer --workspace "$scratch/lane-c1" --path src
"${tool[@]}" add-lane shared b --worker implementer --workspace "$scratch/lane-c1" --path tests
"${tool[@]}" claim shared a --agent worker-4
if "${tool[@]}" claim shared b --agent worker-5 2>/dev/null; then fail 'shared worktree allowed concurrent writes'; fi
ok "concurrent add-lane lands both; a shared worktree cannot be claimed twice"

# ── undeclared path ───────────────────────────────────────────────────────────
"${tool[@]}" init boundary --objective x --acceptance y --repo "$work" --verify true
bnd="$scratch/lane-bnd"
"${tool[@]}" add-lane boundary src-only --worker implementer --workspace "$bnd" --path src
"${tool[@]}" claim boundary src-only --agent worker-5
mkdir -p "$bnd/tests"; printf 'wrong\n' > "$bnd/tests/app.txt"; commit "$bnd" wrong
if "${tool[@]}" submit boundary src-only --evidence 'wrong files' 2>/dev/null; then fail 'undeclared changed path was accepted'; fi
ok "an undeclared changed path is refused"

# ── two lanes: integrate verifies the composed tree once ─────────────────────
verify='test -f src/app.txt && test -f tests/app.txt && grep -q change src/app.txt && grep -q test tests/app.txt'
"${tool[@]}" init multi --objective 'compose' --acceptance 'both files present' --repo "$work" --verify "$verify"
la="$scratch/lane-a"; lb="$scratch/lane-b"
"${tool[@]}" add-lane multi alpha --worker implementer --workspace "$la" --path src --path docs/alpha
"${tool[@]}" add-lane multi beta --worker implementer --workspace "$lb" --path tests --path docs/beta --depends-on alpha
if "${tool[@]}" integrate multi --workspace "$scratch/integration" 2>/dev/null; then fail 'integrate ran before lanes were reviewed'; fi
"${tool[@]}" claim multi alpha --agent a1
printf 'change\n' >> "$la/src/app.txt"; mkdir -p "$la/docs/alpha"; printf 'r\n' > "$la/docs/alpha/review.md"; commit "$la" alpha
# a provisioning link out of the worktree is environment, not a changed path
mkdir -p "$work/node_modules/pkg" "$la/node_modules"; ln -s "$work/node_modules/pkg" "$la/node_modules/pkg"; printf '%s\n' "$work/node_modules" > "$la/node_modules/.colloid-shared"
"${tool[@]}" submit multi alpha --evidence 'alpha ok'
accept multi alpha docs/alpha/review.md#ok
"${tool[@]}" claim multi beta --agent b1
mkdir -p "$lb/tests"; printf 'test\n' > "$lb/tests/app.txt"; mkdir -p "$lb/docs/beta"; printf 'r\n' > "$lb/docs/beta/review.md"; commit "$lb" beta
"${tool[@]}" submit multi beta --evidence 'beta ok'
accept multi beta docs/beta/review.md#ok
"${tool[@]}" qa multi --evidence 'scenarios passed'
if "${tool[@]}" check multi 2>/dev/null; then fail 'a two-lane run passed check without integration'; fi
expect 'integration:missing' "${tool[@]}" check multi
integ="$scratch/integration"
expect "integration workspace is lane 'alpha'" "${tool[@]}" integrate multi --workspace "$la"
expect 'must be a new path or a linked worktree' "${tool[@]}" integrate multi --workspace "$work"
[[ "$(git -C "$la" symbolic-ref --short HEAD)" == "multi/alpha" ]] || fail 'a refused integrate moved the lane worktree'
ok "integrate refuses a lane worktree and the main checkout as its workspace"
expect 'PASS: integrated alpha, beta' "${tool[@]}" integrate multi --workspace "$integ"
[[ "$(git -C "$integ" symbolic-ref --short HEAD)" == "multi/integration" ]] || fail 'integration is not on its branch'
grep -q change "$integ/src/app.txt" && grep -q test "$integ/tests/app.txt" || fail 'integration tree lacks a lane'
expect PASS "${tool[@]}" check multi
ok "integrate merges reviewed lanes in dependency order and check passes; a shared node_modules link never counts as a changed path"

# a lane that moves after integration makes the run stale; re-integrate clears it
printf 'more\n' >> "$la/src/app.txt"; commit "$la" more
expect 'integration:stale:alpha' "${tool[@]}" check multi
expect 'moved after its accepted review' "${tool[@]}" integrate multi --workspace "$integ"
"${tool[@]}" submit multi alpha --evidence 'more'; accept multi alpha docs/alpha/review.md#ok2
expect PASS "${tool[@]}" integrate multi --workspace "$integ"
expect PASS "${tool[@]}" check multi
ok "a lane commit after integration is stale until integrate reruns"

# a failing verify records the failure and blocks check
"${tool[@]}" init failing --objective x --acceptance y --repo "$work" --verify 'test -f never/there'
"${tool[@]}" add-lane failing p --worker implementer --workspace "$scratch/lane-p" --path src --path docs/p
"${tool[@]}" add-lane failing q --worker implementer --workspace "$scratch/lane-q" --path tests --path docs/q
for l in p q; do
  d="$scratch/lane-$l"; "${tool[@]}" claim failing "$l" --agent "$l"
  mkdir -p "$d/tests" "$d/docs/$l"; [[ $l == p ]] && printf 'p\n' >> "$d/src/app.txt" || printf 'q\n' > "$d/tests/app.txt"
  printf 'r\n' > "$d/docs/$l/r.md"; commit "$d" "$l"
  "${tool[@]}" submit failing "$l" --evidence ok; accept failing "$l" "docs/$l/r.md#ok"
done
"${tool[@]}" qa failing --evidence ok
if "${tool[@]}" integrate failing --workspace "$scratch/integration-failing" 2>/dev/null; then fail 'a failing verify passed integrate'; fi
expect 'integration:fail' "${tool[@]}" check failing
ok "a failing verify blocks completion"

# a conflict aborts cleanly and a second integrate starts from the base.
# Owned paths cannot overlap, so the one file two reviewed lanes can both
# carry is a review report, which a reopen review exempts. Both lanes get
# their report at docs/review.md with different content.
"${tool[@]}" init clash --objective x --acceptance y --repo "$work" --verify 'true'
"${tool[@]}" add-lane clash x --worker implementer --workspace "$scratch/lane-x" --path src/app.txt
"${tool[@]}" add-lane clash y --worker implementer --workspace "$scratch/lane-y" --path src/other.txt
for l in x y; do
  d="$scratch/lane-$l"; "${tool[@]}" claim clash "$l" --agent "$l"
  [[ $l == x ]] && printf 'x\n' > "$d/src/app.txt" || printf 'y\n' > "$d/src/other.txt"
  commit "$d" "$l"
  "${tool[@]}" submit clash "$l" --evidence draft
  mkdir -p "$d/docs"; printf 'review by %s\n' "$l" > "$d/docs/review.md"; commit "$d" "review $l"
  "${tool[@]}" review clash "$l" --reference docs/review.md#p1 --result reopen --severity P1 --message 'tighten'
  "${tool[@]}" ack clash "$l" --agent "$l"
  "${tool[@]}" submit clash "$l" --evidence ok
  accept clash "$l" docs/review.md#ok
done
"${tool[@]}" qa clash --evidence ok
set +e; err="$("${tool[@]}" integrate clash --workspace "$scratch/integration-clash" 2>&1 >/dev/null)"; rc=$?; set -e
[[ $rc -ne 0 ]] || fail 'conflicting lanes integrated'
grep -q "lane 'y' conflicts with x" <<<"$err" || fail "conflict did not name the lanes: $err"
[[ -z "$(git -C "$scratch/integration-clash" status --porcelain)" ]] || fail 'conflict left the integration tree dirty'
set +e; "${tool[@]}" integrate clash --workspace "$scratch/integration-clash" >/dev/null 2>&1; rc=$?; set -e
[[ $rc -ne 0 ]] || fail 'second integrate passed a conflict'
[[ -z "$(git -C "$scratch/integration-clash" status --porcelain)" ]] || fail 'second integrate left the tree dirty'
ok "a merge conflict aborts, names the lanes, and reruns from the base"

# a deleted lane branch is named
git -C "$work" worktree remove --force "$scratch/lane-y"; git -C "$work" branch -q -D clash/y
expect "lane 'y' branch 'clash/y' no longer exists" "${tool[@]}" integrate clash --workspace "$scratch/integration-clash"
ok "a deleted lane branch fails integrate by name"

# ── teardown removes worktrees, keeps unmerged branches, check still passes ──
expect 'removed 3 worktree(s)' "${tool[@]}" teardown multi
[[ ! -d "$la" && ! -d "$lb" && ! -d "$integ" ]] || fail 'teardown left a worktree'
git -C "$work" rev-parse --verify -q multi/integration >/dev/null || fail 'teardown deleted the unmerged integration branch'
expect PASS "${tool[@]}" check multi
if "${tool[@]}" teardown boundary 2>/dev/null; then fail 'teardown ran on an incomplete run'; fi
ok "teardown removes worktrees, keeps unmerged branches, and check still passes"


# ── add-lane refuses the main checkout, resumes after a failure, refuses a stale branch
"${tool[@]}" init guard --objective x --acceptance y --repo "$work" --verify true
if "${tool[@]}" add-lane guard main --worker implementer --workspace "$work" --path src 2>/dev/null; then fail 'add-lane accepted the main checkout as a lane workspace'; fi
git -C "$work" branch -q guard/stale "$base"
if "${tool[@]}" add-lane guard stale --worker implementer --workspace "$scratch/lane-stale2" --path src 2>/dev/null; then fail 'add-lane reused a branch from an earlier run'; fi
expect 'stale	ready' "${tool[@]}" status guard
git -C "$work" branch -q -D guard/stale
expect 'resuming a pending lane' "${tool[@]}" add-lane guard stale --worker implementer --workspace "$scratch/lane-stale2" --path src
[[ -d "$scratch/lane-stale2/src" ]] || fail 'resumed add-lane did not create the worktree'
"${tool[@]}" claim guard stale --agent g1
if "${tool[@]}" add-lane guard stale --worker implementer --workspace "$scratch/lane-stale2" --path src 2>/dev/null; then fail 'add-lane resumed a claimed lane'; fi
ok "add-lane refuses the main checkout and a stale branch, and resumes a pending lane"

# ── integrate refuses a reviewed lane with uncommitted owned work ────────────
"${tool[@]}" init dirtyint --objective x --acceptance y --repo "$work" --verify 'true'
for l in m n; do
  d="$scratch/lane-di-$l"; "${tool[@]}" add-lane dirtyint "$l" --worker implementer --workspace "$d" --path "$( [[ $l == m ]] && echo src || echo tests )" --path "docs/$l"
  "${tool[@]}" claim dirtyint "$l" --agent "$l"
  mkdir -p "$d/tests" "$d/docs/$l"; [[ $l == m ]] && printf 'm\n' >> "$d/src/app.txt" || printf 'n\n' > "$d/tests/app.txt"
  printf 'r\n' > "$d/docs/$l/r.md"; commit "$d" "$l"
  "${tool[@]}" submit dirtyint "$l" --evidence ok; accept dirtyint "$l" "docs/$l/r.md#ok"
done
printf 'late\n' >> "$scratch/lane-di-m/src/app.txt"
expect "lane 'm' has uncommitted work" "${tool[@]}" integrate dirtyint --workspace "$scratch/integration-di"
printf 'scratch\n' > "$scratch/lane-di-m/unowned.txt"; git -C "$scratch/lane-di-m" checkout -q -- src/app.txt
expect 'PASS: integrated' "${tool[@]}" integrate dirtyint --workspace "$scratch/integration-di"
ok "integrate refuses uncommitted owned work and ignores unowned scratch files"

# ── teardown survives a lane directory deleted by hand ───────────────────────
"${tool[@]}" qa dirtyint --evidence ok
rm -rf "$scratch/lane-di-n"
expect 'removed 2 worktree(s)' "${tool[@]}" teardown dirtyint
expect PASS "${tool[@]}" check dirtyint
ok "teardown prunes a hand-deleted lane and check still passes"


# ── abandon closes a run whose work landed outside integrate ─────────────────
"${tool[@]}" init aband --objective x --acceptance y --repo "$work" --verify true
"${tool[@]}" add-lane aband one --worker implementer --workspace "$scratch/lane-ab" --path src
"${tool[@]}" claim aband one --agent ab1
printf 'landed elsewhere\n' >> "$scratch/lane-ab/src/app.txt"; commit "$scratch/lane-ab" ab
mkdir -p "$work/moved"; printf 'main moved\n' > "$work/moved/x.txt"; commit "$work" 'main moves past the run base'
if "${tool[@]}" teardown aband 2>/dev/null; then fail 'teardown closed an unfinished run'; fi
: > "$DOCKER_LOG"
out="$("${tool[@]}" abandon aband 2>&1)"; grep -q 'abandoned' <<<"$out" || fail "abandon failed: $out"
grep -q 'kept branch aband/one' <<<"$out" || fail "abandon did not report the branch it kept: $out"
[[ ! -d "$scratch/lane-ab" ]] || fail 'abandon left the lane worktree'
git -C "$work" rev-parse --verify -q aband/one >/dev/null || fail 'abandon deleted a branch HEAD does not contain'
if "${tool[@]}" status aband 2>/dev/null; then fail 'abandon left the run in state'; fi
grep -q 'label=colloid.run=aband' "$DOCKER_LOG" || fail "abandon did not reap the run's labelled containers"
git -C "$work" branch -q -D aband/one
ok "abandon removes worktrees and the run, reaps containers, and keeps a branch HEAD does not contain"
"${tool[@]}" init aband3 --objective x --acceptance y --repo "$work" --verify true
"${tool[@]}" add-lane aband3 one --worker implementer --workspace "$scratch/lane-ab3" --path src
"${tool[@]}" claim aband3 one --agent ab3
printf 'more\n' >> "$scratch/lane-ab3/src/app.txt"; commit "$scratch/lane-ab3" ab3
expect 'abandoned' "${tool[@]}" abandon aband3 --discard-branches
! git -C "$work" rev-parse --verify -q aband3/one >/dev/null || fail '--discard-branches kept the branch'
ok "abandon --discard-branches deletes an unmerged lane branch"


# ── a review report kept in the main checkout is a valid reference ───────────
"${tool[@]}" init mainref --objective x --acceptance y --repo "$work" --verify true --supervised
"${tool[@]}" add-lane mainref w --worker implementer --workspace "$scratch/lane-mr-w" --path src
"${tool[@]}" add-lane mainref r --worker reviewer --workspace "$scratch/lane-mr-r" --path tests
"${tool[@]}" claim mainref w --agent mrw; "${tool[@]}" claim mainref r --agent mrr
printf 'w\n' >> "$scratch/lane-mr-w/src/app.txt"; commit "$scratch/lane-mr-w" mrw
"${tool[@]}" submit mainref w --evidence ok
mkdir -p "$work/docs/reviews"; printf 'report\n' > "$work/docs/reviews/main-only.md"
expect 'does not claim to interrupt' "${tool[@]}" attention mainref w --severity P1 --message m --reference docs/reviews/main-only.md#p1
expect 'sent' "${tool[@]}" send mainref --from-lane r --to-lane w --agent mrr --kind finding --message m --reference docs/reviews/main-only.md#p1
"${tool[@]}" ack mainref w --agent mrw
"${tool[@]}" submit mainref w --evidence ok
expect 'existing file in the main checkout or the lane worktree' accept mainref w docs/reviews/absent.md#ok
expect 'recorded accept review' accept mainref w docs/reviews/main-only.md#ok
ok "attention, send, and review resolve a reference against the main checkout"


# ── a sparse lane carries only its owned directories ─────────────────────────
"${tool[@]}" init sparse --objective x --acceptance y --repo "$work" --verify 'true'
sp="$scratch/lane-sparse"
expect 'sparse to docs, src' "${tool[@]}" add-lane sparse s --worker implementer --workspace "$sp" --path src --sparse --also docs
[[ -f "$sp/src/app.txt" && ! -e "$sp/tests" && -f "$sp/package-lock.json" ]] || fail "sparse cone wrong: $(ls "$sp")"
[[ "$(git -C "$sp" config core.sparseCheckoutCone)" == "true" ]] || fail "cone mode not set per worktree"
expect 'Sparse cone: docs, src' full_brief sparse s
"${tool[@]}" claim sparse s --agent sp1
printf 'sparse\n' >> "$sp/src/app.txt"; commit "$sp" sparse
"${tool[@]}" submit sparse s --evidence ok
mkdir -p "$sp/docs"; printf 'r\n' > "$sp/docs/r.md"; commit "$sp" review
"${tool[@]}" review sparse s --reference docs/r.md#ok --result reopen --severity P1 --message m; "${tool[@]}" ack sparse s --agent sp1
"${tool[@]}" submit sparse s --evidence ok; accept sparse s docs/r.md#ok
"${tool[@]}" add-lane sparse t --worker implementer --workspace "$scratch/lane-sparse-t" --path tests --also src --sparse >/dev/null 2>&1
[[ -f "$scratch/lane-sparse-t/src/app.txt" ]] || fail "--also directory absent from the cone"
mkdir -p "$scratch/lane-sparse-t/tests"; printf 'x\n' > "$scratch/lane-sparse-t/tests/new.txt"; git -C "$scratch/lane-sparse-t" add tests/new.txt || fail "a file inside the cone could not be staged"
ok "a sparse lane holds its owned and --also directories plus root files, and stages what lands inside them"


# ── leases, progress, and reaping by ownership ───────────────────────────────
"${tool[@]}" init res --objective x --acceptance y --repo "$work" --verify true
"${tool[@]}" add-lane res browser-a --worker implementer --workspace "$scratch/lane-ra" --path src --exclusive playwright >/dev/null 2>&1
"${tool[@]}" add-lane res browser-b --worker implementer --workspace "$scratch/lane-rb" --path tests --exclusive playwright >/dev/null 2>&1
"${tool[@]}" add-lane res plain --worker implementer --workspace "$scratch/lane-rp" --path docs >/dev/null 2>&1
"${tool[@]}" claim res browser-a --agent ra
expect 'exclusive resource in use: browser-a holds playwright' "${tool[@]}" claim res browser-b --agent rb
"${tool[@]}" claim res plain --agent rp
ok "a second lane cannot claim a held exclusive resource; an unrelated lane can"
expect 'COLLOID_RUN=res COLLOID_LANE=browser-a COMPOSE_PROJECT_NAME=res-browser-a' full_brief res browser-a
expect 'Exclusive: playwright' full_brief res browser-a
expect 'integrate runs the composed test once over the merged tree' full_brief res plain
expect 'Working practice:' full_brief res plain --role qa
reviewer_brief="$(full_brief res plain --role reviewer)"
grep -q 'WORKLOOP REVIEWER BRIEF' <<<"$reviewer_brief" || fail "the reviewer brief is missing"
! grep -q 'Working practice:' <<<"$reviewer_brief" || fail "a reviewer brief carries the working practice"
ok "the brief exports the lane's environment, its lease, and the working practice for workers and QA only"

# ── the brief is a dispatch line over a file in the lane's worktree ──────────
"${tool[@]}" init brf --objective 'brief file' --acceptance 'file holds the brief' --repo "$work" --verify 'true'
bw="$scratch/lane-brf"
"${tool[@]}" add-lane brf one --worker implementer --workspace "$bw" --path src --sparse >/dev/null 2>&1
prompt="$("${tool[@]}" brief brf one)"
[[ "$(head -n1 <<<"$prompt")" == "WORKLOOP WORKER BRIEF — brf/one" ]] || fail "the dispatch prompt does not open with the header: $prompt"
[[ "$(wc -l <<<"$prompt")" -le 3 && "${#prompt}" -lt 400 ]] || fail "the dispatch prompt is not short: $prompt"
grep -qF "Read the full brief at $(cd "$bw" && pwd -P)/.workloop/BRIEF.md before anything else" <<<"$prompt" || fail "the prompt omits the brief's absolute path: $prompt"
ok "brief prints a short prompt: the header line, then the absolute path of the brief to read"
file_text="$(cat "$bw/.workloop/BRIEF.md")"
for want in 'WORKLOOP WORKER BRIEF — brf/one' 'Objective: brief file' 'Acceptance: file holds the brief' 'Owned paths: src' 'Working practice:' 'Claim: ' 'Worker handoff: '; do
  grep -qF -- "$want" <<<"$file_text" || fail "BRIEF.md lacks '$want'"
done
"${tool[@]}" brief brf one --role reviewer >/dev/null; "${tool[@]}" brief brf one --role qa >/dev/null
grep -q 'WORKLOOP REVIEWER BRIEF' "$bw/.workloop/BRIEF-reviewer.md" && grep -q 'WORKLOOP QA BRIEF' "$bw/.workloop/BRIEF-qa.md" && grep -q 'WORKLOOP WORKER BRIEF' "$bw/.workloop/BRIEF.md" || fail "the roles do not keep one file each"
ok "brief writes the full brief to .workloop/BRIEF.md, one file per role"
# The parallel-writers gate's matcher recognises the dispatch prompt as a lane cell.
kind="$(gate_kind "$scratch/gateroot" "$prompt")"
[[ "$kind" == "brief" ]] || fail "the gate's matcher read the dispatch prompt as '$kind', not a lane brief"
ok "the parallel-writers gate recognises the dispatch prompt as a lane cell"
git -C "$bw" check-ignore -q .workloop/BRIEF.md || fail ".workloop/ is not ignored in the lane"
[[ -z "$(git -C "$bw" status --porcelain --untracked-files=all)" ]] || fail "the brief dirties the lane: $(git -C "$bw" status --porcelain)"
# Only the carrier ships the export fragment; a satellite has its .gitignore alone.
grep -qx '\.workloop/' "$repo/.gitignore" || fail ".workloop/ is missing from .gitignore"
fragment="$repo/.agents/export/gitignore-fragment"
[[ ! -f "$fragment" ]] || grep -qx '\.workloop/' "$fragment" || fail ".workloop/ is missing from the export fragment"
ok ".workloop/ is ignored in the lane and listed in .gitignore and the export fragment"
"${tool[@]}" widen brf one --path gen --also tests >/dev/null
full_brief brf one | grep -q 'Sparse cone: .*tests' || fail "a rerun after widen did not refresh the brief"
ok "a rerun after widen rewrites the brief file"
"${tool[@]}" claim brf one --agent brf1
printf 'b\n' >> "$bw/src/app.txt"; commit "$bw" brf
"${tool[@]}" submit brf one --evidence ok
mkdir -p "$scratch/elsewhere"; printf 'report\n' > "$scratch/elsewhere/review.md"
expect 'existing file' accept brf one "$scratch/elsewhere/absent.md#ok"
expect 'recorded accept review' accept brf one "$scratch/elsewhere/review.md#ok"
ok "a review may cite an existing file outside the repository by absolute path; a missing one is refused"
# An absolute path inside the lane is stored repository-relative, so the
# reopen, correct and resubmit cycle does not count the report as undeclared.
"${tool[@]}" init abs --objective x --acceptance y --repo "$work" --verify 'true' --supervised
aw="$scratch/lane-abs"; "${tool[@]}" add-lane abs one --worker implementer --workspace "$aw" --path src >/dev/null 2>&1
"${tool[@]}" add-lane abs rev --worker reviewer --workspace "$scratch/lane-abs-rev" --path tests >/dev/null 2>&1
"${tool[@]}" claim abs one --agent abs1; "${tool[@]}" claim abs rev --agent absr
aw_real="$(cd "$aw" && pwd -P)"
printf 'a\n' >> "$aw/src/app.txt"; commit "$aw" abs
"${tool[@]}" submit abs one --evidence ok
mkdir -p "$aw/docs"; printf 'r\n' > "$aw/docs/rev.md"
"${tool[@]}" review abs one --reference "$aw_real/docs/rev.md#f1" --result reopen --severity P1 --message m
"${tool[@]}" ack abs one --agent abs1
printf 'b\n' >> "$aw/src/app.txt"; commit "$aw" abs2
expect 'ready for final review' "${tool[@]}" submit abs one --evidence ok
expect 'does not claim to interrupt' "${tool[@]}" attention abs one --severity P1 --message m --reference "$aw_real/docs/rev.md#f1"
expect 'sent' "${tool[@]}" send abs --from-lane rev --to-lane one --agent absr --kind finding --message m --reference "$aw_real/docs/rev.md#f1"
ok "an absolute in-lane reference survives review, reopen, resubmit, attention and send"
expect 'contract-first split' "${tool[@]}" --help
ok "--help names the delegation shapes"
"${tool[@]}" heartbeat res plain --agent rp --progress 'migrations 3/9'
expect $'plain\tactive\tpending=0\timplementer\tdocs\tmigrations 3/9' "${tool[@]}" status res
ok "an ordinary lane's heartbeat carries progress and status shows it"
: > "$DOCKER_LOG"
expect 'reaped 3 docker resource(s)' "${tool[@]}" release-stale res browser-a --reason 'worker gone'
grep -q 'rm -f c1 c2' "$DOCKER_LOG" && grep -q 'network rm n1' "$DOCKER_LOG" || fail "release-stale did not remove the lane's labelled resources: $(cat "$DOCKER_LOG")"
grep -q -- '--filter label=colloid.run=res --filter label=colloid.lane=browser-a' "$DOCKER_LOG" || fail "reap did not filter by run and lane labels"
"${tool[@]}" claim res browser-b --agent rb
ok "releasing a lane reaps what it started by label and frees its lease"
: > "$DOCKER_LOG"
set +e; out="$("${tool[@]}" reap res --lane plain 2>&1)"; rc=$?; set -e
[[ $rc -ne 0 && "$out" == *"NOT removed: volumes v1: volume is in use"* && "$out" == *"reaped 4 docker resource(s)"* ]] || fail "a refused removal was not surfaced: rc=$rc $out"
grep -q 'label=colloid.lane=plain' "$DOCKER_LOG" || fail "reap --lane did not target the lane"
ok "reap reports what it removed and what docker refused, and fails on a refusal"
: > "$DOCKER_LOG"
"${tool[@]}" reap res >/dev/null 2>&1 || true
grep -q 'compose.project=res-plain' "$DOCKER_LOG" || fail "a lane's compose project was not queried"
! grep -q 'compose.project=res-x' "$DOCKER_LOG" || fail "a compose project that is not a lane was queried"
! grep -q 'stranger' "$DOCKER_LOG" || fail "a stranger's compose project was reaped"
grep -q 'rm -f .*compose1' "$DOCKER_LOG" || fail "the lane's compose container was not removed"
ok "reap matches compose projects exactly against the run's lanes"
if "${tool[@]}" init BadName --objective x --acceptance y --repo "$work" --verify true 2>/dev/null; then fail 'an uppercase run name was accepted'; fi
if "${tool[@]}" add-lane res 'my lane' --worker implementer --workspace "$scratch/lane-bad" --path src 2>/dev/null; then fail 'a lane name with a space was accepted'; fi
ok "run and lane names are constrained to what compose and labels accept"

# ── supervised messaging ──────────────────────────────────────────────────────
"${tool[@]}" init supervised --objective x --acceptance y --repo "$work" --verify true --supervised
"${tool[@]}" add-lane supervised writer --worker implementer --workspace "$scratch/lane-w" --path src
"${tool[@]}" add-lane supervised reviewer --worker reviewer --workspace "$scratch/lane-r" --path docs
"${tool[@]}" claim supervised writer --agent writer-agent
"${tool[@]}" claim supervised reviewer --agent reviewer-agent
rv="$scratch/lane-r"; mkdir -p "$rv/docs/reviews"; printf 'finding\n' > "$rv/docs/reviews/finding.md"
message="$("${tool[@]}" send supervised --from-lane reviewer --to-lane writer --agent reviewer-agent --kind finding --message 'check invariant' --reference docs/reviews/finding.md#p1 --requires-ack | sed -n "s/sent \([^ ]*\).*/\1/p")"
expect "$message" "${tool[@]}" inbox supervised writer
if "${tool[@]}" submit supervised writer --evidence 'ignored finding' 2>/dev/null; then fail 'required peer acknowledgement did not block submit'; fi
if "${tool[@]}" ack-message supervised reviewer "$message" --agent reviewer-agent 2>/dev/null; then fail 'sender acknowledged recipient message'; fi
"${tool[@]}" ack-message supervised writer "$message" --agent writer-agent
"${tool[@]}" heartbeat supervised writer --agent writer-agent
inode() { python3 -c 'import os, sys; print(os.stat(sys.argv[1]).st_ino)' "$1"; }
inode_before="$(inode "$state")"
expect 'RESTART REQUEST' "${tool[@]}" watch supervised --stale-seconds 0
[[ "$inode_before" == "$(inode "$state")" ]] || fail 'watch rewrote state'
"${tool[@]}" send supervised --from-lane reviewer --to-lane writer --agent reviewer-agent --kind status --message 'progress' >/dev/null
expect 'archived 1 messages' "${tool[@]}" archive supervised
"${tool[@]}" send supervised --from-lane reviewer --to-lane writer --agent reviewer-agent --kind finding --message 'late finding' --requires-ack >/dev/null
python3 - "$state" <<'EOF'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["runs"]["supervised"]["lanes"]["writer"]["state"] = "reviewed"; json.dump(s, open(p, "w"))
EOF
expect 'archived 1 messages' "${tool[@]}" archive supervised
expect 'late finding' "${tool[@]}" inbox supervised writer
ok "archive drops an acknowledged finding to a reviewed lane and keeps one awaiting acknowledgement"
expect 'does not exist at the base; created empty' "${tool[@]}" add-lane sparse n --worker implementer --workspace "$scratch/lane-newdir" --path brand-new --sparse
ok "a cone directory absent at the base is named"
ok "supervised messaging holds"

# ── a sparse cone gains what the install needs, or the lane is refused ──────
mono="$scratch/mono"
mkdir -p "$mono/src" "$mono/patches" "$mono/vendored-patches" "$mono/apps/web" "$mono/apps/api" "$mono/apps/skip" "$mono/tools/js"
git init -q "$mono"; git -C "$mono" config user.email test@example.com; git -C "$mono" config user.name test
printf 'a\n' > "$mono/src/a.txt"; printf 'p\n' > "$mono/patches/x.patch"; printf 'p\n' > "$mono/vendored-patches/y.patch"
for m in web api skip; do printf '{"name":"%s"}\n' "$m" > "$mono/apps/$m/package.json"; done
printf '{"name":"root","workspaces":{"packages":["apps/*","!apps/skip"]},"pnpm":{"patchedDependencies":{"x@1":"patches/x.patch"}},"patchedDependencies":{"y@1":"./vendored-patches/y.patch"}}\n' > "$mono/package.json"
printf '{"name":"root","lockfileVersion":3}\n' > "$mono/package-lock.json"
git -C "$mono" add -A; git -C "$mono" commit -qm mono
monotool=("${tool[@]}"); mono_init() { "${monotool[@]}" init "$1" --objective x --acceptance y --repo "$mono" --base "${2:-HEAD}" --verify true >/dev/null; }
mono_init gain
out="$("${tool[@]}" add-lane gain g --worker implementer --workspace "$scratch/lane-gain" --path src --sparse 2>&1)"
for want in 'cone + patches, vendored-patches (patchedDependencies)' 'cone + apps/api, apps/web (workspaces)'; do
  [[ "$out" == *"$want"* ]] || fail "add-lane did not report '$want': $out"
done
for d in patches vendored-patches apps/web apps/api src; do [[ -d "$scratch/lane-gain/$d" ]] || fail "$d missing from the sparse cone"; done
[[ ! -e "$scratch/lane-gain/apps/skip" ]] || fail "a negated workspace glob joined the cone"
ok "a sparse lane gets patch folders and workspace members, minus negated globs, and says why"

git -C "$mono" checkout -q -b pnbranch
printf 'packages:\n  - "libs/*"\n  - "!libs/old"\n' > "$mono/pnpm-workspace.yaml"
printf '{"name":"root"}\n' > "$mono/package.json"; git -C "$mono" rm -rq --cached package-lock.json
mkdir -p "$mono/libs/one" "$mono/libs/old"; printf '{}\n' > "$mono/libs/one/package.json"; printf '{}\n' > "$mono/libs/old/package.json"
git -C "$mono" add -A; git -C "$mono" commit -qm pnpm
mono_init pn pnbranch
"${tool[@]}" add-lane pn p --worker implementer --workspace "$scratch/lane-pn" --path src --sparse >/dev/null || fail "a pnpm workspace sparse lane was refused"
[[ -f "$scratch/lane-pn/libs/one/package.json" && ! -e "$scratch/lane-pn/libs/old" ]] || fail "pnpm-workspace.yaml members wrong in the cone: $(ls "$scratch/lane-pn/libs")"
printf 'packages: [libs/*]\n' > "$mono/pnpm-workspace.yaml"; git -C "$mono" commit -qam flow
mono_init pnflow
git -C "$mono" checkout -q -
expect 'only a block list' "${tool[@]}" add-lane pnflow f --worker implementer --workspace "$scratch/lane-flow" --path src --sparse
ok "a pnpm workspace may be sparse; a packages: shape that cannot be read is refused"

# With a root lockfile the nested one is not installed, so none is left at the root here.
git -C "$mono" rm -q -f package-lock.json
printf '{"name":"js","lockfileVersion":3}\n' > "$mono/tools/js/package-lock.json"; git -C "$mono" add -A; git -C "$mono" commit -qm nested-lock
mono_init lock2
if "${tool[@]}" add-lane lock2 l --worker implementer --workspace "$scratch/lane-lock" --path src --sparse 2>/dev/null; then fail "a cone that drops tools/js/package-lock.json was accepted"; fi
expect 'tools/js/package-lock.json (add --also tools/js)' "${tool[@]}" add-lane lock2 l --worker implementer --workspace "$scratch/lane-lock" --path src --sparse
"${tool[@]}" add-lane lock2 l --worker implementer --workspace "$scratch/lane-lock" --path src --also tools/js --sparse >/dev/null 2>&1 || fail "--also tools/js did not clear the refusal"
[[ -f "$scratch/lane-lock/tools/js/package-lock.json" ]] || fail "--also folder missing from the cone"
ok "a cone that drops a nested lockfile is refused by name; --also for its folder passes"
mono_init lock3
"${tool[@]}" add-lane lock3 l --worker implementer --workspace "$scratch/lane-lock3" --path ./src/ --also ./tools/js/ --sparse >/dev/null 2>&1 || fail "--also ./tools/js/ was not normalized like --path"
[[ -f "$scratch/lane-lock3/tools/js/package-lock.json" ]] || fail "--also ./tools/js/ missing from the cone"
ok "--also values are normalized like --path values"

# cone_of drives cone_for directly on a throwaway repository and prints the
# cone and notes, or the refusal message.
cone_of() {  # <repo> [extra dir]...
  local r="$1"; shift
  python3 -c '
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import workloop_git as wg
try:
    cone, notes = wg.cone_for(Path(sys.argv[2]), "HEAD", ["src"], sys.argv[3:])
    print("CONE " + " ".join(cone))
    print("\n".join(notes))
except SystemExit as exc:
    print(exc)
' "$repo/.agents" "$r" "$@" 2>&1
}
fx() {  # <name> -> a repository with src/a.txt, path on stdout
  local d="$scratch/fx-$1"; mkdir -p "$d/src"; git init -q "$d"
  git -C "$d" config user.email test@example.com; git -C "$d" config user.name test
  printf 'a\n' > "$d/src/a.txt"; printf '%s' "$d"
}
fxc() { git -C "$1" add -A; git -C "$1" commit -qm fx; }
cone_has() {  # <output> <fragment> <why>
  [[ "$1" == *"$2"* ]] || fail "$3: wanted '$2' in: $1"
}

for glob in 'apps/{a,b}' 'apps/?' 'apps/[ab]' 'apps/@(a|b)'; do
  d="$(fx glob)"; mkdir -p "$d/apps/a"; printf '{}\n' > "$d/apps/a/package.json"
  printf '{"workspaces":["%s"]}\n' "$glob" > "$d/package.json"; fxc "$d"
  cone_has "$(cone_of "$d")" 'glob syntax beyond' "workspace glob $glob was not refused"
  rm -rf "$d"
done
d="$(fx none)"; printf '{"workspaces":["apps/*"]}\n' > "$d/package.json"; fxc "$d"
cone_has "$(cone_of "$d")" "matches no folder holding a package.json" "a workspace pattern with no member was not refused"
ok "a workspace glob beyond * and ** is refused, and so is a positive pattern that matches nothing"

d="$(fx vendor)"; mkdir -p "$d/vendor/pkg"; printf '{}\n' > "$d/vendor/pkg/package.json"
printf '{"workspaces":["vendor/*"]}\n' > "$d/package.json"; fxc "$d"
cone_has "$(cone_of "$d")" 'CONE src vendor/pkg' "a member under vendor/ did not join the cone"
ok "a workspace member under vendor/ joins the cone"

d="$(fx yamlpatch)"; mkdir -p "$d/libs/one" "$d/yaml-patches" "$d/other-patches"
printf '{}\n' > "$d/libs/one/package.json"; printf 'p\n' > "$d/yaml-patches/l.patch"; printf 'p\n' > "$d/other-patches/q.patch"
printf 'onlyBuiltDependencies:\n  - esbuild\npackages:\n  - libs/*\npatchedDependencies:\n  left-pad@1.0.0: yaml-patches/l.patch\n  "@scope/q@2": "./other-patches/q.patch"\n' > "$d/pnpm-workspace.yaml"; fxc "$d"
out="$(cone_of "$d")"
cone_has "$out" 'cone + other-patches, yaml-patches (patchedDependencies)' "pnpm-workspace.yaml patches did not join the cone"
cone_has "$out" 'cone + libs/one (pnpm-workspace.yaml)' "pnpm-workspace.yaml members did not join the cone"
printf '{"pnpm":{"patchedDependencies":{"x@1":"pkg-patches/x.patch"}}}\n' > "$d/package.json"; mkdir -p "$d/pkg-patches"; printf 'p\n' > "$d/pkg-patches/x.patch"; fxc "$d"
cone_has "$(cone_of "$d")" 'other-patches, pkg-patches, yaml-patches' "package.json patches stopped joining beside the yaml ones"
ok "patchedDependencies is read from pnpm-workspace.yaml and from package.json"

d="$(fx nopackages)"; mkdir -p "$d/ppp"; printf 'p\n' > "$d/ppp/x.patch"
printf 'patchedDependencies:\n  x@1: ppp/x.patch\n' > "$d/pnpm-workspace.yaml"; fxc "$d"
out="$(cone_of "$d")"
cone_has "$out" 'CONE ppp src' "a pnpm-workspace.yaml without packages: was refused or lost its patches"
ok "a pnpm-workspace.yaml without packages: has no members and is not refused"

# Lockfiles: only those provision.sh installs in a full checkout can be dropped.
d="$(fx locks)"; mkdir -p "$d/tools/js" "$d/tools/py" "$d/tools/pinned" "$d/tools/gem" "$d/tools/devonly" "$d/vendor/gems" "$d/tools/owned"
printf '{}\n' > "$d/package-lock.json"; printf '{}\n' > "$d/tools/js/package-lock.json"
printf 'flask>=1\n' > "$d/tools/py/requirements.txt"
printf 'x==1\n' > "$d/tools/devonly/requirements-dev.txt"
printf 'x==1\n' > "$d/vendor/gems/Gemfile.lock"
printf 'x==1\n' > "$d/tools/owned/requirements.txt"; printf 'x\n' > "$d/tools/owned/uv.lock"
fxc "$d"
out="$(cone_of "$d" tools/owned)"
[[ "$out" == "CONE src tools/owned"* ]] || fail "a nested lockfile under a root one, an unpinned or dev-only requirements file, or a vendor/ Gemfile.lock was refused: $out"
printf 'flask==1.0\n' > "$d/tools/pinned/requirements.txt"; printf 'x\n' > "$d/tools/gem/Gemfile.lock"; fxc "$d"
out="$(cone_of "$d" tools/owned)"
cone_has "$out" 'tools/pinned/requirements.txt (add --also tools/pinned)' "a pinned requirements.txt was not refused"
cone_has "$out" 'tools/gem/Gemfile.lock (add --also tools/gem)' "a Gemfile.lock was not refused"
[[ "$out" != *tools/js* && "$out" != *tools/py/* ]] || fail "refused a lockfile provision.sh would not install: $out"
ok "the dropped-lockfile refusal follows provision.sh: root lockfile wins, pinned requirements.txt only, Gemfile.lock counts, vendor/ is skipped"

python3 - "$repo" <<'PY' || fail "workloop_git.py and provision.sh name different lockfiles"
import re
import sys
sys.path.insert(0, sys.argv[1] + "/.agents")
import workloop_git as wg
text = open(sys.argv[1] + "/.agents/provision.sh").read()
body = text.split("manager_for() {", 1)[1].split("\n}", 1)[0]
named = {n for label in re.findall(r"^\s+([\w.|-]+)\)", body, re.M) for n in label.split("|")}
loops = [tuple(line.split()) for line in re.findall(r"^\s*for name in ([^;]+); do", text, re.M)]
loops = [loop for loop in loops if set(loop) <= named]
problems = []
if named != wg.LOCKFILE_NAMES:
    problems.append(f"manager_for names {sorted(named)}, workloop_git.LOCKFILE_NAMES is {sorted(wg.LOCKFILE_NAMES)}")
for loop in loops:
    if loop not in (wg.JS_LOCKFILES, wg.OTHER_LOCKFILES):
        problems.append(f"provision.sh searches {loop}, matching neither JS_LOCKFILES nor OTHER_LOCKFILES")
if wg.JS_LOCKFILES not in loops or wg.OTHER_LOCKFILES not in loops:
    problems.append("provision.sh no longer loops over one of the two lockfile lists")
sys.exit("\n".join(problems) or 0)
PY
ok "workloop_git.py and provision.sh name the same lockfiles"

# ── shared paths: any lane edits them; a rebased lane is measured from its own start
"${tool[@]}" init shr --objective x --acceptance y --repo "$work" --verify true --shared docs/index.md --shared gen
if "${tool[@]}" init shrdup --objective x --acceptance y --repo "$work" --verify true --shared gen --shared gen/ 2>/dev/null; then fail 'a duplicate shared path was accepted'; fi
sa="$scratch/lane-sa"; sb="$scratch/lane-sb"; sc="$scratch/lane-sc"
expect 'lanes edit shared paths without owning them' "${tool[@]}" add-lane shr bad --worker implementer --workspace "$scratch/lane-sbad" --path docs/index.md
expect 'lanes edit shared paths without owning them' "${tool[@]}" add-lane shr bad --worker implementer --workspace "$scratch/lane-sbad" --path gen/api.json
expect 'lanes edit shared paths without owning them' "${tool[@]}" add-lane shr bad --worker implementer --workspace "$scratch/lane-sbad" --path docs
"${tool[@]}" add-lane shr a --worker implementer --workspace "$sa" --path src
"${tool[@]}" add-lane shr b --worker implementer --workspace "$sb" --path tests
"${tool[@]}" add-lane shr c --worker implementer --workspace "$sc" --path docs/c
expect $'shared\tdocs/index.md, gen' "${tool[@]}" status shr
expect 'Shared paths: docs/index.md, gen' full_brief shr a
expect 'Append only; never restructure or reorder existing lines' full_brief shr a
expect 'owned or shared paths' full_brief shr a
ok "init stores shared paths; add-lane refuses a path overlapping one; brief and status show them"
"${tool[@]}" claim shr a --agent sa; "${tool[@]}" claim shr b --agent sb; "${tool[@]}" claim shr c --agent sc
mkdir -p "$sa/gen" "$sa/docs"; printf 'a\n' >> "$sa/src/app.txt"; printf 'a\n' >> "$sa/docs/index.md"; printf 'a\n' > "$sa/gen/api.json"
expect 'uncommitted changes; commit them on the lane branch first: docs/index.md' "${tool[@]}" submit shr a --evidence dirty
commit "$sa" a
"${tool[@]}" submit shr a --evidence 'shared edit'
python3 - "$state" <<'EOF2'
import json, sys
r = json.load(open(sys.argv[1]))["runs"]["shr"]["lanes"]["a"]["evidence"][-1]["paths"]
assert sorted(r) == ["docs/index.md", "gen/api.json", "src/app.txt"], r
EOF2
ok "a lane that edits shared paths submits, and dirty shared work blocks submit"
# lane b builds on lane a's branch, then adds its own file and a shared edit
git -C "$sb" rebase -q shr/a
mkdir -p "$sb/tests"; printf 'b\n' > "$sb/tests/b.txt"; printf 'b\n' >> "$sb/docs/index.md"
commit "$sb" b
"${tool[@]}" submit shr b --evidence 'rebased onto a'
python3 - "$state" <<'EOF2'
import json, sys
r = json.load(open(sys.argv[1]))["runs"]["shr"]["lanes"]["b"]["evidence"][-1]["paths"]
assert sorted(r) == ["docs/index.md", "tests/b.txt"], r
EOF2
ok "a lane rebased onto a sibling submits and records only its own paths"
start_b="$(git -C "$sb" rev-parse shr/a)"
expect "git diff $start_b\.\.$(git -C "$sb" rev-parse HEAD)" full_brief shr b --role reviewer
expect "start point $start_b" full_brief shr b --role reviewer
expect "result accept --tip $(git -C "$sb" rev-parse HEAD)" full_brief shr b --role reviewer
ok "a reviewer brief names the lane's start point, the submitted commit its diff ends at, and the accept command naming it"
mkdir -p "$sc/docs/c" "$sc/tests"; printf 'c\n' > "$sc/docs/c/ok.txt"; commit "$sc" c
python3 - "$state" <<'EOF2'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["runs"]["noshared"] = json.loads(json.dumps(s["runs"]["shr"])); del s["runs"]["noshared"]["shared"]; json.dump(s, open(p, "w"))
EOF2
expect 'workloop noshared' "${tool[@]}" status noshared
if "${tool[@]}" status noshared | grep -q '^shared'; then fail 'a run without shared printed a shared line'; fi
"${tool[@]}" submit noshared c --evidence 'no shared key'
expect 'paths overlap lane' "${tool[@]}" add-lane noshared d --worker implementer --workspace "$scratch/lane-nd" --path src
ok "a run state without shared keeps working"
printf 'c\n' > "$sc/tests/c.txt"; commit "$sc" c-bad
expect 'lane changed undeclared paths: tests/c.txt' "${tool[@]}" submit shr c --evidence wrong
ok "a path that is neither owned nor shared is still refused"

# ── integrate refuses a reviewed lane with uncommitted shared work ───────────
"${tool[@]}" init shint --objective x --acceptance y --repo "$work" --verify 'true' --shared docs/shared
"${tool[@]}" add-lane shint a --worker implementer --workspace "$scratch/lane-shi" --path src --path docs/a
"${tool[@]}" claim shint a --agent a
mkdir -p "$scratch/lane-shi/docs/a" "$scratch/lane-shi/docs/shared"; printf 'a\n' >> "$scratch/lane-shi/src/app.txt"; printf 'r\n' > "$scratch/lane-shi/docs/a/r.md"
printf 'one\n' > "$scratch/lane-shi/docs/shared/log.md"; commit "$scratch/lane-shi" a
"${tool[@]}" submit shint a --evidence ok; accept shint a docs/a/r.md#ok
printf 'late\n' >> "$scratch/lane-shi/docs/shared/log.md"
expect "lane 'a' has uncommitted work" "${tool[@]}" integrate shint --workspace "$scratch/integration-shi"
ok "integrate refuses uncommitted shared work"

# ── a rebase launders nothing: only a sibling in review, inside its paths, sets a start point
"${tool[@]}" init lk --objective x --acceptance y --repo "$work" --verify true
lb="$scratch/lane-lkb"; lc="$scratch/lane-lkc"
"${tool[@]}" add-lane lk b --worker implementer --workspace "$lb" --path tests
"${tool[@]}" add-lane lk c --worker implementer --workspace "$lc" --path docs/c
"${tool[@]}" claim lk b --agent b; "${tool[@]}" claim lk c --agent c
mkdir -p "$lb/tests" "$lb/secret"; printf 'b\n' > "$lb/tests/b.txt"; printf 'k\n' > "$lb/secret/keys.txt"; commit "$lb" b1
git -C "$lc" rebase -q lk/b
mkdir -p "$lc/docs/c"; printf 'c\n' > "$lc/docs/c/c.txt"; commit "$lc" c1
printf 'b2\n' >> "$lb/tests/b.txt"; commit "$lb" b2
expect 'lane changed undeclared paths: secret/keys.txt' "${tool[@]}" submit lk b --evidence x
expect 'lane changed undeclared paths' "${tool[@]}" submit lk c --evidence x
ok "a change to an unowned path is not laundered by a sibling that rebases onto it"

# ── integrate re-measures each lane and refuses a tip that moved after accept ─
"${tool[@]}" init am --objective x --acceptance y --repo "$work" --verify 'true'
aa="$scratch/lane-ama"; ab="$scratch/lane-amb"
"${tool[@]}" add-lane am a --worker implementer --workspace "$aa" --path src --path docs/a
"${tool[@]}" add-lane am b --worker implementer --workspace "$ab" --path tests --path docs/b
"${tool[@]}" claim am a --agent a; "${tool[@]}" claim am b --agent b
mkdir -p "$aa/docs/a"; printf 'a\n' >> "$aa/src/app.txt"; printf 'r\n' > "$aa/docs/a/r.md"; commit "$aa" a1
"${tool[@]}" submit am a --evidence one
git -C "$ab" rebase -q am/a
mkdir -p "$ab/tests" "$ab/docs/b"; printf 'b\n' > "$ab/tests/b.txt"; printf 'r\n' > "$ab/docs/b/r.md"; commit "$ab" b1
"${tool[@]}" submit am b --evidence rebased
"${tool[@]}" review am a --reference docs/a/r.md#p1 --result reopen --severity P1 --message m
"${tool[@]}" ack am a --agent a
git -C "$aa" reset -q --hard HEAD~1; mkdir -p "$aa/docs/a"; printf 'r\n' > "$aa/docs/a/r.md"; commit "$aa" a2
"${tool[@]}" submit am a --evidence amended
accept am a docs/a/r.md#ok
accept am b docs/b/r.md#ok
expect "rebase it onto the sibling's current branch" "${tool[@]}" integrate am --workspace "$scratch/integration-am"
printf 'x\n' > "$aa/docs/a/x.md"; commit "$aa" a3
expect "lane 'a' moved after its accepted review" "${tool[@]}" integrate am --workspace "$scratch/integration-am"
ok "integrate refuses a lane built on a superseded sibling commit and one whose tip moved after accept"

# ── review gate: a P2 is filed, and the fourth round needs a ruling ──────────
"${tool[@]}" init gate --objective x --acceptance y --repo "$work" --verify true
gd="$scratch/lane-gate"; "${tool[@]}" add-lane gate g --worker implementer --workspace "$gd" --path src --path docs/g
"${tool[@]}" claim gate g --agent g
mkdir -p "$gd/docs/g"; printf 'g\n' >> "$gd/src/app.txt"; printf 'r\n' > "$gd/docs/g/r.md"; commit "$gd" g
"${tool[@]}" submit gate g --evidence one
expect 'a P2 is filed, not reopened' "${tool[@]}" review gate g --reference docs/g/r.md#p2 --result reopen --severity P2
expect 'needs --severity' "${tool[@]}" review gate g --reference docs/g/r.md#p1 --result reopen
expect 'a P2 is filed, not reopened' "${tool[@]}" attention gate g --severity P2 --message m
if "${tool[@]}" review gate g --reference docs/g/r.md#p3 --result reopen --severity P3 2>/dev/null; then fail 'an unknown severity was accepted'; fi
"${tool[@]}" review gate g --reference docs/g/r.md#p1 --result reopen --severity P1 --message m
"${tool[@]}" ack gate g --agent g; "${tool[@]}" submit gate g --evidence two
"${tool[@]}" attention gate g --severity P1 --message 'look again'
"${tool[@]}" ack gate g --agent g; "${tool[@]}" submit gate g --evidence three
"${tool[@]}" review gate g --reference docs/g/r.md#p1 --result reopen --severity P1 --message m
"${tool[@]}" ack gate g --agent g; "${tool[@]}" submit gate g --evidence four
expect 'needs the operator' accept gate g docs/g/r.md#ok
accept gate g docs/g/r.md#ok --ruling 'one more round, go ahead'
python3 - "$state" <<'EOF2'
import json, sys
lane = json.load(open(sys.argv[1]))["runs"]["gate"]["lanes"]["g"]
assert lane["state"] == "reviewed", lane["state"]
assert lane["review_refs"][-1]["ruling"] == "one more round, go ahead", lane["review_refs"][-1]
assert "ruling" not in lane["review_refs"][0], lane["review_refs"][0]
EOF2
ok "a P2 reopen is refused; an attention cycle counts as a round; the fourth round needs a recorded ruling"

# ── one writer: init --lane records the run's sole lane in the checkout itself ─
expect '\-\-path needs --lane' "${tool[@]}" init ow --objective x --acceptance y --repo "$work" --verify true --path src
expect '\-\-worker needs --lane' "${tool[@]}" init ow --objective x --acceptance y --repo "$work" --verify true --worker implementer
expect '\-\-lane needs --worker and at least one --path' "${tool[@]}" init ow --objective x --acceptance y --repo "$work" --verify true --lane solo
expect '\-\-lane needs --worker and at least one --path' "${tool[@]}" init ow --objective x --acceptance y --repo "$work" --verify true --lane solo --worker implementer
expect 'overlap a shared path' "${tool[@]}" init ow --objective x --acceptance y --repo "$work" --verify true --shared src --lane solo --worker implementer --path src/app.txt
if "${tool[@]}" status ow >/dev/null 2>&1; then fail 'a refused init --lane left the run in state'; fi
ok "init --lane is refused without --worker and --path, and --path or --worker without --lane"
mark="$scratch/ran-ow"
worktree_paths() { git -C "$work" worktree list --porcelain | grep '^worktree '; }
worktrees_before="$(worktree_paths)"
prompt="$("${tool[@]}" init ow --objective 'one writer' --acceptance 'the main lane is reviewed' --repo "$work" --verify "test -f src/app.txt && test -e node_modules && pwd -P > $scratch/verify-cwd && git rev-parse HEAD > $scratch/verify-head && touch $mark" --lane solo --worker implementer --path src --path docs/ow)"
[[ "$prompt" == *"created workloop 'ow'"*$'\n'"WORKLOOP WORKER BRIEF — ow/solo"$'\n'"Read the full brief at $real_work/.agents/worktrees/ow/.workloop/solo.md before anything else"* ]] || fail "init --lane did not print the lane's dispatch line: $prompt"
[[ -f "$real_work/.agents/worktrees/ow/.workloop/solo.md" ]] || fail "init --lane wrote no brief"
[[ "$(worktree_paths)" == "$worktrees_before" ]] || fail "init --lane made a worktree"
python3 - "$state" "$real_work" <<'EOF'
import json, sys
lane = json.load(open(sys.argv[1]))["runs"]["ow"]["lanes"]["solo"]
assert lane["place"] == "main" and lane["branch"] is None and lane["env"] == "main" and lane["workspace"] == sys.argv[2], lane
assert lane["paths"] == ["src", "docs/ow"] and lane["state"] == "ready" and "start" not in lane, lane
EOF
solo_brief="$(cat "$real_work/.agents/worktrees/ow/.workloop/solo.md")"
for want in "Workspace: the checkout $real_work, on its current branch — no worktree" 'staging by path only (git add -- <path>..., never -A, . or commit -a)' "Provision: .agents/provision.sh $real_work" 'Working practice:'; do
  grep -qF -- "$want" <<<"$solo_brief" || fail "the main lane's worker brief lacks '$want'"
done
! grep -q 'lane branch' <<<"$solo_brief" || fail "the main lane's brief speaks of a lane branch"
[[ "$(gate_kind "$real_work" "$prompt")" == "plain" ]] || fail "the gate did not read the main lane's worker dispatch as a plain writer"
[[ -z "$(git -C "$work" status --porcelain --untracked-files=all | grep -F .workloop || true)" ]] || fail "the main lane's brief dirties the checkout: $(git -C "$work" status --porcelain)"
expect "a one-writer run's lane works in the main tree; start a new run for writers working at once" "${tool[@]}" add-lane ow second --worker implementer --path tests
expect 'a one-writer run has nothing to integrate' "${tool[@]}" integrate ow
expect "lane 'solo' works in the checkout itself, which the controller does not provision" "${tool[@]}" provision ow solo
python3 -c 'import json,sys; l=json.load(open(sys.argv[1]))["runs"]["ow"]["lanes"]["solo"]; assert l["branch"] is None and l["env"] == "main", l' "$state" || fail "provision changed the main lane"
ok "init --lane records the main lane with no worktree, branch or install, prints its dispatch as a plain writer, and the run takes no second lane or provision"

# the brief for a reviewer or QA cell opens READ-ONLY, which the gate honours
rev_prompt="$("${tool[@]}" brief ow solo --role reviewer)"
[[ "$(head -n1 <<<"$rev_prompt")" == READ-ONLY* && "$(sed -n 2p <<<"$rev_prompt")" == "WORKLOOP REVIEWER BRIEF — ow/solo" ]] || fail "the main lane's reviewer dispatch does not open READ-ONLY: $rev_prompt"
[[ "$(gate_kind "$real_work" "$rev_prompt")" == "read-only" ]] || fail "the gate did not read the main lane's reviewer dispatch as read-only"
[[ "$(head -n1 "$real_work/.agents/worktrees/ow/.workloop/solo-reviewer.md")" == READ-ONLY* ]] || fail "the reviewer brief file does not open READ-ONLY"
[[ "$(head -n1 <<<"$("${tool[@]}" brief ow solo --role qa)")" == READ-ONLY* && -f "$real_work/.agents/worktrees/ow/.workloop/solo-qa.md" ]] || fail "the main lane's QA dispatch does not open READ-ONLY"
ok "a main lane's reviewer and QA briefs open READ-ONLY, one file per role under the run's .workloop folder"

# claim sets start; submit attributes the commits since it by the lane's paths (ruling 32):
# another writer's commit is listed, a mixed one is listed for the reviewer (ruling 34), none refuses
"${tool[@]}" claim ow solo --agent solo1
start_ow="$(git -C "$work" rev-parse HEAD)"
python3 -c 'import json,sys; l=json.load(open(sys.argv[1]))["runs"]["ow"]["lanes"]["solo"]; assert l["start"] == sys.argv[2] and l["state"] == "active", l' "$state" "$start_ow"
expect "no commits since the lane's first claim" "${tool[@]}" submit ow solo --evidence nothing
mkdir -p "$work/elsewhere"; printf 'other\n' > "$work/elsewhere/o.txt"; commit_paths "$work" 'another writer' elsewhere/o.txt
other_sha="$(git -C "$work" rev-parse HEAD)"
mkdir -p "$work/tests"; printf 'solo\n' >> "$work/src/app.txt"; printf 'x\n' > "$work/tests/mixed.txt"; commit_paths "$work" mixed src/app.txt tests/mixed.txt
mixed_sha="$(git -C "$work" rev-parse HEAD)"
printf 'x\n' >> "$work/src/app.txt"
expect 'uncommitted changes; commit them in the checkout first: src/app.txt' "${tool[@]}" submit ow solo --evidence dirty
git -C "$work" checkout -q -- src/app.txt
# a rename out of the lane is seen leaving: the deleted source is the lane's, the destination is not
printf 'extra\n' > "$work/src/extra.txt"; commit_paths "$work" extra src/extra.txt
git -C "$work" mv src/extra.txt elsewhere/extra.txt; git -C "$work" -c user.email=t@e.com -c user.name=t commit -qm 'moved out'
mv_sha="$(git -C "$work" rev-parse HEAD)"
out="$("${tool[@]}" submit ow solo --evidence 'verify passed' 2>&1)" || fail "submit refused the main lane: $out"
[[ "$out" == *"commit ${other_sha:0:12} is not this lane's"* && "$out" == *"mixed: ${mixed_sha:0:12} also touches tests/mixed.txt"* && "$out" == *"mixed: ${mv_sha:0:12} also touches elsewhere/extra.txt"* && "$out" == *"ready for final review at ${mv_sha:0:12}"* ]] || fail "submit did not list the other writer's and the mixed commits: $out"
[[ "$("${tool[@]}" status ow)" == *$'\t'"tip=${mv_sha:0:12}"* ]] || fail "status does not show the submitted tip the reviewer's accept names: $("${tool[@]}" status ow)"
python3 - "$state" "$mv_sha" "$mixed_sha" <<'EOF'
import json, sys
lane = json.load(open(sys.argv[1]))["runs"]["ow"]["lanes"]["solo"]
evidence = lane["evidence"][-1]
assert lane["tip"] == sys.argv[2] and evidence["paths"] == ["src/app.txt", "src/extra.txt"], evidence
assert [m["commit"] for m in evidence["mixed"]] == [sys.argv[3], sys.argv[2]] and evidence["mixed"][0]["paths"] == ["tests/mixed.txt"], evidence["mixed"]
assert evidence["mixed"][0]["text"] == f"mixed: {sys.argv[3][:12]} also touches tests/mixed.txt", evidence["mixed"]
EOF
[[ "$(worktree_paths)" == "$worktrees_before" ]] || fail "the main lane's lifecycle made a worktree"
ok "a main lane's work is the commits since its first claim that touch its paths; mixed commits and a rename out are listed, another writer's commit named, none refused"

# a merge commit counts by the paths its own resolution changed
branch_ow="$(git -C "$work" symbolic-ref --short HEAD)"
git -C "$work" checkout -q -b ow-side "$other_sha"; printf 'side\n' >> "$work/src/app.txt"; commit_paths "$work" side src/app.txt
git -C "$work" checkout -q "$branch_ow"
git -C "$work" -c user.email=t@e.com -c user.name=t merge -q --no-edit ow-side >/dev/null 2>&1 || true
printf 'resolved\n' > "$work/src/app.txt"; git -C "$work" add -- src/app.txt; git -C "$work" -c user.email=t@e.com -c user.name=t commit -q --no-edit
merge_sha="$(git -C "$work" rev-parse HEAD)"
[[ "$(git -C "$work" rev-list --parents -n1 HEAD | wc -w)" -eq 3 ]] || fail "the merge fixture is not a merge commit"
"${tool[@]}" submit ow solo --evidence 'verify passed' >/dev/null 2>&1
rev_brief="$(full_brief ow solo --role reviewer)"
grep -qF "Diff: ${start_ow:0:12}..${merge_sha:0:12} in the checkout; this lane's commits: " <<<"$rev_brief" || fail "the reviewer brief does not name the range: $rev_brief"
for sha in "$mixed_sha" "$mv_sha" "$merge_sha"; do grep -q "this lane's commits: .*${sha:0:12}" <<<"$rev_brief" || fail "the reviewer brief omits the lane's commit ${sha:0:12}: $rev_brief"; done
grep -qF -- "-- src docs/ow" <<<"$rev_brief" && grep -qF "Mixed commits — mixed: ${mixed_sha:0:12} also touches tests/mixed.txt; mixed: ${mv_sha:0:12} also touches elsewhere/extra.txt" <<<"$rev_brief" || fail "the reviewer brief does not list the mixed commits: $rev_brief"
! grep -q "${other_sha:0:12}" <<<"$rev_brief" || fail "the reviewer brief lists another writer's commit as the lane's"
grep -qF "review ow solo --reference '<canonical-review-path>#<finding>' --result accept --tip $merge_sha" <<<"$rev_brief" || fail "the reviewer brief's accept command does not name the tip: $rev_brief"
ok "a merge's own resolution is the lane's; the reviewer brief names the range, the lane's commits, the mixed ones and the accept command with its tip"

# an accepting review binds the commit it read: --tip must be the submitted tip, still the lane's live tip
mkdir -p "$work/docs/ow"; printf 'r\n' > "$work/docs/ow/review.md"
expect 'result accept needs --tip' "${tool[@]}" review ow solo --reference docs/ow/review.md#ok --result accept
expect "is not the submitted tip ${merge_sha:0:12}" "${tool[@]}" review ow solo --reference docs/ow/review.md#ok --result accept --tip "$other_sha"
printf 'late\n' >> "$work/src/app.txt"; commit_paths "$work" late src/app.txt docs/ow/review.md
late_sha="$(git -C "$work" rev-parse HEAD)"
expect "the lane moved since the reviewed commit ${merge_sha:0:12}: ${late_sha:0:12} touch its paths; re-submit, then review ${late_sha:0:12}" "${tool[@]}" review ow solo --reference docs/ow/review.md#ok --result accept --tip "$merge_sha"
"${tool[@]}" submit ow solo --evidence 'verify passed again' >/dev/null 2>&1
expect 'recorded accept review' "${tool[@]}" review ow solo --reference docs/ow/review.md#ok --result accept --tip "${late_sha:0:12}"
python3 -c 'import json,sys; l=json.load(open(sys.argv[1]))["runs"]["ow"]["lanes"]["solo"]; assert l["accepted_tip"] == l["tip"] == sys.argv[2], l' "$state" "$late_sha"
# the same binding for a worktree lane, whose live tip is its branch head
"${tool[@]}" init wt --objective x --acceptance y --repo "$work" --verify true >/dev/null
"${tool[@]}" add-lane wt one --worker implementer --workspace "$scratch/lane-wt" --path tests >/dev/null 2>&1
"${tool[@]}" claim wt one --agent wt1; mkdir -p "$scratch/lane-wt/tests"; printf 'a\n' > "$scratch/lane-wt/tests/a.txt"; commit "$scratch/lane-wt" a
expect "ready for final review at $(git -C "$scratch/lane-wt" rev-parse --short=12 HEAD)" "${tool[@]}" submit wt one --evidence ok
wt_tip="$(git -C "$scratch/lane-wt" rev-parse HEAD)"
expect 'result accept needs --tip' "${tool[@]}" review wt one --reference tests/a.txt#ok --result accept
printf 'b\n' > "$scratch/lane-wt/tests/b.txt"; commit "$scratch/lane-wt" b
expect "the lane moved since the reviewed commit ${wt_tip:0:12}; re-submit, then review $(git -C "$scratch/lane-wt" rev-parse --short=12 HEAD)" "${tool[@]}" review wt one --reference tests/a.txt#ok --result accept --tip "$wt_tip"
"${tool[@]}" submit wt one --evidence ok >/dev/null
expect "is not the submitted tip" "${tool[@]}" review wt one --reference tests/a.txt#ok --result accept --tip "$wt_tip"
expect 'recorded accept review' accept wt one tests/a.txt#ok
python3 -c 'import json,sys; l=json.load(open(sys.argv[1]))["runs"]["wt"]["lanes"]["one"]; assert l["accepted_tip"] == l["tip"] == sys.argv[2], l' "$state" "$(git -C "$scratch/lane-wt" rev-parse HEAD)"
# a rename out of, and into, a worktree lane is seen on both sides
git -C "$scratch/lane-wt" mv tests/a.txt moved-a.txt; commit "$scratch/lane-wt" 'moved out'
expect 'lane changed undeclared paths: moved-a.txt' "${tool[@]}" submit wt one --evidence x
git -C "$scratch/lane-wt" reset -q --hard HEAD~1
git -C "$scratch/lane-wt" mv src/app.txt tests/app.txt; commit "$scratch/lane-wt" 'moved in'
expect 'lane changed undeclared paths: src/app.txt' "${tool[@]}" submit wt one --evidence x
"${tool[@]}" abandon wt --discard-branches >/dev/null
ok "an accepting review needs --tip naming the submitted commit, refuses a lane that moved, and renames are seen leaving and arriving in worktree lanes too"

# check runs the composed test in a worktree at the accepted commit (ruling 33); --recorded never runs it
expect 'completion is blocked by qa:missing, verified:missing' "${tool[@]}" check ow --recorded
[[ ! -e "$mark" ]] || fail "check --recorded ran the composed test"
printf 'dirty\n' >> "$work/src/app.txt"
expect "completion is blocked by solo:uncommitted, qa:missing, verified:missing"$'\n'"the checkout has uncommitted changes in the lane's paths: src/app.txt; commit or discard them" "${tool[@]}" check ow
[[ ! -e "$mark" ]] || fail "check ran the composed test over a dirty lane path"
git -C "$work" checkout -q -- src/app.txt
# a staged rename into the lane's paths is a dirty lane path too
git -C "$work" mv elsewhere/o.txt src/o.txt
expect "completion is blocked by solo:uncommitted, qa:missing, verified:missing"$'\n'"the checkout has uncommitted changes in the lane's paths: src/o.txt" "${tool[@]}" check ow --recorded
git -C "$work" mv src/o.txt elsewhere/o.txt
[[ -z "$(git -C "$work" status --porcelain -- elsewhere src)" ]] || fail "the rename fixture was not undone: $(git -C "$work" status --porcelain)"
printf 'lead\n' >> "$work/moved/x.txt"
set +e; out="$("${tool[@]}" check ow 2>&1)"; rc=$?; set -e
verify_dir="$real_work/.agents/worktrees/ow/verify"
[[ $rc -ne 0 && "$out" == *"running verify at ${late_sha:0:12} in $verify_dir"* && "$out" == *"completion is blocked by qa:missing"* && "$out" != *"verified:"* ]] || fail "check did not run and record the composed test: rc=$rc $out"
# the verify command itself checks node_modules: the worktree is provisioned (shared from the checkout) before it runs
[[ -f "$mark" && "$(cat "$scratch/verify-cwd")" == "$verify_dir" && "$(cat "$scratch/verify-head")" == "$late_sha" ]] || fail "the composed test did not run in a provisioned verify worktree at the accepted commit: $(cat "$scratch/verify-cwd" "$scratch/verify-head" 2>&1)"
[[ ! -e "$verify_dir" && "$(worktree_paths)" == "$worktrees_before" ]] || fail "a passing check left the verify worktree"
git -C "$work" checkout -q -- moved/x.txt
python3 - "$state" "$late_sha" "$verify_dir" <<'EOF'
import json, sys
run = json.load(open(sys.argv[1]))["runs"]["ow"]
v = run["verified"]
# a pass records no worktree path: the worktree is gone, and a recorded path to it would read as a lost worktree at the start sweep
assert v["result"] == "pass" and v["head"] == sys.argv[2] and v["lane_tips"] == {"solo": sys.argv[2]} and v["verify"] == run["verify"] and "workspace" not in v and "dirty" not in v, v
assert run["events"][-1]["action"] == "verify" and run["events"][-1]["detail"] == "pass", run["events"][-1]
EOF
rm "$mark"
"${tool[@]}" qa ow --evidence 'scenario passed'
expect "PASS: 'ow' has reviewed lanes, a passing composed test and QA evidence" "${tool[@]}" check ow
[[ ! -e "$mark" ]] || fail "check reran a current, passing verification"
ok "check tests the accepted commit in a provisioned verify worktree, removed after the pass, and a current pass is not rerun"
# the review report is the lead's: editing and committing it in the checkout after the accept leaves the lane reviewed
mkdir -p "$work/reports"; printf 'round 1\n' > "$work/reports/ow.md"
python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["runs"]["ow"]["lanes"]["solo"]["review_refs"].append({"at": "2026-10-16T00:00:00Z", "reference": "reports/ow.md#ok", "result": "accept"}); json.dump(s, open(p,"w"))' "$state"
expect PASS "${tool[@]}" check ow --recorded
commit_paths "$work" report reports/ow.md
printf 'trailing\n' >> "$work/reports/ow.md"
expect PASS "${tool[@]}" check ow --recorded
commit_paths "$work" report2 reports/ow.md
ok "a commit or an edit to the cited review report after the accept does not move the lane"
# only a pass is current: a recorded failure makes the next check run again
python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["runs"]["ow"]["verified"]["result"]="fail"; json.dump(s, open(p,"w"))' "$state"
expect 'verified:fail' "${tool[@]}" check ow --recorded
expect PASS "${tool[@]}" check ow
[[ -f "$mark" ]] || fail "check did not rerun after a recorded failure"
rm "$mark"
ok "a recorded failure is not current: check runs the composed test again"
# the run reads live state after its review: a lane-path commit or a dirty lane path makes it stale everywhere
printf 'after\n' >> "$work/src/app.txt"; commit_paths "$work" after src/app.txt; after_sha="$(git -C "$work" rev-parse HEAD)"
expect "completion is blocked by solo:moved-after-review"$'\n'"the checkout has commits touching the lane's paths after its accepted tip ${late_sha:0:12}; re-submit the lane for review" "${tool[@]}" check ow
expect 'solo:moved-after-review' "${tool[@]}" check ow --recorded
expect 'teardown waits for completion; blocked by solo:moved-after-review' "${tool[@]}" teardown ow
[[ ! -e "$mark" ]] || fail "check ran the composed test for a lane that moved after its review"
# a re-submission is a review round like any other: this is the lane's fourth, so the accept carries a ruling
"${tool[@]}" submit ow solo --evidence 'verify passed' >/dev/null 2>&1; accept ow solo docs/ow/review.md#ok --ruling 'moved after review; review it again'
expect 'verified:stale' "${tool[@]}" check ow --recorded
expect PASS "${tool[@]}" check ow
[[ -f "$mark" ]] || fail "check did not retest the newly accepted commit"
rm "$mark"
ok "a lane-path commit after the accepted review blocks check, check --recorded and teardown until a new review and test"
# one check per run at a time; a run with no verify is named
python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["runs"]["ow"]["verified"]["result"]="fail"; json.dump(s, open(p,"w"))' "$state"
python3 -c 'import fcntl,sys,time; f=open(sys.argv[1],"a+"); fcntl.flock(f,fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(30)' "$real_work/.agents/worktrees/ow/.workloop/check.lock" "$scratch/check-held" & holder=$!
for _ in $(seq 50); do [[ -e "$scratch/check-held" ]] && break; sleep 0.1; done
expect "check is already running for 'ow'" "${tool[@]}" check ow
kill "$holder"; wait "$holder" 2>/dev/null || true
expect PASS "${tool[@]}" check ow
python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["runs"]["ow"]["verify"]=None; json.dump(s, open(p,"w"))' "$state"
expect 'completion is blocked by verify:undeclared' "${tool[@]}" check ow --recorded
python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["runs"]["ow"]["verify"]=s["runs"]["ow"]["verified"]["verify"]; json.dump(s, open(p,"w"))' "$state"
ok "a second check waits for the first; a run with lanes and no verify reports verify:undeclared"
# a failing verify leaves its worktree named; the next check, or abandon, removes it
"${tool[@]}" init owf --objective x --acceptance y --repo "$work" --verify 'test -f never/there' --lane f --worker implementer --path docs/owf >/dev/null
"${tool[@]}" claim owf f --agent f1; mkdir -p "$work/docs/owf"; printf 'f\n' > "$work/docs/owf/f.txt"; commit_paths "$work" f docs/owf/f.txt
"${tool[@]}" submit owf f --evidence ok >/dev/null; accept owf f docs/ow/review.md#ok
fail_dir="$real_work/.agents/worktrees/owf/verify"
expect "verify failed in $fail_dir; the worktree stays for inspection" "${tool[@]}" check owf
[[ -d "$fail_dir" && -n "$(worktree_paths | grep -F "$fail_dir")" ]] || fail "a failed verify did not leave its worktree"
expect 'verified:fail' "${tool[@]}" check owf --recorded
python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))["runs"]["owf"]["verified"]; assert v["workspace"] == sys.argv[2], v' "$state" "$fail_dir"
# a verify folder deleted by hand leaves a stale registration, which the next check overrides;
# another worktree whose folder is away keeps its registration (no prune)
git -C "$work" worktree add -q "$scratch/wt-away" -b wt-away >/dev/null; rm -rf "$scratch/wt-away" "$fail_dir"
expect "verify failed in $fail_dir" "${tool[@]}" check owf
[[ -d "$fail_dir" && -n "$(worktree_paths | grep -F "$scratch/wt-away")" ]] || fail "check pruned a worktree whose folder is away, or did not override the verify path's stale registration: $(worktree_paths)"
git -C "$work" worktree remove --force "$scratch/wt-away" 2>/dev/null || git -C "$work" worktree prune; git -C "$work" branch -q -D wt-away
expect "abandoned 'owf': removed 1 worktree(s)" "${tool[@]}" abandon owf
[[ ! -e "$fail_dir" && "$(worktree_paths)" == "$worktrees_before" ]] || fail "abandon left the failed verify worktree"
ok "a failing composed test is recorded, its worktree stays and is named, and the next check or abandon removes it"

# teardown reaps the main lane's labelled resources, removes the briefs and nothing else; the run stays passing
: > "$DOCKER_LOG"
expect 'removed 0 worktree(s)' "${tool[@]}" teardown ow
grep -q 'label=colloid.run=ow' "$DOCKER_LOG" && grep -q 'label=com.docker.compose.project=ow-solo' "$DOCKER_LOG" || fail "teardown did not reap the main lane's compose project and the run's labelled resources: $(cat "$DOCKER_LOG")"
[[ ! -e "$real_work/.agents/worktrees/ow" ]] || fail "teardown left the main lane's brief folder: $(ls -R "$real_work/.agents/worktrees/ow")"
[[ "$(worktree_paths)" == "$worktrees_before" && "$(git -C "$work" rev-parse HEAD)" != "$start_ow" ]] || fail "teardown touched the checkout's worktrees or history"
printf 'later\n' >> "$work/src/app.txt"; commit_paths "$work" later src/app.txt
expect PASS "${tool[@]}" check ow
expect PASS "${tool[@]}" check ow --recorded
ok "teardown of a one-writer run reaps its lane's resources and removes its briefs; check still passes as the checkout moves on"

# an amend after submit names re-submit; only a history that lost the claim's start names abandon
"${tool[@]}" init owa --objective x --acceptance y --repo "$work" --verify true --lane a --worker implementer --path src >/dev/null
"${tool[@]}" claim owa a --agent a1
printf 'a\n' >> "$work/src/app.txt"; commit_paths "$work" a src/app.txt
"${tool[@]}" submit owa a --evidence ok >/dev/null; owa_tip="$(git -C "$work" rev-parse HEAD)"
git -C "$work" -c user.email=t@e.com -c user.name=t commit -q --amend --no-edit -m 'a amended'
expect "no longer contains ${owa_tip:0:12}; re-submit the lane" "${tool[@]}" review owa a --reference docs/ow/review.md#ok --result accept --tip "$owa_tip"
"${tool[@]}" submit owa a --evidence ok >/dev/null; expect 'recorded accept review' accept owa a docs/ow/review.md#ok
"${tool[@]}" abandon owa >/dev/null
# a checkout switched to another branch is told to switch back, not to re-submit
"${tool[@]}" init owb --objective x --acceptance y --repo "$work" --verify true --lane b --worker implementer --path src >/dev/null
"${tool[@]}" claim owb b --agent b1; owb_start="$(git -C "$work" rev-parse HEAD)"; owb_branch="$(git -C "$work" symbolic-ref --short HEAD)"
printf 'b\n' >> "$work/src/app.txt"; commit_paths "$work" b src/app.txt
"${tool[@]}" submit owb b --evidence ok >/dev/null; owb_tip="$(git -C "$work" rev-parse HEAD)"
git -C "$work" checkout -q -b owb-elsewhere "$owb_start"
expect "no longer contains ${owb_tip:0:12}, which branch $owb_branch still holds: switch back to it (git switch $owb_branch), then rerun" "${tool[@]}" review owb b --reference docs/ow/review.md#ok --result accept --tip "$owb_tip"
git -C "$work" checkout -q "$owb_branch"; git -C "$work" branch -q -D owb-elsewhere
expect 'recorded accept review' accept owb b docs/ow/review.md#ok
git -C "$work" checkout -q -b owb-elsewhere "$owb_start"
expect "completion is blocked by b:rewritten, qa:missing, verified:missing"$'\n'"HEAD ${owb_start:0:12} no longer contains ${owb_tip:0:12}, which branch $owb_branch still holds: switch back to it" "${tool[@]}" check owb --recorded
git -C "$work" checkout -q "$owb_branch"; git -C "$work" branch -q -D owb-elsewhere
"${tool[@]}" abandon owb >/dev/null
ok "a checkout switched to another branch is told to switch back before a review or check can proceed"
"${tool[@]}" init owr --objective x --acceptance y --repo "$work" --verify true --lane r --worker implementer --path src >/dev/null
"${tool[@]}" claim owr r --agent r1
printf 'r\n' >> "$work/src/app.txt"; commit_paths "$work" r src/app.txt
git -C "$work" reset -q --hard HEAD~2; printf 'r2\n' >> "$work/src/app.txt"; commit_paths "$work" r2 src/app.txt
expect "does not descend from the lane's start"'.*close it with: abandon owr' "${tool[@]}" submit owr r --evidence ok
expect "abandoned 'owr': removed 0 worktree(s)" "${tool[@]}" abandon owr
if "${tool[@]}" status owr 2>/dev/null; then fail 'abandon left the one-writer run in state'; fi
ok "an amend after submit is re-submitted; a history that lost the claim's start is refused naming abandon, which closes the run without touching the checkout"

# ── read-only cells: a light entry in any run, tracked until it returns (ruling 8) ──
"${tool[@]}" init oc --objective 'cells beside a writer' --acceptance 'every cell back' --repo "$work" --verify true --lane solo --worker implementer --path src >/dev/null
cell_prompt="$("${tool[@]}" add-cell oc scout --role research --model opus)"
cell_file="$real_work/.agents/worktrees/oc/.workloop/cells/scout.md"
[[ "$(head -n1 <<<"$cell_prompt")" == READ-ONLY* && "$(sed -n 2p <<<"$cell_prompt")" == "WORKLOOP CELL BRIEF — oc/scout" && "$(sed -n 3p <<<"$cell_prompt")" == "Read the full brief at $cell_file before anything else"*"Your question follows below this prompt." ]] || fail "add-cell did not print a READ-ONLY cell dispatch naming its brief: $cell_prompt"
[[ "$(head -n1 "$cell_file")" == READ-ONLY* && "$(sed -n 2p "$cell_file")" == "WORKLOOP CELL BRIEF — oc/scout" ]] || fail "the cell brief does not open READ-ONLY at cells/<name>.md: $(cat "$cell_file" 2>&1)"
for want in 'Objective: cells beside a writer' 'Role: research — ' 'Model: opus' 'Question: the lead wrote it below the three lines of your dispatch prompt.' 'your whole result is your reply to the lead' 'you write no file' "returned oc scout --result <path|reply>, or --failed"; do
  grep -qF -- "$want" "$cell_file" || fail "the cell brief lacks '$want': $(cat "$cell_file")"
done
! grep -q 'A writing cell runs' "$cell_file" || fail "a research cell's brief carries the working practice"
[[ "$(gate_kind "$real_work" "$cell_prompt")" == "read-only" ]] || fail "the gate did not read the cell dispatch as read-only"
[[ "$(worktree_paths)" == "$worktrees_before" ]] || fail "add-cell made a worktree"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["runs"]["oc"]["cells"]["scout"]; assert c["role"] == "research" and c["model"] == "opus" and c["state"] == "out" and c["out_since"] and c["added_at"], c' "$state"
expect "run already has a lane or cell named 'solo'" "${tool[@]}" add-cell oc solo --role review --model opus
expect "run already has a lane or cell named 'scout'" "${tool[@]}" add-cell oc scout --role review --model opus
"${tool[@]}" add-cell oc critic --role qa --model sonnet >/dev/null
grep -q 'A writing cell runs' "$real_work/.agents/worktrees/oc/.workloop/cells/critic.md" || fail "a qa cell's brief lacks the working practice"
expect "a cell's role is set at add-cell" "${tool[@]}" brief oc scout --role qa
[[ "$("${tool[@]}" brief oc scout)" == "$cell_prompt" ]] || fail "brief on a cell out did not reprint its prompt unchanged"
expect "'solo' is a lane, whose brief prints without it" "${tool[@]}" brief oc solo --again
oc_status="$("${tool[@]}" status oc)"
[[ "$oc_status" == *$'scout\tcell out\tresearch\tmodel=opus'* && "$oc_status" == *$'critic\tcell out\tqa\tmodel=sonnet'* ]] || fail "status does not list the cells with role, model and state: $oc_status"
ok "add-cell records a read-only cell beside a one-writer run's lane, one namespace with it, and prints a READ-ONLY dispatch to its cells/<name>.md brief"
# a cell's brief never lands on a main lane's: lane cell-a's brief and cell a's are two files
"${tool[@]}" init sc --objective x --acceptance y --repo "$work" --verify true --lane cell-a --worker implementer --path src >/dev/null
"${tool[@]}" add-cell sc a --role research --model haiku >/dev/null
[[ "$(head -n1 "$real_work/.agents/worktrees/sc/.workloop/cell-a.md")" == "WORKLOOP WORKER BRIEF — sc/cell-a" ]] || fail "cell a's brief overwrote main lane cell-a's: $(head -n2 "$real_work/.agents/worktrees/sc/.workloop/cell-a.md")"
[[ "$(sed -n 2p "$real_work/.agents/worktrees/sc/.workloop/cells/a.md")" == "WORKLOOP CELL BRIEF — sc/a" ]] || fail "cell a's brief is not at cells/a.md"
"${tool[@]}" abandon sc >/dev/null
ok "a cell's brief and a main lane's never share a file, whatever the names"

# returned records where the result went or why none came; --again sends a cell out again
expect 'names no file (a relative path reads from the working directory); it names a file the lead wrote, or the word reply' "${tool[@]}" returned oc scout --result docs/oc/none.md
mkdir -p "$work/docs/oc"; printf 'found\n' > "$work/docs/oc/scout.md"
# a relative path reads from the working directory, not the run's checkout, and is stored absolute
expect 'names no file' bash -c 'cd "$1" && shift && "$@"' _ "$scratch" "${tool[@]}" returned oc scout --result docs/oc/scout.md
expect "cell 'scout' returned; still out: critic" bash -c 'cd "$1" && shift && "$@"' _ "$work/docs" "${tool[@]}" returned oc scout --result oc/scout.md
expect "cell 'scout' is returned, not out; brief oc scout --again sends it out again" "${tool[@]}" returned oc scout --result reply
expect "cell 'scout' is returned; a cell dispatched again is tracked again: brief oc scout --again" "${tool[@]}" brief oc scout
expect "cell 'critic' is out already; brief without --again reprints its prompt" "${tool[@]}" brief oc critic --again
python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["runs"]["oc"]["cells"]["scout"]; assert c["state"] == "returned" and c["result"] == sys.argv[2] and c["returned_at"], c' "$state" "$real_work/docs/oc/scout.md"
[[ "$("${tool[@]}" brief oc scout --again)" == "$cell_prompt" ]] || fail "brief --again did not print the cell's prompt"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["runs"]["oc"]; c=r["cells"]["scout"]; assert c["state"] == "out" and "result" not in c and "returned_at" not in c and r["events"][-1]["action"] == "brief-again", c' "$state"
expect "cell 'scout' failed" "${tool[@]}" returned oc scout --failed 'stopped by the operator'
expect "cell 'critic' returned" "${tool[@]}" returned oc critic --result reply
oc_status="$("${tool[@]}" status oc)"
[[ "$oc_status" == *$'scout\tcell failed\tresearch\tmodel=opus\treason=stopped by the operator'* && "$oc_status" == *$'critic\tcell returned\tqa\tmodel=sonnet\tresult=reply'* ]] || fail "status does not show the cells' outcomes: $oc_status"
ok "returned takes an existing path or reply, refuses a cell not out, --failed records why, and brief --again sends a returned or failed cell out again"

# check and teardown wait for a cell out and not for a failed one; integrate does not wait
"${tool[@]}" brief oc critic --again >/dev/null
"${tool[@]}" claim oc solo --agent oc1; printf 'cells\n' >> "$work/src/app.txt"; commit_paths "$work" cells src/app.txt
"${tool[@]}" submit oc solo --evidence ok >/dev/null; accept oc solo docs/oc/scout.md#ok
"${tool[@]}" qa oc --evidence 'scenario passed'
expect 'completion is blocked by cell:critic:out, verified:missing' "${tool[@]}" check oc --recorded
expect 'teardown waits for completion; blocked by cell:critic:out' "${tool[@]}" teardown oc
# a cell out does not keep check from running the composed test, and check names returned for it
oc_check="$("${tool[@]}" check oc 2>&1)" && fail "check passed with a cell out: $oc_check"
[[ "$oc_check" == *"completion is blocked by cell:critic:out"$'\n'"cell critic is out: returned oc critic --result <path|reply> when it comes back, or --failed '<why>'" ]] || fail "check did not run the composed test past a cell out, or named no remedy: $oc_check"
python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))["runs"]["oc"]["verified"]; assert v["result"] == "pass", v' "$state"
"${tool[@]}" returned oc critic --result reply >/dev/null
expect PASS "${tool[@]}" check oc
expect 'removed 0 worktree(s)' "${tool[@]}" teardown oc
[[ ! -e "$real_work/.agents/worktrees/oc" ]] || fail "teardown left the cell briefs: $(ls -R "$real_work/.agents/worktrees/oc")"
"${tool[@]}" init wc --objective x --acceptance y --repo "$work" --verify true >/dev/null
"${tool[@]}" add-cell wc qa1 --role qa --model sonnet >/dev/null
expect "run already has a lane or cell named 'qa1'" "${tool[@]}" add-lane wc qa1 --worker implementer --workspace "$scratch/lane-wc-qa1" --path tests
"${tool[@]}" add-lane wc one --worker implementer --workspace "$scratch/lane-wc" --path tests >/dev/null 2>&1
"${tool[@]}" claim wc one --agent wc1; mkdir -p "$scratch/lane-wc/tests"; printf 'c\n' > "$scratch/lane-wc/tests/c.txt"; commit "$scratch/lane-wc" c
"${tool[@]}" submit wc one --evidence ok >/dev/null; accept wc one tests/c.txt#ok
expect 'PASS: integrated one' "${tool[@]}" integrate wc --workspace "$scratch/integration-wc"
"${tool[@]}" qa wc --evidence ok
expect 'completion is blocked by cell:qa1:out' "${tool[@]}" check wc
"${tool[@]}" returned wc qa1 --result reply >/dev/null
expect PASS "${tool[@]}" check wc
"${tool[@]}" abandon wc --discard-branches >/dev/null
ok "a cell out blocks check and teardown, a failed one does not, and integrate merges with a QA cell still out"
# integrate drops exactly the cells' and QA's problems: a reopened lane named cell still blocks it
"${tool[@]}" init ic --objective x --acceptance y --repo "$work" --verify true >/dev/null
"${tool[@]}" add-lane ic cell --worker implementer --workspace "$scratch/lane-ic" --path tests >/dev/null 2>&1
"${tool[@]}" add-cell ic q --role qa --model sonnet >/dev/null
"${tool[@]}" claim ic cell --agent ic1; mkdir -p "$scratch/lane-ic/tests"; printf 'c\n' > "$scratch/lane-ic/tests/c.txt"; commit "$scratch/lane-ic" c
"${tool[@]}" submit ic cell --evidence ok >/dev/null
"${tool[@]}" review ic cell --reference tests/c.txt#p1 --result reopen --severity P1 >/dev/null
expect 'integration is blocked by cell:reopened, cell:attention$' "${tool[@]}" integrate ic --workspace "$scratch/integration-ic"
"${tool[@]}" abandon ic --discard-branches >/dev/null
ok "integrate drops exactly cell_problems and qa:missing, never a lane's problem by its name's prefix"

# ── a run declared without --verify is a read-only fan-out (ruling 35) ───────
out="$("${tool[@]}" init fo --objective 'three scouts' --acceptance 'three answers' --repo "$work")" || fail "init without --verify and --lane was refused: $out"
[[ "$out" == *"created workloop 'fo'"*"a read-only fan-out: it holds cells only (add-cell fo <name>"* ]] || fail "init did not name the fan-out's next step: $out"
expect 'completion is blocked by run:empty' "${tool[@]}" check fo
# each command says what a fan-out needs: an empty one a cell, qa and integrate nothing
expect '^the run holds no lane or cell: add-cell fo <name> --role research|review|qa --model <model>$' "${tool[@]}" check fo
expect "^workloop: run 'fo' declared no --verify, so it has nothing to merge: a read-only fan-out holds cells only, and check fo passes once every cell is back$" "${tool[@]}" integrate fo
expect "run has no lane or cell named 'nobody'" "${tool[@]}" brief fo nobody
expect "this run declared no --verify, so it holds read-only cells only; a writer that will follow starts with init <run> … --verify '<test command>' --lane <name> --worker <type> --path <p> (widen grows its paths later)" "${tool[@]}" add-lane fo w --worker implementer --path tests
if "${tool[@]}" status fo | grep -q '^qa'; then fail "a fan-out's status shows a QA line"; fi
for c in a b c; do "${tool[@]}" add-cell fo "$c" --role research --model haiku >/dev/null; done
expect 'completion is blocked by cell:a:out, cell:b:out, cell:c:out' "${tool[@]}" check fo
"${tool[@]}" returned fo a --result reply >/dev/null; "${tool[@]}" returned fo b --failed 'usage limit' >/dev/null
expect 'teardown waits for completion; blocked by cell:c:out' "${tool[@]}" teardown fo
expect "run 'fo' declared no --verify: a read-only fan-out records no QA, and check fo passes once every cell is back" "${tool[@]}" qa fo --evidence x
"${tool[@]}" returned fo c --result reply >/dev/null
expect "PASS: 'fo' is a read-only fan-out and every cell is back" "${tool[@]}" check fo
python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["runs"]["fo"]; assert r["verify"] is None and r["qa"] is None and "verified" not in r, r' "$state"
expect 'removed 0 worktree(s)' "${tool[@]}" teardown fo
[[ ! -e "$real_work/.agents/worktrees/fo" && "$(worktree_paths)" == "$worktrees_before" ]] || fail "the fan-out's teardown left briefs or touched worktrees"
# a torn-down run takes no cell: nothing would wait for it
expect "run 'fo' is torn down, so nothing waits for a cell sent out on it" "${tool[@]}" add-cell fo d --role research --model haiku
expect "run 'fo' is torn down, so nothing waits for a cell sent out on it" "${tool[@]}" brief fo a --again
python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["runs"]["fo"]; assert "d" not in r["cells"] and r["cells"]["a"]["state"] == "returned", r["cells"]' "$state"
# a cell added while teardown releases the run is caught under teardown's write lock
"${tool[@]}" init tg --objective x --acceptance y --repo "$work" >/dev/null
"${tool[@]}" add-cell tg early --role research --model haiku >/dev/null; "${tool[@]}" returned tg early --result reply >/dev/null
mkdir -p "$scratch/bin-late"
printf '#!/usr/bin/env bash\n[[ -e "%s/late.done" ]] || { touch "%s/late.done"; %s add-cell tg late --role review --model opus >/dev/null; }\nexec "%s/bin/docker" "$@"\n' \
  "$scratch" "$scratch" "${tool[*]}" "$scratch" > "$scratch/bin-late/docker"
chmod +x "$scratch/bin-late/docker"
expect 'completion changed while teardown ran: blocked by cell:late:out;.*close it with abandon tg' env PATH="$scratch/bin-late:$PATH" "${tool[@]}" teardown tg
[[ -e "$scratch/late.done" ]] || fail "the late cell was never added during teardown"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["runs"]["tg"]; assert not r.get("torn_down") and r["cells"]["late"]["state"] == "out", r' "$state"
"${tool[@]}" returned tg late --result reply >/dev/null; expect "abandoned 'tg'" "${tool[@]}" abandon tg
ok "add-cell and brief --again refuse a torn-down run, and teardown refuses inside its write lock when a cell went out while it released the run"
# a run with --verify and no lane yet is not finished: scouts returned before the first add-lane never let it close
"${tool[@]}" init pre --objective x --acceptance y --repo "$work" --verify true >/dev/null
"${tool[@]}" add-cell pre scout --role research --model haiku >/dev/null; "${tool[@]}" returned pre scout --result reply >/dev/null
expect 'completion is blocked by qa:missing, lanes:none' "${tool[@]}" check pre --recorded
"${tool[@]}" abandon pre >/dev/null
ok "a run without --verify takes cells and no lane, needs no QA or composed test, and is finished once every cell is back; one with --verify and no lane yet is not"

# ── a lane's model is recorded, printed in its brief and in status; absent prints nothing ──
expect '\-\-model needs --lane' "${tool[@]}" init om --objective x --acceptance y --repo "$work" --verify true --model opus
"${tool[@]}" init om --objective x --acceptance y --repo "$work" --verify true --lane m --worker implementer --path src --model opus >/dev/null
grep -qx 'Model: opus' "$real_work/.agents/worktrees/om/.workloop/m.md" || fail "the main lane's brief lacks its model: $(cat "$real_work/.agents/worktrees/om/.workloop/m.md")"
[[ "$("${tool[@]}" status om)" == *$'m\tready\tpending=0\timplementer\tmodel=opus\tsrc'* ]] || fail "status does not show the main lane's model: $("${tool[@]}" status om)"
python3 -c 'import json,sys; l=json.load(open(sys.argv[1]))["runs"]["om"]["lanes"]["m"]; assert l["model"] == "opus", l' "$state"
"${tool[@]}" abandon om >/dev/null
"${tool[@]}" init wm --objective x --acceptance y --repo "$work" --verify true >/dev/null
"${tool[@]}" add-lane wm with --worker implementer --workspace "$scratch/lane-wm-with" --path tests --model sonnet >/dev/null 2>&1
"${tool[@]}" add-lane wm without --worker implementer --workspace "$scratch/lane-wm-without" --path docs >/dev/null 2>&1
grep -qx 'Model: sonnet' <<<"$(full_brief wm with)" || fail "a worktree lane's brief lacks its model"
! grep -q '^Model:' <<<"$(full_brief wm without)" || fail "a lane without --model prints a Model line"
wm_status="$("${tool[@]}" status wm)"
[[ "$wm_status" == *$'with\tready\tpending=0\timplementer\tmodel=sonnet\ttests'* && "$wm_status" == *$'without\tready\tpending=0\timplementer\tdocs'* ]] || fail "status does not show a lane's model, or shows one it has not: $wm_status"
"${tool[@]}" abandon wm --discard-branches >/dev/null
ok "init --lane --model and add-lane --model record a lane's model for its brief and status; a lane without one prints nothing"

# ── the controller's modules import one another without a cycle ──────────────
python3 - "$repo/.agents" <<'EOF' || fail "the controller's module structure regressed"
import ast, sys
from pathlib import Path
modules = {path.stem: ast.parse(path.read_text()) for path in Path(sys.argv[1]).glob("workloop*.py")}
graph = {}
for name, tree in modules.items():
    names = {alias.name for node in ast.walk(tree) if isinstance(node, ast.Import) for alias in node.names}
    names |= {node.module for node in ast.walk(tree) if isinstance(node, ast.ImportFrom) and node.module}
    graph[name] = names & modules.keys()
def cycle(name, path):
    if name in path:
        return path[path.index(name):] + [name]
    return next((found for dep in sorted(graph[name]) if (found := cycle(dep, path + [name]))), None)
found = next((found for name in sorted(graph) if (found := cycle(name, []))), None)
if found:
    sys.exit("import cycle: " + " -> ".join(found))
wide = [f"{node.name} takes {len(node.args.args)}" for node in ast.walk(modules["workloop_cells"])
        if isinstance(node, ast.FunctionDef) and len(node.args.args) > 4]
if wide:
    sys.exit("workloop_cells functions over four parameters: " + ", ".join(wide))
EOF
ok "the controller's modules import one another without a cycle, and no cell function takes over four parameters"

# ── a state file from before pinned bases is refused ─────────────────────────
python3 - "$state" <<'EOF'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["runs"]["legacy"] = dict(s["runs"]["demo"], base="HEAD"); s["runs"]["legacy"].pop("repo"); json.dump(s, open(p, "w"))
EOF
expect 'predates pinned bases' "${tool[@]}" status legacy
ok "a run without a pinned base is refused"

rm "$state.lock"
if "${tool[@]}" status supervised 2>/dev/null; then fail 'read-only status recreated a missing lock'; fi
printf 'PASS: workloop controller\n'
