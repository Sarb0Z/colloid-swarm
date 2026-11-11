#!/usr/bin/env bash
# Firing tests for access.py: the systems schema, the publish-guard screen on
# every declared command, the probe record and the readout it writes.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
access="$repo/.agents/access.py"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

# A fixture repository holding only a policy; access.py is told where it is.
fixture() {  # <policy json> -> prints the fixture root
  local root
  root="$(mktemp -d "$scratch/fx.XXXXXX")"
  mkdir -p "$root/.agents"
  printf '%s\n' "$1" > "$root/.agents/policy.json"
  printf '%s' "$root"
}
acc() { python3 "$access" "$@"; }

# The carrier's own policy passes.
acc check >/dev/null || fail "the carrier's own systems fail check"
ok "the carrier's own policy passes check"

# Schema errors are named.
bad="$(fixture '{"systems":[{"name":"Bad Name","probe":"","read":"x","extra":1,"logs":{"Prod":"ls"}},{"name":"a","probe":"true","read":[]},{"name":"a","probe":"true","read":[]}]}')"
set +e; err="$(acc check --repo "$bad" 2>&1)"; rc=$?; set -e
[[ $rc -eq 1 ]] || fail "schema errors must exit 1 (got $rc)"
for want in "name must match" "unknown key 'extra'" "probe must be a non-empty" "read must be a list" "log environment 'Prod'" "name declared twice"; do
  grep -qF "$want" <<<"$err" || fail "schema error missing: $want"
done
ok "schema errors are named"

# A write declared as a read is refused by name, with the guard's reason.
write="$(fixture '{"systems":[{"name":"github","probe":"true","read":["gh pr list","gh pr merge 1"],"logs":{"ci":"gh pr create --title x"}}]}')"
set +e; err="$(acc check --repo "$write" 2>&1)"; rc=$?; set -e
[[ $rc -eq 1 ]] || fail "a guarded read must fail check (got $rc)"
grep -qF '`gh pr merge 1` in system github, read: the publish guard asks:' <<<"$err" || fail "merge not named: $err"
grep -qF '`gh pr create --title x` in system github, log ci:' <<<"$err" || fail "log write not named: $err"
grep -qF 'gh pr list`' <<<"$err" && fail "a plain read was flagged"
ok "a declared read the guard asks about is refused by name"

# Probes record reachable, unreachable and timeout; output never lands in a file.
probes="$(fixture '{"systems":[{"name":"up","probe":"echo SECRETUP; true","read":["ls"]},{"name":"down","probe":"echo SECRETDOWN; false","read":[],"logs":{"local":"ls","production":"ls"}},{"name":"slow","probe":"sleep 20","read":[]}]}')"
out="$(acc probe --repo "$probes")" || fail "probe with unreachable systems must exit 0"
grep -qF 'up: reachable (exit 0), 1 reads, logs: none' <<<"$out" || fail "reachable line wrong: $out"
grep -qF 'down: unreachable (exit 1), 0 reads, logs: local, production' <<<"$out" || fail "unreachable line wrong: $out"
grep -qF 'slow: unreachable (timeout)' <<<"$out" || fail "timeout line wrong: $out"
grep -rq 'SECRET' "$probes/.agents/.readout" "$probes/.agents/.readout/" 2>/dev/null && fail "probe output reached the readout"
grep -q SECRET <<<"$out" && fail "probe output was printed"
ok "probes record reachable, unreachable (exit 1) and timeout, no output"

# The readout carries the strip and one note line per system.
strip="$(python3 "$repo/.agents/hooks/lib/readout.py" strip "$probes" s1)"
[[ "$strip" == *"systems: down, slow unreachable"* ]] || fail "strip wrong: $strip"
python3 - "$probes/.agents/.readout/systems.json" <<'PY' || fail "readout record wrong"
import json, sys
r = json.load(open(sys.argv[1]))
assert r["stale_after"] == 86400 and "session" not in r and len(r["note"].splitlines()) == 3, r
PY
ok "the readout carries the strip, three note lines and a day of freshness"

# All reachable: the strip is empty.
fine="$(fixture '{"systems":[{"name":"up","probe":"true","read":[]}]}')"
acc probe --repo "$fine" >/dev/null
[[ -z "$(python3 "$repo/.agents/hooks/lib/readout.py" strip "$fine" s1)" ]] || fail "strip must be empty when all reachable"
ok "an all-reachable table shows no strip"

# --name probes one system and leaves the readout alone.
rm -rf "$fine/.agents/.readout"
acc probe --name up --repo "$fine" | grep -qF 'up: reachable' || fail "--name did not probe"
[[ ! -e "$fine/.agents/.readout/systems.json" ]] || fail "--name must not write the readout"
set +e; acc probe --name nope --repo "$fine" >/dev/null 2>&1; rc=$?; set -e
[[ $rc -eq 1 ]] || fail "an unknown --name must exit 1"
ok "--name probes one system and writes no readout"

# A probe the guard would ask about is refused and never run.
marker="$scratch/ran"
guarded="$(fixture "{\"systems\":[{\"name\":\"gh\",\"probe\":\"touch $marker; gh pr merge 1\",\"read\":[]},{\"name\":\"up\",\"probe\":\"true\",\"read\":[]}]}")"
set +e; err="$(acc probe --repo "$guarded" 2>&1 >/dev/null)"; rc=$?; set -e
[[ $rc -eq 1 ]] || fail "a guarded probe must exit 1 (got $rc)"
[[ ! -e "$marker" ]] || fail "a guarded probe ran"
grep -qF 'in system gh not run: the publish guard asks' <<<"$err" || fail "refusal not named: $err"
ok "a probe the guard asks about is refused and not run"

# No systems key: one pointer line, exit 0.
none="$(fixture '{"hooks":{}}')"
for verb in list probe; do
  out="$(acc "$verb" --repo "$none")" || fail "$verb with no systems must exit 0"
  [[ "$(wc -l <<<"$out")" -eq 1 ]] && grep -qF 'Systems step of .agents/export/README.md' <<<"$out" || fail "$verb pointer wrong: $out"
done
[[ ! -e "$none/.agents/.readout" ]] || fail "no systems must write no readout"
ok "no systems key prints the pointer and exits 0"

# list shows every command.
out="$(acc list --repo "$probes")"
grep -qF 'log production: ls' <<<"$out" && grep -qF 'probe: sleep 20' <<<"$out" || fail "list incomplete: $out"
ok "list shows probes, reads and logs"
