#!/usr/bin/env bash
# Engine-agnostic policy: end-of-session wrap-up, gated by magnitude ESCALATION.
#
# Input  (stdin JSON): {"project_dir": "...", "stop_hook_active": bool,
#                        "transcript_path": "...", "session_id": "..."}
# session_id is the session identity, with the transcript path as fallback. The
# transcript also serves as the exchange counter, so the no-diff investigation
# branch needs one and stays engine-limited; the magnitude measures do not.
# Output: exit 2 + stderr on escalation; exit 0 otherwise.
#
# The checklist prose lives in .agents/playbooks/*.md — this script owns only
# the gate. It emits a short trigger naming the sections and their files; the
# model reads a file only if the user opts into the wrap. A skipped wrap
# therefore costs the model nothing, where an inline checklist costs it the
# whole wall whether or not it is used.
#
# THE GATE: fire on tier ESCALATION, not on every turn in a tier.
#   none -> trivial -> diff -> large
# A session that reaches `diff` fires once; it does not re-fire on the next turn
# still sitting at `diff`. Reaching `large` fires again. Committing drops the
# tier back to `none` and re-arms the ladder, so atomic commits give one wrap per
# unit of work rather than one per turn. State lives in
# .agents/.wrap-state-<hash of session identity> — one file per session, so a
# new session starts the ladder fresh and concurrent sessions never clobber.
#
# TWO MEASURES, because the tier reads the UNCOMMITTED tree. An agent that edits
# and commits inside one turn leaves a clean tree at Stop, so its tier is `none`
# every turn: the diff ladder never leaves the floor, and the work falls to the
# no-diff branch that reports a research session. The second measure is the work
# that LANDED — commits made since the last one reported — on the same thresholds.
# Discipline about committing inside the turn now earns the wrap instead of hiding
# it. It is not a ladder: reporting a range consumes it, so unit two of a session
# earns the same wrap unit one did.
#
# .agents/hooks/policy/session-start.sh seeds the baseline at session start,
# before turn 1 runs. Without it the baseline lands a turn late (see below).
#
# Why escalation and not every turn: firing every turn makes each turn cost two
# assistant messages and forces the model to triage a wall it will mostly ignore.
# It is also self-defeating — Claude Code overrides a Stop hook after it blocks
# eight times in a row without progress (code.claude.com/docs/en/hooks-guide), so
# a hook that always blocks trains its own ceiling and then stops being heard.
# The reference community hook (disler/claude-code-hooks-mastery stop.py) never
# blocks at all. Set hooks.session_wrap.report_every_turn=true to opt into a
# report on every turn regardless of escalation.
#
# Tunable via .agents/config.json (env vars still override):
#   trivial_files (2), trivial_lines (30)   -> the trivial floor
#   review_files (5),  review_lines (150)   -> the `large` threshold
#   heavy_tool_calls (60)                   -> no-diff session worth reporting
#
# ATTRIBUTION. Several sessions can share one working tree, and each wrap must
# measure its own work. edit-record.sh records, per session, the paths its
# editor tools wrote (.agents/.wrap-edits-<key>) and the commits it made
# (.agents/.wrap-commits-<key>), keyed like the state file below.
#   - Uncommitted: a changed file counts when this session's edits file names
#     it, or when no other session's edits file does, or when that claim is
#     older than the path's last commit. The unclaimed rule keeps what a shell
#     command wrote; a session with no edits file measures every file no other
#     session claims.
#   - Committed: a commit counts when this session recorded it, or when no
#     session did and it is not on a remote-tracking branch. With no record
#     anywhere (a host without the recorder) the whole range counts, as it
#     always did: a safety wrap fails toward review.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="$repo/.agents/hooks/lib"
cfg_path="$repo/.agents/config.json"
wrap_dir=".agents/playbooks"

