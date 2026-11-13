#!/usr/bin/env bash
# Firing tests for suite.sh's isolation: the checks run in a copy of a fixture
# checkout under a temporary home, and a run whose checks escape it fails.
# Each row swaps the fixture's suite for a probe and puts the passing one back.
# Every suite.sh run here sweeps a TMPDIR private to this script, never the
# shared one, where a real run's scratch folder may live.
#
# Seams under test:
#   suite.sh's copy of the checkout: catches a check that writes relative to
#     its own script; misses an absolute path to the checkout.
#   suite.sh's temporary home: catches a write under `~`; misses a lookup that
#     skips HOME.
#   suite.sh's settings check: catches a check that rewrites the checkout's
#     core.* or extensions.* settings, directly or through an include; misses
#     every other absolute write.
#   suite.sh's check of the copy's tree: catches a check that writes a tracked
#     or untracked unignored file; misses one that writes only ignored files.
#   suite.sh's process handling: catches checks left running by an interrupt,
#     a SIGKILL to suite.sh's group or a read from the terminal, and a scratch
#     folder a killed run left; misses a check that leaves its session.
#   check-env.sh's github mode: catches a CI step left with the runner's git
#     identity, system settings or a token; misses a step placed before it.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/tmp"
export TMPDIR="$scratch/tmp"
tmp="$(cd "$TMPDIR" && pwd -P)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

