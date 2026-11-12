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
for want in "name must match" "unknown key 'extra'" "probe must be a non-empty" "read must be a list" "log environment 'Prod' must be one of local, staging, production" "name declared twice"; do
  grep -qF "$want" <<<"$err" || fail "schema error missing: $want"
done
ok "schema errors are named"

# A write declared as a read is refused by name, with the guard's reason.
write="$(fixture '{"systems":[{"name":"github","probe":"true","read":["gh pr list","gh pr merge 1"],"logs":{"staging":"gh pr create --title {since}"}}]}')"
set +e; err="$(acc check --repo "$write" 2>&1)"; rc=$?; set -e
[[ $rc -eq 1 ]] || fail "a guarded read must fail check (got $rc)"
grep -qF '`gh pr merge 1` in system github, read: refused by guard-publish:' <<<"$err" || fail "merge not named: $err"
grep -qF '`gh pr create --title {since}` in system github, log staging:' <<<"$err" || fail "log write not named: $err"
grep -qF 'gh pr list`' <<<"$err" && fail "a plain read was flagged"
ok "a declared read the guard asks about is refused by name"

# Probes record reachable, unreachable and timeout; output never lands in a file.
probes="$(fixture '{"systems":[{"name":"up","probe":"echo SECRETUP; true","read":["ls"]},{"name":"down","probe":"echo SECRETDOWN; false","read":[],"logs":{"local":"ls {since}","production":"ls {since}"}},{"name":"slow","probe":"sleep 20","read":[]}]}')"
out="$(acc probe --repo "$probes")" || fail "probe with unreachable systems must exit 0"
grep -qF 'up: reachable (exit 0), 1 reads, logs: none' <<<"$out" || fail "reachable line wrong: $out"
grep -qF 'down: unreachable (exit 1), 0 reads, logs: local, production' <<<"$out" || fail "unreachable line wrong: $out"
grep -qF 'slow: unreachable (timeout)' <<<"$out" || fail "timeout line wrong: $out"
grep -rq 'SECRET' "$probes/.agents/.readout" "$probes/.agents/.readout/" 2>/dev/null && fail "probe output reached the readout"
grep -q SECRET <<<"$out" && fail "probe output was printed"
ok "probes record reachable, unreachable (exit 1) and timeout, no output"

# The readout carries the strip and one note line per system.
strip="$(python3 "$repo/.agents/hooks/lib/readout.py" strip "$probes" s1)"
[[ "$strip" == *"systems: down unreachable, slow unreachable"* ]] || fail "strip wrong: $strip"
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
grep -qF 'in system gh not run: refused by guard-publish' <<<"$err" || fail "refusal not named: $err"
python3 "$repo/.agents/hooks/lib/readout.py" strip "$guarded" s1 | grep -qF 'systems: gh refused' || fail "a refused system must appear in the strip"
ok "a probe the guard asks about is refused and not run, and shows in the strip"

# The destructive guard screens probes too: git clean must not delete a file.
victim="$scratch/victim"
mkdir -p "$victim/.agents"
git -C "$victim" init -q
printf 'keep\n' > "$victim/untracked.txt"
printf '%s\n' '{"systems":[{"name":"clean","probe":"git clean -fdx","read":[]}]}' > "$victim/.agents/policy.json"
set +e; err="$(acc check --repo "$victim" 2>&1)"; rc=$?; set -e
[[ $rc -eq 1 ]] && grep -qF 'refused by guard-destructive' <<<"$err" || fail "check must refuse git clean via guard-destructive: $err"
set +e; acc probe --repo "$victim" >/dev/null 2>&1; rc=$?; set -e
[[ $rc -eq 1 && -f "$victim/untracked.txt" ]] || fail "probe ran git clean (rc=$rc) or deleted the file"
ok "a destructive probe is refused by check and not run, and the file survives"

# A guard cannot see through expansion, so declared commands are literal.
expand="$(fixture '{"systems":[{"name":"x","probe":"true","read":["G=gh; $G pr merge 1"]},{"name":"y","probe":"echo `id`","read":[]}]}')"
set +e; err="$(acc check --repo "$expand" 2>&1)"; rc=$?; set -e
[[ $rc -eq 1 ]] || fail "expansion must fail check"
[[ "$(grep -cF 'declared commands are literal: no shell expansion' <<<"$err")" -eq 2 ]] || fail "both expansions must be named: $err"
ok "a command with a dollar sign or a backtick is a schema error"

# No systems key: one pointer line, exit 0.
none="$(fixture '{"hooks":{}}')"
for verb in list probe; do
  out="$(acc "$verb" --repo "$none")" || fail "$verb with no systems must exit 0"
  [[ "$(wc -l <<<"$out")" -eq 1 ]] && grep -qF 'Systems step of .agents/export/README.md' <<<"$out" || fail "$verb pointer wrong: $out"
done
[[ ! -e "$none/.agents/.readout" ]] || fail "no systems must write no readout"
# A readout left from an earlier declaration is removed.
mkdir -p "$none/.agents/.readout"; printf '{}' > "$none/.agents/.readout/systems.json"
acc probe --repo "$none" >/dev/null
[[ ! -e "$none/.agents/.readout/systems.json" ]] || fail "a stale systems readout survived an undeclared policy"
empty="$(fixture '{"systems":[]}')"
mkdir -p "$empty/.agents/.readout"; printf '{}' > "$empty/.agents/.readout/systems.json"
acc probe --repo "$empty" | grep -qF 'no systems declared' || fail "an empty list must print the pointer"
[[ ! -e "$empty/.agents/.readout/systems.json" ]] || fail "an empty list must remove the readout"
ok "no systems key prints the pointer and exits 0"

