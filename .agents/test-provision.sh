#!/usr/bin/env bash
# Firing tests for provision.sh: install-once-per-lockfile-hash, scripts off by
# default, one install per checkout at a time, and a failure that never leaves
# a stale memo behind.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prov="$repo/.agents/provision.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
# Canonicalize once: provision.sh resolves its target with `pwd -P`, and a
# comparison against a path built from an un-resolved mktemp root (e.g. macOS's
# /var -> /private/var) would otherwise flag a match as a stray file.
scratch="$(cd "$scratch" && pwd -P)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

# --- a fake npm on PATH, controllable through files in $scratch -------------
mkdir -p "$scratch/bin"
cat > "$scratch/bin/npm" <<'FAKE'
#!/usr/bin/env bash
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
printf '%s\n' "$*" >> "$dir/npm.log"
pwd >> "$dir/npm.pwd.log"
: > "$dir/npm.ran"
[[ -f "$dir/npm.sleep" ]] && sleep "$(cat "$dir/npm.sleep")"
rc=0
[[ -f "$dir/npm.rc" ]] && rc="$(cat "$dir/npm.rc")"
exit "$rc"
FAKE
chmod +x "$scratch/bin/npm"
export PATH="$scratch/bin:$PATH"

# --- the main fixture repo ---------------------------------------------------
dir="$scratch/fixture"
mkdir -p "$dir"
git -C "$dir" init -q
git -C "$dir" config user.email t@t
git -C "$dir" config user.name t
printf '{"name":"x","lockfileVersion":3}\n' > "$dir/package-lock.json"
git -C "$dir" add -A
git -C "$dir" commit -q -m first

gitdir() { git -C "$1" rev-parse --path-format=absolute --git-dir; }
memo="$(gitdir "$dir")/colloid-provisioned"

# 1. first run, from inside the fixture dir
out="$(cd "$dir" && "$prov" .)"
[[ "$out" == provision:\ installed\ npm:* ]] || fail "first run stdout: $out"
[[ "$(wc -l < "$scratch/npm.log" | tr -d ' ')" == 1 ]] || fail "npm.log line count after first run: $(cat "$scratch/npm.log")"
[[ "$(cat "$scratch/npm.log")" == "ci --ignore-scripts" ]] || fail "first argv: $(cat "$scratch/npm.log")"
[[ -f "$memo" ]] || fail "memo missing after first install"
first_hash="$(cat "$memo")"
[[ "$first_hash" =~ ^[0-9a-f]{64}$ ]] || fail "memo is not 64 hex chars: $first_hash"
ok "a first run installs with scripts off and writes a 64-hex memo"

# 2. second run: unchanged lockfile, no reinstall
out="$(cd "$dir" && "$prov" .)"
[[ "$out" == provision:\ current\ * ]] || fail "second run stdout: $out"
[[ "$(wc -l < "$scratch/npm.log" | tr -d ' ')" == 1 ]] || fail "npm.log grew on an unchanged lockfile"
ok "an unchanged lockfile reinstalls nothing"

# 3. edited lockfile reinstalls
printf '{"name":"x","lockfileVersion":3,"v":3}\n' > "$dir/package-lock.json"
git -C "$dir" commit -aqm edit3
out="$(cd "$dir" && "$prov" .)"
[[ "$out" == *installed* ]] || fail "third run stdout: $out"
[[ "$(wc -l < "$scratch/npm.log" | tr -d ' ')" == 2 ]] || fail "npm.log after edited lockfile: $(cat "$scratch/npm.log")"
[[ "$(cat "$memo")" != "$first_hash" ]] || fail "memo did not change after editing the lockfile"
ok "an edited lockfile changes the hash and reinstalls"

# 4. PROVISION_ALLOW_SCRIPTS=1 drops --ignore-scripts
printf '{"name":"x","lockfileVersion":3,"v":4}\n' > "$dir/package-lock.json"
git -C "$dir" commit -aqm edit4
out="$(cd "$dir" && PROVISION_ALLOW_SCRIPTS=1 "$prov" .)"
[[ "$out" == *installed* ]] || fail "allow-scripts run stdout: $out"
last_argv="$(tail -n1 "$scratch/npm.log")"
[[ "$last_argv" == "ci" ]] || fail "allow-scripts argv: $last_argv"
ok "PROVISION_ALLOW_SCRIPTS=1 runs the install without --ignore-scripts"

