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
aged() {  # <file name> <hours old> <session or ""> <strip> <note>
  python3 - "$dir/$1" "$2" "$3" "$4" "$5" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
path, hours, session, strip, note = sys.argv[1:]
record = {"strip": strip, "note": note,
          "written_at": (datetime.now(timezone.utc) - timedelta(hours=float(hours))).strftime("%Y-%m-%dT%H:%M:%SZ")}
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
assert set(r) == {"strip", "note", "written_at"} and r["strip"] == "2 owed" and r["written_at"].endswith("Z"), r
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

out="$(rd strip "$target" "")"
[[ "$out" == "2 owed" ]] || fail "an empty session must see only repository-wide readouts: $out"
ok "an empty session argument sees only repository-wide readouts"

out="$(rd note "$target" s1)"
[[ "$out" == *"owed: two replies owed"* && "$out" == *"progress: build running"* && "$out" != *"other build"* ]] || fail "note for s1: $out"
ok "note prints name and note of each visible readout"

out="$(rd show "$target" s1)"
[[ "$out" == *"build 3/9"* && "$out" != *"other build"* ]] || fail "show for s1: $out"
out="$(rd show "$target" s1 --all)"
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
for command in "strip" "note" "show"; do
  out="$(rd $command "$target" s1)" || fail "$command exited non-zero on a bad readout"
  [[ "$out" == *"broken: unreadable"* && "$out" == *"nodate: unreadable"* ]] || fail "$command did not name unreadable files: $out"
done
ok "an unparseable file or one without written_at is named unreadable and never fails the reader"
rm "$dir/broken.json" "$dir/nodate.json"

printf 'not a readout' > "$dir/owed.ledger"
printf '{"strip": "ghost"}' > "$dir/notes.txt"
out="$(rd strip "$target" s1)$(rd note "$target" s1)$(rd show "$target" s1)"
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
if rd write ok-name --session "bad/id" --repo "$target" 2>/dev/null; then fail "a bad session id was accepted"; fi
if rd bogus 2>/dev/null; then fail "an unknown command was accepted"; fi
[[ ! -e "$dir/Bad_Name.json" ]] || fail "a refused name left a file"
ok "a bad name, bad session id or unknown command is refused"

empty="$scratch/empty"
mkdir -p "$empty"
[[ -z "$(rd strip "$empty" s1)$(rd note "$empty" s1)$(rd show "$empty" s1)" ]] || fail "a missing folder printed something"
ok "a repository with no readout folder prints nothing"

printf 'PASS: readout reader\n'