fx="$scratch/fx"
mkdir -p "$fx/.agents/hooks/lib"
cp "$repo"/.agents/hooks/lib/*.py "$fx/.agents/hooks/lib/"
cp "$repo/.agents/suite.sh" "$repo/.agents/check-env.sh" "$fx/.agents/"
printf '{"owed": {"suite": "bash .agents/fake-suite.sh"}}\n' > "$fx/.agents/policy.json"
cat > "$fx/.agents/fake-suite.sh" <<'SH'
#!/usr/bin/env bash
[[ -f "$(dirname "$0")/../suite-should-pass" ]]
SH
cp "$fx/.agents/fake-suite.sh" "$scratch/fake-suite.pass"
touch "$fx/suite-should-pass"
printf 'x\n' > "$fx/app.txt"
printf '.agents/.readout/\n.agents/.sources-ledger\n__pycache__/\n*.ign\n' > "$fx/.gitignore"
g() { git -C "$fx" -c user.name=t -c user.email=t@t "$@"; }
g init -q -b main
g add -A && g commit -qm base
pass="$fx/.agents/.readout/suite-pass"
suite() { (cd "$fx" && .agents/suite.sh) 2>&1; }
copy_of() { sed -n 's/^suite.sh: checks run in //p' <<<"$1"; }
probe_suite() { cat > "$fx/.agents/fake-suite.sh"; }
passing_suite() { cp "$scratch/fake-suite.pass" "$fx/.agents/fake-suite.sh"; }

out="$(suite)" || fail "suite.sh must pass on the fixture: $out"
[[ -s "$pass" ]] || fail "a passing run must record its tree"
ok "a passing run records its tree"

# ── the copy and the temporary home ─────────────────────────────────────────
probe="suite-probe-$$.ign"
probe_suite <<SH
#!/usr/bin/env bash
printf 'x\n' > .agents/.sources-ledger
printf 'x\n' > "\$HOME/$probe"
printf '%s\n' "\$(pwd -P)" "\$HOME" "\${CLAUDE_PROJECT_DIR-unset}" > "$scratch/where"
SH
out="$(cd "$fx" && CLAUDE_PROJECT_DIR="$fx" .agents/suite.sh 2>&1)" || fail "suite.sh with the probe suite: $out"
escaped=""
for f in "$fx/.agents/.sources-ledger" "$HOME/$probe"; do
  if [[ -e "$f" ]]; then escaped+=" $f"; rm -f "$f"; fi
done
[[ -z "$escaped" ]] || fail "probes written outside the copy and the temporary home:$escaped"
copy="$(copy_of "$out")"
{ read -r cwd; read -r home; read -r project; } < "$scratch/where"
[[ -n "$copy" && "$copy" != "$(cd "$fx" && pwd -P)" ]] || fail "suite.sh must print a copy's path: $out"
[[ "$cwd" == "$copy" ]] || fail "the checks ran in $cwd, not the copy $copy"
[[ "$project" == unset ]] || fail "an inherited CLAUDE_PROJECT_DIR must not reach a check: $project"
[[ "$home" != "$HOME" && "$(dirname "$home")" == "$(dirname "$copy")" ]] || fail "HOME $home is not a temporary home beside the copy $copy"
[[ ! -e "$(dirname "$copy")" ]] || fail "the scratch folder $(dirname "$copy") outlived the run"
ok "the checks run in the copy under a temporary home with no CLAUDE_PROJECT_DIR, and nothing they write reaches the checkout or the real home"
passing_suite

printf 'gone\n' > "$fx/gone.txt"
g add -- gone.txt && g commit -qm "a file to delete"
rm "$fx/gone.txt"
printf 'edit\n' >> "$fx/app.txt"
printf 'untracked\n' > "$fx/untracked.txt"
printf 'staged\n' > "$fx/staged.txt" && g add -- staged.txt
ln -s app.txt "$fx/link"
printf 'ignored\n' > "$fx/x.ign"
probe_suite <<SH
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
out="$(suite)" || fail "suite.sh with the copy probe: $out"
cmp -s "$fx/app.txt" "$scratch/copy-app.txt" || fail "the copy must carry the uncommitted edit of app.txt"
[[ "$(cat "$scratch/copy-files")" == $'untracked\ndeleted\nlink -> app.txt\nstaged\nno ignored file' ]] || fail "the copy's files: $(cat "$scratch/copy-files")"
[[ "$(g status --porcelain)" == "$(cat "$scratch/copy-status")" ]] || fail "git status in the copy: $(cat "$scratch/copy-status") against the fixture's $(g status --porcelain)"
[[ "$(cat "$scratch/copy-status")" == *"A  staged.txt"* && "$(cat "$scratch/copy-status")" == *" D gone.txt"* ]] || fail "the copy's index must be the fixture's: $(cat "$scratch/copy-status")"
[[ ! -s "$scratch/copy-remote" ]] || fail "the copy must have no remote: $(cat "$scratch/copy-remote")"
ok "the copy carries the uncommitted edit, untracked file, deletion, symlink and index, no ignored file, and no remote"
g rm -q --cached -- staged.txt
rm "$fx/untracked.txt" "$fx/staged.txt" "$fx/link" "$fx/x.ign"
g checkout -q -- gone.txt app.txt
passing_suite

# Another session commits and stages after suite.sh reads HEAD, the index and
# the tree, and before it clones: a git on PATH that does that on `clone`.
real_git="$(command -v git)"
mkdir "$scratch/shim"
cat > "$scratch/shim/git" <<SH
#!/usr/bin/env bash
if [[ "\$1" == clone && ! -e "$scratch/raced" ]]; then
  touch "$scratch/raced"
  printf 'raced\n' > "$fx/raced.txt"
  "$real_git" -C "$fx" add -- raced.txt
  "$real_git" -C "$fx" -c user.name=t -c user.email=t@t commit -qm "another session's commit"
  printf 'staged later\n' > "$fx/later.txt"
  "$real_git" -C "$fx" add -- later.txt
fi
exec "$real_git" "\$@"
SH
chmod +x "$scratch/shim/git"
probe_suite <<SH
#!/usr/bin/env bash
git rev-parse HEAD > "$scratch/copy-head"
git status --porcelain > "$scratch/copy-status"
SH
head_before="$(g rev-parse HEAD)"
status_before="$(g status --porcelain)"
out="$(cd "$fx" && PATH="$scratch/shim:$PATH" .agents/suite.sh 2>&1)" || fail "suite.sh with a commit landing before the clone: $out"
[[ -e "$scratch/raced" ]] || fail "the shim never ran: $out"
[[ "$(cat "$scratch/copy-head")" == "$head_before" ]] || fail "the copy's HEAD must be the commit read with the tree: $(cat "$scratch/copy-head"), not $head_before"
[[ "$(cat "$scratch/copy-status")" == "$status_before" ]] || fail "the copy's status must be the one read with the tree: $(cat "$scratch/copy-status")"
ok "a commit and a stage landing before the clone do not change the copy's HEAD or index"
g rm -q --cached -- later.txt && rm "$fx/later.txt"
passing_suite

printf 'excluded-only.txt\n' >> "$fx/.git/info/exclude"
probe_suite <<'SH'
#!/usr/bin/env bash
printf 'x\n' > excluded-only.txt
SH
out="$(suite)" || fail "a file only the checkout's info/exclude ignores must not fail the run: $out"
ok "the copy ignores what the checkout's info/exclude ignores"
passing_suite

# Every way a git setting reaches a check from outside the temporary home
# carries a credential helper here, and the global ones a second identity.
mkdir -p "$scratch/xdg/git"
printf '[credential]\n\thelper = from-system\n' > "$scratch/system.gitconfig"
printf '[credential]\n\thelper = from-global\n[user]\n\temail = global@example.invalid\n' > "$scratch/global.gitconfig"
printf '[credential]\n\thelper = from-xdg\n[user]\n\temail = xdg@example.invalid\n' > "$scratch/xdg/git/config"
probe_suite <<SH
#!/usr/bin/env bash
{
  git config user.email
  printf 'helper=%s\n' "\$(git config --get-all credential.helper)"
  printf 'GH_TOKEN=%s GITHUB_TOKEN=%s GIT_TERMINAL_PROMPT=%s\n' "\${GH_TOKEN-unset}" "\${GITHUB_TOKEN-unset}" "\${GIT_TERMINAL_PROMPT-unset}"
} > "$scratch/identity"
SH
out="$(cd "$fx" && GIT_CONFIG_SYSTEM="$scratch/system.gitconfig" GIT_CONFIG_GLOBAL="$scratch/global.gitconfig" \
  XDG_CONFIG_HOME="$scratch/xdg" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=from-env \
  GH_TOKEN=leak GITHUB_TOKEN=leak GIT_TERMINAL_PROMPT=1 .agents/suite.sh 2>&1)" || fail "suite.sh with the identity probe: $out"
[[ "$(cat "$scratch/identity")" == $'suite@colloid.invalid\nhelper=\nGH_TOKEN=unset GITHUB_TOKEN=unset GIT_TERMINAL_PROMPT=0' ]] || fail "a check's git identity, credential helper, tokens and prompt: $(cat "$scratch/identity")"
ok "a check sees the suite identity, no credential helper, no GitHub token, and git never prompts"

# CI gives its later steps the same environment through check-env.sh's github
# mode. A system file that marks every folder safe, as GitHub's Ubuntu image
# writes one, stands in for the runner's: under the mode's settings a step
# reads git's refusal of a checkout whose owner differs, and the suite identity.
clean=(env -u GH_TOKEN -u GITHUB_TOKEN -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM -u GIT_CONFIG_PARAMETERS
  -u GIT_CONFIG_COUNT -u CLAUDE_PROJECT_DIR)
runner=(env -u GIT_CONFIG_NOSYSTEM GIT_CONFIG_SYSTEM="$scratch/trusting.gitconfig" GIT_TEST_ASSUME_DIFFERENT_OWNER=1)
printf '[safe]\n\tdirectory = *\n' > "$scratch/trusting.gitconfig"
git init -q "$scratch/foreign"
"${runner[@]}" git -C "$scratch/foreign" status >/dev/null 2>&1 || fail "the stand-in runner's system file did not mark the checkout safe"
: > "$scratch/github.env"
out="$("${clean[@]}" GITHUB_ENV="$scratch/github.env" RUNNER_TEMP="$scratch/runner" "$fx/.agents/check-env.sh" github 2>&1)" \
  || fail "check-env.sh github: $out"
step=()
while IFS= read -r line; do step+=("$line"); done < "$scratch/github.env"
out="$("${runner[@]}" "${step[@]}" git -C "$scratch/foreign" status 2>&1)" && fail "a step under check-env.sh github read a checkout git refuses: $out"
[[ "$out" == *"dubious ownership"* ]] || fail "a step's refusal was not git's ownership check: $out"
[[ "$("${runner[@]}" "${step[@]}" git -C "$scratch" config user.email)" == suite@colloid.invalid ]] || fail "a step's git identity is not the suite's"
out="$("${clean[@]}" GH_TOKEN=leak GITHUB_ENV="$scratch/github-token.env" RUNNER_TEMP="$scratch/runner" \
  "$fx/.agents/check-env.sh" github 2>&1)" && fail "check-env.sh github passed with GH_TOKEN set"
[[ "$out" == *"GH_TOKEN is set"* && ! -s "$scratch/github-token.env" ]] || fail "a set GH_TOKEN was not named, or settings were written anyway: $out"
ok "check-env.sh github gives CI's later steps the suite identity and no system git settings, and refuses a set token"

probe_suite <<SH
#!/usr/bin/env bash
python3 -c 'import signal; print(signal.getsignal(signal.SIGINT) is signal.SIG_IGN)' > "$scratch/sigint"
SH
out="$(suite)" || fail "suite.sh with the interrupt probe: $out"
[[ "$(cat "$scratch/sigint")" == False ]] || fail "a check must start with interrupts at their default, not ignored"
ok "a check starts with interrupts at their default, so a nested run can be interrupted"

# Playwright's browsers sit where a server that drops PLAYWRIGHT_ variables
# looks, under the temporary home, and a write there stays there.
case "$(uname -s)" in
  Darwin) browsers_default="Library/Caches/ms-playwright" ;;
  *) browsers_default=".cache/ms-playwright" ;;
esac
mkdir -p "$scratch/browsers/chromium-1"
printf 'bin\n' > "$scratch/browsers/chromium-1/chrome"
probe_suite <<SH
#!/usr/bin/env bash
{
  [[ -f "\$HOME/$browsers_default/chromium-1/chrome" ]] && echo "found at the default"
  [[ "\$PLAYWRIGHT_BROWSERS_PATH" == "\$HOME/$browsers_default" ]] && echo "variable at the default"
} > "$scratch/browsers-seen"
printf 'x\n' > "\$HOME/$browsers_default/written"
SH
out="$(cd "$fx" && PLAYWRIGHT_BROWSERS_PATH="$scratch/browsers" .agents/suite.sh 2>&1)" || fail "suite.sh with the browsers probe: $out"
[[ "$(cat "$scratch/browsers-seen")" == $'found at the default\nvariable at the default' ]] || fail "a check's browsers: $(cat "$scratch/browsers-seen")"
[[ ! -e "$scratch/browsers/written" ]] || fail "a write to the temporary home's browsers reached the real folder"
ok "Playwright's browsers are copied to their default place in the temporary home, and a write there stays there"
passing_suite

# ── the checkout's git settings ─────────────────────────────────────────────
escape_run() {  # <expected name>: the run fails, names it, and records no pass
  local status=0
  rm -f "$pass"
  out="$(suite)" || status=$?
  [[ "$status" == 1 && "$out" == *"$1"* ]] || { cleanup_settings; fail "a run whose check changed $1 must fail and name it (exit $status): $out"; }
  [[ ! -e "$pass" ]] || { cleanup_settings; fail "a run whose check changed $1 recorded a pass"; }
}
cleanup_settings() {
  for key in core.bare include.path extensions.colloidprobe extensions.worktreeconfig branch.main.vscode-merge-base; do
    g config --unset-all "$key" || true
  done
}
printf '#!/usr/bin/env bash\ngit -C "%s" config core.bare true\n' "$fx" | probe_suite
escape_run core.bare
cleanup_settings
printf '#!/usr/bin/env bash\ngit -C "%s" config branch.main.vscode-merge-base origin/main\n' "$fx" | probe_suite
rm -f "$pass"
out="$(suite)" || { cleanup_settings; fail "a branch setting written during the run must not fail it: $out"; }
cleanup_settings
[[ -s "$pass" ]] || fail "a run that changed only a branch setting must record a pass"
ok "a check that sets the checkout's core.bare fails the run and records no pass; a branch setting does not"

printf '[core]\n\tbare = true\n' > "$scratch/bare.gitconfig"
printf '#!/usr/bin/env bash\ngit -C "%s" config include.path "%s"\n' "$fx" "$scratch/bare.gitconfig" | probe_suite
escape_run core.bare
cleanup_settings
printf '#!/usr/bin/env bash\ngit -C "%s" config extensions.colloidprobe true\n' "$fx" | probe_suite
escape_run extensions.colloidprobe
cleanup_settings
ok "core.bare set through an included file, and a changed extensions setting, fail the run"

printf '#!/usr/bin/env bash\ngit -C "%s" config extensions.worktreeConfig true\n' "$fx" | probe_suite
rm -f "$pass"
out="$(suite)" || { cleanup_settings; fail "extensions.worktreeConfig turned on, as a sparse-cone lane does, must not fail the run: $out"; }
cleanup_settings
[[ -s "$pass" ]] || fail "a run that only turned extensions.worktreeConfig on must record a pass"
ok "extensions.worktreeConfig going from absent to true is not a check's escape"
passing_suite

# ── the copy's own tree ─────────────────────────────────────────────────────
rm -f "$pass"
probe_suite <<'SH'
#!/usr/bin/env bash
printf 'changed\n' >> app.txt
printf 'x\n' > made-in-copy.txt
SH
status=0; out="$(suite)" || status=$?
[[ "$status" == 1 && "$out" == *"app.txt"* && "$out" == *"made-in-copy.txt"* ]] || fail "a check that writes the copy's files must fail the run and name them (exit $status): $out"
[[ ! -e "$pass" && ! -e "$fx/made-in-copy.txt" ]] || fail "a run that changed the copy recorded a pass or wrote the checkout"
ok "a check that writes a tracked or untracked file of the copy fails the run, names the files and records no pass"

probe_suite <<'SH'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")/.." && pwd -P)"
[[ "$here" == */colloid-suite.*/copy ]] && rm -rf "$here"
SH
status=0; out="$(suite)" || status=$?
[[ "$status" == 1 && "$out" == *"was removed during the run; no pass recorded"* && "$out" != *Traceback* ]] || fail "a copy removed during the run must fail it in one line (exit $status): $out"
[[ ! -e "$pass" ]] || fail "a run whose copy was removed recorded a pass"
ok "a copy removed during the run fails it with one line and records no pass"
passing_suite

