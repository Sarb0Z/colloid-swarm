#!/usr/bin/env bash
# Link each .agents/iterm/bin/* into $HOME/.local/bin. Safe to rerun; refuses
# to replace anything that is not already its own link.
set -euo pipefail

src=$(cd "$(dirname "${BASH_SOURCE[0]}")/bin" && pwd -P)
dest=$HOME/.local/bin
mkdir -p "$dest"

for f in "$src"/*; do
  name=$(basename "$f")
  target=$dest/$name
  if [[ -L $target && $(readlink "$target") == "$f" ]]; then
    echo "unchanged: $target"
  elif [[ -e $target || -L $target ]]; then
    echo "install.sh: $target exists and is not a link to $f; not replacing it" >&2
    exit 1
  else
    ln -s "$f" "$target"
    echo "linked: $target -> $f"
  fi
done
