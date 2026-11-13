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
  "ps -aq --filter label=colloid.run=abgone") printf 'cg1\n' ;;
  "ps -aq --filter label=com.docker.compose.project=abgone-one") printf 'cg2\n' ;;
  "volume ls -q --filter label=colloid.run=abfail") printf 'v9\n' ;;
  "volume rm -f v9") [[ -z "${DOCKER_V9_BUSY:-}" ]] || { echo "volume is in use" >&2; exit 1; } ;;
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
expect 'qa:stale' "${tool[@]}" check multi
"${tool[@]}" qa multi --evidence 'scenarios passed again'
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
grep -q "lane y conflicts with lane x in docs/review.md; rebase y onto x's branch (clash/x), resolve it there and re-submit y" <<<"$err" || fail "conflict did not name the lanes, the path and the remedy: $err"
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


# ── a checkout that is not readable: abandon waits for the operator's word ───
# A missing folder may be a deleted checkout or an unmounted disk, and the
# session-end sweep runs abandon unattended, so only --checkout-gone drops it,
# once the folder is gone and no surviving checkout still holds the run.
git clone -q "$work" "$scratch/gone-repo"
"${tool[@]}" init abgone --objective x --acceptance y --repo "$scratch/gone-repo" --verify true
"${tool[@]}" add-lane abgone one --worker implementer --workspace "$scratch/lane-gone" --path src --path docs
"${tool[@]}" claim abgone one --agent abg1
printf 'gone change\n' >> "$scratch/lane-gone/src/app.txt"; commit "$scratch/lane-gone" 'gone change'
mkdir -p "$scratch/lane-gone/docs/reviews"; printf 'ok\n' > "$scratch/lane-gone/docs/reviews/gone.md"; commit "$scratch/lane-gone" review
"${tool[@]}" submit abgone one --evidence 'unit test passed'
accept abgone one docs/reviews/gone.md#accepted
"${tool[@]}" qa abgone --evidence 'scenario passed'
expect 'PASS: integrated one' "${tool[@]}" integrate abgone --workspace "$scratch/int-gone"
rm -rf "$scratch/gone-repo"
: > "$DOCKER_LOG"
out="$("${tool[@]}" abandon abgone 2>&1)" && fail "abandon dropped a run whose checkout is not on disk, unasked: $out"
grep -q "gone-repo is not on disk.*mount or repair it and rerun.*rerun with --checkout-gone" <<<"$out" || fail "the refusal did not say how to go on: $out"
"${tool[@]}" status abgone >/dev/null 2>&1 || fail 'a refused abandon removed the run from state'
mkdir "$scratch/gone-repo"
out="$("${tool[@]}" abandon abgone 2>&1)" && fail "abandon dropped a run whose checkout git cannot read, unasked: $out"
grep -q "gone-repo is not a checkout git can read: fatal: not a git repository" <<<"$out" || fail "the refusal did not quote git's reason: $out"
expect "gone-repo is still there (is not a checkout git can read.*move it away and rerun with --checkout-gone" "${tool[@]}" abandon abgone --checkout-gone
"${tool[@]}" status abgone >/dev/null 2>&1 || fail 'abandon --checkout-gone dropped a run whose checkout folder is still there'
[[ ! -s "$DOCKER_LOG" ]] || fail "a refused abandon touched docker: $(cat "$DOCKER_LOG")"
rmdir "$scratch/gone-repo"
out="$("${tool[@]}" abandon abgone --checkout-gone --discard-branches 2>&1)" || fail "abandon --checkout-gone refused: $out"
grep -q "abandoned 'abgone': its checkout .*gone-repo is gone, so no worktree or branch was touched" <<<"$out" || fail "abandon did not report closing the run: $out"
grep -q "no branch was deleted: the run's branches went with its checkout" <<<"$out" || fail "abandon did not say --discard-branches reached nothing: $out"
grep -q "left folder .*/lane-gone: it holds the only copy left of its work; copy out what you need" <<<"$out" || fail "abandon did not name the lane folder it left: $out"
grep -q "left folder .*/int-gone: it holds" <<<"$out" || fail "abandon did not name the integration folder it left: $out"
! grep -q "folder .*gone-repo" <<<"$out" || fail "abandon named a folder that went with the checkout: $out"
[[ -d "$scratch/lane-gone/src" && -d "$scratch/int-gone/src" ]] || fail 'abandon deleted a folder whose checkout is gone'
if "${tool[@]}" status abgone 2>/dev/null; then fail 'abandon --checkout-gone left the run in state'; fi
grep -qx 'rm -f cg1 cg2' "$DOCKER_LOG" || fail "abandon did not remove a gone checkout's labelled and compose containers: $(cat "$DOCKER_LOG")"
rm -rf "$scratch/lane-gone" "$scratch/int-gone"
ok "abandon refuses a missing or unreadable checkout without --checkout-gone and a folder still there with it, touching nothing; then reaps, and names every folder it leaves"

# An empty mount point left by an unmounted disk inside another repository is
# not that repository: reading it as one would release through the wrong checkout.
mkdir -p "$scratch/home-repo/mnt"; printf 'dotfiles\n' > "$scratch/home-repo/f"; git -C "$scratch/home-repo" init -q; commit "$scratch/home-repo" home
git clone -q "$work" "$scratch/home-repo/mnt/disk"
"${tool[@]}" init abmount --objective x --acceptance y --repo "$scratch/home-repo/mnt/disk" --verify true
mv "$scratch/home-repo/mnt/disk" "$scratch/disk-away"; mkdir "$scratch/home-repo/mnt/disk"
: > "$DOCKER_LOG"
out="$("${tool[@]}" abandon abmount 2>&1)" && fail "abandon released an empty mount point through the repository around it: $out"
grep -q "disk is not a checkout of its own: git reads it as part of .*home-repo" <<<"$out" || fail "the refusal did not name the enclosing repository: $out"
expect "disk is still there" "${tool[@]}" abandon abmount --checkout-gone
"${tool[@]}" status abmount >/dev/null 2>&1 || fail 'abandon dropped a run whose checkout is an empty mount point'
[[ ! -s "$DOCKER_LOG" ]] || fail "a refused abandon touched docker: $(cat "$DOCKER_LOG")"
rmdir "$scratch/home-repo/mnt/disk"; mv "$scratch/disk-away" "$scratch/home-repo/mnt/disk"
expect "abandoned 'abmount': removed 0 worktree(s)" "${tool[@]}" abandon abmount
rm -rf "$scratch/home-repo"
ok "an empty mount point inside another repository is refused, with or without --checkout-gone"

# A checkout git refuses (here its owner differs) is named with git's reason.
"${tool[@]}" init abreadable --objective x --acceptance y --repo "$work" --verify true
expect "checkout .* is readable.*abandon it without --checkout-gone" "${tool[@]}" abandon abreadable --checkout-gone
"${tool[@]}" status abreadable >/dev/null 2>&1 || fail 'abandon --checkout-gone dropped a run whose checkout is readable'
out="$(GIT_TEST_ASSUME_DIFFERENT_OWNER=1 "${tool[@]}" abandon abreadable 2>&1)" && fail "abandon dropped a run whose checkout git refuses: $out"
grep -q "is not a checkout git can read: fatal: detected dubious ownership" <<<"$out" || fail "the refusal did not quote git's reason: $out"
"${tool[@]}" abandon abreadable >/dev/null
ok "--checkout-gone is refused on a readable checkout, and a checkout git refuses is named with git's reason"

# A deleted linked worktree leaves its branches in the main checkout, which
# a surviving lane folder leads back to; the release goes through it.
git clone -q "$work" "$scratch/main-lw"
git -C "$scratch/main-lw" worktree add -q "$scratch/wt-lw" -b lw-base
"${tool[@]}" init ablw --objective x --acceptance y --repo "$scratch/wt-lw" --verify true
"${tool[@]}" add-lane ablw one --worker implementer --workspace "$scratch/lane-lw" --path src
"${tool[@]}" claim ablw one --agent lw1
printf 'lw change\n' >> "$scratch/lane-lw/src/app.txt"; commit "$scratch/lane-lw" 'lw change'
rm -rf "$scratch/wt-lw"
expect "wt-lw is not on disk" "${tool[@]}" abandon ablw
out="$("${tool[@]}" abandon ablw --checkout-gone 2>&1)" || fail "abandon --checkout-gone refused a deleted linked worktree: $out"
grep -q "abandoned 'ablw': its checkout .*wt-lw is gone; released its worktrees and branches through .*main-lw: removed 1 worktree(s)" <<<"$out" || fail "abandon did not release through the main checkout: $out"
grep -q "kept branch ablw/one" <<<"$out" || fail "abandon did not name the branch it kept: $out"
git -C "$scratch/main-lw" rev-parse --verify -q ablw/one >/dev/null || fail 'abandon deleted a branch HEAD does not contain'
[[ ! -e "$scratch/lane-lw" ]] || fail 'abandon left the lane worktree the main checkout could remove'
if "${tool[@]}" status ablw 2>/dev/null; then fail 'abandon left the run in state'; fi
rm -rf "$scratch/main-lw"
ok "a deleted linked worktree's run is released through the main checkout that still holds its branches"

