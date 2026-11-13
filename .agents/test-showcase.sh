#!/usr/bin/env bash
# Firing tests for demo/check-inventory.py's source-panel rows: a showcase whose
# quoted file changed since embed-src.py last ran, or whose publish variant
# differs by a byte from what a rebuild writes, fails the suite and CI.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
scratch="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$scratch"' EXIT
fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
ok() { printf 'ok    %s\n' "$*"; }

# The fixture holds what check-inventory.py reads: both scripts, the page and
# its publish variant, every file a panel quotes, the hook policies and the
# skill folders.
fx="$scratch/fx"
mkdir -p "$fx/demo" "$fx/.agents/hooks/policy" "$fx/.agents/skills"
cp "$repo/demo/embed-src.py" "$repo/demo/check-inventory.py" "$repo/demo/scaffold-showcase.html" \
  "$repo/demo/scaffold-showcase.artifact.html" "$fx/demo/"
cp "$repo"/.agents/hooks/policy/*.sh "$fx/.agents/hooks/policy/"
for dir in "$repo"/.agents/skills/*/; do mkdir -p "$fx/.agents/skills/$(basename "$dir")"; done
while IFS= read -r rel; do
  mkdir -p "$(dirname "$fx/$rel")" && cp "$repo/$rel" "$fx/$rel"
done < <(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("embed_src", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print("\n".join(sorted(set(module.MANIFEST.values()))))
' "$repo/demo/embed-src.py")
check() { python3 "$fx/demo/check-inventory.py" 2>&1; }

python3 "$fx/demo/embed-src.py" >/dev/null
out="$(check)" || fail "a showcase rebuilt from its sources must pass: $out"
[[ "$out" == *"page matches the repository"* ]] || fail "wrong message: $out"
ok "check-inventory passes a showcase rebuilt from its sources"

cp "$fx/demo/scaffold-showcase.html" "$scratch/page.before"
cp "$fx/demo/scaffold-showcase.artifact.html" "$scratch/artifact.before"
printf -- '- **A line added after the last rebuild.**\n' >> "$fx/.agents/breadcrumbs.md"
out="$(check)" && fail "a panel older than its file must fail: $out"
[[ "$out" == *'panels: stale against `.agents/breadcrumbs.md`'* ]] || fail "the failure must name the changed file: $out"
[[ "$out" == *'python3 demo/embed-src.py'* ]] || fail "the failure must name the command that fixes it: $out"
[[ "$out" != *"publish variant"* ]] || fail "a stale page must not also blame the publish variant built from it: $out"
cmp -s "$scratch/page.before" "$fx/demo/scaffold-showcase.html" \
  && cmp -s "$scratch/artifact.before" "$fx/demo/scaffold-showcase.artifact.html" \
  || fail "the check must write neither page"
ok "check-inventory fails a panel whose file changed since the last rebuild, names it, and writes nothing"

python3 "$fx/demo/embed-src.py" >/dev/null
out="$(check)" || fail "the rebuild must clear the failure: $out"
ok "embed-src.py clears a stale panel"

printf '<p>edited by hand</p>\n' >> "$fx/demo/scaffold-showcase.artifact.html"
out="$(check)" && fail "a publish variant that differs from the page must fail: $out"
[[ "$out" == *'panels: `demo/scaffold-showcase.artifact.html` is not the publish variant of the page'* ]] \
  || fail "the failure must name the publish variant: $out"
[[ "$out" != *"stale against"* ]] || fail "a fresh page must not read as stale: $out"
ok "check-inventory fails a publish variant that is not built from the page"

python3 "$fx/demo/embed-src.py" >/dev/null
python3 -c 'import sys; p = sys.argv[1]; t = open(p, "rb").read(); open(p, "wb").write(t.replace(b"\n", b"\r\n"))' \
  "$fx/demo/scaffold-showcase.artifact.html"
out="$(check)" && fail "a publish variant with other line endings must fail, as the rebuild rewrites it: $out"
[[ "$out" == *'`demo/scaffold-showcase.artifact.html` is not the publish variant of the page'* ]] || fail "wrong message: $out"
python3 "$fx/demo/embed-src.py" >/dev/null
python3 -c 'import sys; p = sys.argv[1]; t = open(p, "rb").read(); open(p, "wb").write(t.replace(b"\n", b"\r\n"))' \
  "$fx/demo/scaffold-showcase.html"
out="$(check)" && fail "a page with other line endings must fail, as the rebuild rewrites it: $out"
[[ "$out" == *'page: `demo/scaffold-showcase.html` is not what `embed-src.py` writes from it'* ]] || fail "wrong message: $out"
ok "check-inventory compares bytes, so a page or publish variant saved with CRLF line endings fails"

python3 "$fx/demo/embed-src.py" >/dev/null
python3 -c 'import sys; p = sys.argv[1]; t = open(p).read(); open(p, "w").write(t.replace("<style>", "<style media=\"all\">", 1))' \
  "$fx/demo/scaffold-showcase.html"
out="$(check)" && fail "a page the publish variant cannot be cut from must fail: $out"
[[ "$out" == *'page: demo/scaffold-showcase.html has no <style> or <body> block'* ]] || fail "wrong message: $out"
[[ "$out" == *'showcase drifted from the scaffold'* && "$out" != *Traceback* ]] \
  || fail "the problem must join the list, not stop the check: $out"
ok "check-inventory lists a page with no <style> block among its problems"

cp "$scratch/page.before" "$fx/demo/scaffold-showcase.html"
python3 "$fx/demo/embed-src.py" >/dev/null
rm "$fx/.agents/debt-log.md"
rm "$fx/.agents/knowledge/README.md" && mkdir "$fx/.agents/knowledge/README.md"
out="$(check)" && fail "a quoted file that is gone or a folder must fail: $out"
[[ "$out" == *'`debt-log.md` points at `.agents/debt-log.md`, which is not a file'* ]] || fail "wrong message: $out"
[[ "$out" == *'`knowledge/` points at `.agents/knowledge/README.md`, which is not a file'* ]] || fail "wrong message: $out"
[[ "$out" != *Traceback* ]] || fail "a missing quoted file must not end in a traceback: $out"
ok "check-inventory names a quoted file that is gone or a folder, with no traceback"

[[ ! -e "$fx/demo/__pycache__" ]] || fail "the check must leave no __pycache__ beside the generator"
ok "loading the generator writes no bytecode"

if (( fails )); then
  printf '\n%d showcase check(s) failed\n' "$fails" >&2
  exit 1
fi
printf '\nshowcase checks: all passed\n'
