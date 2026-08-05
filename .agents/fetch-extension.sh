#!/usr/bin/env bash
# Install a browser extension for the reader browser tier.
#
# Extensions are operator-supplied, never vendored: uBO Lite is GPL-3.0, and the
# repository carries the wiring, not the payload. The install tree
# (.agents/browser-extensions/) is gitignored.
#
# Usage:
#   .agents/fetch-extension.sh ublock-lite [version]
#
# Then enable the reader tier and restart the session:
#   .agents/sync-mcp.sh enable playwright-reader
#
# Only Manifest V3 extensions load. Chromium removed the last MV2 code paths at
# milestone 151, which is what Playwright bundles.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="${1:-}"
version="${2:-latest}"

if [[ "$name" != "ublock-lite" ]]; then
  echo "usage: fetch-extension.sh ublock-lite [version]" >&2
  echo "known extensions: ublock-lite" >&2
  exit 2
fi

for tool in curl unzip python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "fetch-extension: $tool is required" >&2; exit 1; }
done

dest="$repo/.agents/browser-extensions/$name"
work="$(mktemp -d "${TMPDIR:-/tmp}/fetch-extension.XXXXXX")"
trap 'rm -rf "$work"' EXIT

if [[ "$version" == "latest" ]]; then
  api="https://api.github.com/repos/uBlockOrigin/uBOL-home/releases/latest"
else
  api="https://api.github.com/repos/uBlockOrigin/uBOL-home/releases/tags/$version"
fi

# The Chromium asset is the only loadable one: .edge is the same build under a
# different store id, .xpi is Firefox, .safari is a wrapped app extension.
read -r tag url < <(curl -fsSL "$api" | python3 -c '
import json, sys
release = json.load(sys.stdin)
for asset in release.get("assets", []):
    if asset["name"].endswith(".chromium.zip"):
        print(release["tag_name"], asset["browser_download_url"])
        break
else:
    sys.exit("fetch-extension: no .chromium.zip asset in release")
')

echo "fetch-extension: uBO Lite $tag"
curl -fsSL -o "$work/ext.zip" "$url"
unzip -q "$work/ext.zip" -d "$work/unpacked"

# The release ships files mode 0600. Chromium must read them as whatever user
# runs the browser, so widen before the tree is installed.
chmod -R u+rwX,go+rX "$work/unpacked"

[[ -f "$work/unpacked/manifest.json" ]] || {
  echo "fetch-extension: no manifest.json at the archive root — layout changed" >&2
  exit 1
}
python3 - "$work/unpacked/manifest.json" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
if manifest.get("manifest_version") != 3:
    sys.exit(f"fetch-extension: manifest_version {manifest.get('manifest_version')} will not load; MV3 required")
print(f"fetch-extension: manifest v3, extension version {manifest.get('version')}")
PY

mkdir -p "$(dirname "$dest")"
rm -rf "$dest"
mv "$work/unpacked" "$dest"
echo "fetch-extension: installed $dest"
echo "next: .agents/sync-mcp.sh enable playwright-reader   (then restart the session)"