git clone -q "$work" "$scratch/fail-repo"
"${tool[@]}" init abfail --objective x --acceptance y --repo "$scratch/fail-repo" --verify true
"${tool[@]}" add-lane abfail one --worker implementer --workspace "$scratch/lane-fail" --path src
rm -rf "$scratch/fail-repo" "$scratch/lane-fail"
out="$(DOCKER_V9_BUSY=1 "${tool[@]}" abandon abfail --checkout-gone 2>&1)" && fail "abandon dropped a run whose reap failed: $out"
grep -q 'volumes v9: volume is in use' <<<"$out" && grep -q "run 'abfail' is still in state" <<<"$out" || fail "a failed reap was not reported: $out"
"${tool[@]}" status abfail >/dev/null 2>&1 || fail 'a failed reap removed the run from state'
out="$("${tool[@]}" abandon abfail --checkout-gone 2>&1)" || fail "the retried abandon failed: $out"
grep -q "folder .*/lane-fail is not on disk: if it is on a disk that is not mounted, its files are still there" <<<"$out" || fail "abandon did not name a lane folder that is not on disk: $out"
if "${tool[@]}" status abfail 2>/dev/null; then fail 'the retried abandon left the run in state'; fi
ok "a failed reap keeps the run, the retry closes it, and a lane folder not on disk is named"


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
# a failing verify's output keeps the failure lines that scrolled above its last 40 lines
ow_verify="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runs"]["ow"]["verify"])' "$state")"
# stdin is the script a verify prints; its exit status is the next argument; the run's check output comes back
ow_check_printing() {
  printf '%s\n' "$1" > "$scratch/verify-out.sh"
  python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); r=s["runs"]["ow"]; r["verify"]="bash "+sys.argv[2]; r["verified"]["result"]="fail"; json.dump(s, open(p,"w"))' "$state" "$scratch/verify-out.sh"
  "${tool[@]}" check ow 2>&1 || true
}
label='failure lines above the tail:'
out="$(ow_check_printing 'echo "FAIL: first"; echo "Traceback (most recent call last):"; echo "AssertionError: boom"; for i in $(seq 100); do echo "ok $i"; done; exit 1')"
[[ "$out" == *"$label"* && "$out" == *"FAIL: first"* && "$out" == *"Traceback (most recent call last):"* && "$out" == *"AssertionError: boom"* && "$out" != *"ok 1"$'\n'* ]] || fail "a failure above the tail was lost: $out"
out="$(ow_check_printing 'for i in $(seq 100); do echo "ok $i"; done; echo "FAIL: late"; for i in $(seq 5); do echo "ok tail $i"; done; exit 1')"
[[ "$out" != *"$label"* && "$(grep -c 'FAIL: late' <<<"$out")" == 1 ]] || fail "a failure inside the tail was repeated or labelled: $out"
out="$(ow_check_printing 'for i in $(seq 25); do echo "FAIL: row $i"; done; for i in $(seq 40); do echo "ok $i"; done; exit 1')"
[[ "$out" == *"$label"* && "$(grep -c '^FAIL: row' <<<"$out")" == 20 && "$out" == *"FAIL: row 20"* && "$out" != *"FAIL: row 21"* && "$out" == *"… and 5 more failure lines"* ]] || fail "the cap on failure lines above the tail was wrong: $out"
# check prints nothing of a passing verify, so its recorded text is read instead
ow_check_printing 'echo "FAIL: passed anyway"; for i in $(seq 100); do echo "ok $i"; done; exit 0' >/dev/null
recorded="$(python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))["runs"]["ow"]["verified"]; print(v["result"]); print(v["tail"])' "$state")"
[[ "$recorded" == pass$'\n'* && "$recorded" != *"$label"* && "$recorded" == *"ok 100" ]] || fail "a passing verify was labelled: $recorded"
out="$(ow_check_printing 'echo "not ok 7 - x"; echo "noise line"; echo "  note FAIL: y"; echo "Error: Cannot find module z"; echo "AssertionError"; for i in $(seq 45); do echo "ok $i"; done; exit 1')"
kept="$(awk -v a="$label" -v b='last 40 lines:' '$0==a {on=1; next} $0==b {on=0} on' <<<"$out")"
[[ "$kept" == $'not ok 7 - x\n  note FAIL: y\nError: Cannot find module z\nAssertionError' ]] || fail "the failure lines above the tail were not each form, in order, without the noise line: $kept"
python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); r=s["runs"]["ow"]; r["verify"]=sys.argv[2]; r["verified"]["result"]="fail"; json.dump(s, open(p,"w"))' "$state" "$ow_verify"
expect PASS "${tool[@]}" check ow
rm -f "$mark"
ok "a failing verify shows up to 20 failure lines from above its last 40, each once, and says how many more there were"
# the run reads live state after its review: a lane-path commit or a dirty lane path makes it stale everywhere
printf 'after\n' >> "$work/src/app.txt"; commit_paths "$work" after src/app.txt; after_sha="$(git -C "$work" rev-parse HEAD)"
expect "completion is blocked by solo:moved-after-review"$'\n'"the checkout has commits touching the lane's paths after its accepted tip ${late_sha:0:12}; re-submit the lane for review" "${tool[@]}" check ow
expect 'solo:moved-after-review' "${tool[@]}" check ow --recorded
expect 'teardown waits for completion; blocked by solo:moved-after-review' "${tool[@]}" teardown ow
[[ ! -e "$mark" ]] || fail "check ran the composed test for a lane that moved after its review"
# a re-submission is a review round like any other: this is the lane's fourth, so the accept carries a ruling
"${tool[@]}" submit ow solo --evidence 'verify passed' >/dev/null 2>&1; accept ow solo docs/ow/review.md#ok --ruling 'moved after review; review it again'
expect 'verified:stale' "${tool[@]}" check ow --recorded
"${tool[@]}" qa ow --evidence 'scenario passed on the new tip'
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
# ── the open-gates line: the root contract's sentence and the briefs' line, as tested in fresh sessions ──
# A reviewer and a review cell close with their own contract's lines instead.
root_gates='A final message that leaves a gate or a ruling open ends with one line for each, `needs_confirmation: <gate> — <what waits> — <how to resume>`.'
open_gates='Open gates: finish the work no gate holds, then end your final message with one line per open gate or open ruling, `needs_confirmation: <gate> — <what waits> — <how to resume>`; never skip one.'
grep -qF -- "$root_gates" "$repo/AGENTS.md" || fail "the root AGENTS.md lacks the open-gates sentence: $root_gates"
grep -qxF -- "$open_gates" <<<"$(full_brief oc solo)" || fail "the worker brief lacks the open-gates line"
grep -qxF -- "$open_gates" <<<"$(full_brief oc solo --role qa)" || fail "the qa brief lacks the open-gates line"
grep -qxF -- "$open_gates" "$cell_file" || fail "the research cell's brief lacks the open-gates line"
! grep -qF -- 'needs_confirmation:' <<<"$(full_brief oc solo --role reviewer)" || fail "the reviewer brief carries the open-gates line beside its contract's closing lines"
"${tool[@]}" init og --objective x --acceptance y --repo "$work" --verify true --lane og-lane --worker implementer --path src >/dev/null
"${tool[@]}" add-cell og judge --role review --model sonnet >/dev/null
! grep -qF -- 'needs_confirmation:' "$real_work/.agents/worktrees/og/.workloop/cells/judge.md" || fail "a review cell's brief carries the open-gates line"
"${tool[@]}" abandon og >/dev/null
ok "the root contract, the worker and qa briefs and a research cell's brief carry the open-gates line; a reviewer's and a review cell's do not"
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
# a run that had no worktree prunes none: another worktree whose folder is away keeps its registration
git -C "$work" worktree add -q --detach "$scratch/s7-away" && mv "$scratch/s7-away" "$scratch/s7-moved"
"${tool[@]}" init s7 --objective x --acceptance y --repo "$work" >/dev/null
"${tool[@]}" add-cell s7 a --role research --model haiku >/dev/null; "${tool[@]}" returned s7 a --result reply >/dev/null
expect "abandoned 's7'" "${tool[@]}" abandon s7
git -C "$work" worktree list --porcelain | grep -q "^worktree .*/s7-away$" || fail "abandon of a run with no worktree pruned another worktree's registration"
mv "$scratch/s7-moved" "$scratch/s7-away" && git -C "$work" worktree remove --force "$scratch/s7-away"
ok "abandon prunes worktree registrations only for a run that had a worktree"
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

