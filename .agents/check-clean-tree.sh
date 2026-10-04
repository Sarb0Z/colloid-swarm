#!/usr/bin/env bash
# Fails when a CI step left tracked changes or new files behind, so a stale
# generated file shows up as a red job instead of a silent edit.
set -euo pipefail

changed="$(git status --porcelain --untracked-files=all)"
if [[ -n "$changed" ]]; then
  printf '%s\n' "$changed"
  echo '::error title=Working tree is dirty::A step left tracked changes or new files behind.'
  exit 1
fi
