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
#   heavy_lines (200)                       -> no-diff session worth reporting

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
  hooks.session_wrap.heavy_lines=200 \
  hooks.session_wrap.report_every_turn=false \
  hooks.learning_report.enabled=false)"
enabled="$(printf '%s\n' "$cfg" | sed -n '1p')"
[[ "$enabled" == "no" ]] && exit 0
cfg_trivial_files="$(printf '%s\n' "$cfg" | sed -n '2p')"
cfg_trivial_lines="$(printf '%s\n' "$cfg" | sed -n '3p')"
cfg_review_files="$(printf '%s\n' "$cfg" | sed -n '4p')"
cfg_review_lines="$(printf '%s\n' "$cfg" | sed -n '5p')"
cfg_heavy_lines="$(printf '%s\n' "$cfg" | sed -n '6p')"
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
HEAVY="${WRAP_HEAVY_LINES:-$cfg_heavy_lines}"

# The kit's own transient state is not session work — exclude by name (precise,
# so a real file that merely sits in .agents/ is never hidden). Generated
# learning reports are tooling output, not the user's diff.
ledgers='sources-ledger|compaction-pending'
# colloid-only
ledgers="genome-ledger|mutagen-ledger|$ledgers"
# /colloid-only
markers='(\.agents/\.('"$ledgers"')$|\.agents/\.wrap-state-|^docs/learning/)'

changed=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  changed="$(git status --porcelain=v1 --untracked-files=all 2>/dev/null \
    | awk 'NF { sub(/^.. /, ""); print }' \
    | sed 's/^"//; s/"$//' \
    | grep -v '^$' \
    | grep -Ev "$markers" || true)"
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

count=0
lines=""
binary=""
if [[ -n "$changed" ]]; then
  count="$(printf '%s\n' "$changed" | wc -l | tr -d ' ')"
  if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    binary="$(git diff HEAD --numstat 2>/dev/null \
      | awk '$1 == "-" && $2 == "-" { b = 1 } END { if (b) print 1 }' || true)"
    tracked="$(git diff HEAD --numstat 2>/dev/null \
      | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { s += $1 + $2 } END { print s + 0 }' || true)"
    untracked="$(git ls-files --others --exclude-standard 2>/dev/null \
      | grep -Ev "$markers" \
      | while IFS= read -r f; do [[ -f "$f" ]] && wc -l <"$f" 2>/dev/null || true; done \
      | awk '{ s += $1 } END { print s + 0 }' || true)"
    lines=$(( ${tracked:-0} + ${untracked:-0} ))
  fi
fi

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
ident="${session_id:-$transcript}"
state=""
if [[ -n "$ident" ]]; then
  state="$proj/.agents/.wrap-state-$(printf '%s' "$ident" | cksum | tr -d ' ')"
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
# What it cannot see: a repository with no commits when the session began (the
# dirty-tree branch already covers everything up to the first commit, and this
# branch starts measuring from it), and which session authored a commit when two
# share one working tree — debt: colloid-wrap-concurrent-attribution
landed_count=0
landed_lines=""
landed_binary=""
landed_changed=""
if [[ -n "$unreported" && -n "$head_sha" && "$unreported" != "$head_sha" ]]; then
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
  find "$proj/.agents" -maxdepth 1 -name '.wrap-state-*' -mtime +7 -delete 2>/dev/null || true
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
  landed_commits="$(git rev-list --count "$unreported..HEAD" 2>/dev/null || true)"
  size="${landed_commits:-?} commit(s), $landed_count file(s)"
  [[ -n "$landed_lines" ]] && size="$size, ~$landed_lines changed lines"
  [[ -n "$landed_binary" ]] && size="$size, binary"
  shown="$(printf '%s\n' "$landed_changed" | sed -n '1,20{s/^/  - /;p;}')"
  (( landed_count > 20 )) && shown="$shown"$'\n'"  - … $((landed_count - 20)) more"

  add "Committed and unwrapped ($size):"
  add "$shown"
  add ""
  add "This crossed the '$landed_tier' threshold. Ask the user — full session wrap,"
  add "or skip? Use a question tool where the host has one, otherwise ask in the"
  add "reply. Honor the answer; if"
  add "they skip, stop here. If they want it, read the file for each section below"
  add "and work it against the files listed above — do not sweep files you did not"
  add "edit."
  add "Anything it turns up lands as a follow-up commit."
  [[ -n "$changed" ]] && \
  add "$count more file(s) are still uncommitted and are NOT in that list."
  add ""
  add "  - Clean-up + behavior impact  -> $wrap_dir/diff-wrap.md"
  [[ "$landed_tier" == "large" ]] && \
  add "  - Hostile review (subagent)   -> $wrap_dir/hostile-review.md"
  add "  - Session report              -> $wrap_dir/report-implementation.md"
  [[ "$learning_enabled" == "yes" ]] && \
  add "  - Pairing: learning report    -> $wrap_dir/learning-report.md  (NOT governed by the skip)"
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
    add "This crossed the '$tier' threshold. Ask the user — full session wrap, or skip?"
    add "Use a question tool where the host has one, otherwise ask in the reply."
    add "Honor the answer; if they skip,"
    add "stop here."
    add "If they want it, read the file for each section below and work it against"
    add "the files this session touched — do not sweep files you did not edit."
    add ""
    add "  - Clean-up + behavior impact  -> $wrap_dir/diff-wrap.md"
    [[ "$tier" == "large" ]] && \
    add "  - Hostile review (subagent)   -> $wrap_dir/hostile-review.md"
    add "  - Session report + commit msg -> $wrap_dir/report-implementation.md"
    [[ "$learning_enabled" == "yes" ]] && \
    add "  - Pairing: learning report    -> $wrap_dir/learning-report.md  (NOT governed by the skip)"
  fi
  next_fired="$tier"
  # Work of this size, committed or not, means the session BUILT something. Without
  # this the investigation report reappears the moment the tree goes clean by any
  # route other than a commit — a stash, a revert — and calls it research.
  next_implemented="1"
else
  # ──────────── no diff (or trivial): capture a long investigation ────────────
  # Length ≈ transcript line count (one line per exchange); schema-agnostic, so
  # any engine that hands us a transcript path works. Throttled by the
  # `investigated` flag: once per session, not once per turn.
  #
  # `implemented` is the load-bearing guard: without it this branch reads a clean
  # tree as "nothing was built" and calls a heavily-committed implementation
  # session a research session. It asks whether the session BUILT something, not
  # whether it committed anything — a research session that fixes one typo along
  # the way is still a research session, and still needs its findings written down.
  events=""
  [[ -n "$transcript" && -f "$transcript" ]] && \
    events="$(wc -l <"$transcript" 2>/dev/null | tr -d ' ' || true)"

  if [[ -n "$events" ]] && (( events >= HEAVY )) \
     && [[ -z "$implemented" && "$baseline_known" == "yes" ]] \
     && { [[ -z "$investigated" ]] || [[ "$report_every_turn" == "yes" ]]; }; then
    add "A long session (~$events exchanges) with no substantial diff — a debugging"
    add "or research session whose findings die with the context window."
    add ""
    add "Ask the user whether they want a session report, with a question tool where"
    add "the host has one and in the reply otherwise."
    add "If they want it: $wrap_dir/report-investigation.md"
    next_investigated="1"
  fi
fi

if ! record_state "$next_fired" "$next_investigated" "$next_implemented"; then
  sections=""
fi

[[ -z "$sections" ]] && exit 0
printf '%s' "$sections" >&2
exit 2