# ── share: a path lanes edit without owning, merged by Git or rebuilt at integrate ──
shr_repo() {  # <dir>: the fixture for the shared-file rows
  git init -q "$1"; git -C "$1" config user.email test@example.com; git -C "$1" config user.name test
  mkdir -p "$1/a" "$1/b" "$1/gen" "$1/docs"
  printf 'l1\nl2\nl3\n' > "$1/README.md"; printf 'x\n' > "$1/a/dep.txt"; printf 'y\n' > "$1/b/dep.txt"
  printf '{"name":"f","lockfileVersion":3}\n' > "$1/package-lock.json"; printf 'base-lock\n' > "$1/lock.txt"
  printf 'old\n' > "$1/gen/api.json"; printf 'review\n' > "$1/docs/review.md"
  printf 'node_modules/\n.agents/worktrees/\n' > "$1/.gitignore"
  git -C "$1" add . && git -C "$1" commit -qm base
}
shr_init() {  # <run> <verify> <lane>...: a fixture repository, the run, and one lane per name owning the folder of that name
  local run="$1" verify="$2"; shift 2
  shr_repo "$scratch/$run-repo"
  "${tool[@]}" init "$run" --objective x --acceptance y --repo "$scratch/$run-repo" --verify "$verify" >/dev/null
  for l in "$@"; do "${tool[@]}" add-lane "$run" "$l" --worker implementer --workspace "$scratch/$run-$l" --path "$l" >/dev/null 2>&1; done
}
shr_done() {  # <run> <lane>: claim, commit the worktree, submit, accept
  "${tool[@]}" claim "$1" "$2" --agent "$2" >/dev/null
  commit "$scratch/$1-$2" "$2 work"
  "${tool[@]}" submit "$1" "$2" --evidence ok >/dev/null
  accept "$1" "$2" docs/review.md#ok >/dev/null
}
shr_integrate() { "${tool[@]}" integrate "$1" --workspace "$scratch/int-$1" 2>&1; }
run_field() {  # <run> <key>...: a JSON value from the state file
  python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))["runs"][sys.argv[2]]
for k in sys.argv[3:]: v=v.get(k) if isinstance(v,dict) else v
print(json.dumps(v,sort_keys=True))' "$state" "$@"
}
LOCK='cat a/dep.txt b/dep.txt | LC_ALL=C sort > lock.txt'

# refusals, and the forms of a repeated share
shr_init sh1 true a b
expect "lane 'a' owns it" "${tool[@]}" share sh1 a/dep.txt
expect "lane 'b' owns it" "${tool[@]}" share sh1 b
"${tool[@]}" init fan --objective x --acceptance y --repo "$scratch/sh1-repo" >/dev/null
expect 'declared no --verify' "${tool[@]}" share fan README.md
"${tool[@]}" init one --objective x --acceptance y --repo "$scratch/sh1-repo" --verify true --lane solo --worker implementer --path a >/dev/null
expect 'one-writer run merges nothing' "${tool[@]}" share one lock.txt --rebuild "$LOCK"
expect 'shared README.md' "${tool[@]}" share one README.md
python3 - "$state" <<'EOF2'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["runs"]["gone"] = json.loads(json.dumps(s["runs"]["sh1"])); s["runs"]["gone"]["torn_down"] = {"at": "x"}; json.dump(s, open(p, "w"))
EOF2
expect 'is torn down' "${tool[@]}" share gone README.md
expect 'rebuild command refused' "${tool[@]}" share sh1 lock.txt --rebuild 'git push origin main'
[[ "$(run_field sh1 shared)" == '[]' ]] || fail "a refused share changed the shared list: $(run_field sh1 shared)"
ok "share refuses a path a lane owns, a fan-out, a rebuild on a one-writer run, a torn-down run and a rebuild command the guards refuse"
expect 'shared lock.txt (rebuilt by: echo one)' "${tool[@]}" share sh1 lock.txt --rebuild 'echo one'
expect 'lock.txt is already shared, rebuilt by: echo one' "${tool[@]}" share sh1 lock.txt
[[ "$(run_field sh1 rebuild)" == '{"lock.txt": "echo one"}' ]] || fail "a share without --rebuild changed the command"
expect 'rebuilt by: echo two' "${tool[@]}" share sh1 lock.txt --rebuild 'echo two'
[[ "$(run_field sh1 rebuild)" == '{"lock.txt": "echo two"}' && "$(run_field sh1 shared)" == '["lock.txt"]' ]] || fail "re-sharing did not replace the command in place"
expect $'shared\tlock.txt (rebuilt by: echo two)' "${tool[@]}" status sh1
expect 'shared lock.txt$' "${tool[@]}" share sh1 lock.txt --rebuild ''
[[ "$(run_field sh1 rebuild)" == '{}' && "$(run_field sh1 shared)" == '["lock.txt"]' ]] || fail "--rebuild '' did not clear the command"
"${tool[@]}" share sh1 gen >/dev/null
expect 'shared gen/api.json (rebuilt by: echo nested)' "${tool[@]}" share sh1 gen/api.json --rebuild 'echo nested'
[[ "$(run_field sh1 shared)" == '["lock.txt", "gen", "gen/api.json"]' ]] || fail "a rebuild path inside a merged shared path was refused or reordered"
expect 'gen is shared with no rebuild command, so there is none to clear' "${tool[@]}" share sh1 gen --rebuild ''
expect "already shared with that rebuild command" "${tool[@]}" share sh1 gen/api.json --rebuild 'echo nested'
ok "a repeated share sets, keeps, replaces or clears the rebuild command in place; a rebuild path may sit inside a merged one"

# lanes declared before a share learn it from a fresh brief
"${tool[@]}" claim sh1 a --agent sh1a >/dev/null
out="$("${tool[@]}" share sh1 README.md)"
[[ "$out" == *"brief sh1 a"* && "$out" != *"brief sh1 b"* ]] || fail "share did not name the claimed lane alone: $out"
grep -q "^\.agents/workloop\.py --state .*/state\.json brief sh1 a$" <<<"$out" || fail "share did not print the full re-brief command: $out"
"${tool[@]}" share sh1 docs/rules --rebuild 'echo r' >/dev/null
expect 'Shared paths: lock.txt, gen, gen/api.json, README.md, docs/rules' full_brief sh1 a
expect 'Shared path README.md — merged by Git: any lane may edit it. Append only; never restructure or reorder existing lines.' full_brief sh1 a
expect 'same end of a list still conflict, so add in the middle of a sorted list' full_brief sh1 a
expect 'Shared path docs/rules — rebuilt at integrate by `echo r`: change it to test in your worktree and commit it with your work; integrate replaces it' full_brief sh1 a
expect 'rebase onto its branch and resolve shared-path conflicts in your worktree' full_brief sh1 a
ok "share names the claimed lanes to re-brief, and the brief states each shared path's rule"

# a conflict on a merged shared path names both lanes, the path and the remedy
shr_init sh2 true a b
"${tool[@]}" share sh2 README.md >/dev/null
printf 'l1\nA\nl3\n' > "$scratch/sh2-a/README.md"; printf 'l1\nB\nl3\n' > "$scratch/sh2-b/README.md"
shr_done sh2 a; shr_done sh2 b
"${tool[@]}" qa sh2 --evidence ok >/dev/null
out="$(shr_integrate sh2)" && fail "two lanes' README edits integrated: $out"
grep -q "lane b conflicts with lane a in README.md; rebase b onto a's branch (sh2/a), resolve it there and re-submit b" <<<"$out" || fail "the conflict did not name both lanes, the path and the remedy: $out"
[[ -z "$(git -C "$scratch/int-sh2" status --porcelain)" ]] || fail "the conflict left the integration tree dirty"
ok "a shared-path conflict names both lanes, the path and the rebase remedy"