# learning_report is the one OPT-IN toggle: its `false` default leaves pairing
# mode off unless the config says exactly `true`.
cfg="$(python3 "$lib/config.py" "$cfg_path" \
  hooks.session_wrap.enabled=true \
  hooks.session_wrap.trivial_files=2 \
  hooks.session_wrap.trivial_lines=30 \
  hooks.session_wrap.review_files=5 \
  hooks.session_wrap.review_lines=150 \
  hooks.session_wrap.heavy_tool_calls=60 \
  hooks.session_wrap.report_every_turn=false \
  hooks.learning_report.enabled=false)"
enabled="$(printf '%s\n' "$cfg" | sed -n '1p')"
[[ "$enabled" == "no" ]] && exit 0
cfg_trivial_files="$(printf '%s\n' "$cfg" | sed -n '2p')"
cfg_trivial_lines="$(printf '%s\n' "$cfg" | sed -n '3p')"
cfg_review_files="$(printf '%s\n' "$cfg" | sed -n '4p')"
cfg_review_lines="$(printf '%s\n' "$cfg" | sed -n '5p')"
cfg_heavy_calls="$(printf '%s\n' "$cfg" | sed -n '6p')"
report_every_turn="$(printf '%s\n' "$cfg" | sed -n '7p')"
learning_enabled="$(printf '%s\n' "$cfg" | sed -n '8p')"

parsed="$(python3 "$lib/payload.py" stop_hook_active=false project_dir transcript_path session_id)"
stop_active="$(printf '%s\n' "$parsed" | sed -n '1p')"
proj="$(printf '%s\n' "$parsed" | sed -n '2p')"
transcript="$(printf '%s\n' "$parsed" | sed -n '3p')"
session_id="$(printf '%s\n' "$parsed" | sed -n '4p')"

[[ "$stop_active" == "yes" ]] && exit 0
[[ -z "$proj" ]] && proj="$PWD"
cd "$proj"

TRIVIAL_FILES="${WRAP_TRIVIAL_FILES:-$cfg_trivial_files}"
TRIVIAL_LINES="${WRAP_TRIVIAL_LINES:-$cfg_trivial_lines}"
REVIEW_FILES="${WRAP_REVIEW_FILES:-$cfg_review_files}"
REVIEW_LINES="${WRAP_REVIEW_LINES:-$cfg_review_lines}"
HEAVY="${WRAP_HEAVY_TOOL_CALLS:-$cfg_heavy_calls}"

# The kit's own transient state is not session work — exclude by name (precise,
# so a real file that merely sits in .agents/ is never hidden). Generated
# learning reports are tooling output, not the user's diff.
ledgers='sources-ledger|compaction-pending'
# colloid-only
ledgers="genome-ledger|mutagen-ledger|$ledgers"
# /colloid-only
markers='(\.agents/\.('"$ledgers"')$|\.agents/\.wrap-(state|edits|commits|head)-|^docs/learning/)'

# Session identity: session_id, falling back to the transcript path (the state
# file's comment below says why an absent identity writes nothing).
ident="${session_id:-$transcript}"
key=""
[[ -n "$ident" ]] && key="$(printf '%s' "$ident" | cksum | tr -d ' ')"
others_edits=()
others_commits=()
own_edits=""
own_commits=""
for f in "$proj"/.agents/.wrap-edits-* "$proj"/.agents/.wrap-commits-*; do
  [[ -f "$f" ]] || continue
  case "${f##*/}" in
    ".wrap-edits-$key") own_edits="$f" ;;
    ".wrap-commits-$key") own_commits="$f" ;;
    .wrap-edits-*) others_edits+=("$f") ;;
    *) others_commits+=("$f") ;;
  esac
