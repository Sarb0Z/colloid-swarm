#!/usr/bin/env bash
# Firing tests for the shared readout reader (hooks/lib/readout.py): atomic
# per-session writes, visibility, age, unreadable files and pruning.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
reader="$repo/.agents/hooks/lib/readout.py"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

target="$scratch/repo"
dir="$target/.agents/.readout"
rd() { python3 "$reader" "$@"; }

# An aged readout: written_at is set by hand, since write stamps the present.
aged() {  # <file name> <hours old> <session or ""> <strip> <note> [stale_after seconds]
  python3 - "$dir/$1" "$2" "$3" "$4" "$5" "${6:-}" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
path, hours, session, strip, note, stale = sys.argv[1:]
record = {"strip": strip, "note": note,
          "written_at": (datetime.now(timezone.utc) - timedelta(hours=float(hours))).strftime("%Y-%m-%dT%H:%M:%SZ")}
if stale:
    record["stale_after"] = int(stale)
if session:
    record["session"] = session
open(path, "w").write(json.dumps(record))
PY
}

rd write owed --repo "$target" --strip "2 owed" --note "two replies owed"
[[ -f "$dir/owed.json" ]] || fail "a repository-wide readout is not stored as <name>.json"
python3 - "$dir/owed.json" <<'PY' || fail "the stored record has the wrong shape"
import json, sys
r = json.load(open(sys.argv[1]))
assert set(r) == {"strip", "note", "written_at", "stale_after"} and r["strip"] == "2 owed" and r["stale_after"] == 86400 and r["written_at"].endswith("Z"), r
PY
ok "write stores a repository-wide readout with no session field"

rd write progress --repo "$target" --session s1 --strip "build 3/9" --note "build running"
rd write progress --repo "$target" --session s2 --strip "build 9/9" --note "other build"
[[ -f "$dir/progress--s1.json" && -f "$dir/progress--s2.json" ]] || fail "session readouts are not named per session"
[[ -z "$(ls -A "$dir" | grep -v '\.json$' || true)" ]] || fail "write left a temp file behind: $(ls -A "$dir")"
ok "write names a session readout per session and leaves no temp file"

out="$(rd strip "$target" s1)"
[[ "$out" == "2 owed  ·  build 3/9" ]] || fail "strip for s1: $out"
[[ "$out" != *"9/9"* ]] || fail "another session's readout is visible"
ok "strip joins visible segments in file-name order and hides another session's"

# Seam: readout.py strip fed a folder of five readouts. Catches the order of
# segments in the line; misses where the host's terminal cuts the line.
order="$scratch/order"
rd write access --repo "$order" --strip "access A"
rd write checks --repo "$order" --strip "checks C"
rd write owed --repo "$order" --session s1 --strip "owed O"
rd write systems --repo "$order" --strip "systems S"
rd write workloop --repo "$order" --strip "workloop W"
out="$(rd strip "$order" s1)"
[[ "$out" == "owed O  ·  access A  ·  checks C  ·  systems S  ·  workloop W" ]] || fail "owed must lead the strip, the rest by name: $out"
ok "strip puts the owed readout first, session suffix included, and the rest in file-name order"

out="$(rd strip "$target" "")"
[[ "$out" == "2 owed" ]] || fail "an empty session must see only repository-wide readouts: $out"
ok "an empty session argument sees only repository-wide readouts"

out="$(rd note "$target" s1)"
[[ "$out" == *"owed: two replies owed"* && "$out" == *"progress: build running"* && "$out" != *"other build"* ]] || fail "note for s1: $out"
ok "note prints name and note of each visible readout"

out="$(rd show --repo "$target" --session s1)"
[[ "$out" == *"build 3/9"* && "$out" != *"other build"* ]] || fail "show for s1: $out"
out="$(rd show --repo "$target" --session s1 --all)"
[[ "$out" == *"other build"* && "$out" == *"[session s2]"* ]] || fail "show --all hides another session: $out"
ok "show hides another session's file and --all includes it"

aged old-thing.json 30 "" "stale" "stale note"
aged older-thing.json 72 "" "staler" ""
out="$(rd strip "$target" s1)"
[[ "$out" == *"stale (30h old)"* && "$out" == *"staler (3d old)"* ]] || fail "age suffix missing: $out"
[[ "$(rd note "$target" s1)" == *"old-thing (30h old): stale note"* ]] || fail "note lacks the age"
aged fresh-thing.json 23 "" "recent" ""
[[ "$(rd strip "$target" s1)" == *"recent"* && "$(rd strip "$target" s1)" != *"recent ("* ]] || fail "a readout under a day carries an age"
ok "a readout older than 24 hours carries its age in the strip and the note"
rm "$dir"/old-thing.json "$dir"/older-thing.json "$dir"/fresh-thing.json

long="$(printf 'x%.0s' $(seq 70))"
rd write long --repo "$target" --strip "$long"
out="$(rd strip "$target" s1)"
[[ "$out" == *"$(printf 'x%.0s' $(seq 59))…"* && "$out" != *"$(printf 'x%.0s' $(seq 60))"* ]] || fail "segment not cut to 59 plus an ellipsis: $out"
rm "$dir/long.json"
ok "a segment over 60 characters is cut to 59 plus an ellipsis"