# two lanes' lockfiles conflict as text; a rebuild path is rebuilt once instead
shr_init sh3 'grep -q adep lock.txt && grep -q bdep lock.txt' a b
"${tool[@]}" share sh3 lock.txt --rebuild "$LOCK" >/dev/null
printf 'x\nadep\n' > "$scratch/sh3-a/a/dep.txt"; printf 'lock-a\n' > "$scratch/sh3-a/lock.txt"
printf 'y\nbdep\n' > "$scratch/sh3-b/b/dep.txt"; printf 'lock-b\n' > "$scratch/sh3-b/lock.txt"
shr_done sh3 a; shr_done sh3 b
probe="$scratch/sh3-probe"; git clone -q "$scratch/sh3-repo" "$probe"
git -C "$probe" checkout -q -b probe origin/sh3/a
if git -C "$probe" merge -q --no-edit origin/sh3/b >/dev/null 2>&1; then fail "the fixture's lockfiles do not conflict as plain Git merges"; fi
"${tool[@]}" qa sh3 --evidence ok >/dev/null
out="$(shr_integrate sh3)" || fail "integrate failed over two lanes' conflicting lockfiles: $out"
[[ "$(git -C "$scratch/int-sh3" show HEAD:lock.txt)" == $'adep\nbdep\nx\ny' ]] || fail "lock.txt is not the rebuilt copy: $(git -C "$scratch/int-sh3" show HEAD:lock.txt)"
[[ "$(git -C "$scratch/int-sh3" log -1 --format=%s)" == "integrate: rebuild lock.txt" ]] || fail "the rebuild was not committed: $(git -C "$scratch/int-sh3" log -1 --format=%s)"
[[ "$(git -C "$scratch/int-sh3" log --format=%s | grep -c '^integrate: rebuild')" == 1 ]] || fail "more than one rebuild commit"
[[ "$(run_field sh3 integration rebuilt)" == "{\"lock.txt\": \"$LOCK\"}" && "$(run_field sh3 integration shared)" == '["lock.txt"]' ]] || fail "the integration record lacks rebuilt/shared: $(run_field sh3 integration)"
expect PASS "${tool[@]}" check sh3
ok "two lanes' conflicting lockfiles integrate: each lane merge takes the path from the base and one rebuild commit lands before the composed test"

# a dependent lane rebased onto its producer, both changing the lockfile
shr_init sh4 'grep -q adep lock.txt && grep -q bdep lock.txt' a b
"${tool[@]}" share sh4 lock.txt --rebuild "$LOCK" >/dev/null
python3 - "$state" <<'EOF2'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["runs"]["sh4"]["lanes"]["b"]["depends_on"] = ["a"]; json.dump(s, open(p, "w"))
EOF2
printf 'x\nadep\n' > "$scratch/sh4-a/a/dep.txt"; printf 'lock-a\n' > "$scratch/sh4-a/lock.txt"
shr_done sh4 a
git -C "$scratch/sh4-b" rebase -q sh4/a
printf 'y\nbdep\n' > "$scratch/sh4-b/b/dep.txt"; printf 'lock-a\nlock-b\n' > "$scratch/sh4-b/lock.txt"
shr_done sh4 b
"${tool[@]}" qa sh4 --evidence ok >/dev/null
out="$(shr_integrate sh4)" || fail "a dependent lane over a producer that also changed the lockfile did not integrate: $out"
[[ "$(git -C "$scratch/int-sh4" show HEAD:lock.txt)" == $'adep\nbdep\nx\ny' ]] || fail "dependent lane's lockfile was not rebuilt"
ok "a dependent lane rebased onto a producer that also changed the lockfile integrates"

# a directory rebuild path drops a file a lane added; a path the base lacks is rebuilt; a rebuild that reproduces the base commits nothing
shr_init sh5 'test ! -e gen/extra.json && grep -q adep gen/api.json && grep -q adep out.txt && ! grep -q lane-out out.txt && grep -q base-lock lock.txt' a
"${tool[@]}" share sh5 gen --rebuild 'cat a/dep.txt > gen/api.json' >/dev/null
"${tool[@]}" share sh5 out.txt --rebuild 'cat a/dep.txt > out.txt' >/dev/null
"${tool[@]}" share sh5 lock.txt --rebuild 'true' >/dev/null
printf 'x\nadep\n' > "$scratch/sh5-a/a/dep.txt"; printf 'lane\n' > "$scratch/sh5-a/gen/api.json"; printf 'lane\n' > "$scratch/sh5-a/gen/extra.json"
printf 'lane-out\n' > "$scratch/sh5-a/out.txt"; printf 'lane-lock\n' > "$scratch/sh5-a/lock.txt"
shr_done sh5 a
"${tool[@]}" qa sh5 --evidence ok >/dev/null
out="$(shr_integrate sh5)" || fail "directory, absent-at-base and no-change rebuilds did not integrate: $out"
[[ "$(git -C "$scratch/int-sh5" log -1 --format=%s)" == "integrate: rebuild gen, out.txt, lock.txt" ]] || fail "the rebuild commit is missing or misnamed: $(git -C "$scratch/int-sh5" log -1 --format=%s)"
[[ "$(git -C "$scratch/int-sh5" show HEAD:lock.txt)" == base-lock ]] || fail "a rebuild path that reproduces the base kept the lane's copy"
ok "a directory rebuild path loses the lane's added file, a path the base lacks is rebuilt, and an unchanged path stays the base's"
shr_init sh6 'grep -q base-lock lock.txt' a
"${tool[@]}" share sh6 lock.txt --rebuild 'true' >/dev/null
printf 'x\nadep\n' > "$scratch/sh6-a/a/dep.txt"; printf 'lane-lock\n' > "$scratch/sh6-a/lock.txt"
shr_done sh6 a; "${tool[@]}" qa sh6 --evidence ok >/dev/null
out="$(shr_integrate sh6)" || fail "a rebuild that reproduces the base failed integrate: $out"
[[ "$(git -C "$scratch/int-sh6" log --format=%s | grep -c '^integrate: rebuild')" == 0 ]] || fail "an empty rebuild made a commit"
[[ "$(run_field sh6 integration rebuilt)" == '{"lock.txt": "true"}' ]] || fail "rebuilt is not recorded when the rebuild changed nothing"
ok "a rebuild that reproduces the base commits nothing and still records rebuilt"

# a rebuild that touches an undeclared path, fails, or runs out of time stops integrate and is recorded
shr_init sh7 true a
"${tool[@]}" share sh7 lock.txt --rebuild 'echo x > stray.txt' >/dev/null
printf 'x\nadep\n' > "$scratch/sh7-a/a/dep.txt"; shr_done sh7 a
out="$(shr_integrate sh7)" && fail "a rebuild writing outside its paths passed: $out"
grep -q 'rebuild changed paths outside the declared rebuild paths (lock.txt): stray.txt' <<<"$out" || fail "the stray path was not named: $out"
grep -q 'rebuild failed over the composed tree' <<<"$out" || fail "the failure was not reported as a rebuild failure: $out"
[[ "$(run_field sh7 integration result)" == '"fail"' && "$(run_field sh7 integration failed_at)" == '"rebuild"' ]] || fail "the failed rebuild was not recorded"
expect 'integration:fail' "${tool[@]}" check sh7
"${tool[@]}" share sh7 lock.txt --rebuild 'echo boom >&2; exit 3' >/dev/null
out="$(shr_integrate sh7)" && fail "a failing rebuild passed: $out"
grep -q 'rebuild of lock.txt failed: echo boom >&2; exit 3' <<<"$out" && grep -q '^boom' <<<"$out" || fail "the failing command, path and output were not named: $out"
"${tool[@]}" share sh7 lock.txt --rebuild 'sleep 30' >/dev/null
out="$(WORKLOOP_VERIFY_TIMEOUT=2 shr_integrate sh7)" && fail "a hanging rebuild passed: $out"
grep -q 'rebuild did not finish within 2s' <<<"$out" || fail "the rebuild timeout was not reported: $out"
"${tool[@]}" share sh7 lock.txt --rebuild 'sleep 2; echo a > a.txt' >/dev/null
"${tool[@]}" share sh7 a.txt --rebuild 'true' >/dev/null
"${tool[@]}" share sh7 b.txt --rebuild 'sleep 2; echo b > b.txt' >/dev/null
out="$(WORKLOOP_VERIFY_TIMEOUT=3 shr_integrate sh7)" && fail "two rebuilds each inside the limit but over it together passed: $out"
grep -q 'rebuild of b.txt failed' <<<"$out" || fail "the second rebuild did not run out of the shared budget: $out"
grep -q 'rebuild did not finish within 3s' <<<"$out" || fail "the timeout line did not report the budget, 3s, but the time left: $out"
for bad in abc 0 -5 1.5; do
  out="$(WORKLOOP_VERIFY_TIMEOUT=$bad shr_integrate sh7)" && fail "WORKLOOP_VERIFY_TIMEOUT=$bad integrated: $out"
  grep -q "WORKLOOP_VERIFY_TIMEOUT must be a positive whole number of seconds, got '$bad'" <<<"$out" || fail "WORKLOOP_VERIFY_TIMEOUT=$bad was not named: $out"
done
WORKLOOP_VERIFY_TIMEOUT=abc "${tool[@]}" status sh7 >/dev/null || fail "a bad WORKLOOP_VERIFY_TIMEOUT broke a command that runs no verify"
ok "a stray path, a failing command and a timeout (one budget across all rebuilds) stop integrate, name the command and are recorded as a rebuild failure"

