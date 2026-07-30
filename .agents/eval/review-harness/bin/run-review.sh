#!/usr/bin/env bash
# Materialise one scenario and print the reviewer dispatch prompt.
#
#   run-review.sh <fixture> <replicate>
#
# Bash cannot dispatch a subagent. This script prepares everything the dispatch
# needs and prints the prompt. The operator dispatches, saves the returned text
# to the report path, then fills the token column in runs.tsv.
#
# Run directories are opaque. The reviewer reads its own working path, so a
# path carrying the fixture name tells it what it is reviewing. The mapping
# lives in index.tsv, outside the tree.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
episodes="$here/../../fixtures/review-episodes"
projects="$HOME/Projects"
work="${REVIEW_HARNESS_WORK:-${TMPDIR:-/tmp}/rvw}"

fixture="${1:?usage: run-review.sh <fixture> <replicate>}"
rep="${2:?missing replicate}"

contract="$here/contract.md"
intent="$here/intents/$fixture.md"
[[ -s "$contract" ]] || { echo "no contract — run bin/extract-contract.sh" >&2; exit 1; }
[[ -s "$intent"   ]] || { echo "no sanitised intent: $intent" >&2; exit 1; }
[[ -s "$here/genome.txt" ]] || { echo "missing $here/genome.txt" >&2; exit 1; }

row=$(awk -F'\t' -v f="$fixture" 'NR>1 && $1==f' "$here/sources.tsv")
[[ -n "$row" ]] || { echo "$fixture not in sources.tsv" >&2; exit 1; }
IFS=$'\t' read -r _ repo base commit apply target _conf <<<"$row"

token=$(printf '%s' "$fixture/$rep" | shasum | cut -c1-10)
run_dir="$work/runs/$token"
tree="$run_dir/tree"
extra="$here/fixtures-extra/$fixture"

rm -rf "$run_dir"; mkdir -p "$tree"
git -C "$projects/$repo" archive "$base" | tar -x -C "$tree"

# Reconstruct the working tree as the original reviewer saw it: the base tree
# with the artifact applied. Never the commit tree — that one has the review
# fixes already folded in.
case "$apply" in
  diff)
    git -C "$tree" init -q
    git -C "$tree" apply -p1 "$episodes/$fixture/artifact.diff"
    rm -rf "$tree/.git"
    if [[ -s "$extra/truncate-at" ]]; then
      head -n "$(cat "$extra/truncate-at")" "$episodes/$fixture/artifact.diff" > "$tree/CHANGE.diff"
    else
      cp "$episodes/$fixture/artifact.diff" "$tree/CHANGE.diff"
    fi
    ;;
  file)
    artifact=$(ls "$episodes/$fixture"/artifact.* | head -1)
    git -C "$projects/$repo" show "$base:$target" > "$run_dir/base-version"
    cp "$artifact" "$tree/$target"
    diff -u --label "a/$target" --label "b/$target" \
      "$run_dir/base-version" "$artifact" > "$tree/CHANGE.diff" || true
    ;;
  *) echo "unknown apply mode: $apply" >&2; exit 1 ;;
esac

# Files the artifact carries as raw text rather than as diff hunks. git apply
# drops those silently, which removes real files from the review and leaves a
# malformed tail in the diff.
if [[ -d "$extra/files" ]]; then
  while IFS= read -r rel; do
    mkdir -p "$tree/$(dirname "$rel")"
    cp "$extra/files/$rel" "$tree/$rel"
    {
      printf 'diff --git a/%s b/%s\nnew file mode 100644\n--- /dev/null\n+++ b/%s\n' "$rel" "$rel" "$rel"
      printf '@@ -0,0 +1,%s @@\n' "$(wc -l < "$extra/files/$rel" | tr -d ' ')"
      sed 's/^/+/' "$extra/files/$rel"
    } >> "$tree/CHANGE.diff"
  done < <(cd "$extra/files" && find . -type f | sed 's|^\./||')
fi

cp "$intent" "$tree/REVIEW-INTENT.md"

# Transplant the contract only. The base tree keeps its own .agents/ because
# the original reviewer saw it; copying this repo's .agents/ would ship the
# fixture corpus and the harness itself into the scenario.
mkdir -p "$tree/.agents/playbooks"
cp "$contract" "$tree/.agents/playbooks/hostile-review.md"

# The contract reads the axis catalogue by path and is told to stop if it is
# missing, so a run without it produces a refusal, not a review.
axes="$here/../../playbooks/review-axes.md"
[[ -s "$axes" ]] || { echo "missing axis catalogue: $axes" >&2; exit 1; }
cp "$axes" "$tree/.agents/playbooks/review-axes.md"

# Every skill the contract names must exist in the tree, or the reviewer
# follows a dead reference. It invokes one of these and flags the other.
for name in thermo-nuclear-code-quality-review scalability-audit; do
  src="$here/../../skills/$name"
  [[ -d "$src" ]] || { echo "contract names skill '$name' but it is missing" >&2; exit 1; }
  mkdir -p "$tree/.agents/skills"
  cp -R "$src" "$tree/.agents/skills/"
done

if grep -rqlE "review-episodes|ground-truth|colloid-swarm" "$tree/.agents" 2>/dev/null; then
  echo "ABORT: harness content reached the scenario tree" >&2
  grep -rlE "review-episodes|ground-truth|colloid-swarm" "$tree/.agents" >&2
  exit 1
fi

report="$run_dir/report.md"
{
  cat "$here/genome.txt"
  cat <<PROMPT

Review the change in CHANGE.diff. The repository root is $tree — read whatever
files there you need. The intent of the change is in REVIEW-INTENT.md.

Follow the review contract in .agents/playbooks/hostile-review.md exactly.

Return the complete report as your final message. Do not write it to a file.
Do not use ReportFindings or any other tool to emit findings — anything not in
your final message is lost.
PROMPT
} > "$run_dir/prompt.txt"

index="$work/index.tsv"
mkdir -p "$work"
[[ -s "$index" ]] || printf 'token\tfixture\treplicate\n' > "$index"
grep -q "^$token	" "$index" || printf '%s\t%s\t%s\n' "$token" "$fixture" "$rep" >> "$index"

runs="$here/runs.tsv"
[[ -s "$runs" ]] || printf 'token\tfixture\treplicate\tcontract_sha\tbase\tstatus\ttokens\n' > "$runs"
grep -q "^$token	" "$runs" 2>/dev/null || printf '%s\t%s\t%s\t%s\t%s\tpending\t-\n' \
  "$token" "$fixture" "$rep" \
  "$(shasum "$contract" | cut -c1-12)" "${base:0:12}" >> "$runs"

echo "token:  $token"
echo "prompt: $run_dir/prompt.txt"
echo "report: $report"
