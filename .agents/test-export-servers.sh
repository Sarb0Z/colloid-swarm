#!/usr/bin/env bash
set -euo pipefail
# What a satellite receives of the repository-owned MCP servers: the bundle,
# its licence and its README, and nothing a dependency graph can read. Run from
# the committed HEAD, as the export itself does.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/scaffold-export-servers.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "test-export-servers: $*" >&2; exit 1; }
git_quiet() { git -c user.name=t -c user.email=t@example.invalid "$@"; }

servers=(research-mcp security-mcp)

git clone --quiet --no-hardlinks "$repo" "$work/source"
"$work/source/.agents/export-scaffold.py" "$work/kit" >/dev/null
kit="$work/kit"

# --- 1. The kit's shape -------------------------------------------------------
unexpected="$(cd "$kit/.agents/mcp-servers" && find . -type f \
  ! -path './*/dist/*' ! -path './*/LICENSE' ! -path './*/README.md' \
  ! -path './security-mcp/UPSTREAM.json' | sort)"
[[ -z "$unexpected" ]] || { printf '%s\n' "$unexpected" >&2; fail "a server file outside the shipped list reached the kit"; }
for name in "${servers[@]}"; do
  [[ -f "$kit/.agents/mcp-servers/$name/dist/server.js" ]] || fail "$name ships no bundle"
done

manifests="$(cd "$kit" && find . -name package.json -not -path './export/*' | sort)"
expected_manifests="$(printf './.agents/mcp-servers/%s/dist/package.json\n' "${servers[@]}" | sort)"
[[ "$manifests" == "$expected_manifests" ]] \
  || { printf '%s\n' "$manifests" >&2; fail "the kit holds a package.json beyond each bundle's own"; }
for name in "${servers[@]}"; do
  [[ "$(cat "$kit/.agents/mcp-servers/$name/dist/package.json")" == '{"type":"module"}' ]] \
    || fail "$name/dist/package.json is not exactly {\"type\":\"module\"}"
done

locks="$(find "$kit" \( -name package-lock.json -o -name npm-shrinkwrap.json -o -name pnpm-lock.yaml \
  -o -name yarn.lock -o -name 'bun.lock' -o -name 'bun.lockb' -o -name sbom.cdx.json \) | sort)"
[[ -z "$locks" ]] || { printf '%s\n' "$locks" >&2; fail "the kit carries a lockfile or an SBOM"; }

for name in "${servers[@]}"; do
  ! grep -q 'npm' "$kit/.agents/mcp-servers/$name/README.md" || fail "$name/README.md mentions npm in the kit"
  [[ -s "$kit/.agents/mcp-servers/$name/dist/THIRD-PARTY-NOTICES.txt" ]] || fail "$name ships no third-party notices"
done
echo 'ok  the kit ships the bundles only'

# --- 10. The notices name every bundled package --------------------------------
for name in "${servers[@]}"; do
  dist="$kit/.agents/mcp-servers/$name/dist"
  while IFS= read -r package; do
    grep -qE "^${package//\//\\/}@[0-9]" "$dist/THIRD-PARTY-NOTICES.txt" \
      || fail "$name's notices omit the bundled package $package"
  done < <(sed -nE 's|^// node_modules/(@[^/]+/[^/]+\|[^/@][^/]*)/.*|\1|p' "$dist/server.js" | sort -u)
  grep -q 'Permission is hereby granted\|Redistribution and use\|Apache License\|Permission to use' \
    "$dist/THIRD-PARTY-NOTICES.txt" || fail "$name's notices carry no licence text"
done
echo 'ok  the notices name every bundled package'

# --- 2. The kit's launch -------------------------------------------------------
# A bundle runs with no install, from a satellite whose own package.json says
# commonjs. The driver answers initialize and tools/list over stdio.
cat >"$work/probe.mjs" <<'JS'
import { spawn } from 'node:child_process';
const [folder, serverName, toolList] = process.argv.slice(2);
const child = spawn(process.execPath, ['dist/server.js'], { cwd: folder, stdio: ['pipe', 'pipe', 'pipe'] });
let stderr = '';
child.stderr.on('data', (chunk) => { stderr += chunk; });
const replies = new Map();
let buffer = '';
const finish = (message) => { child.kill(); console.error(`probe: ${message}\n${stderr}`); process.exit(1); };
const timer = setTimeout(() => finish('no answer within 20 s'), 20000);
child.on('exit', (code) => { if (code) finish(`server exited ${code}`); });
child.stdout.on('data', (chunk) => {
  buffer += chunk;
  let at;
  while ((at = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, at);
    buffer = buffer.slice(at + 1);
    if (!line.trim()) continue;
    const message = JSON.parse(line);
    replies.set(message.id, message);
    if (message.id === 1) {
      child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' })}\n`);
      child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list' })}\n`);
    }
    if (message.id === 2) {
      clearTimeout(timer);
      const name = replies.get(1).result.serverInfo.name;
      const tools = message.result.tools.map((tool) => tool.name).join(',');
      child.kill();
      if (name !== serverName || tools !== toolList) {
        console.error(`probe: got ${name} / ${tools}, wanted ${serverName} / ${toolList}`);
        process.exit(1);
      }
      process.exit(0);
    }
  }
});
child.stdin.write(`${JSON.stringify({
  jsonrpc: '2.0', id: 1, method: 'initialize',
  params: { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'probe', version: '0' } },
})}\n`);
JS
mkdir -p "$work/host"
printf '{"type":"commonjs"}\n' >"$work/host/package.json"
cp -R "$kit/.agents/mcp-servers/research-mcp" "$work/host/research-mcp"
cp -R "$kit/.agents/mcp-servers/security-mcp" "$work/host/security-mcp"
node "$work/probe.mjs" "$work/host/research-mcp" research-mcp fetch_readable,resolve_open_access \
  || fail "research-mcp's kit bundle does not answer under a commonjs parent"