# rebuilds run in the order the paths were shared, across a state save, and before the install
shr_init sh8 'grep -q z lock.txt' a
"${tool[@]}" share sh8 z.txt --rebuild 'echo z > z.txt' >/dev/null
"${tool[@]}" share sh8 a.txt --rebuild "test -f z.txt && cat z.txt > a.txt && echo \$(wc -l < $NPM_LOG) > npm-lines.txt" >/dev/null
"${tool[@]}" share sh8 npm-lines.txt --rebuild 'true' >/dev/null
"${tool[@]}" share sh8 lock.txt --rebuild 'cat z.txt > lock.txt' >/dev/null
[[ "$(run_field sh8 rebuild | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)))')" == "a.txt,lock.txt,npm-lines.txt,z.txt" ]] || fail "the state file did not sort the rebuild map; the row proves nothing"
printf 'x\nadep\n' > "$scratch/sh8-a/a/dep.txt"; shr_done sh8 a; "${tool[@]}" qa sh8 --evidence ok >/dev/null
before="$(wc -l < "$NPM_LOG" | tr -d ' ')"
out="$(shr_integrate sh8)" || fail "rebuilds in declaration order failed (a.txt needs z.txt first): $out"
[[ "$(git -C "$scratch/int-sh8" show HEAD:npm-lines.txt)" == "$before" ]] || fail "a rebuild ran after the install: it saw $(git -C "$scratch/int-sh8" show HEAD:npm-lines.txt) npm calls, $before before"
[[ "$(wc -l < "$NPM_LOG" | tr -d ' ')" -gt "$before" ]] || fail "integrate did not install after the rebuild"
ok "rebuilds run in declaration order, not the sorted state order, and before provision installs"

# a share after integrate makes the integration stale; a share mid-integrate does not leak into its record
shr_init stl true a
"${tool[@]}" share stl lock.txt --rebuild "python3 $repo/.agents/workloop.py --state $state share stl extra.txt >/dev/null" >/dev/null
printf 'x\nadep\n' > "$scratch/stl-a/a/dep.txt"; shr_done stl a; "${tool[@]}" qa stl --evidence ok >/dev/null
out="$(shr_integrate stl)" || fail "integrate failed: $out"
[[ "$(run_field stl integration shared)" == '["lock.txt"]' && "$(run_field stl shared)" == '["lock.txt", "extra.txt"]' ]] || fail "the record did not keep the snapshot the merge used: $(run_field stl integration shared) vs $(run_field stl shared)"
expect 'integration:stale' "${tool[@]}" check stl
out="$(shr_integrate stl)" || fail "re-integrate failed: $out"
expect PASS "${tool[@]}" check stl
"${tool[@]}" share stl README.md >/dev/null
expect 'integration:stale' "${tool[@]}" check stl
"${tool[@]}" share stl lock.txt --rebuild 'true' >/dev/null
out="$(shr_integrate stl)" || fail "re-integrate with a changed rebuild failed: $out"
expect PASS "${tool[@]}" check stl
"${tool[@]}" share stl lock.txt --rebuild 'echo changed >/dev/null' >/dev/null
expect 'integration:stale' "${tool[@]}" check stl
ok "a share changing the shared paths or a rebuild command makes the integration stale until integrate reruns; the record keeps the snapshot its merge used"
python3 - "$state" <<'EOF2'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); r = json.loads(json.dumps(s["runs"]["sh6"])); r["shared"] = []; r["rebuild"] = {}
for key in ("rebuilt", "shared"): r["integration"].pop(key)
r.pop("rebuild"); s["runs"]["sh6old"] = r; json.dump(s, open(p, "w"))
EOF2
expect PASS "${tool[@]}" check sh6old
ok "an integration record from before rebuilt and shared reads as none, in a run that shares nothing"

# a rebuild that installs cannot write through a node_modules shared from the checkout
shr_init sh9 true a
mkdir -p "$scratch/sh9-repo/node_modules/pkg"; printf 'orig\n' > "$scratch/sh9-repo/node_modules/pkg/index.js"
"${tool[@]}" share sh9 lock.txt --rebuild 'mkdir -p node_modules/pkg && echo installed > node_modules/pkg/installed.txt' >/dev/null
printf 'x\nadep\n' > "$scratch/sh9-a/a/dep.txt"; shr_done sh9 a; "${tool[@]}" qa sh9 --evidence ok >/dev/null
out="$(shr_integrate sh9)" || fail "first integrate failed: $out"
[[ -f "$scratch/int-sh9/node_modules/.colloid-shared" ]] || fail "the row needs the integration tree provisioned by sharing the checkout's node_modules"
listing="$(cd "$scratch/sh9-repo/node_modules" && find . | sort)"
out="$(shr_integrate sh9)" || fail "second integrate failed: $out"
[[ "$(cd "$scratch/sh9-repo/node_modules" && find . | sort)" == "$listing" ]] || fail "a rebuild wrote through the shared node_modules into the checkout"
[[ "$(cat "$scratch/sh9-repo/node_modules/pkg/index.js")" == orig ]] || fail "the checkout's node_modules/pkg changed"
ok "a rebuild after a shared provision leaves the checkout's node_modules untouched"

# the brief tells a lane how to change a lockfile without writing through a linked node_modules, and how to settle a rebase conflict in a rebuilt path
shr_repo "$scratch/lkb-repo"; mkdir -p "$scratch/lkb-repo/node_modules/pkg"; printf 'orig\n' > "$scratch/lkb-repo/node_modules/pkg/index.js"
"${tool[@]}" init lkb --objective x --acceptance y --repo "$scratch/lkb-repo" --verify true >/dev/null
"${tool[@]}" add-lane lkb a --worker implementer --workspace "$scratch/lkb-a" --path a >/dev/null 2>&1
"${tool[@]}" share lkb lock.txt --rebuild 'true' >/dev/null
"${tool[@]}" share lkb gen --rebuild 'true' >/dev/null
brief="$(full_brief lkb a)"; ws="$(cd "$scratch/lkb-a" && pwd -P)"
grep -q 'node_modules here is a link into the checkout' <<<"$brief" || fail "the fixture's lane has no linked node_modules; the row proves nothing: $brief"
grep -q 'Never install into it: change the lockfile with `pnpm install --lockfile-only`, `npm install --package-lock-only --ignore-scripts`, `bun install --lockfile-only` or `yarn install --mode update-lockfile`, then run .agents/provision.sh '"$ws"', which gives' <<<"$brief" || fail "the linked node_modules sentence lacks the lockfile-only commands and the provision command: $brief"
grep -q 'To change a lockfile run only its lockfile-only form (`pnpm install --lockfile-only`, `npm install --package-lock-only --ignore-scripts`, `bun install --lockfile-only` or `yarn install --mode update-lockfile`), then `.agents/provision.sh '"$ws"'` to install' <<<"$brief" || fail "the rebuilt-path rule lacks the lockfile-only commands and the provision command: $brief"
[[ "$(grep -c 'To change a lockfile run only its lockfile-only form' <<<"$brief")" == 1 ]] || fail "the lockfile-only sentence is not said exactly once for two rebuilt paths: $brief"
grep -q 'On a rebase conflict in it, regenerate it with that command instead of merging it by hand' <<<"$brief" || fail "the rebuilt-path rule lost the regenerate instruction: $brief"
ok "the lane brief names the lockfile-only commands and the provision command, and says to regenerate a rebuilt path instead of merging it by hand"

# names with spaces or non-ASCII characters survive status and ls-tree: a rebuild writing them is not stray, and a base rebuild path with one is restored
shr_repo "$scratch/uni-repo"; printf 'base-é\n' > "$scratch/uni-repo/é.txt"; git -C "$scratch/uni-repo" add . && git -C "$scratch/uni-repo" commit -qm unicode
"${tool[@]}" init uni --objective x --acceptance y --repo "$scratch/uni-repo" --verify 'test -f "gen/a b.json" && test -f "gen/é.json" && grep -q base-é é.txt' >/dev/null
"${tool[@]}" add-lane uni a --worker implementer --workspace "$scratch/uni-a" --path a >/dev/null 2>&1
"${tool[@]}" share uni gen --rebuild 'echo 1 > "gen/a b.json"; echo 2 > "gen/é.json"' >/dev/null
"${tool[@]}" share uni é.txt --rebuild 'true' >/dev/null
printf 'x\nadep\n' > "$scratch/uni-a/a/dep.txt"
shr_done uni a
"${tool[@]}" qa uni --evidence ok >/dev/null
out="$(shr_integrate uni)" || fail "a rebuild writing names with a space or a non-ASCII character, or restoring one, did not integrate: $out"
[[ "$(git -C "$scratch/int-uni" show HEAD:é.txt)" == base-é ]] || fail "the non-ASCII rebuild path was not restored from the base"
ok "rebuilds writing names with spaces and non-ASCII characters integrate, and a non-ASCII base rebuild path is restored"

