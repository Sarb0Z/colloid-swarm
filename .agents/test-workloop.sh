#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
state="$scratch/state.json"
work="$scratch/work"
git init -q "$work"
git -C "$work" config user.email test@example.com
git -C "$work" config user.name test
mkdir -p "$work/src" "$work/tests"
printf 'base\n' > "$work/src/app.txt"
git -C "$work" add . && git -C "$work" commit -qm base
base="$(git -C "$work" rev-parse HEAD)"
git -C "$work" worktree add -q "$scratch/reviewer" -b reviewer "$base"
reviewer="$scratch/reviewer"
tool=(python3 "$repo/.agents/workloop.py" --state "$state")
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

"${tool[@]}" --event-id init-demo init demo --objective 'prove coordination' --acceptance 'all lanes reviewed and QA observed' --base "$base"
"${tool[@]}" --event-id init-demo init demo --objective 'ignored replay' --acceptance ignored --base "$base" | grep -q 'replayed event'
"${tool[@]}" add-lane demo implementation --worker implementer --workspace "$work" --path src --path tests
"${tool[@]}" claim demo implementation --agent worker-1
printf 'change\n' >> "$work/src/app.txt"
"${tool[@]}" submit demo implementation --evidence 'unit test passed'
mkdir -p "$work/docs/reviews"
printf 'review evidence\n' > "$work/docs/reviews/demo.md"
if "${tool[@]}" review demo implementation --reference docs/reviews/missing.md#pass --result reopen 2>/dev/null; then fail 'missing review reference was accepted'; fi
"${tool[@]}" review demo implementation --reference docs/reviews/demo.md#pass --result reopen --severity P1 --message 'add coverage'
if "${tool[@]}" qa demo --evidence nope 2>/dev/null; then fail 'QA passed a reopened lane'; fi
"${tool[@]}" ack demo implementation --agent worker-1
printf 'test\n' > "$work/tests/app.txt"
"${tool[@]}" submit demo implementation --evidence 'unit and regression tests passed'
"${tool[@]}" review demo implementation --reference docs/reviews/demo.md#accepted --result accept
"${tool[@]}" qa demo --evidence 'independent scenario passed'
"${tool[@]}" check demo
"${tool[@]}" status demo | grep -q $'implementation\treviewed'

"${tool[@]}" init ownership --objective x --acceptance y --base "$base"
"${tool[@]}" add-lane ownership one --worker implementer --workspace "$work" --path src
if "${tool[@]}" add-lane ownership two --worker implementer --workspace "$work" --path src/app.txt 2>/dev/null; then fail 'overlapping paths were accepted'; fi
"${tool[@]}" claim ownership one --agent worker-2
mkdir -p "$work/docs/reviews"
printf 'attention evidence\n' > "$work/docs/reviews/attention.md"
"${tool[@]}" attention ownership one --severity P0 --message 'pause' --reference docs/reviews/attention.md#p0 | grep -q 'does not claim to interrupt'
"${tool[@]}" release-stale ownership one --reason 'lost worker'
if "${tool[@]}" claim ownership one --agent worker-3 2>/dev/null; then fail 'stale release erased pending attention'; fi
"${tool[@]}" ack ownership one --agent worker-2

"${tool[@]}" init concurrent --objective x --acceptance y --base "$base"
("${tool[@]}" add-lane concurrent first --worker implementer --workspace "$work" --path src >/dev/null) &
("${tool[@]}" add-lane concurrent second --worker implementer --workspace "$work" --path tests >/dev/null) &
wait
"${tool[@]}" status concurrent | grep -q $'first\tready'
"${tool[@]}" status concurrent | grep -q $'second\tready'
"${tool[@]}" claim concurrent first --agent worker-3
if "${tool[@]}" claim concurrent second --agent worker-4 2>/dev/null; then fail 'shared worktree allowed concurrent writes'; fi

"${tool[@]}" init boundary --objective x --acceptance y --base "$base"
"${tool[@]}" add-lane boundary src-only --worker implementer --workspace "$work" --path src
"${tool[@]}" claim boundary src-only --agent worker-5
if "${tool[@]}" submit boundary src-only --evidence 'wrong files' 2>/dev/null; then fail 'undeclared changed path was accepted'; fi

"${tool[@]}" init supervised --objective x --acceptance y --base "$base" --supervised
"${tool[@]}" add-lane supervised writer --worker implementer --workspace "$work" --path src
"${tool[@]}" add-lane supervised reviewer --worker reviewer --workspace "$reviewer" --path docs
"${tool[@]}" claim supervised writer --agent writer-agent
"${tool[@]}" claim supervised reviewer --agent reviewer-agent
mkdir -p "$reviewer/docs/reviews"
printf 'finding\n' > "$reviewer/docs/reviews/finding.md"
message="$("${tool[@]}" send supervised --from-lane reviewer --to-lane writer --agent reviewer-agent --kind finding --message 'check invariant' --reference docs/reviews/finding.md#p1 --requires-ack | sed -n "s/sent \([^ ]*\).*/\1/p")"
"${tool[@]}" inbox supervised writer | grep -q "$message"
if "${tool[@]}" submit supervised writer --evidence 'ignored finding' 2>/dev/null; then fail 'required peer acknowledgement did not block submit'; fi
if "${tool[@]}" ack-message supervised reviewer "$message" --agent reviewer-agent 2>/dev/null; then fail 'sender acknowledged recipient message'; fi
"${tool[@]}" ack-message supervised writer "$message" --agent writer-agent
"${tool[@]}" heartbeat supervised writer --agent writer-agent
inode_before="$(stat -f '%i' "$state")"
"${tool[@]}" watch supervised --stale-seconds 0 | grep -q 'RESTART REQUEST'
[[ "$inode_before" == "$(stat -f '%i' "$state")" ]] || fail 'watch rewrote state'
"${tool[@]}" send supervised --from-lane reviewer --to-lane writer --agent reviewer-agent --kind status --message 'progress' >/dev/null
"${tool[@]}" archive supervised | grep -q 'archived 1 nonblocking messages'
rm "$state.lock"
if "${tool[@]}" status supervised 2>/dev/null; then fail 'read-only status recreated a missing lock'; fi
printf 'PASS: workloop controller\n'
