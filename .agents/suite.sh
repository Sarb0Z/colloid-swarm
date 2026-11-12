#!/usr/bin/env bash
# Run the repository's suite (`owed.suite` in .agents/policy.json) and, when it
# passes, record the tree it passed on, so `owed.py` stops reporting the suite
# as owed until the next edit. The tree is taken before the run: an edit made
# while it runs is not covered by the pass.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
owed="$repo/.agents/hooks/lib/owed.py"
cd "$repo"

command="$(python3 "$owed" suite-command)" || exit 1
tree="$(python3 "$owed" tree)" || exit 1
bash -c "$command" || exit $?
python3 "$owed" record-pass "$tree"