# a merged path inside a rebuild path is refused in either declaration order; the reverse nesting stays allowed
shr_init nst true a
"${tool[@]}" share nst gen --rebuild 'true' >/dev/null
out="$("${tool[@]}" share nst gen/hand.json 2>&1)" && fail "a merged path inside a rebuild path was accepted: $out"
grep -q 'gen/hand.json.*inside gen.*share gen/hand.json with its own --rebuild command' <<<"$out" || fail "the refusal did not name both paths and the next step: $out"
"${tool[@]}" share nst docs/hand >/dev/null
out="$("${tool[@]}" share nst docs --rebuild 'true' 2>&1)" && fail "a rebuild path over a merged one was accepted: $out"
grep -q 'docs/hand.*inside docs' <<<"$out" || fail "the refusal did not name both paths: $out"
[[ "$(run_field nst shared)" == '["gen", "docs/hand"]' && "$(run_field nst rebuild)" == '{"gen": "true"}' ]] || fail "a refused share changed the run: $(run_field nst shared) $(run_field nst rebuild)"
"${tool[@]}" share nst gen --rebuild 'echo again' >/dev/null || fail "re-sharing a rebuild path with a new command was refused"
"${tool[@]}" share nst docs/hand --rebuild 'true' >/dev/null || fail "giving a merged path its own rebuild command was refused"
"${tool[@]}" share nst docs --rebuild 'true' >/dev/null || fail "a rebuild path over a rebuilt path was refused"
"${tool[@]}" share nst README.md >/dev/null && "${tool[@]}" share nst README.md/x --rebuild 'true' >/dev/null || fail "a rebuild path inside a merged path was refused"
shr_repo "$scratch/nst2-repo"
"${tool[@]}" init nst2 --objective x --acceptance y --repo "$scratch/nst2-repo" --verify true --shared gen/hand.json >/dev/null
"${tool[@]}" add-lane nst2 a --worker implementer --workspace "$scratch/nst2-a" --path a >/dev/null 2>&1
expect 'gen/hand.json.*inside gen' "${tool[@]}" share nst2 gen --rebuild 'true'
"${tool[@]}" share nst2 docs --rebuild 'true' >/dev/null
"${tool[@]}" share nst2 docs/hand >/dev/null 2>&1 && fail "a merged path inside docs was accepted after docs was rebuilt"
"${tool[@]}" share nst2 gen/hand.json --rebuild 'true' >/dev/null || fail "a declared merged path could not take its own rebuild command"
"${tool[@]}" share nst2 gen --rebuild 'true' >/dev/null || fail "a rebuild path over a now-rebuilt path was refused"
ok "share refuses a merged path inside a rebuild path in either order, init --shared included, and keeps a rebuild path inside a merged one allowed"

# a conflict with two merged lanes names both and the one remedy the controller supports; one no merged lane lists names every merged lane
shr_init cf true a b d
"${tool[@]}" share cf README.md >/dev/null
printf 'A\nl2\nl3\n' > "$scratch/cf-a/README.md"; printf 'l1\nl2\nB\n' > "$scratch/cf-b/README.md"; printf 'l1\nD\nl3\n' > "$scratch/cf-d/README.md"
shr_done cf a; shr_done cf b; shr_done cf d; "${tool[@]}" qa cf --evidence ok >/dev/null
out="$(shr_integrate cf)" && fail "a lane conflicting with two merged lanes integrated: $out"
grep -q "lane d conflicts with lane a, lane b in README.md; a lane can be rebased onto one lane's branch only (a: cf/a, b: cf/b): rebase d onto one of them, drop or defer the edits that overlap the others, then re-submit d" <<<"$out" || fail "the two-lane conflict message is wrong: $out"
shr_init cr true a b
"${tool[@]}" share cr gen >/dev/null; "${tool[@]}" share cr gen2 >/dev/null
git -C "$scratch/cr-a" mv gen gen2; printf 'new\n' > "$scratch/cr-b/gen/new.json"
shr_done cr a; shr_done cr b; "${tool[@]}" qa cr --evidence ok >/dev/null
out="$(shr_integrate cr)" && fail "a directory rename colliding with an added file integrated: $out"
grep -q 'lane b conflicts in gen2/new.json, which no merged lane lists among its files' <<<"$out" && grep -q 'any merged lane may be the cause: lane a' <<<"$out" || fail "an unlisted conflict did not name the merged lanes: $out"
grep -q 'conflicts with the base' <<<"$out" && fail "an unlisted conflict still blames the base: $out"
ok "a conflict with several merged lanes names them all and the one-branch remedy; a conflict no merged lane lists names every merged lane and not the base"

# a rebuild path is a name, not a pattern: '*.txt' leaves lane-owned and other base files alone
shr_init pl 'grep -q adep a/dep.txt' a
"${tool[@]}" share pl '*.txt' --rebuild 'true' >/dev/null
printf 'x\nadep\n' > "$scratch/pl-a/a/dep.txt"
shr_done pl a; "${tool[@]}" qa pl --evidence ok >/dev/null
out="$(shr_integrate pl)" || fail "a glob-looking rebuild path did not integrate: $out"
[[ "$(git -C "$scratch/int-pl" show HEAD:a/dep.txt)" == $'x\nadep' ]] || fail "a rebuild path '*.txt' was read as a pattern and reset a lane's file it does not name"
"${tool[@]}" add-lane pl loc --worker implementer --workspace "$scratch/pl-loc" --path 'web/[locale]' >/dev/null || fail "add-lane refused a path containing brackets"
ok "shared and rebuild paths reach git as literal names; bracketed lane paths are still accepted"

# path listings are read NUL-separated: git quotes a name with a non-ASCII character, a double quote or a backslash otherwise
shr_repo "$scratch/nq-repo"; mkdir -p "$scratch/nq-repo/src"; printf 'b\n' > "$scratch/nq-repo/src/ü.txt"; printf 'b\n' > "$scratch/nq-repo/src/q\"x.txt"; printf 'b\n' > "$scratch/nq-repo/src/b\\s.txt"
git -C "$scratch/nq-repo" add . && git -C "$scratch/nq-repo" commit -qm names
"${tool[@]}" init nq --objective x --acceptance y --repo "$scratch/nq-repo" --verify true --lane solo --worker implementer --path src >/dev/null
"${tool[@]}" claim nq solo --agent s >/dev/null
printf 'one\n' >> "$scratch/nq-repo/src/ü.txt"; commit_paths "$scratch/nq-repo" one src/ü.txt
"${tool[@]}" submit nq solo --evidence ok >/dev/null; accept nq solo docs/review.md#ok >/dev/null
expect "completion is blocked by qa:missing, verified:missing" "${tool[@]}" check nq --recorded
for late in 'src/ü.txt' 'src/q"x.txt' 'src/b\s.txt'; do
  printf 'late\n' >> "$scratch/nq-repo/$late"; commit_paths "$scratch/nq-repo" late "$late"
  expect 'solo:moved-after-review' "${tool[@]}" check nq --recorded
  git -C "$scratch/nq-repo" reset -q --hard HEAD~1
done
ok "a commit after the review to an owned path with a non-ASCII character, a quote or a backslash in its name moves the lane"
shr_repo "$scratch/nw-repo"; mkdir -p "$scratch/nw-repo/a"
"${tool[@]}" init nw --objective x --acceptance y --repo "$scratch/nw-repo" --verify true --shared 'docs/é "q".md' >/dev/null
"${tool[@]}" add-lane nw a --worker implementer --workspace "$scratch/nw-a" --path a >/dev/null 2>&1
"${tool[@]}" claim nw a --agent a >/dev/null
printf 'x\n' > "$scratch/nw-a/a/ü.txt"; printf 'x\n' > "$scratch/nw-a/docs/é \"q\".md"; printf 'x\n' > "$scratch/nw-a/a/b\\s.txt"
commit "$scratch/nw-a" names
"${tool[@]}" submit nw a --evidence ok >/dev/null || fail "a lane editing a non-ASCII shared path and owned paths with a quote or a backslash was refused at submit"
printf 'y\n' > "$scratch/nw-a/a/ü2.txt"
expect 'uncommitted changes; commit them on the lane branch first: a/ü2.txt' "${tool[@]}" submit nw a --evidence dirty
ok "a worktree lane editing shared and owned paths with unusual names submits"