# ── processes ───────────────────────────────────────────────────────────────
# A suite whose check leaves a child running, started as its own job so it
# takes an interrupt the way a terminal sends one.
printf '#!/usr/bin/env bash\nsleep 300 &\necho "$!" > "%s/child"\nwait\n' "$scratch" | probe_suite
start_suite() {  # <log>: start suite.sh in the background, wait for its check's child
  rm -f "$scratch/child"
  set -m; (cd "$fx" && exec .agents/suite.sh) >"$1" 2>&1 & suite_pid=$!; set +m
  for _ in $(seq 100); do [[ -s "$scratch/child" ]] && break; sleep 0.1; done
  [[ -s "$scratch/child" ]] || fail "the check never started: $(cat "$1")"
  child="$(cat "$scratch/child")"
}
ended() {  # <pid> <tenths of a second>: true once the process is gone
  for _ in $(seq "$2"); do ps -p "$1" >/dev/null || return 0; sleep 0.1; done
  return 1
}
stop_leftovers() {  # what a run that failed a row left running
  kill -KILL -- "-$suite_pid" 2>/dev/null || true
  local group; group="$(ps -o pgid= -p "$child" | tr -d ' ')" || true
  [[ -n "$group" ]] && kill -KILL -- "-$group" 2>/dev/null || true
}
running() {  # <pid>: the process exists and is not a zombie
  local state
  state="$(ps -o stat= -p "$1")" || return 1
  [[ "$state" != Z* ]]
}
start_suite "$scratch/int.log"
kill -INT "$suite_pid"
ended "$suite_pid" 100 || { stop_leftovers; fail "an interrupt must end suite.sh: $(cat "$scratch/int.log")"; }
# suite.sh stops the checks before it removes their copy, so none is left the
# moment it has exited.
if running "$child"; then stop_leftovers; fail "an interrupted suite.sh exited while its check's child still ran"; fi
wait "$suite_pid" 2>/dev/null && fail "an interrupted run must not exit 0"
left="$(dirname "$(copy_of "$(cat "$scratch/int.log")")")"
[[ "$left" != . && ! -e "$left" ]] || fail "an interrupted run left its scratch folder $left"
ok "an interrupt stops the checks' process group and removes the scratch folder"