# list shows every command.
out="$(acc list --repo "$probes")"
grep -qF 'log production: ls {since}' <<<"$out" && grep -qF 'probe: sleep 20' <<<"$out" || fail "list incomplete: $out"
ok "list shows probes, reads and logs"

# A log command carries exactly one window placeholder.
for logs in '"ls"' '"ls {since} {minutes}"' '"ls {since} {since}"'; do
  window="$(fixture "{\"systems\":[{\"name\":\"w\",\"probe\":\"true\",\"read\":[],\"logs\":{\"staging\":$logs}}]}")"
  set +e; err="$(acc check --repo "$window" 2>&1)"; rc=$?; set -e
  [[ $rc -eq 1 ]] || fail "log command $logs must fail check (got $rc)"
  grep -qF 'log staging must carry exactly one window placeholder, {since} or {minutes}' <<<"$err" || fail "placeholder error missing for $logs: $err"
done
ok "a log command with no placeholder or with two is refused"

# A write hidden behind a placeholder is still refused, by both guards.
hidden="$(fixture '{"systems":[{"name":"h","probe":"true","read":[],"logs":{"local":"gh pr merge {minutes}","staging":"git clean -fdx {since}"}}]}')"
set +e; err="$(acc check --repo "$hidden" 2>&1)"; rc=$?; set -e
[[ $rc -eq 1 ]] || fail "a guarded log command must fail check (got $rc)"
grep -qF '`gh pr merge {minutes}` in system h, log local: refused by guard-publish' <<<"$err" || fail "publish refusal not named: $err"
grep -qF '`git clean -fdx {since}` in system h, log staging: refused by guard-destructive' <<<"$err" || fail "destructive refusal not named: $err"
ok "a guard-refused write behind a placeholder is refused"

# The placeholders fill from the scenario's start and an injected clock.
python3 - "$repo/.agents" <<'PY' || fail "window fill wrong"
import sys
from datetime import datetime, timezone
sys.path.insert(0, sys.argv[1])
import access
now = datetime(2026, 11, 12, 10, 0, 0, tzinfo=timezone.utc)
fill = access.fill_window
assert fill("v --since {since}", "2026-11-12T09:30:00Z", now) == "v --since 2026-11-12T09:30:00Z"
assert fill("j --since=-{minutes}min", "2026-11-12T09:30:00Z", now) == "j --since=-30min"
assert fill("j -{minutes}", "2026-11-12T09:29:59Z", now) == "j -31", "partial minutes round up"
assert fill("j -{minutes}", "2026-11-12T10:00:00Z", now) == "j -1", "a zero window is one minute"
for bad in ("2026-11-12 09:30:00", "2026-11-12T09:30:00+00:00", "2026-11-12T10:00:01Z", "$(id)"):
    try:
        fill("x {since}", bad, now)
    except ValueError:
        continue
    raise SystemExit(f"accepted {bad!r}")
PY
ok "{since} and {minutes} fill for a fixed clock, and a bad start is refused"

# logs fills the placeholder, runs the declared command in the repo root, prints it.
runs="$(fixture '{"systems":[{"name":"svc","probe":"true","read":[],"logs":{"staging":"echo since {since}","production":"pwd; echo minutes {minutes}"}}]}')"
out="$(acc logs --name svc --env staging --since 2026-11-12T09:30:00Z --repo "$runs")" || fail "logs on a harmless command failed"
[[ "$out" == "since 2026-11-12T09:30:00Z" ]] || fail "logs output wrong: $out"
out="$(acc logs --name svc --env production --since 2000-01-01T00:00:00Z --repo "$runs")" || fail "logs production failed"
[[ "$(head -n1 <<<"$out")" == "$(cd "$runs" && pwd -P)" ]] || fail "logs must run in the repository root: $out"
grep -qE '^minutes [0-9]{7,}$' <<<"$out" || fail "{minutes} not filled from the real clock: $out"
ok "logs runs the declared command in the repository root with the window filled"

# logs refuses what the guards refuse, an unknown system or environment, and a bad start.
marker2="$scratch/ran-log"
guarded="$(fixture "{\"systems\":[{\"name\":\"svc\",\"probe\":\"true\",\"read\":[],\"logs\":{\"staging\":\"touch $marker2; gh pr merge {minutes}\"}}]}")"
set +e; err="$(acc logs --name svc --env staging --since 2026-11-12T09:30:00Z --repo "$guarded" 2>&1)"; rc=$?; set -e
[[ $rc -eq 1 && ! -e "$marker2" ]] || fail "a guarded log command ran or exited $rc"
grep -qF 'refused by guard-publish' <<<"$err" || fail "logs refusal not named: $err"
for args in "--name nope --env staging" "--name svc --env local" "--name svc --env staging --since yesterday"; do
  since_arg="--since 2026-11-12T09:30:00Z"
  [[ "$args" == *--since* ]] && since_arg=""
  set +e; acc logs $args $since_arg --repo "$runs" >/dev/null 2>&1; rc=$?; set -e
  [[ $rc -eq 1 ]] || fail "logs $args must exit 1 (got $rc)"
done
ok "logs refuses a guarded command, an unknown system, an undeclared environment and a bad start"
