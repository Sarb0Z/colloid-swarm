#!/usr/bin/env bash
# The scaffold's whole check list, run from the repository root. `suite.sh`
# runs this as the repository's `owed.suite`. To run one surface, copy its line
# out of the list.
#
# Every check runs even after one fails, so a single run names every failure; a
# check whose script this repository does not carry is skipped and named.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR
cd "$(dirname "${BASH_SOURCE[0]}")/.."

checks() {
  cat <<'LIST'
python3 .agents/check-layout.py
.agents/lint-skills.sh
.agents/test-lint-skills.sh
python3 .agents/lint-breadcrumbs.py
python3 .agents/lint-decisions.py
python3 .agents/check-test-isolation.py
.agents/test-owed.sh
.agents/test-session-start.sh
.agents/test-done-prime.sh
.agents/test-workloop.sh
.agents/test-provision.sh
.agents/test-worktree-provision.sh
.agents/test-worktree-sessions.sh
.agents/test-parallel-writers.sh
.agents/test-workloop-inbox.sh
.agents/test-style-inject.sh
.agents/test-ui-gate.sh
.agents/test-teardown-gate.sh
.agents/test-session-end.sh
.agents/test-post-edit-check.sh
.agents/test-stop-investigate.sh
.agents/test-access.sh
.agents/test-provenance-gate.sh
.agents/test-review-contract.sh
python3 .agents/test-sources-matcher.py
.agents/test-untrusted-content.sh
python3 .agents/test-guard-destructive.py
python3 .agents/test-wait-gate.py
.agents/test-keychain-notice.sh
.agents/test-session-wrap.sh
python3 .agents/test-guard-publish.py
python3 .agents/test-hosted-scripts.py
.agents/test-device-policy.sh
.agents/test-mcp.sh
.agents/test-opencode.sh
python3 .agents/test-lsp.py
python3 .agents/test-browser-sync.py
.agents/test-permissions.sh
.agents/test-statusline.sh
.agents/test-readout.sh
.agents/test-hook-lookup.sh
.agents/test-product-folder.sh
.agents/test-mods.sh
.agents/test-codex.sh
.agents/test-scrapling-launcher.sh
python3 .agents/test-proxy-names.py
.agents/test-scrapling-proxy.sh
.agents/test-proxy-file-guard.sh
.agents/skills/seo-geo-growth-audit/scripts/test-quick-audit.sh
# colloid-only
python3 .agents/lint-contract.py
python3 .agents/lint-suite.py
python3 .agents/eval/test-cell-time.py
.agents/test-export.sh
.agents/test-stack-packs.sh
python3 .agents/port-public.py check
.agents/test-port-public.sh
python3 demo/check-inventory.py
# /colloid-only
LIST
}

failed=()
while IFS= read -r check; do
  [[ -z "$check" || "$check" == \#* ]] && continue
  script="${check#python3 }"
  script="${script%% *}"
  if [[ ! -e "$script" ]]; then
    # The carrier lists only what it ships, so a missing script there is a
    # defect; a repository that pruned a skill or a subsystem skips it.
    if [[ -e .agents/export-scaffold.py ]]; then
      printf '== %s (listed but missing)\n' "$check"
      failed+=("$check")
    else
      printf '== %s (absent here, skipped)\n' "$check"
    fi
    continue
  fi
  printf '== %s\n' "$check"
  bash -c "$check" || failed+=("$check")
done < <(checks)

if ((${#failed[@]})); then
  printf 'FAILED:\n' >&2
  printf '  %s\n' "${failed[@]}" >&2
  exit 1
fi
printf 'all checks passed\n'