done
# The committed ladder narrows to attributed commits once any session keeps a
# record; with none anywhere (a host without the recorder) it measures the
# whole range as it always did.
recorded="no"
[[ -n "$own_edits" || -n "$own_commits" || ${#others_commits[@]} -gt 0 ]] && recorded="yes"

# What no session claims is attributed to whoever stops: a shell command's
# write reaches no recorder, and neither does a commit made where no recorder
# ran — debt: colloid-wrap-concurrent-attribution
#
# The measures, in one interpreter. `uncommitted` prints the file count, the
# changed lines (empty when there is no commit to diff against), "1" when a
# binary changed, then the attributed files. `commits <base>` prints the
# commits in <base>..HEAD this session is answerable for.
measure="$(cat <<'PY'
import os
import re
import subprocess
import sys

mode, markers, own_edits, own_commits = sys.argv[1:5]
rest = sys.argv[5:]


def git(*args):
    result = subprocess.run(["git", "--literal-pathspecs", *args], capture_output=True)
    return result.stdout.decode("utf-8", "surrogateescape") if result.returncode == 0 else ""


def read(path):
    try:
        with open(path, encoding="utf-8") as source:
            return source.read().splitlines()
    except (FileNotFoundError, IsADirectoryError):
        return []


if mode == "commits":
    base, others = rest[0], rest[1:]
    mine = set(read(own_commits)) if own_commits else set()
    claimed = {line for path in others for line in read(path)}
    in_range = git("rev-list", "--reverse", "--no-merges", f"{base}..HEAD").split()
    # Unclaimed commits count for whoever stops, except what a pull brought in.
    local = set(git("rev-list", "--no-merges", f"{base}..HEAD", "--not", "--remotes").split())
    for commit in in_range:
        if commit in mine or (commit not in claimed and commit in local):
            print(commit)
    sys.exit(0)

# uncommitted
pattern = re.compile(markers)
tokens = git("status", "--porcelain=v1", "-z", "--untracked-files=all").split("\0")
changed, untracked, old_names = [], set(), {}
index = 0
while index < len(tokens):
    entry = tokens[index]
    index += 1
    if len(entry) < 4:
        continue
    code, path = entry[:2], entry[3:]
    if "R" in code or "C" in code:          # `-z` gives the destination, then the source
        old_names[path] = tokens[index]
        index += 1
    if pattern.search(path):
        continue
    changed.append(path)
    if code == "??":
        untracked.add(path)

own = {line.partition("\t")[2] for line in read(own_edits)} if own_edits else set()
claims = {}
for path in rest:
    for line in read(path):
        stamp, _, name = line.partition("\t")
        if stamp.isdigit():
            claims[name] = max(claims.get(name, 0), int(stamp))
counted = []
for path in changed:
    if path in own or path not in claims:
        counted.append(path)
        continue
    # A peer's claim stands until the path's next commit; an edit after that
    # commit is new work no recorder saw.
    last = git("log", "-1", "--format=%ct", "--", path).strip()
    if last.isdigit() and claims[path] <= int(last):
        counted.append(path)

lines, binary = "", ""
if counted and git("rev-parse", "-q", "--verify", "HEAD"):
    total = 0
    tracked = [p for p in counted if p not in untracked]
    if tracked:
        spec = tracked + [old_names[p] for p in tracked if p in old_names]
        fields = git("diff", "HEAD", "-M", "--numstat", "-z", "--", *spec).split("\0")
        position = 0
        while position < len(fields):
            head = fields[position]
            position += 1
            parts = head.split("\t")
            if len(parts) != 3:
                continue
            added, deleted, name = parts
            if not name:                     # a rename: source, then destination
                name = fields[position + 1] if position + 1 < len(fields) else ""
                position += 2
            if name not in counted:
                continue
            if added == "-" and deleted == "-":
                binary = "1"
            elif added.isdigit() and deleted.isdigit():
                total += int(added) + int(deleted)
    for path in counted:
        if path in untracked and os.path.isfile(path):
            with open(path, "rb") as source:
                total += source.read().count(b"\n")
    lines = str(total)
print(len(counted))
print(lines)
print(binary)
for path in counted:
    print(path)
PY
)"

count=0
lines=""
binary=""
changed=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  measured="$(python3 -c "$measure" uncommitted "$markers" "$own_edits" "$own_commits" \
    ${others_edits[@]+"${others_edits[@]}"})" || measured=""
  count="$(printf '%s\n' "$measured" | sed -n '1p')"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  lines="$(printf '%s\n' "$measured" | sed -n '2p')"
  binary="$(printf '%s\n' "$measured" | sed -n '3p')"
  changed="$(printf '%s\n' "$measured" | sed -n '4,$p')"
fi

# ───────────────────────────── classify the tier ─────────────────────────────
# A binary change, or churn we cannot measure (no commit yet), is never trivial:
# a safety wrap fails toward more review. Shared by both ladders — the committed
# one must not drift onto its own thresholds.
classify() {                       # files, lines ("" = unmeasurable), binary flag
  local n_files="$1" n_lines="$2" is_binary="$3" tier="diff"
  (( n_files == 0 )) && { echo none; return; }
  if [[ -z "$is_binary" && -n "$n_lines" ]] && (( n_files <= TRIVIAL_FILES && n_lines <= TRIVIAL_LINES )); then
    tier="trivial"
  elif [[ -z "$n_lines" ]] || (( n_files >= REVIEW_FILES || n_lines >= REVIEW_LINES )); then
    tier="large"
  fi
  echo "$tier"
}


tier="$(classify "$count" "$lines" "$binary")"

rank() { case "$1" in none) echo 0;; trivial) echo 1;; diff) echo 2;; large) echo 3;; *) echo 0;; esac; }