node "$work/probe.mjs" "$work/host/security-mcp" security-mcp validate_target,security_scan,list_security_prompts \
  || fail "security-mcp's kit bundle does not answer under a commonjs parent"
echo 'ok  each kit bundle answers initialize and tools/list under a commonjs parent'

# --- 3. Migration by sync ------------------------------------------------------
# The old-shape kit is the new kit with each server folder as earlier exports
# shipped it: HEAD's whole folder, less the two files these units add.
old="$work/old-kit"
cp -R "$kit" "$old"
git -C "$work/source" archive HEAD .agents/mcp-servers | tar -x -C "$work"
for name in "${servers[@]}"; do
  rm -rf "$old/.agents/mcp-servers/$name"
  cp -R "$work/.agents/mcp-servers/$name" "$old/.agents/mcp-servers/$name"
  rm -rf "$old/.agents/mcp-servers/$name/node_modules"
  rm -f "$old/.agents/mcp-servers/$name/dist/package.json" "$old/.agents/mcp-servers/$name/dist/THIRD-PARTY-NOTICES.txt"
done

satellite() {  # <dir> : a committed copy of the old kit's tree, as a satellite holds it
  cp -R "$old" "$1"
  rm -rf "$1/export"
  git -C "$1" init -q
  git -C "$1" add -A
  git_quiet -C "$1" commit -qm sync
}
satellite "$work/sat-plain"
satellite "$work/sat-lean"
rm -rf "$work/sat-lean/.agents/mcp-servers/security-mcp"
python3 "$kit/export/drop-server.py" "$work/sat-lean" security-mcp >/dev/null
git -C "$work/sat-lean" add -A
git_quiet -C "$work/sat-lean" commit -qm 'drop security-mcp'

sync_report() {  # <satellite> <label> <servers present before the sync...>
  local sat="$1" label="$2" out present before
  shift 2
  present=("$@")
  before="$(cd "$sat/.agents/mcp-servers" && find . -type f | sort)"
  out="$(python3 "$kit/export/merge-kit.py" "$sat" "$old" "$kit" --apply 2>&1)" \
    || { printf '%s\n' "$out" >&2; fail "$label: merge-kit --apply did not exit 0"; }
  python3 - "$out" "$sat" "$before" "${present[@]}" <<'PY' || fail "$label: the sync report is wrong"
import sys

report, sat, before, *present = sys.argv[1:]
sections, current = {}, None
for line in report.splitlines():
    if line.startswith("  ") and current:
        sections[current].append(line.strip())
    elif ": " in line and line.split(": ")[0].replace("-", "").isalpha():
        current = line.split(":")[0]
        sections[current] = []
for bad in ("conflict", "hand-merge"):
    if sections.get(bad):
        raise SystemExit(f"{bad}: {sections[bad]}")
shipped = ("dist/", "LICENSE", "README.md", "UPSTREAM.json")
dropped = {
    f".agents/mcp-servers/{path[2:]}" for path in before.splitlines()
    if not path[2:].split("/", 1)[1].startswith(shipped)
}
removed = {p for p in sections.get("removed", []) if p.startswith(".agents/mcp-servers/")}
if removed != dropped:
    raise SystemExit(f"removed differs: missing {sorted(dropped - removed)}, extra {sorted(removed - dropped)}")
added = {p for p in sections.get("added", []) if p.startswith(".agents/mcp-servers/")}
wanted = {f".agents/mcp-servers/{name}/dist/package.json" for name in present}
wanted |= {f".agents/mcp-servers/{name}/dist/THIRD-PARTY-NOTICES.txt" for name in present}
if added != wanted:
    raise SystemExit(f"added differs: missing {sorted(wanted - added)}, extra {sorted(added - wanted)}")
PY
  unexpected="$(cd "$sat/.agents/mcp-servers" && find . -type f \
    ! -path './*/dist/*' ! -path './*/LICENSE' ! -path './*/README.md' ! -path './security-mcp/UPSTREAM.json')"
  [[ -z "$unexpected" ]] || { printf '%s\n' "$unexpected" >&2; fail "$label: a server file outside the list survived the sync"; }
  python3 "$sat/.agents/mcp.py" >/dev/null || fail "$label: mcp.py rejects the synced satellite"
}
sync_report "$work/sat-plain" 'unchanged satellite' research-mcp security-mcp
sync_report "$work/sat-lean" 'satellite without security-mcp' research-mcp
[[ ! -e "$work/sat-lean/.agents/mcp-servers/security-mcp" ]] || fail "the sync restored the dropped security-mcp"
echo 'ok  an old-shape kit syncs into both satellites with only removals and additions'

# --- 4. provision.sh finds no lockfile under .agents/ --------------------------
# A kit-only repository has no root lockfile; `--hash` prints `none` when
# discovery finds no lockfile anywhere, and a hash when it finds one.
for fixture in kit old-kit; do
  git -C "$work/$fixture" init -q
  git -C "$work/$fixture" add -A
  git_quiet -C "$work/$fixture" commit -qm fixture
done
[[ "$("$kit/.agents/provision.sh" --hash "$kit")" == none ]] \
  || fail "provision.sh finds a lockfile in the kit"
[[ "$("$kit/.agents/provision.sh" --hash "$old")" != none ]] \
  || fail "the probe is blind: provision.sh finds no lockfile in an old-shape kit"
echo 'ok  provision.sh finds no lockfile in the kit'
