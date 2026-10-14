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
commit() { git -C "$1" add -A && git -C "$1" -c user.email=t@e.com -c user.name=t commit -qm "$2"; }

# ── base is pinned, verify is guarded ────────────────────────────────────────
"${tool[@]}" --event-id init-demo init demo --objective 'prove coordination' --acceptance 'all lanes reviewed and QA observed' --repo "$work" --base HEAD
expect 'replayed event' "${tool[@]}" --event-id init-demo init demo --objective 'ignored replay' --acceptance ignored --repo "$work"
python3 - "$state" <<'EOF'
import json, re, sys
base = json.load(open(sys.argv[1]))["runs"]["demo"]["base"]
assert re.fullmatch(r"[0-9a-f]{40}", base), base
EOF
ok "init resolves --base HEAD to a commit SHA"
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
"${tool[@]}" review demo implementation --reference docs/reviews/demo.md#accepted --result accept
"${tool[@]}" qa demo --evidence 'independent scenario passed'
expect PASS "${tool[@]}" check demo
expect $'implementation\treviewed' "${tool[@]}" status demo
ok "a single-lane run completes without an integration step"

# ── lanes default to .agents/worktrees inside the checkout ───────────────────
real_work="$(cd "$work" && pwd -P)"
"${tool[@]}" init unignored --objective x --acceptance y --repo "$work"
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
expect "Workspace: $n1 " "${tool[@]}" brief nest one
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
if [[ "$real_work" != /tmp/* && "$real_work" != /private/tmp/* ]]; then
  expect "lies under /tmp, which the system clears; omit --workspace to use the default $real_work/.agents/worktrees/nest/three" \
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
"${tool[@]}" init nestsp --objective x --acceptance y --repo "$work"
"${tool[@]}" add-lane nestsp sp --worker implementer --path brand-new --sparse >/dev/null 2>&1
nsp="$real_work/.agents/worktrees/nestsp/sp"
[[ -f "$nsp/package-lock.json" && ! -e "$nsp/src" ]] || fail "the sparse lane is wrong before widen: $(ls "$nsp")"
expect 'widened lane .sp.: owned + gen; cone + gen, src' "${tool[@]}" widen nestsp sp --path gen --also src
[[ -f "$nsp/src/app.txt" ]] || fail "widen --also did not check src out in the sparse lane"
expect 'Sparse cone: brand-new, gen, src' "${tool[@]}" brief nestsp sp
mkdir -p "$nsp/gen"; printf 'g\n' > "$nsp/gen/g.txt"; git -C "$nsp" add gen/g.txt || fail "a widened cone directory could not be staged"
expect 'already covers src/deep' "${tool[@]}" widen nestsp sp --also src/deep
"${tool[@]}" abandon nestsp --discard-branches >/dev/null
ok "widen of a sparse lane adds the directories to its cone and checks them out"

# integrate defaults to .agents/worktrees/<run>/integration
for l in one two; do
  d="$real_work/.agents/worktrees/nest/$l"; "${tool[@]}" claim nest "$l" --agent "$l"
  mkdir -p "$d/tests" "$d/docs/$l"; [[ $l == one ]] && printf 'n\n' >> "$d/src/app.txt" || printf 't\n' > "$d/tests/t.txt"
  printf 'r\n' > "$d/docs/$l/r.md"; commit "$d" "$l"
  "${tool[@]}" submit nest "$l" --evidence ok; "${tool[@]}" review nest "$l" --reference "docs/$l/r.md#ok" --result accept
done
if [[ "$real_work" != /tmp/* && "$real_work" != /private/tmp/* ]]; then
  expect "integration workspace /tmp/colloid-int-$$ lies under /tmp, which the system clears; omit --workspace to use the default $real_work/.agents/worktrees/nest/integration" \
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
"${tool[@]}" init stale --objective x --acceptance y --repo "$work"
stale_lane="$scratch/lane-stale"
"${tool[@]}" add-lane stale one --worker implementer --workspace "$stale_lane" --path src
printf '{"name":"fixture","lockfileVersion":3,"changed":true}\n' > "$stale_lane/package-lock.json"
if "${tool[@]}" claim stale one --agent worker-9 2>/dev/null; then fail 'claim ignored a changed lockfile'; fi
: > "$NPM_LOG"
"${tool[@]}" provision stale one
grep -q 'ci --ignore-scripts' "$NPM_LOG" || fail 'provision did not reinstall'
"${tool[@]}" claim stale one --agent worker-9
ok "a changed lockfile blocks claim until provision reruns"

# ── ownership, attention, stale release ───────────────────────────────────────
"${tool[@]}" init ownership --objective x --acceptance y --repo "$work"
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
"${tool[@]}" init concurrent --objective x --acceptance y --repo "$work"
("${tool[@]}" add-lane concurrent first --worker implementer --workspace "$scratch/lane-c1" --path src >/dev/null 2>&1) &
("${tool[@]}" add-lane concurrent second --worker implementer --workspace "$scratch/lane-c2" --path tests >/dev/null 2>&1) &
wait
expect $'first\tready' "${tool[@]}" status concurrent
expect $'second\tready' "${tool[@]}" status concurrent
"${tool[@]}" claim concurrent first --agent worker-3
"${tool[@]}" init shared --objective x --acceptance y --repo "$work"
"${tool[@]}" add-lane shared a --worker implementer --workspace "$scratch/lane-c1" --path src
"${tool[@]}" add-lane shared b --worker implementer --workspace "$scratch/lane-c1" --path tests
"${tool[@]}" claim shared a --agent worker-4
if "${tool[@]}" claim shared b --agent worker-5 2>/dev/null; then fail 'shared worktree allowed concurrent writes'; fi
ok "concurrent add-lane lands both; a shared worktree cannot be claimed twice"

# ── undeclared path ───────────────────────────────────────────────────────────
"${tool[@]}" init boundary --objective x --acceptance y --repo "$work"
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
"${tool[@]}" review multi alpha --reference docs/alpha/review.md#ok --result accept
"${tool[@]}" claim multi beta --agent b1
mkdir -p "$lb/tests"; printf 'test\n' > "$lb/tests/app.txt"; mkdir -p "$lb/docs/beta"; printf 'r\n' > "$lb/docs/beta/review.md"; commit "$lb" beta
"${tool[@]}" submit multi beta --evidence 'beta ok'
"${tool[@]}" review multi beta --reference docs/beta/review.md#ok --result accept
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
"${tool[@]}" submit multi alpha --evidence 'more'; "${tool[@]}" review multi alpha --reference docs/alpha/review.md#ok2 --result accept
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
  "${tool[@]}" submit failing "$l" --evidence ok; "${tool[@]}" review failing "$l" --reference "docs/$l/r.md#ok" --result accept
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
  "${tool[@]}" review clash "$l" --reference docs/review.md#ok --result accept
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
"${tool[@]}" init guard --objective x --acceptance y --repo "$work"
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
  "${tool[@]}" submit dirtyint "$l" --evidence ok; "${tool[@]}" review dirtyint "$l" --reference "docs/$l/r.md#ok" --result accept
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
"${tool[@]}" init aband --objective x --acceptance y --repo "$work"
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
"${tool[@]}" init aband3 --objective x --acceptance y --repo "$work"
"${tool[@]}" add-lane aband3 one --worker implementer --workspace "$scratch/lane-ab3" --path src
"${tool[@]}" claim aband3 one --agent ab3
printf 'more\n' >> "$scratch/lane-ab3/src/app.txt"; commit "$scratch/lane-ab3" ab3
expect 'abandoned' "${tool[@]}" abandon aband3 --discard-branches
! git -C "$work" rev-parse --verify -q aband3/one >/dev/null || fail '--discard-branches kept the branch'
ok "abandon --discard-branches deletes an unmerged lane branch"


# ── a review report kept in the main checkout is a valid reference ───────────
"${tool[@]}" init mainref --objective x --acceptance y --repo "$work" --supervised
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
expect 'existing file in the main checkout or the lane worktree' "${tool[@]}" review mainref w --reference docs/reviews/absent.md#ok --result accept
expect 'recorded accept review' "${tool[@]}" review mainref w --reference docs/reviews/main-only.md#ok --result accept
ok "attention, send, and review resolve a reference against the main checkout"


# ── a sparse lane carries only its owned directories ─────────────────────────
"${tool[@]}" init sparse --objective x --acceptance y --repo "$work" --verify 'true'
sp="$scratch/lane-sparse"
expect 'sparse to docs, src' "${tool[@]}" add-lane sparse s --worker implementer --workspace "$sp" --path src --sparse --also docs
[[ -f "$sp/src/app.txt" && ! -e "$sp/tests" && -f "$sp/package-lock.json" ]] || fail "sparse cone wrong: $(ls "$sp")"
[[ "$(git -C "$sp" config core.sparseCheckoutCone)" == "true" ]] || fail "cone mode not set per worktree"
expect 'Sparse cone: docs, src' "${tool[@]}" brief sparse s
"${tool[@]}" claim sparse s --agent sp1
printf 'sparse\n' >> "$sp/src/app.txt"; commit "$sp" sparse
"${tool[@]}" submit sparse s --evidence ok
mkdir -p "$sp/docs"; printf 'r\n' > "$sp/docs/r.md"; commit "$sp" review
"${tool[@]}" review sparse s --reference docs/r.md#ok --result reopen --severity P1 --message m; "${tool[@]}" ack sparse s --agent sp1
"${tool[@]}" submit sparse s --evidence ok; "${tool[@]}" review sparse s --reference docs/r.md#ok --result accept
"${tool[@]}" add-lane sparse t --worker implementer --workspace "$scratch/lane-sparse-t" --path tests --also src --sparse >/dev/null 2>&1
[[ -f "$scratch/lane-sparse-t/src/app.txt" ]] || fail "--also directory absent from the cone"
mkdir -p "$scratch/lane-sparse-t/tests"; printf 'x\n' > "$scratch/lane-sparse-t/tests/new.txt"; git -C "$scratch/lane-sparse-t" add tests/new.txt || fail "a file inside the cone could not be staged"
ok "a sparse lane holds its owned and --also directories plus root files, and stages what lands inside them"


# ── leases, progress, and reaping by ownership ───────────────────────────────
"${tool[@]}" init res --objective x --acceptance y --repo "$work"
"${tool[@]}" add-lane res browser-a --worker implementer --workspace "$scratch/lane-ra" --path src --exclusive playwright >/dev/null 2>&1
"${tool[@]}" add-lane res browser-b --worker implementer --workspace "$scratch/lane-rb" --path tests --exclusive playwright >/dev/null 2>&1
"${tool[@]}" add-lane res plain --worker implementer --workspace "$scratch/lane-rp" --path docs >/dev/null 2>&1
"${tool[@]}" claim res browser-a --agent ra
expect 'exclusive resource in use: browser-a holds playwright' "${tool[@]}" claim res browser-b --agent rb
"${tool[@]}" claim res plain --agent rp
ok "a second lane cannot claim a held exclusive resource; an unrelated lane can"
expect 'COLLOID_RUN=res COLLOID_LANE=browser-a COMPOSE_PROJECT_NAME=res-browser-a' "${tool[@]}" brief res browser-a
expect 'Exclusive: playwright' "${tool[@]}" brief res browser-a
expect 'integrate runs the composed test once over the merged tree' "${tool[@]}" brief res plain
expect 'Working practice:' "${tool[@]}" brief res plain --role qa
"${tool[@]}" brief res plain --role reviewer | grep -q 'Working practice:' && fail "a reviewer brief carries the working practice"
ok "the brief exports the lane's environment, its lease, and the working practice for workers and QA only"
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
if "${tool[@]}" init BadName --objective x --acceptance y --repo "$work" 2>/dev/null; then fail 'an uppercase run name was accepted'; fi
if "${tool[@]}" add-lane res 'my lane' --worker implementer --workspace "$scratch/lane-bad" --path src 2>/dev/null; then fail 'a lane name with a space was accepted'; fi
ok "run and lane names are constrained to what compose and labels accept"

# ── supervised messaging ──────────────────────────────────────────────────────
"${tool[@]}" init supervised --objective x --acceptance y --repo "$work" --supervised
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
monotool=("${tool[@]}"); mono_init() { "${monotool[@]}" init "$1" --objective x --acceptance y --repo "$mono" --base "${2:-HEAD}" >/dev/null; }
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
"${tool[@]}" init shr --objective x --acceptance y --repo "$work" --shared docs/index.md --shared gen
if "${tool[@]}" init shrdup --objective x --acceptance y --repo "$work" --shared gen --shared gen/ 2>/dev/null; then fail 'a duplicate shared path was accepted'; fi
sa="$scratch/lane-sa"; sb="$scratch/lane-sb"; sc="$scratch/lane-sc"
expect 'lanes edit shared paths without owning them' "${tool[@]}" add-lane shr bad --worker implementer --workspace "$scratch/lane-sbad" --path docs/index.md
expect 'lanes edit shared paths without owning them' "${tool[@]}" add-lane shr bad --worker implementer --workspace "$scratch/lane-sbad" --path gen/api.json
expect 'lanes edit shared paths without owning them' "${tool[@]}" add-lane shr bad --worker implementer --workspace "$scratch/lane-sbad" --path docs
"${tool[@]}" add-lane shr a --worker implementer --workspace "$sa" --path src
"${tool[@]}" add-lane shr b --worker implementer --workspace "$sb" --path tests
"${tool[@]}" add-lane shr c --worker implementer --workspace "$sc" --path docs/c
expect $'shared\tdocs/index.md, gen' "${tool[@]}" status shr
expect 'Shared paths: docs/index.md, gen' "${tool[@]}" brief shr a
expect 'Append only; never restructure or reorder existing lines' "${tool[@]}" brief shr a
expect 'owned or shared paths' "${tool[@]}" brief shr a
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
expect "git diff $start_b\.\.shr/b" "${tool[@]}" brief shr b --role reviewer
expect "start point $start_b" "${tool[@]}" brief shr b --role reviewer
ok "a reviewer brief names the lane's start point and its diff command"
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
"${tool[@]}" submit shint a --evidence ok; "${tool[@]}" review shint a --reference docs/a/r.md#ok --result accept
printf 'late\n' >> "$scratch/lane-shi/docs/shared/log.md"
expect "lane 'a' has uncommitted work" "${tool[@]}" integrate shint --workspace "$scratch/integration-shi"
ok "integrate refuses uncommitted shared work"

# ── a rebase launders nothing: only a sibling in review, inside its paths, sets a start point
"${tool[@]}" init lk --objective x --acceptance y --repo "$work"
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
"${tool[@]}" review am a --reference docs/a/r.md#ok --result accept
"${tool[@]}" review am b --reference docs/b/r.md#ok --result accept
expect "rebase it onto the sibling's current branch" "${tool[@]}" integrate am --workspace "$scratch/integration-am"
printf 'x\n' > "$aa/docs/a/x.md"; commit "$aa" a3
expect "lane 'a' moved after its accepted review" "${tool[@]}" integrate am --workspace "$scratch/integration-am"
ok "integrate refuses a lane built on a superseded sibling commit and one whose tip moved after accept"

# ── review gate: a P2 is filed, and the fourth round needs a ruling ──────────
"${tool[@]}" init gate --objective x --acceptance y --repo "$work"
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
expect 'needs the operator' "${tool[@]}" review gate g --reference docs/g/r.md#ok --result accept
"${tool[@]}" review gate g --reference docs/g/r.md#ok --result accept --ruling 'one more round, go ahead'
python3 - "$state" <<'EOF2'
import json, sys
lane = json.load(open(sys.argv[1]))["runs"]["gate"]["lanes"]["g"]
assert lane["state"] == "reviewed", lane["state"]
assert lane["review_refs"][-1]["ruling"] == "one more round, go ahead", lane["review_refs"][-1]
assert "ruling" not in lane["review_refs"][0], lane["review_refs"][0]
EOF2
ok "a P2 reopen is refused; an attention cycle counts as a round; the fourth round needs a recorded ruling"

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