# ────────────────────────── escalation gate (the throttle) ──────────────────────────
# State file, one per session — the transcript path is hashed into the NAME, not
# compared inside a shared file. Two Claude sessions in one repo would otherwise
# share `.wrap-state`, each read the other's identity, reset the ladder, and fire
# every turn — the exact behavior this gate exists to prevent.
#   line 1  highest tier already fired (the diff ladder)
#   line 2  "1" once the no-diff investigation report has fired this session
#   line 3  commit count at the last write — a rise means a commit landed
#   line 4  the commit the committed ladder measures FROM: session start, then the
#           last commit whose work was reported. Everything after it is unreported.
#   line 5  "1" once the committed ladder has fired this session
# Each branch carries its own throttle. The diff ladder cannot throttle the other
# two — `none` never out-ranks a fresh `none` — and the committed ladder is not a
# ladder of tiers at all: reporting a range CONSUMES it by advancing line 4, so the
# next unit measures from zero again and earns its own wrap. A rung that only
# climbs would fire on the session's first unit and stay latched for every one
# after it, which is the throttle swallowing the work rather than pacing it.
#
# The commit count is tracked because a tier drop is not the only way work
# completes: a turn that commits AND opens the next unit never dips to `none`, so
# the ladder would stay latched and swallow the next wrap. The count catches the
# commit the tier never shows. It is a COUNT and not a sha because a sha merely
# *moves* on `--amend`, `rebase`, or `checkout` — none of which close a unit of
# work — and would re-fire the wrap on an unchanged tree. Line 4 holds a sha for
# the other job, MEASURING: the two are not interchangeable. A count cannot name
# a diff range, and a sha cannot answer "did a commit land".
#
# Session identity: session_id, falling back to the transcript path. Neither
# present = no identity = no throttle: read and write nothing, and let every diff
# escalation fire. Keying a shared file on an empty identity would make one
# repo-wide ladder that every future session inherits, silently suppressing wraps
# forever. A safety wrap fails toward review. The other two branches need a
# remembered baseline to mean anything, so they are silent without identity.
state=""
if [[ -n "$key" ]]; then
  state="$proj/.agents/.wrap-state-$key"
fi

# Empty in a repo with no commits — which correctly makes the count signal inert
# rather than writing a bogus marker.
commits="$(git rev-list --count HEAD 2>/dev/null || true)"
[[ "$commits" =~ ^[0-9]+$ ]] || commits=""

fired="none"
investigated=""
prev_commits=""
unreported=""
implemented=""
if [[ -n "$state" && -f "$state" ]]; then
  fired="$(sed -n '1p' "$state" 2>/dev/null || true)"
  investigated="$(sed -n '2p' "$state" 2>/dev/null || true)"
  prev_commits="$(sed -n '3p' "$state" 2>/dev/null || true)"
  unreported="$(sed -n '4p' "$state" 2>/dev/null || true)"
  implemented="$(sed -n '5p' "$state" 2>/dev/null || true)"