# dirty_paths lists each changed path once, whatever status.renames says: with copy detection a staged copy's source arrives as a second field
shr_repo "$scratch/cp-repo"; seq 1 40 > "$scratch/cp-repo/gen/s.txt"; git -C "$scratch/cp-repo" add . && git -C "$scratch/cp-repo" commit -qm seq
git -C "$scratch/cp-repo" config status.renames copies
printf '41\n' >> "$scratch/cp-repo/gen/s.txt"; cp "$scratch/cp-repo/gen/s.txt" "$scratch/cp-repo/docs/c.txt"; git -C "$scratch/cp-repo" add gen/s.txt docs/c.txt
[[ "$(git -C "$scratch/cp-repo" status --porcelain | head -1)" == C* ]] || fail "the fixture's staged copy was not detected as a copy: $(git -C "$scratch/cp-repo" status --porcelain)"
PYTHONPATH="$repo/.agents" python3 - "$scratch/cp-repo" <<'EOF'
import sys
import workloop_git as wg
paths = wg.dirty_paths(sys.argv[1])
assert paths == ["docs/c.txt", "gen/s.txt"], paths
EOF
ok "a staged copy under status.renames=copies lists its source once"

# ── background agents' time out and silence, as the inbox hook stamps them ───
"${tool[@]}" init act --objective 'three cells out' --acceptance 'each answers' --repo "$work" >/dev/null
for cell_name in busy quiet unstamped fresh; do "${tool[@]}" add-cell act "$cell_name" --role research --model haiku >/dev/null; done
python3 - "$state" <<'EOF'
import json, sys, time
p = sys.argv[1]; s = json.load(open(p)); cells = s["runs"]["act"]["cells"]
moment = time.time()
def at(minutes): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(moment - minutes * 60))
def clock(minutes): return time.strftime("%H:%MZ", time.gmtime(moment - minutes * 60))
for cell in cells.values(): cell["out_since"] = at(40)
cells["busy"].update(activity_at=at(1), activity="Edit parser.py")
cells["quiet"].update(activity_at=at(25), activity="Bash pytest -q")
cells["fresh"].update(activity_at=at(0.5), activity="Read notes.md")
json.dump(s, open(p, "w"))
# the expected times of day, from the same instant the state was written at
open(sys.argv[1] + ".clock", "w").write(f"out={clock(40)}\nbusy={clock(1)}\nquiet={clock(25)}\n")
EOF
source "$state.clock"
status_out="$("${tool[@]}" status act)"
grep -qE $'^quiet\tcell out\tresearch\tmodel=haiku\tout 40m\tsilent 25m\tBash pytest -q$' <<<"$status_out" || fail "status did not name the silent cell, its time out and its age: $status_out"
grep -qE $'^busy\tcell out\tresearch\tmodel=haiku\tout 40m\tsilent 1m\tEdit parser.py$' <<<"$status_out" || fail "status did not show the busy cell's last action: $status_out"
grep -qE $'^unstamped\tcell out\tresearch\tmodel=haiku\tout 40m\tunstamped$' <<<"$status_out" || fail "a cell with no stamp did not read as unstamped, with no silence figure: $status_out"
grep -qE $'^fresh\tcell out\tresearch\tmodel=haiku\tout 40m\tsilent 0m\tRead notes.md$' <<<"$status_out" || fail "status did not print the silence of a cell stamped half a minute ago in whole minutes: $status_out"
ok "status shows each cell's time out, its silence in whole minutes and its last action, and unstamped for a cell with no stamp, with no controller command run by the cell"

digest_out="$("${tool[@]}" digest act)"
[[ "$(wc -l <<<"$digest_out" | tr -d ' ')" == 4 ]] || fail "digest did not print one line per agent: $digest_out"
grep -qE $'^quiet\tresearch\tout\tout '"$out"$'\tstamp '"$quiet"$'\tBash pytest -q$' <<<"$digest_out" || fail "digest did not show the silent cell's times of day and action: $digest_out"
grep -qE $'^busy\tresearch\tout\tout '"$out"$'\tstamp '"$busy"$'\tEdit parser.py$' <<<"$digest_out" || fail "digest did not show the busy cell's last action: $digest_out"
grep -qE $'^unstamped\tresearch\tout\tout '"$out"$'\tunstamped\t-$' <<<"$digest_out" || fail "digest did not print unstamped for a cell with no stamp: $digest_out"
sleep 1
[[ "$("${tool[@]}" digest act)" == "$digest_out" ]] || fail "the same agents in the same state printed different digests on two passes"
expect $'plain\timplementer\tactive\t' "${tool[@]}" digest res
ok "digest prints one line per agent with UTC times of day, not ages, so two passes agree"
watch_out="$("${tool[@]}" watch act --stale-seconds 900)"
grep -q 'SILENT CELL — act/quiet: out 40m, silent 25m, last Bash pytest -q' <<<"$watch_out" || fail "watch did not name the silent cell: $watch_out"
grep -q 'UNSTAMPED CELL — act/unstamped: out 40m and carries no stamp' <<<"$watch_out" || fail "watch did not name the cell that never stamped on its own line: $watch_out"
! grep 'act/unstamped' <<<"$watch_out" | grep -q -- '--failed' || fail "watch offered returned --failed for a cell that carries no stamp: $watch_out"
! grep -q 'act/busy' <<<"$watch_out" || fail "watch named a cell stamped a minute ago: $watch_out"
ok "watch runs on an ordinary run, judges silence by the latest stamp, and names an unstamped cell apart with no --failed remedy"

# A cell whose agent waits on a permission prompt reads waiting on the operator, not silent.
# The PermissionRequest hook's record sits beside the state file; the agent's session is
# registered live under a scratch home, and its transcript ends on the call that asked.
wait_home="$scratch/wait-home"; wait_repo="$scratch/wait-repo"
wait_state="$wait_repo/.agents/.workloop-state.json"
mkdir -p "$wait_home/.claude/sessions" "$wait_home/.claude/projects/-w/sw/subagents" "$wait_repo/.agents"
wtool=(python3 "$repo/.agents/workloop.py" --state "$wait_state")
"${wtool[@]}" init asks --objective 'two cells out' --acceptance 'each answers' --repo "$work" >/dev/null
for cell_name in asking hushed; do "${wtool[@]}" add-cell asks "$cell_name" --role research --model haiku >/dev/null; done
python3 - "$wait_state" "$wait_home" "$(LC_ALL=C TZ=UTC ps -o lstart= -p $$ | awk '{$1=$1};1')" $$ <<'EOF'
import json, sys, time
state, home, start, pid = sys.argv[1:]
s = json.load(open(state)); cells = s["runs"]["asks"]["cells"]
def at(minutes): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - minutes * 60))
for cell in cells.values(): cell.update(out_since=at(40), activity_at=at(25), activity="Bash touch prompted.txt")
cells["asking"]["agent_id"] = "awaits"
json.dump(s, open(state, "w"))
json.dump({"pid": int(pid), "sessionId": "sw", "procStart": start, "startedAt": int(time.time() * 1000)},
          open(f"{home}/.claude/sessions/{pid}.json", "w"))
stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() - 60)) + ".000Z"
call = {"type": "assistant", "timestamp": stamp, "cwd": "/", "message": {"role": "assistant", "stop_reason": "tool_use",
        "content": [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "touch prompted.txt"}}]}}
open(f"{home}/.claude/projects/-w/sw/subagents/agent-awaits.jsonl", "w").write(json.dumps(call) + "\n")
EOF
printf '{"project_dir":"%s","agent_id":"awaits","agent_type":"general-purpose","session_id":"sw","transcript_path":"%s","tool_name":"Bash","tool_input":{"command":"touch prompted.txt"}}' \
  "$wait_repo" "$wait_home/.claude/projects/-w/sw.jsonl" | HOME="$wait_home" python3 "$repo/.agents/hooks/lib/agent_waits.py" record "$wait_repo"
watch_out="$(HOME="$wait_home" CLAUDE_CONFIG_DIR= "${wtool[@]}" watch asks --stale-seconds 900)"
grep -q "WAITING ON THE OPERATOR — asks/asking: its cell's agent waits on a permission prompt for .*, Bash: touch prompted.txt" <<<"$watch_out" \
  || fail "watch did not name the cell waiting on a permission prompt: $watch_out"
! grep -q 'SILENT CELL — asks/asking' <<<"$watch_out" || fail "watch called a cell waiting on the operator silent: $watch_out"
grep -q 'SILENT CELL — asks/hushed' <<<"$watch_out" || fail "watch stopped naming the silent cell beside the waiting one: $watch_out"
ok "watch names a cell whose agent waits on a permission prompt as waiting on the operator, with its tool and command, not silent"