# A verify timeout SIGKILLs the process group suite.sh runs in.
start_suite "$scratch/group-kill.log"
kill -KILL -- "-$suite_pid"; wait "$suite_pid" 2>/dev/null || true
if ! ended "$child" 40; then stop_leftovers; fail "the checks must end within 4 s of a SIGKILL to suite.sh's group"; fi
left="$(dirname "$(copy_of "$(cat "$scratch/group-kill.log")")")"
passing_suite
out="$(suite)" || fail "suite.sh after a SIGKILLed run: $out"
[[ "$left" != . && ! -e "$left" ]] || fail "the next run must remove the scratch folder of a SIGKILLed run: $left"
ok "a SIGKILL to suite.sh's process group ends the checks, and the next run removes its scratch folder"

printf '#!/usr/bin/env bash\nsleep 300 &\necho "$!" > "%s/child"\nwait\n' "$scratch" | probe_suite
start_suite "$scratch/kill.log"
kill -KILL "$suite_pid"; wait "$suite_pid" 2>/dev/null || true
ended "$child" 40 || stop_leftovers
left="$(dirname "$(copy_of "$(cat "$scratch/kill.log")")")"
[[ "$left" != . && -d "$left" ]] || fail "a killed run must leave its scratch folder for this row to sweep: $left"
passing_suite
# A folder whose maker still runs (this script) or whose maker the kernel will
# not say is gone (pid 1 refuses a signal from this user) is another run's.
live="$(mktemp -d "$tmp/colloid-suite.$$.XXXXXX")"
refused="$(mktemp -d "$tmp/colloid-suite.1.XXXXXX")"
out="$(suite)" || fail "suite.sh after a killed run: $out"
kept=""
if [[ -d "$live" ]]; then kept+=" live"; fi
if [[ -d "$refused" ]]; then kept+=" refused"; fi
rm -rf "$live" "$refused"
[[ ! -e "$left" ]] || fail "the next run must sweep the scratch folder a killed run left: $left"
[[ "$kept" == " live refused" ]] || fail "the sweep must keep a folder whose maker runs or cannot be looked up, kept: '$kept'"
ok "the next run sweeps a scratch folder a killed run left, and keeps one whose maker runs or cannot be looked up"