fi
case "$fired" in none|trivial|diff|large) ;; *) fired="none";; esac
[[ "$investigated" == "1" ]] || investigated=""
[[ "$implemented" == "1" ]] || implemented=""
[[ "$prev_commits" =~ ^[0-9]+$ ]] || prev_commits=""
# Width, not 40: a sha-256 repository writes 64 hex characters, and a baseline
# rejected as malformed is re-seeded to HEAD every turn — which silently empties
# the range and disables the committed branch for the whole session.
[[ "$unreported" =~ ^[0-9a-f]{7,64}$ ]] || unreported=""

head_sha="$(git rev-parse -q --verify HEAD 2>/dev/null || true)"

# The baseline is normally seeded by session-start.sh, before turn 1 runs. Without
# it — another engine, session_start disabled, a session_id that changed under us —
# the first Stop seeds it instead, and that write lands AFTER turn 1 already
# committed. On that one invocation "did this session build anything?" is
# unanswerable, so the two branches that depend on the answer stay silent rather
# than guess: a late wrap costs a turn, where a session labelled "research"
# because it committed its implementation is the defect this exists to remove.
baseline_known="yes"
if [[ -z "$unreported" ]]; then
  [[ -n "$head_sha" ]] && baseline_known="no"
  unreported="$head_sha"
fi

# Re-arm the ladder when the unit of work closed. Two independent signals:
#   - the tier dropped (work committed away, or reverted)
#   - the commit count ROSE (a commit landed even though the tier never dipped)
if (( $(rank "$tier") < $(rank "$fired") )); then
  fired="none"
elif [[ -n "$prev_commits" && -n "$commits" ]] && (( commits > prev_commits )); then
  fired="none"
fi

escalated="no"
(( $(rank "$tier") > $(rank "$fired") )) && escalated="yes"

# ────────────────── the committed branch: work that already landed ──────────────────
# The range is `unreported..HEAD` — everything committed since the last report, not
# the whole session. Reporting it advances the base, so the next unit measures from
# zero. Committed work below the threshold is NOT dropped: the base does not
# advance, so a run of small commits accumulates until it crosses.
#
# Two shapes of history motion are refused rather than measured, because neither is
# this session's work closing a unit — and the emitted text tells the agent to
# review "the files this session touched":
#   - HEAD does not descend from the base (checkout, reset, a rebase onto another
#     base). The range would be someone else's branch.
#   - a merge landed in the range (merge, pull). The range would be whatever the
#     other side wrote.
# Both re-base the range on HEAD and stay silent for the turn.
#
# Once any session keeps a record, the range narrows to the commits this
# session recorded plus those no session recorded (except what is already on a
# remote-tracking branch): a peer's commit is not its work, a workloop wave it
# integrated is, and a commit nobody saw fails toward review. Merges are not
# measured and the merge refusal above does not apply; each counted commit is
# measured against its parent, so a file two commits touch is counted once and
# its lines twice.
#
# What it cannot see: a repository with no commits when the session began (the
# dirty-tree branch already covers everything up to the first commit, and this
# branch starts measuring from it).
landed_count=0
landed_lines=""
landed_binary=""
landed_changed=""
landed_commits=""
if [[ -n "$unreported" && -n "$head_sha" && "$unreported" != "$head_sha" && "$recorded" == "yes" ]]; then
  if git merge-base --is-ancestor "$unreported" HEAD 2>/dev/null; then
    own_range="$(python3 -c "$measure" commits "$markers" "" "$own_commits" "$unreported" \
      ${others_commits[@]+"${others_commits[@]}"} || true)"
    if [[ -n "$own_range" ]]; then
      landed_commits="$(printf '%s\n' "$own_range" | wc -l | tr -d ' ')"
      numstat="$(printf '%s\n' "$own_range" \
        | git diff-tree --stdin --no-commit-id --root -r --numstat 2>/dev/null || true)"
      landed_changed="$(printf '%s\n' "$own_range" \
        | git diff-tree --stdin --no-commit-id --root -r --name-only 2>/dev/null \
        | sort -u | grep -v '^$' | grep -Ev "$markers" || true)"
      if [[ -n "$landed_changed" ]]; then
        landed_count="$(printf '%s\n' "$landed_changed" | wc -l | tr -d ' ')"
        landed_binary="$(printf '%s\n' "$numstat" \
          | MARKERS="$markers" awk 'BEGIN { m = ENVIRON["MARKERS"] }
              $3 !~ m && $NF !~ m && $1 == "-" && $2 == "-" { b = 1 }
              END { if (b) print 1 }' || true)"
        landed_lines="$(printf '%s\n' "$numstat" \
          | MARKERS="$markers" awk 'BEGIN { m = ENVIRON["MARKERS"] }
              $3 !~ m && $NF !~ m && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { s += $1 + $2 }
              END { print s + 0 }' || true)"
      fi
    fi
  else
    unreported="$head_sha"
  fi
