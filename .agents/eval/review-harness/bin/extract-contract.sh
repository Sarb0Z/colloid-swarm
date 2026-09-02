#!/usr/bin/env bash
# Extract the shipped reviewer contract for the harness to transplant.
#
# The tested bytes and the shipped bytes must be the same. This reads the
# fenced block under `## Reviewer contract` in hostile-review.md. Drift between
# the two means the harness is measuring something that does not ship.
#
# Usage: extract-contract.sh [--check]
#   (none)   regenerate contract.md from the playbook
#   --check  fail if contract.md differs from a fresh extraction, without
#            writing. Nothing invokes the regenerating form automatically, so
#            an edit to the playbook is only caught because a test runs this.
set -euo pipefail

check_only="no"
case "${1:-}" in
  --check) check_only="yes" ;;
  "") ;;
  *) echo "usage: extract-contract.sh [--check]" >&2; exit 2 ;;
esac

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$here/../../playbooks/hostile-review.md"
dst="$here/contract.md"

[[ -s "$src" ]] || { echo "missing $src" >&2; exit 1; }

# Validate the fresh extraction in both modes, then decide what to do with it.
# Writing first would leave a rejected extraction on disk for the next reader.
fresh="$(mktemp)"
trap 'rm -f "$fresh"' EXIT
awk '/^````$/ { n++; next } n == 1' "$src" > "$fresh"

lines=$(wc -l < "$fresh" | tr -d ' ')
[[ "$lines" -gt 20 ]] || { echo "extracted only $lines lines — fence markers moved?" >&2; exit 1; }
for want in '## Authority' '## Static sweep' 'CONFORMANCE:' 'EFFECTS:' \
            '[P0|P1|P2 / <class>]' 'evidence:' 'recurrence:' 'trigger:' \
            'risk:' 'fix:' 'next:' 'residual:' 'cost:' 'recommendation:' \
            'AMBIGUITY:' 'HANDOFF: qa-verifier' 'HANDOFF: scalability-audit' \
            'FINDINGS: none' \
            'review-axes.md'; do
  grep -Fq -- "$want" "$fresh" || { echo "extract is missing: $want" >&2; exit 1; }
done

# The contract points at the catalogue by path, so the two files must agree.
axes="$here/../../playbooks/review-axes.md"
[[ -s "$axes" ]] || { echo "contract references $axes, which is missing" >&2; exit 1; }
groups=$(grep -cE '^## [0-9]\. ' "$axes")
count=$(grep -cE '^- \*\*' "$axes")
[[ "$groups" -eq 3 ]] || { echo "catalogue has $groups groups, expected 3" >&2; exit 1; }
[[ "$count" -ge 9 ]] || { echo "catalogue has $count axes, expected 9 or more" >&2; exit 1; }

if [[ "$check_only" == "yes" ]]; then
  if ! diff -u "$dst" "$fresh" >/dev/null 2>&1; then
    echo "contract.md is stale — hostile-review.md changed and the harness would" >&2
    echo "grade a contract the repository no longer ships. Run:" >&2
    echo "  .agents/eval/review-harness/bin/extract-contract.sh" >&2
    diff -u "$dst" "$fresh" >&2 || true
    exit 1
  fi
  echo "contract: in sync with hostile-review.md ($lines lines)"
else
  cp "$fresh" "$dst"
  echo "contract: $lines lines -> $dst"
fi
echo "axes:     $count across $groups groups"