# A check that reads the terminal, under a pseudo-terminal: it must fail, not
# stop the run in the background and hang it.
probe_suite <<SH
#!/usr/bin/env bash
echo "\$\$" > "$scratch/tty-check"
read -r line < /dev/tty
SH
if script --version 2>/dev/null | grep -q util-linux; then
  set -m; script -qec "cd '$fx' && .agents/suite.sh" /dev/null </dev/null >"$scratch/tty.log" 2>&1 & tty_pid=$!; set +m
else
  set -m; script -q /dev/null bash -c "cd '$fx' && .agents/suite.sh" </dev/null >"$scratch/tty.log" 2>&1 & tty_pid=$!; set +m
fi
if ! ended "$tty_pid" 150; then
  kill -KILL -- "-$tty_pid" 2>/dev/null || true
  if [[ -s "$scratch/tty-check" ]]; then
    tty_group="$(ps -o pgid= -p "$(cat "$scratch/tty-check")" | tr -d ' ')" || true
    [[ -n "$tty_group" ]] && kill -KILL -- "-$tty_group" 2>/dev/null || true
  fi
  fail "a check that reads /dev/tty hung the run: $(cat "$scratch/tty.log")"
fi
wait "$tty_pid" 2>/dev/null && fail "a check that cannot read the terminal must fail the run: $(cat "$scratch/tty.log")"
ok "a check that reads the terminal fails the run instead of hanging it"
passing_suite