elif [[ -n "$unreported" && -n "$head_sha" && "$unreported" != "$head_sha" ]]; then
  if git merge-base --is-ancestor "$unreported" HEAD 2>/dev/null \
     && [[ -z "$(git rev-list --merges --max-count=1 "$unreported..HEAD" 2>/dev/null)" ]]; then
    landed_changed="$(git diff --name-only "$unreported" HEAD 2>/dev/null \
      | grep -Ev "$markers" || true)"
    if [[ -n "$landed_changed" ]]; then
      landed_count="$(printf '%s\n' "$landed_changed" | wc -l | tr -d ' ')"
      # numstat is `added <TAB> deleted <TAB> path`, except a rename, which prints
      # `old => new` and so splits into $3..$5 — hence both ends are tested. ENVIRON
      # keeps the marker regex literal, where -v would eat its backslashes and turn
      # `\.` into "any character".
      landed_binary="$(git diff --numstat "$unreported" HEAD 2>/dev/null \
        | MARKERS="$markers" awk 'BEGIN { m = ENVIRON["MARKERS"] }
            $3 !~ m && $NF !~ m && $1 == "-" && $2 == "-" { b = 1 }
            END { if (b) print 1 }' || true)"
      landed_lines="$(git diff --numstat "$unreported" HEAD 2>/dev/null \
        | MARKERS="$markers" awk 'BEGIN { m = ENVIRON["MARKERS"] }
            $3 !~ m && $NF !~ m && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { s += $1 + $2 }
            END { print s + 0 }' || true)"
    fi
  else
    unreported="$head_sha"
  fi
fi
landed_tier="$(classify "$landed_count" "$landed_lines" "$landed_binary")"

# Persist unconditionally, at every invocation — NOT only when emitting. A commit
# turn emits nothing; if the re-armed `fired` were written only from an emit
# branch, the re-arm would live in memory and die there, and the next unit of work
# reaching the same tier would be silently swallowed.
#
# Returns non-zero when the write did not land. The caller stays SILENT on that
# path: with a state file it cannot write (a read-only checkout, a root-owned
# .agents/ from a container run), every turn re-reads the same absent state and
# re-fires the same wall — a throttle that cannot remember is a spammer, and eight
# such blocks in a row make the engine drop the hook for the rest of the session.
record_state() {                   # fired, investigated, implemented
  [[ -z "$state" ]] && return 0
  mkdir -p "$proj/.agents" 2>/dev/null || true
  { printf '%s\n%s\n%s\n%s\n%s\n' \
      "$1" "$2" "$commits" "$unreported" "$3" > "$state"; } 2>/dev/null || return 1
  # Reap state from long-dead sessions; today's file was just written, so a
  # week-old mtime can only mean an abandoned session.
  find "$proj/.agents" -maxdepth 1 \( -name '.wrap-state-*' -o -name '.wrap-edits-*' -o -name '.wrap-commits-*' -o -name '.wrap-head-*' \) \
    -mtime +7 -delete 2>/dev/null || true
}

# ───────────────────────────── build the sections ─────────────────────────────
sections=""
add() { sections="${sections}${1}"$'\n'; }

