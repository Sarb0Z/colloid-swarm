#!/usr/bin/env bash
# Extract the shipped reviewer contract for the harness to transplant.
#
# The tested bytes and the shipped bytes must be the same. This reads the
# fenced block under `## Reviewer contract` in hostile-review.md. Drift between
# the two means the harness is measuring something that does not ship.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$here/../../playbooks/hostile-review.md"
dst="$here/contract.md"

[[ -s "$src" ]] || { echo "missing $src" >&2; exit 1; }

awk '/^````$/ { n++; next } n == 1' "$src" > "$dst"

lines=$(wc -l < "$dst" | tr -d ' ')
[[ "$lines" -gt 20 ]] || { echo "extracted only $lines lines — fence markers moved?" >&2; exit 1; }
for want in '## Then work the axes' '## How to report' 'one line on conformance' \
            'AMBIGUITY:' 'review-axes.md'; do
  grep -q "$want" "$dst" || { echo "extract is missing: $want" >&2; exit 1; }
done

# The contract points at the catalogue by path, so the two files must agree.
axes="$here/../../playbooks/review-axes.md"
[[ -s "$axes" ]] || { echo "contract references $axes, which is missing" >&2; exit 1; }
groups=$(grep -cE '^## [0-9]\. ' "$axes")
count=$(grep -cE '^- \*\*' "$axes")
[[ "$groups" -eq 4 ]] || { echo "catalogue has $groups groups, expected 4" >&2; exit 1; }
[[ "$count" -ge 12 ]] || { echo "catalogue has $count axes, expected 12 or more" >&2; exit 1; }

echo "contract: $lines lines -> $dst"
echo "axes:     $count across $groups groups"