printf 'not json' > "$dir/broken.json"
printf '{"strip": "x"}' > "$dir/nodate.json"
for command in "strip $target s1" "note $target s1" "show --repo $target --session s1"; do
  out="$(rd $command)" || fail "$command exited non-zero on a bad readout"
  [[ "$out" == *"broken: unreadable"* && "$out" == *"nodate: unreadable"* ]] || fail "$command did not name unreadable files: $out"
done
ok "an unparseable file or one without written_at is named unreadable and never fails the reader"
rm "$dir/broken.json" "$dir/nodate.json"

printf 'not a readout' > "$dir/owed.ledger"
printf '{"strip": "ghost"}' > "$dir/notes.txt"
out="$(rd strip "$target" s1)$(rd note "$target" s1)$(rd show --repo "$target" --session s1)"
[[ "$out" != *"ledger"* && "$out" != *"ghost"* && "$out" != *"notes"* ]] || fail "a non-JSON file was read: $out"
ok "a file that is not *.json is ignored"
rm "$dir/owed.ledger" "$dir/notes.txt"

aged progress--s3.json 200 s3 "ancient" ""
aged owed-old.json 200 "" "ancient repo" ""
rd prune "$target"
[[ ! -e "$dir/progress--s3.json" ]] || fail "prune kept an old session readout"
[[ -f "$dir/owed-old.json" && -f "$dir/progress--s1.json" && -f "$dir/owed.json" ]] || fail "prune removed a repository-wide or recent readout"
ok "prune removes only session readouts older than 7 days"

if rd write Bad_Name --repo "$target" 2>/dev/null; then fail "a bad name was accepted"; fi
if rd write a--b --repo "$target" 2>/dev/null; then fail "a name with a double hyphen was accepted"; fi
if rd write a- --repo "$target" 2>/dev/null; then fail "a name with a trailing hyphen was accepted"; fi
[[ ! -e "$dir/a--b.json" ]] || fail "a refused name left a file"
if rd bogus 2>/dev/null; then fail "an unknown command was accepted"; fi
[[ ! -e "$dir/Bad_Name.json" ]] || fail "a refused name left a file"
ok "a bad name (uppercase, double or trailing hyphen) or an unknown command is refused"

# stale_after: a readout is current for that many seconds, then shows its age.
rd write quick --repo "$target" --strip "tick" --stale-after 60
aged quick.json 0.0834 "" "tick" "" 60
[[ "$(rd strip "$target" s1)" == *"tick (5m old)"* ]] || fail "stale_after 60 at 5 minutes: $(rd strip "$target" s1)"
aged quick.json 0.0834 "" "tick" "" 600
[[ "$(rd strip "$target" s1)" != *"tick ("* ]] || fail "a readout inside its stale_after carried an age"
aged quick.json 50 "" "tick" "" 3600
[[ "$(rd strip "$target" s1)" == *"tick (2d old)"* ]] || fail "48 hours is not shown in days"
rm "$dir/quick.json"
ok "a readout shows its age in minutes, hours or days once past its own stale_after"

# Control characters: a strip segment is one line of plain text; a note keeps
# its newlines and is cut at 12 lines.
python3 "$reader" write ctl --repo "$target" --strip $'one\ntwo\x1b[31mred'
[[ "$(rd strip "$target" s1 | wc -l | tr -d ' ')" == 1 ]] || fail "a newline in a strip segment made a second line"
[[ "$(rd strip "$target" s1)" != *$'\x1b'* ]] || fail "an escape character reached the strip"
python3 "$reader" write ctl --repo "$target" --note "$(printf 'l%s\n' $(seq 15))"$'\x1b[31m'
out="$(rd note "$target" s1)"
[[ "$out" != *$'\x1b'* ]] || fail "an escape character reached the note"
[[ "$(printf '%s\n' "$out" | grep -c '^ctl\|^l[0-9]')" == 12 && "$out" == *"… 3 more lines: python3 .agents/hooks/lib/readout.py show --session s1"* ]] || fail "note not cut at 12 lines: $out"
[[ "$(rd note "$target" "")" == *"… 3 more lines: python3 .agents/hooks/lib/readout.py show --all"* ]] || fail "a note with no session names the wrong command"
[[ "$(rd show --repo "$target" --session s1)" == *"l15"* ]] || fail "show cut the note"
rm "$dir/ctl.json"
ok "control characters become spaces; a note keeps newlines and is cut at 12 lines"

# One session-id form on write and on read.
rd write dotted --repo "$target" --session "a.b" --strip "dotted" --note "dotted note"
[[ -f "$dir/dotted--ab.json" ]] || fail "the session id was not sanitized in the file name: $(ls "$dir")"
[[ "$(rd strip "$target" "a.b")" == *dotted* && "$(rd strip "$target" ab)" == *dotted* ]] || fail "a raw id is not visible to itself"
[[ "$(rd strip "$target" other)" != *dotted* ]] || fail "a sanitized readout is visible to another session"
rm "$dir/dotted--ab.json"
ok "a session id with a dot is written sanitized and visible to the same raw id"