# What to persist this turn. Defaults to the re-armed ladder so a commit turn —
# which emits nothing — still writes the reset.
next_fired="$fired"
next_investigated="$investigated"
next_implemented="$implemented"

# A CLOSED unit outranks work in flight, so the committed branch is tested first.
# Ordered the other way, one stray untracked file above the trivial floor holds the
# tier at `diff` for the whole session — the commit-count re-arm re-fires the same
# stale wall every commit turn, and the units that actually landed are never named.
if [[ "$landed_tier" == "diff" || "$landed_tier" == "large" ]]; then
  [[ -n "$landed_commits" ]] || landed_commits="$(git rev-list --count "$unreported..HEAD" 2>/dev/null || true)"
  size="${landed_commits:-?} commit(s), $landed_count file(s)"
  [[ -n "$landed_lines" ]] && size="$size, ~$landed_lines changed lines"
  [[ -n "$landed_binary" ]] && size="$size, binary"
  shown="$(printf '%s\n' "$landed_changed" | sed -n '1,20{s/^/  - /;p;}')"
  (( landed_count > 20 )) && shown="$shown"$'\n'"  - … $((landed_count - 20)) more"

  add "Committed and unwrapped ($size):"
  add "$shown"
  add ""
  add "This crossed the '$landed_tier' threshold. Ask the user: full session wrap, or skip? Use a question tool where the host has one, otherwise ask in the reply."
  add "Honor the answer; if they skip, stop here."
  add "If they want it, read the file for each section below and work it against the files listed above; do not sweep files you did not edit."
  add "Its findings land as a follow-up commit."
  [[ -n "$changed" ]] && \
  add "$count more file(s) are still uncommitted and are not in that list."
  add ""
  add "  - Clean-up + behavior impact  -> $wrap_dir/diff-wrap.md"
  [[ "$landed_tier" == "large" ]] && \
  add "  - Hostile review (cell)       -> $wrap_dir/hostile-review.md"
  add "  - Session report              -> $wrap_dir/report-implementation.md"
  [[ "$learning_enabled" == "yes" ]] && \
  add "  - Pairing: learning report    -> $wrap_dir/learning-report.md  (not governed by the skip)"
  unreported="$head_sha"          # consumed: the next unit measures from here
  next_implemented="1"
elif [[ "$tier" == "diff" || "$tier" == "large" ]]; then
  if [[ "$escalated" == "yes" || "$report_every_turn" == "yes" ]]; then
    size="$count file(s)"
    [[ -n "$lines" ]] && size="$size, ~$lines changed lines"
    [[ -n "$binary" ]] && size="$size, binary"
    shown="$(printf '%s\n' "$changed" | sed -n '1,20{s/^/  - /;p;}')"
    (( count > 20 )) && shown="$shown"$'\n'"  - … $((count - 20)) more"

    add "Uncommitted changes this session ($size):"
    add "$shown"
    add ""
    add "This crossed the '$tier' threshold. Ask the user: full session wrap, or skip? Use a question tool where the host has one, otherwise ask in the reply."
    add "Honor the answer; if they skip, stop here."
    add "If they want it, read the file for each section below and work it against the files this session touched; do not sweep files you did not edit."
    add ""
    add "  - Clean-up + behavior impact  -> $wrap_dir/diff-wrap.md"
    [[ "$tier" == "large" ]] && \
    add "  - Hostile review (cell)       -> $wrap_dir/hostile-review.md"
    add "  - Session report + commit msg -> $wrap_dir/report-implementation.md"
    [[ "$learning_enabled" == "yes" ]] && \
    add "  - Pairing: learning report    -> $wrap_dir/learning-report.md  (not governed by the skip)"
  fi
  next_fired="$tier"
  # Work of this size, committed or not, means the session BUILT something. Without
  # this the investigation report reappears the moment the tree goes clean by any
  # route other than a commit — a stash, a revert — and calls it research.
  next_implemented="1"