# 5. a failing install leaves no memo and names the failure as environmental
printf '1' > "$scratch/npm.rc"
printf '{"name":"x","lockfileVersion":3,"v":5}\n' > "$dir/package-lock.json"
git -C "$dir" commit -aqm edit5
set +e
err="$(cd "$dir" && "$prov" . 2>&1 >/dev/null)"
rc=$?
set -e
[[ $rc -eq 1 ]] || fail "failing install exit code: $rc"
[[ ! -f "$memo" ]] || fail "memo survived a failed install"
[[ "$err" == *"provision: npm failed (exit 1)"* ]] || fail "failure line missing: $err"
[[ "$err" == *"This is an environment failure, not a code failure. Do not edit source to satisfy it."* ]] \
  || fail "environment-failure sentence missing: $err"
printf '0' > "$scratch/npm.rc"
ok "a failing install leaves no memo and names itself an environment failure"

# 6. no lockfile: unlocked manifests are named, and nothing is nothing
dir2="$scratch/unlocked"
mkdir -p "$dir2"
git -C "$dir2" init -q
git -C "$dir2" config user.email t@t
git -C "$dir2" config user.name t
printf '{"name":"x"}\n' > "$dir2/package.json"
git -C "$dir2" add -A && git -C "$dir2" commit -q -m first
out="$(cd "$dir2" && "$prov" .)"
[[ $? -eq 0 ]] || true
[[ "$out" == *"skipped unlocked manifests: package.json"* ]] || fail "unlocked-manifest message: $out"
ok "an unlocked manifest is named and skipped"

dir3="$scratch/empty"
mkdir -p "$dir3"
git -C "$dir3" init -q
git -C "$dir3" config user.email t@t
git -C "$dir3" config user.name t
git -C "$dir3" commit -q -m first --allow-empty
out="$("$prov" "$dir3")"
[[ "$out" == *"nothing to install"* ]] || fail "empty-repo message: $out"
ok "a repo with nothing to install says so"

# 7. caller cwd never decides where the memo lands
before="$(cat "$memo" 2>/dev/null || true)"
out="$(cd "$scratch" && "$prov" "$dir")"
rc=$?
[[ $rc -eq 0 ]] || fail "caller-cwd run failed: $out"
[[ -f "$memo" ]] || fail "memo missing after a run from a different cwd"
stray="$(find "$scratch" -name colloid-provisioned | grep -v -F "$memo" || true)"
[[ -z "$stray" ]] || fail "a colloid-provisioned file landed outside the fixture's git dir: $stray"
ok "the memo lands in the target's git dir regardless of the caller's cwd"

