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
if "${tool[@]}" review demo implementation --reference docs/reviews/missing.md#pass --result reopen 2>/dev/null; then fail 'missing review reference was accepted'; fi
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
  "${tool[@]}" review clash "$l" --reference docs/review.md#p1 --result reopen --message 'tighten'
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
"${tool[@]}" review sparse s --reference docs/r.md#ok --result reopen --message m; "${tool[@]}" ack sparse s --agent sp1
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
expect 'Do not run the end-to-end or browser suite here' "${tool[@]}" brief res plain
ok "the brief exports the lane's environment, its lease, and the narrow-acceptance rule"
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
git -C "$work" checkout -q -b pnpmws; printf 'packages:\n  - apps/*\n' > "$work/pnpm-workspace.yaml"; git -C "$work" add -A; git -C "$work" commit -qm ws; git -C "$work" checkout -q -
"${tool[@]}" init pnpmws --objective x --acceptance y --repo "$work" --base pnpmws
if "${tool[@]}" add-lane pnpmws w --worker implementer --workspace "$scratch/lane-pnpm" --path src --sparse 2>/dev/null; then fail 'a sparse lane was allowed on a pnpm workspace'; fi
expect 'does not exist at the base; created empty' "${tool[@]}" add-lane sparse n --worker implementer --workspace "$scratch/lane-newdir" --path brand-new --sparse
ok "a pnpm workspace refuses --sparse; a cone directory absent at the base is named"
ok "supervised messaging holds"

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
