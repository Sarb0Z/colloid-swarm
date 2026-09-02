#!/usr/bin/env bash
# Gate the reviewer contract the eval harness grades against.
#
# hostile-review.md is the reviewer contract; review-harness/contract.md is the
# copy the harness transplants into each graded run. extract-contract.sh keeps
# them equal, but nothing invokes it on an edit — so without this test a change
# to the playbook silently ships one review and measures another, which is the
# exact failure AGENTS.md names.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

extract="$repo/.agents/eval/review-harness/bin/extract-contract.sh"
contract="$repo/.agents/eval/review-harness/contract.md"

# The eval harness is colloid-only — export-scaffold.py drops `.agents/eval`.
# A satellite carries hostile-review.md without a harness grading against it, so
# there is nothing here to gate. Skip rather than fail: asserting the carrier's
# layout is what makes a suite red in every repository but one.
if [[ ! -e "$repo/.agents/eval/review-harness" ]]; then
  ok "no review harness in this repository — nothing to gate"
  printf '\nALL PASS\n'
  exit 0
fi

[[ -x "$extract" ]] || fail "$extract is missing or not executable"

"$extract" --check >/dev/null || fail "contract.md is stale — run $extract"
ok "contract.md matches the fenced block in hostile-review.md"

# --check has to be able to fail, or the line above proves nothing. Restore from
# the extractor rather than a copy, so a crash here cannot leave the tree edited.
trap '"$extract" >/dev/null 2>&1 || true' EXIT
printf '\ndrift\n' >> "$contract"
set +e
"$extract" --check >/dev/null 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "--check passed a drifted contract.md"
ok "--check fails when contract.md drifts"

"$extract" >/dev/null
trap - EXIT
"$extract" --check >/dev/null || fail "regenerating did not restore contract.md"
ok "the regenerating form restores it"

printf '\nALL PASS\n'