else
  # ──────────── no diff (or trivial): capture a long investigation ────────────
  # Length is the agent's tool calls, not transcript lines: a transcript also
  # carries titles, mode changes and attachments, which roughly doubles a line
  # count. Claude records a call as a `tool_use` content block, Codex as a
  # `function_call` or `custom_tool_call` item. Throttled by the `investigated`
  # flag: once per session, not once per turn.
  #
  # `implemented` is the load-bearing guard: without it this branch reads a clean
  # tree as "nothing was built" and calls a heavily-committed implementation
  # session a research session. It asks whether the session BUILT something, not
  # whether it committed anything — a research session that fixes one typo along
  # the way is still a research session, and still needs its findings written down.
  events=""
  [[ -n "$transcript" && -f "$transcript" ]] && \
    events="$(python3 - "$transcript" <<'EOF' 2>/dev/null || true
import json, sys
calls = 0
for line in open(sys.argv[1], errors="replace"):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if not isinstance(event, dict):
        continue
    content = (event.get("message") or {}).get("content") if event.get("type") == "assistant" else None
    if isinstance(content, list):
        calls += sum(1 for block in content if isinstance(block, dict) and block.get("type") == "tool_use")
    payload = event.get("payload") if event.get("type") == "response_item" else None
    if isinstance(payload, dict) and payload.get("type") in ("function_call", "custom_tool_call"):
        calls += 1
print(calls)
EOF
)"

  if [[ -n "$events" ]] && (( events >= HEAVY )) \
     && [[ -z "$implemented" && "$baseline_known" == "yes" ]] \
     && { [[ -z "$investigated" ]] || [[ "$report_every_turn" == "yes" ]]; }; then
    add "A long session ($events tool calls) with no substantial diff — a debugging or research session whose findings die with the context window."
    add ""
    add "Ask the user whether they want a session report, with a question tool where the host has one and in the reply otherwise."
    add "If they want it: $wrap_dir/report-investigation.md"
    next_investigated="1"
  fi
fi

# The work log (hooks.worklog), when on: one line inside a wrap that already
# fires, never a block of its own, when today's file predates this session's
# newest recorded commit. session-start.sh owns the folder rules.
if [[ -n "$sections" && -n "$own_commits" ]]; then
  newest="$(tail -n 1 "$own_commits" 2>/dev/null || true)"
  committed_at="$(git log -1 --format=%ct "$newest" 2>/dev/null || true)"
  if [[ "$committed_at" =~ ^[0-9]+$ ]]; then
    worklog="$(python3 "$repo/.agents/hooks/lib/worklog.py" "$repo" || true)"
    day_file="$(printf '%s\n' "$worklog" | sed -n '2p')"
    if [[ "$(printf '%s\n' "$worklog" | sed -n '1p')" == "ok" ]] \
       && ! python3 -c 'import os, sys; sys.exit(0 if os.path.getmtime(sys.argv[1]) >= int(sys.argv[2]) else 1)' \
            "$day_file" "$committed_at" 2>/dev/null; then
      add "Work log: $day_file is older than this session's last commit; add its outcome entry (.agents/playbooks/worklog.md)."
    fi
  fi
fi

if ! record_state "$next_fired" "$next_investigated" "$next_implemented"; then
  sections=""
fi

# Both prompts end in a question to the user. `codex exec` has no one to answer
# it, so the turn would fail on a refused request_user_input after the work is
# done. The Stop payload carries no run mode; Codex records it on the
# transcript's first line as session_meta.payload.source. State was already
# recorded above, so a skipped wrap does not re-arm itself.
if [[ -n "$sections" && -n "$transcript" && -f "$transcript" ]]; then
  launch_source="$(head -n 1 "$transcript" | python3 -c '
import json, sys
try:
    meta = json.loads(sys.stdin.readline())
    print(meta["payload"]["source"] if meta.get("type") == "session_meta" else "")
except (ValueError, KeyError, TypeError):
    print("")
')"
  [[ "$launch_source" == "exec" ]] && sections=""
fi

[[ -z "$sections" ]] && exit 0
printf '%s' "$sections" >&2
exit 2