# Prune also clears stray temp files and abandoned ledgers.
touch "$dir/.write-old.tmp" "$dir/.write-new.tmp" "$dir/ledger-old.log" "$dir/ledger-new.log"
touch -t 202001010000 "$dir/ledger-old.log"
python3 -c 'import os,time,sys; t=time.time()-7200; os.utime(sys.argv[1],(t,t))' "$dir/.write-old.tmp"
rd prune "$target"
[[ ! -e "$dir/.write-old.tmp" && ! -e "$dir/ledger-old.log" ]] || fail "prune kept an old temp or ledger file"
[[ -e "$dir/.write-new.tmp" && -e "$dir/ledger-new.log" ]] || fail "prune removed a fresh temp or ledger file"
rm "$dir/.write-new.tmp" "$dir/ledger-new.log"
touch "$dir/unit.lock"
touch -t 202001010000 "$dir/unit.lock"
rd prune "$target"
[[ -e "$dir/unit.lock" ]] || fail "prune removed a lock file"
rm "$dir/unit.lock"
ok "prune removes temp files over an hour old and other files over 7 days old, never a lock file"

# Death segments: the strip names a lane whose claimant, or a cell whose agent, the death
# reader's cache judged failed, lost or parked. Seam: readout.py strip over a workloop state and
# a cache written by hand. Catches the join between state and cache, dismissals and a bad cache;
# misses whether the reader writes that cache shape (test-agent-deaths.sh).
deaths="$scratch/deaths"
mkdir -p "$deaths/.agents/.readout"
cat > "$deaths/.agents/.workloop-state.json" <<'JSON'
{"runs": {"r1": {"lanes": {"l1": {"state": "active", "claimed_by": "aaa"},
                            "l2": {"state": "active", "claimed_by": "ccc"},
                            "l3": {"state": "submitted", "claimed_by": "ddd"}},
                 "cells": {"c1": {"state": "out", "agent_id": "bbb"},
                           "c2": {"state": "out", "agent_id": "aaa", "out_since": "2026-11-13T00:00:00Z"}}},
          "old": {"torn_down": true, "lanes": {"l9": {"state": "active", "claimed_by": "aaa"}}}}}
JSON
cache="$deaths/.agents/.readout/.agent-deaths-cache"
printf '%s' '{"judged": {"aaa": ["failed", "connection_failed", 1000.0, ""], "bbb": ["parked", "", 1000.0, "j1"], "ddd": ["lost", "stall", 1000.0, ""]}}' > "$cache"
out="$(rd strip "$deaths" s1)"
[[ "$out" == "r1/l1 died connection_failed  ·  r1/c1 parked" ]] || fail "death segments: $out"
ok "strip names a dead lane claimant and a parked cell agent, not a live claimant, a submitted lane, a torn-down run, or a cell sent out again after its agent's death"
printf '%s\t%s\t%s\t%s\n' 2026-11-13T00:00:00Z aaa 1000.0 why > "$deaths/.agents/.agents-dismissed"
out="$(rd strip "$deaths" s1)"
[[ "$out" == "r1/c1 parked" ]] || fail "a dismissed death still shows: $out"
ok "a dismissed death leaves the strip"
rm "$deaths/.agents/.agents-dismissed"
printf '%s' '{not json' > "$cache"
[[ "$(rd strip "$deaths" s1)" == "deaths: unreadable" ]] || fail "a corrupt cache did not show unreadable: $(rd strip "$deaths" s1)"
printf '%s' '{"judged": {"aaa": ["failed"]}}' > "$cache"
[[ "$(rd strip "$deaths" s1)" == "deaths: unreadable" ]] || fail "a reshaped cache did not show unreadable: $(rd strip "$deaths" s1)"
rm "$cache"
[[ -z "$(rd strip "$deaths" s1)" ]] || fail "a missing cache showed something"
ok "a missing cache shows nothing; a corrupt or reshaped one shows deaths: unreadable"

# show defaults to the script's own repository.
fake="$scratch/fake"
mkdir -p "$fake/.agents/hooks/lib"
cp "$reader" "$fake/.agents/hooks/lib/"
python3 "$fake/.agents/hooks/lib/readout.py" write here --strip "mine"
[[ "$(python3 "$fake/.agents/hooks/lib/readout.py" show)" == *"here"* && -f "$fake/.agents/.readout/here.json" ]] || fail "show and write did not default to the script's repository"
ok "show and write default to the repository that holds the script"

empty="$scratch/empty"
mkdir -p "$empty"
[[ -z "$(rd strip "$empty" s1)$(rd note "$empty" s1)$(rd show --repo "$empty" --session s1)" ]] || fail "a missing folder printed something"
ok "a repository with no readout folder prints nothing"

printf 'PASS: readout reader\n'