# returned and teardown rewrite the workloop readout; a cell sent out again starts with no stamp
readout_note() { python3 "$repo/.agents/hooks/lib/readout.py" show --repo "$work"; }
"${tool[@]}" returned act busy --result reply >/dev/null
readout_out="$(readout_note)"
[[ "$readout_out" == *"act/quiet"* && "$readout_out" == *"act/unstamped"* && "$readout_out" != *"act/busy"* ]] || fail "returned did not rewrite the readout: $readout_out"
"${tool[@]}" brief act busy --again >/dev/null
python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["runs"]["act"]["cells"]["busy"]; assert "activity" not in c and "activity_at" not in c, c' "$state" || fail "brief --again kept the last agent's stamp and action"
"${tool[@]}" returned act busy --result reply >/dev/null
"${tool[@]}" returned act fresh --result reply >/dev/null
"${tool[@]}" returned act quiet --failed 'gone' >/dev/null
"${tool[@]}" returned act unstamped --failed 'gone' >/dev/null
python3 "$repo/.agents/hooks/lib/readout.py" write workloop --strip 'ghost' --note 'act/ghost silent 9m: -' --repo "$work"
"${tool[@]}" teardown act >/dev/null
[[ "$(readout_note)" != *"act/"* ]] || fail "teardown did not rewrite the readout: $(readout_note)"
ok "returned and teardown rewrite the workloop readout, and brief --again clears the stamp and action"

# a new claimant starts with no stamp and no action of its own
"${tool[@]}" init reclaim --objective x --acceptance y --repo "$work" --verify true >/dev/null
"${tool[@]}" add-lane reclaim one --worker implementer --workspace "$scratch/lane-reclaim" --path src >/dev/null
"${tool[@]}" claim reclaim one --agent first >/dev/null
python3 - "$state" <<'EOF'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["runs"]["reclaim"]["lanes"]["one"].update(activity_at="2026-01-01T00:00:00Z", activity="Bash old"); json.dump(s, open(p, "w"))
EOF
"${tool[@]}" release-stale reclaim one --reason 'gone' >/dev/null
"${tool[@]}" claim reclaim one --agent second >/dev/null
python3 -c 'import json,sys; l=json.load(open(sys.argv[1]))["runs"]["reclaim"]["lanes"]["one"]; assert l["claimed_by"] == "second" and "activity" not in l and "activity_at" not in l, l' "$state" || fail "claim kept the last claimant's stamp and action"
ok "a lane claimed again starts with no stamp and no action"

# ── a state file from before pinned bases is refused ─────────────────────────
python3 - "$state" <<'EOF'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["runs"]["legacy"] = dict(s["runs"]["demo"], base="HEAD"); s["runs"]["legacy"].pop("repo"); json.dump(s, open(p, "w"))
EOF
expect 'predates pinned bases' "${tool[@]}" status legacy
ok "a run without a pinned base is refused"

# ── unit 2.1: QA beside review, bound to the tips it ran on ─────────────────
# Seams. cmd_qa's gate: catches QA recorded before every lane is submitted;
# misses whether QA ran on the right tree. The tip binding: catches evidence
# taken on a lane that moved; misses an integration rebuilt to identical tips,
# which is not stale. check's qa:stale: catches stale evidence at completion;
# misses the evidence's content. The QA brief: catches a diff or changed-path
# list reaching QA; misses wording QA reads elsewhere.
"${tool[@]}" init qs --objective 'qa beside review' --acceptance '1. the page lists rows' --repo "$work" --verify 'true' >/dev/null
qsl="$scratch/lane-qs"
"${tool[@]}" add-lane qs one --worker implementer --workspace "$qsl" --path src --path docs/qs >/dev/null
"${tool[@]}" claim qs one --agent qs1
expect 'QA is blocked by lanes: one' "${tool[@]}" qa qs --evidence early
printf 'qs\n' >> "$qsl/src/app.txt"; mkdir -p "$qsl/docs/qs"; printf 'r\n' > "$qsl/docs/qs/review.md"; commit "$qsl" qs-one
"${tool[@]}" submit qs one --evidence 'one ok' >/dev/null
qs_tip="$(tip_of qs one)"
"${tool[@]}" qa qs --evidence 'scenario passed' || fail 'QA was refused for a lane in review'
python3 -c 'import json,sys; q=json.load(open(sys.argv[1]))["runs"]["qs"]["qa"]; assert q["tips"] == {"one": sys.argv[2]}, q' "$state" "$qs_tip" || fail 'the QA record does not hold the lane tip it ran on'
if "${tool[@]}" check qs --recorded 2>&1 | grep -q 'qa:stale'; then fail 'check called QA stale with no lane moved'; fi
ok "QA is recorded once every lane is submitted and stores each lane's tip; an unmoved lane is not stale"
"${tool[@]}" review qs one --reference docs/qs/review.md#p1 --result reopen --severity P1 --message 'more' >/dev/null
"${tool[@]}" ack qs one --agent qs1 >/dev/null
printf 'more\n' >> "$qsl/src/app.txt"; commit "$qsl" qs-two
"${tool[@]}" submit qs one --evidence 'one again' >/dev/null
expect 'qa:stale' "${tool[@]}" check qs --recorded
ok "a lane reopened and resubmitted after QA makes check fail with qa:stale"
# a lane added after QA is a lane the evidence never covered
"${tool[@]}" init qa3 --objective x --acceptance y --repo "$work" --verify true >/dev/null
"${tool[@]}" add-lane qa3 one --worker implementer --workspace "$scratch/lane-qa3a" --path src >/dev/null
"${tool[@]}" claim qa3 one --agent q3 >/dev/null
printf 'q3\n' >> "$scratch/lane-qa3a/src/app.txt"; commit "$scratch/lane-qa3a" q3-one
"${tool[@]}" submit qa3 one --evidence ok >/dev/null
"${tool[@]}" qa qa3 --evidence 'one lane covered' >/dev/null
"${tool[@]}" add-lane qa3 two --worker implementer --workspace "$scratch/lane-qa3b" --path tests >/dev/null
expect 'qa:stale' "${tool[@]}" check qa3 --recorded
ok "a lane added after QA makes check fail with qa:stale"
# a record without tips binds nothing, so it is stale
python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); del s["runs"]["qa3"]["qa"]["tips"]; json.dump(s, open(p,"w"))' "$state"
expect 'qa:stale' "${tool[@]}" check qa3 --recorded
ok "a QA record with no tips is stale"
# QA covers each lane's submitted tip; the composed tree is the integration's own verify run
python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["runs"]["multi"]; assert sorted(r["qa"]["tips"]) == ["alpha", "beta"] and "integration" not in r["qa"], r["qa"]' "$state" || fail "a several-lane QA record holds the tips and no integration field"
ok "a several-lane QA record holds both lane tips and no integration commit"
"${tool[@]}" init qe --objective x --acceptance y --repo "$work" --verify true >/dev/null
expect 'QA needs at least one submitted lane' "${tool[@]}" qa qe --evidence x

# QA brief: the acceptance and the run's test suite, no diff, no path list
qs_brief="$(full_brief qs one --role qa)"
grep -q '^Acceptance: 1. the page lists rows$' <<<"$qs_brief" && grep -q '^Test suite: true$' <<<"$qs_brief" || fail "the QA lane brief lacks the acceptance or the test suite"
! grep -Eq '^(Diff|Owned paths):|git diff|Run commands' <<<"$qs_brief" || fail "the QA lane brief carries a diff, a path list or a run-commands label"
"${tool[@]}" add-cell qs critic --role qa --model sonnet >/dev/null
qs_cell="$(cat "$work/.agents/worktrees/qs/.workloop/cells/critic.md")"
grep -q '^Acceptance: 1. the page lists rows$' <<<"$qs_cell" && grep -q '^Test suite: true$' <<<"$qs_cell" || fail "the QA cell brief lacks the acceptance or the test suite"
! grep -Eq '^(Diff|Owned paths):|git diff|Run commands' <<<"$qs_cell" || fail "the QA cell brief carries a diff, a path list or a run-commands label"
"${tool[@]}" init qf --objective x --acceptance y --repo "$work" >/dev/null
"${tool[@]}" add-cell qf critic --role qa --model sonnet >/dev/null
! grep -Eq 'Test suite|None' "$work/.agents/worktrees/qf/.workloop/cells/critic.md" || fail "a QA cell brief of a run with no --verify names a test suite"
# a main lane's QA brief says nothing of owned paths or of the lane's commits; its worker brief still does
"${tool[@]}" init qm --objective x --acceptance y --repo "$work" --verify true --lane solo --worker implementer --path docs/qm >/dev/null
qm_qa="$(full_brief qm solo --role qa)"
! grep -Eq 'Do not edit outside owned|commits since its first claim' <<<"$qm_qa" || fail "a main lane's QA brief points at owned paths or the lane's commits"
qm_worker="$(full_brief qm solo --role worker)"
grep -q 'Do not edit outside owned' <<<"$qm_worker" && grep -q 'commits since its first claim' <<<"$qm_worker" || fail "the worker brief lost its owned-path lines"
ok "a QA brief holds the acceptance and the test suite, none when the run has none, and no diff or path list"

rm "$state.lock"
if "${tool[@]}" status supervised 2>/dev/null; then fail 'read-only status recreated a missing lock'; fi
printf 'PASS: workloop controller\n'