# 8. a linked worktree gets its own memo, in its own git dir
git -C "$dir" worktree add "$scratch/wt" -b wt -q
wt="$scratch/wt"
wt_gitdir="$(gitdir "$wt")"
case "$wt_gitdir" in
  "$dir"/.git/worktrees/*) ;;
  *) fail "worktree git dir not under fixture/.git/worktrees: $wt_gitdir" ;;
esac
fixture_memo_before="$(cat "$memo")"
out="$("$prov" "$wt")"
[[ "$out" == *installed* || "$out" == *current* ]] || fail "worktree run stdout: $out"
wt_memo="$wt_gitdir/colloid-provisioned"
[[ -f "$wt_memo" ]] || fail "worktree memo missing at $wt_memo"
[[ "$(cat "$memo")" == "$fixture_memo_before" ]] || fail "the fixture's own memo changed from a worktree run"
ok "a linked worktree provisions into its own git dir, leaving the main checkout's memo alone"

# 9. concurrent runs against the same checkout install at most once
: > "$scratch/npm.log"
printf '2' > "$scratch/npm.sleep"
printf '{"name":"x","lockfileVersion":3,"v":9}\n' > "$dir/package-lock.json"
git -C "$dir" commit -aqm edit9
( cd "$dir" && "$prov" . >"$scratch/out1" 2>&1; echo $? >"$scratch/rc1" ) &
( cd "$dir" && "$prov" . >"$scratch/out2" 2>&1; echo $? >"$scratch/rc2" ) &
wait
rm -f "$scratch/npm.sleep"
[[ "$(cat "$scratch/rc1")" == 0 && "$(cat "$scratch/rc2")" == 0 ]] \
  || fail "concurrent runs did not both exit 0: $(cat "$scratch/rc1") $(cat "$scratch/rc2")"
[[ "$(wc -l < "$scratch/npm.log" | tr -d ' ')" == 1 ]] || fail "concurrent runs produced more than one install: $(cat "$scratch/npm.log")"
out1="$(cat "$scratch/out1")"; out2="$(cat "$scratch/out2")"
[[ "$out1" == *current* || "$out2" == *current* ]] || fail "neither concurrent run reported current: $out1 / $out2"
ok "two concurrent runs against one checkout install exactly once"

# 10. a deadline kills a stuck install and leaves nothing behind
printf '30' > "$scratch/npm.sleep"
printf '{"name":"x","lockfileVersion":3,"v":10}\n' > "$dir/package-lock.json"
git -C "$dir" commit -aqm edit10
start=$(date +%s)
set +e
err="$(cd "$dir" && PROVISION_DEADLINE=3 "$prov" . 2>&1 >/dev/null)"
rc=$?
set -e
elapsed=$(( $(date +%s) - start ))
rm -f "$scratch/npm.sleep"
[[ $rc -eq 1 ]] || fail "deadline run exit code: $rc"
[[ $elapsed -le 8 ]] || fail "deadline run took ${elapsed}s, expected ~6s"
[[ "$err" == *"did not finish within 3s"* ]] || fail "deadline message missing: $err"
[[ ! -f "$memo" ]] || fail "memo survived a deadline kill"
[[ ! -d "$(gitdir "$dir")/colloid-provision.lock" ]] || fail "lock dir survived a deadline kill"
ok "a stuck install is killed at its deadline and leaves no memo or lock"

# 10b. a lock left by a killed install is taken over, not waited on; a lock
# whose holder is alive is honoured
lock="$(gitdir "$dir")/colloid-provision.lock"
mkdir "$lock"; printf '%s' 999999 > "$lock/pid"
printf '{"name":"x","lockfileVersion":3,"v":11}\n' > "$dir/package-lock.json"
git -C "$dir" commit -aqm edit11
start=$(date +%s)
(cd "$dir" && PROVISION_DEADLINE=20 "$prov" . >/dev/null 2>&1) || fail "a stale lock blocked provisioning"
elapsed=$(( $(date +%s) - start ))
[[ $elapsed -le 6 ]] || fail "stale-lock takeover took ${elapsed}s"
[[ ! -d "$lock" ]] || fail "stale lock survived"
mkdir "$lock"; sleep 30 & sleeper=$!; printf '%s' "$sleeper" > "$lock/pid"
printf '{"name":"x","lockfileVersion":3,"v":12}\n' > "$dir/package-lock.json"
git -C "$dir" commit -aqm edit12
set +e
err="$(cd "$dir" && PROVISION_DEADLINE=3 "$prov" . 2>&1 >/dev/null)"; rc=$?
set -e
kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null || true; rm -rf "$lock"
[[ $rc -eq 1 && "$err" == *"another install has held"* ]] || fail "a live holder's lock was not honoured: rc=$rc $err"
ok "a dead holder's lock is taken over; a live holder's lock is honoured"

# 11. a manager missing from PATH fails by name (prefer a manager absent from
# both this machine's real PATH root and the restricted PATH below)
manager=cargo; lockname=Cargo.lock
if [[ -x /usr/bin/cargo || -x /bin/cargo ]]; then
  manager=go; lockname=go.sum
  echo "note: real cargo found on the restricted PATH; using go/go.sum instead" >&2
fi
mgr_dir="$scratch/missing-manager"
mkdir -p "$mgr_dir"
git -C "$mgr_dir" init -q
git -C "$mgr_dir" config user.email t@t
git -C "$mgr_dir" config user.name t
printf 'lock\n' > "$mgr_dir/$lockname"
git -C "$mgr_dir" add -A && git -C "$mgr_dir" commit -q -m first
set +e
err="$(PATH="$scratch/bin:/usr/bin:/bin" "$prov" "$mgr_dir" 2>&1 >/dev/null)"
rc=$?
set -e
[[ $rc -eq 1 ]] || fail "missing-manager exit code: $rc"
[[ "$err" == *"$manager is not installed on this machine"* ]] || fail "missing-manager message: $err"
ok "a manager absent from PATH fails by name ($manager)"

# 12. a real manager, end to end
if command -v uv >/dev/null 2>&1; then
  uv_dir="$scratch/uv-real"
  mkdir -p "$uv_dir"
  git -C "$uv_dir" init -q
  git -C "$uv_dir" config user.email t@t
  git -C "$uv_dir" config user.name t
  cat > "$uv_dir/pyproject.toml" <<'PY'
[project]
name = "p"
version = "0"
requires-python = ">=3.9"
PY
  ( cd "$uv_dir" && uv lock ) >/dev/null 2>&1 || fail "uv lock failed to produce a fixture lockfile"
  git -C "$uv_dir" add -A && git -C "$uv_dir" commit -q -m first
  out="$("$prov" "$uv_dir")"
  [[ "$out" == *"installed uv:"* ]] || fail "real uv run stdout: $out"
  [[ -d "$uv_dir/.venv" ]] || fail "uv sync did not create .venv"
  ok "a real uv lockfile installs end to end"
else
  echo "SKIP: uv not on PATH"
fi

# --- a pinned requirements.txt is a lockfile; a loose one is a manifest -----
pip_dir="$scratch/pip-pinned"
mkdir -p "$pip_dir/svc"
git -C "$pip_dir" init -q
git -C "$pip_dir" config user.email t@t
git -C "$pip_dir" config user.name t
printf '%s\n' '# nothing to fetch: the venv itself is the proof' '-r constraints.txt' > "$pip_dir/svc/requirements.txt"
: > "$pip_dir/svc/constraints.txt"
printf '%s\n' '-r requirements.txt' > "$pip_dir/svc/requirements-dev.txt"
git -C "$pip_dir" add -A && git -C "$pip_dir" commit -q -m first
out="$("$prov" "$pip_dir")"
[[ "$out" == *"installed pip:svc"* ]] || fail "pinned requirements stdout: $out"
[[ -x "$pip_dir/svc/.venv/bin/pip" ]] || fail "pip provisioning created no .venv"
ok "a pinned requirements.txt builds a .venv and installs into it"
before="$("$prov" --hash "$pip_dir")"
printf 'pytest==9.1.1\n' >> "$pip_dir/svc/requirements-dev.txt"
[[ "$("$prov" --hash "$pip_dir")" != "$before" ]] || fail "requirements-dev.txt edit did not move the hash"
ok "the sibling requirements-dev.txt is part of the hash"

loose_dir="$scratch/pip-loose"
mkdir -p "$loose_dir"
git -C "$loose_dir" init -q
git -C "$loose_dir" config user.email t@t
git -C "$loose_dir" config user.name t
printf 'fastapi>=0.100\n' > "$loose_dir/requirements.txt"
git -C "$loose_dir" add -A && git -C "$loose_dir" commit -q -m first
out="$("$prov" "$loose_dir")"
[[ "$out" == *"skipped unlocked manifests: requirements.txt"* ]] || fail "loose requirements stdout: $out"
[[ ! -d "$loose_dir/.venv" ]] || fail "a loose requirements.txt built a venv"
ok "an unpinned requirements.txt is named and skipped"

pyver_dir="$scratch/pip-pyver"
mkdir -p "$pyver_dir"
git -C "$pyver_dir" init -q
git -C "$pyver_dir" config user.email t@t
git -C "$pyver_dir" config user.name t
: > "$pyver_dir/requirements.txt"
printf '2.4\n' > "$pyver_dir/.python-version"
git -C "$pyver_dir" add -A && git -C "$pyver_dir" commit -q -m first
if "$prov" "$pyver_dir" >/dev/null 2>"$scratch/pyver.err"; then fail "a missing interpreter was not an environment failure"; fi
grep -q "python2.4 is not on PATH" "$scratch/pyver.err" || fail "missing-interpreter stderr: $(cat "$scratch/pyver.err")"
grep -q "environment failure" "$scratch/pyver.err" || fail "missing-interpreter stderr lacks the sentence"
ok "a .python-version the machine cannot satisfy fails by name, not by falling back"


# 13. a lockfile that matches another checkout's links its node_modules
# instead of installing; a changed lockfile drops the link and installs
share_main="$scratch/share-main"; mkdir -p "$share_main/node_modules/left-pad"
git -C "$share_main" init -q 2>/dev/null || { git init -q "$share_main"; }
printf '{"name":"s","lockfileVersion":3}\n' > "$share_main/package-lock.json"
share_lane="$scratch/share-lane"; git init -q "$share_lane"; git -C "$share_lane" config user.email t@t; git -C "$share_lane" config user.name t
cp "$share_main/package-lock.json" "$share_lane/"; git -C "$share_lane" add -A; git -C "$share_lane" commit -qm lock
rm -f "$scratch/npm.ran"
out="$(cd "$share_lane" && PROVISION_SHARE_FROM="$share_main" "$prov" .)" || fail "shared provision failed: $out"
[[ "$out" == *"(shared from"* ]] || fail "share not reported: $out"
[[ -d "$share_lane/node_modules" && ! -L "$share_lane/node_modules" && -L "$share_lane/node_modules/left-pad" && -d "$share_lane/node_modules/left-pad" && -f "$share_lane/node_modules/.colloid-shared" ]] || fail "node_modules is not a directory of links to the shared tree"
[[ -z "$(git -C "$share_lane" ls-files --others --exclude-standard | grep node_modules)" ]] || { printf 'node_modules/\n' > "$share_lane/.gitignore"; [[ -z "$(git -C "$share_lane" ls-files --others --exclude-standard | grep node_modules)" ]] || fail "a node_modules/ ignore rule did not cover the shared directory"; }
[[ ! -e "$scratch/npm.ran" ]] || fail "npm ran despite a matching shared tree"
[[ -f "$(gitdir "$share_lane")/colloid-provisioned" ]] || fail "shared provision wrote no memo"
ok "a matching lockfile links the shared node_modules and installs nothing"
printf '{"name":"s","lockfileVersion":3,"changed":1}\n' > "$share_lane/package-lock.json"
rm -f "$scratch/npm.ran"
out="$(cd "$share_lane" && PROVISION_SHARE_FROM="$share_main" "$prov" .)" || fail "unshared provision failed: $out"
[[ -e "$scratch/npm.ran" && ! -f "$share_lane/node_modules/.colloid-shared" ]] || fail "changed lockfile kept the shared directory or skipped the install"
[[ -d "$share_main/node_modules/left-pad" ]] || fail "the shared tree was disturbed"
ok "a changed lockfile drops the link before installing and leaves the shared tree alone"
out="$(cd "$share_lane" && PROVISION_SHARE_FROM="$share_lane" "$prov" . 2>&1 || true)"
[[ "$out" != *"(shared from"* ]] || fail "a checkout shared from itself"
ok "a checkout never shares from itself"


# 14. a source that declares workspaces is never shared; another ecosystem's
# lockfile in the same directory leaves the link alone
printf '{"name":"s","workspaces":["packages/*"]}\n' > "$share_main/package.json"
printf '{"name":"s","lockfileVersion":3,"ws":1}\n' > "$share_main/package-lock.json"; cp "$share_main/package-lock.json" "$share_lane/"; git -C "$share_lane" commit -qam ws
rm -f "$scratch/npm.ran"
out="$(cd "$share_lane" && PROVISION_SHARE_FROM="$share_main" "$prov" .)" || fail "workspace provision failed: $out"
[[ "$out" != *"(shared from"* && -e "$scratch/npm.ran" && ! -f "$share_lane/node_modules/.colloid-shared" ]] || fail "a workspace source was shared: $out"
ok "a source that declares workspaces is installed, never linked"
rm -f "$share_main/package.json"; printf '{"name":"s","lockfileVersion":3,"mixed":1}\n' > "$share_main/package-lock.json"; cp "$share_main/package-lock.json" "$share_lane/"
cat > "$scratch/bin/bundle" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$scratch/bin/bundle"
printf 'GEM\n' > "$share_lane/Gemfile.lock"; git -C "$share_lane" add -A; git -C "$share_lane" commit -qm mixed
out="$(cd "$share_lane" && PROVISION_SHARE_FROM="$share_main" "$prov" .)" || fail "mixed provision failed: $out"
[[ "$out" == *"(shared from"* && "$out" == *"bundle:"* && -f "$share_lane/node_modules/.colloid-shared" ]] || fail "a Gemfile.lock beside the lockfile removed the shared directory: $out"
ok "a non-JS lockfile in the same directory leaves the shared link in place"

printf '\nall provision tests passed\n'
