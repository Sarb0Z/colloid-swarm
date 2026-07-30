#!/usr/bin/env bash
# Corpus integrity check. Every fixture must hold three files, and the
# manifest must agree with the ground-truth files it is built from.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
fail=0

for d in */; do
  d="${d%/}"
  for f in intent.md ground-truth.md; do
    [[ -s "$d/$f" ]] || { echo "FAIL $d: missing or empty $f"; fail=1; }
  done
  compgen -G "$d/artifact.*" > /dev/null \
    || { echo "FAIL $d: no artifact file"; fail=1; }

  want=$(grep -cE '^## [0-9]+\.' "$d/ground-truth.md" 2>/dev/null || echo 0)
  got=$(awk -F'\t' -v f="$d" 'NR>1 && $1==f' manifest.tsv | wc -l | tr -d ' ')
  [[ "$want" == "$got" ]] \
    || { echo "FAIL $d: ground-truth has $want findings, manifest has $got"; fail=1; }
done

unlabeled=$(awk -F'\t' 'NR>1 && ($3=="UNLABELED" || $4=="UNLABELED")' manifest.tsv | wc -l | tr -d ' ')
[[ "$unlabeled" == "0" ]] \
  || { echo "FAIL: $unlabeled finding(s) missing a class or disposition"; fail=1; }

total=$(($(wc -l < manifest.tsv) - 1))
[[ "$fail" == "0" ]] && echo "OK — $(ls -d */ | wc -l | tr -d ' ') fixtures, $total findings"
exit "$fail"
