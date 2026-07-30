#!/usr/bin/env bash
# Engine-agnostic policy: end-of-session wrap-up, gated by magnitude ESCALATION.
#
# Input  (stdin JSON): {"project_dir": "...", "stop_hook_active": bool,
#                        "transcript_path": "...", "session_id": "..."}
# transcript_path (Claude) doubles as session identity and exchange counter;
# session_id (Kimi) supplies identity alone — the no-diff investigation branch
# needs a transcript and stays engine-limited.
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
cfg_path="$repo/.agents/config.json"
wrap_dir=".agents/playbooks"

cfg="$(CFG_PATH="$cfg_path" python3 <<'PY'
import json, os
cfg = {}
try:
    with open(os.environ["CFG_PATH"], encoding="utf-8") as f: cfg = json.load(f)
except Exception: pass
sw = cfg.get("hooks", {}).get("session_wrap", {})
print("yes" if sw.get("enabled", True) else "no")
print(sw.get("trivial_files", 2))
print(sw.get("trivial_lines", 30))
print(sw.get("review_files", 5))
print(sw.get("review_lines", 150))
print(sw.get("heavy_lines", 200))
print("yes" if sw.get("report_every_turn", False) else "no")
# Pairing mode is the one OPT-IN toggle: a missing or broken config must leave
# it OFF, never silently on.
lr = cfg.get("hooks", {}).get("learning_report", {})
print("yes" if lr.get("enabled", False) else "no")
PY
)"
enabled="$(printf '%s\n' "$cfg" | sed -n '1p')"
[[ "$enabled" == "no" ]] && exit 0
cfg_trivial_files="$(printf '%s\n' "$cfg" | sed -n '2p')"
cfg_trivial_lines="$(printf '%s\n' "$cfg" | sed -n '3p')"
cfg_review_files="$(printf '%s\n' "$cfg" | sed -n '4p')"
cfg_review_lines="$(printf '%s\n' "$cfg" | sed -n '5p')"
cfg_heavy_lines="$(printf '%s\n' "$cfg" | sed -n '6p')"
report_every_turn="$(printf '%s\n' "$cfg" | sed -n '7p')"
learning_enabled="$(printf '%s\n' "$cfg" | sed -n '8p')"

input="$(cat)"
parsed="$(HOOK_INPUT="$input" python3 <<'PY'
import json, os
d = json.loads(os.environ["HOOK_INPUT"] or "{}")
print(str(d.get("stop_hook_active", False)).lower())
print(d.get("project_dir", ""))
print(d.get("transcript_path", ""))
print(d.get("session_id", ""))
PY
)"
stop_active="$(printf '%s\n' "$parsed" | sed -n '1p')"
proj="$(printf '%s\n' "$parsed" | sed -n '2p')"
transcript="$(printf '%s\n' "$parsed" | sed -n '3p')"
session_id="$(printf '%s\n' "$parsed" | sed -n '4p')"

[[ "${stop_active:-false}" == "true" ]] && exit 0
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
markers='(\.agents/\.(genome-ledger|mutagen-ledger|sources-ledger|compaction-pending)$|\.agents/\.wrap-state-|^docs/learning/)'

changed=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  changed="$(git status --porcelain=v1 --untracked-files=all 2>/dev/null \
    | awk 'NF { sub(/^.. /, ""); print }' \
    | sed 's/^"//; s/"$//' \
    | grep -v '^$' \
    | grep -Ev "$markers" || true)"
fi

# ───────────────────────────── classify the tier ─────────────────────────────
count=0
lines=""
binary=""
if [[ -n "$changed" ]]; then
  count="$(printf '%s\n' "$changed" | wc -l | tr -d ' ')"
  if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    binary="$(git diff HEAD --numstat 2>/dev/null \
      | awk '$1 == "-" && $2 == "-" { print 1; exit }' || true)"
    tracked="$(git diff HEAD --numstat 2>/dev/null \
      | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { s += $1 + $2 } END { print s + 0 }' || true)"
    untracked="$(git ls-files --others --exclude-standard 2>/dev/null \
      | grep -Ev "$markers" \
      | while IFS= read -r f; do [[ -f "$f" ]] && wc -l <"$f" 2>/dev/null || true; done \
      | awk '{ s += $1 } END { print s + 0 }' || true)"
    lines=$(( ${tracked:-0} + ${untracked:-0} ))
  fi
fi

# A binary change, or churn we cannot measure (no commit yet), is never trivial:
# a safety wrap fails toward more review.
tier="none"
if [[ -n "$changed" ]]; then
  if [[ -n "$binary" || -z "$lines" ]]; then
    tier="diff"
  elif (( count <= TRIVIAL_FILES && lines <= TRIVIAL_LINES )); then
    tier="trivial"
  else
    tier="diff"
  fi
  if [[ "$tier" == "diff" ]] && { [[ -z "$lines" ]] || (( count >= REVIEW_FILES || lines >= REVIEW_LINES )); }; then
    tier="large"
  fi
fi

rank() { case "$1" in none) echo 0;; trivial) echo 1;; diff) echo 2;; large) echo 3;; *) echo 0;; esac; }

# ────────────────────────── escalation gate (the throttle) ──────────────────────────
# State file, one per session — the transcript path is hashed into the NAME, not
# compared inside a shared file. Two Claude sessions in one repo would otherwise
# share `.wrap-state`, each read the other's identity, reset the ladder, and fire
# every turn — the exact behavior this gate exists to prevent.
#   line 1  highest tier already fired (the diff ladder)
#   line 2  "1" once the no-diff investigation report has fired this session
#   line 3  commit count at the last write — a rise means a commit landed
# The diff ladder cannot throttle the no-diff branch — `none` and `trivial` never
# out-rank a fresh `none` — so that branch carries its own flag.
#
# The commit count is tracked because a tier drop is not the only way work
# completes: a turn that commits AND opens the next unit never dips to `none`, so
# the ladder would stay latched and swallow the next wrap. The count catches the
# commit the tier never shows. It is a COUNT and not a sha because a sha merely
# *moves* on `--amend`, `rebase`, or `checkout` — none of which close a unit of
# work — and would re-fire the wrap on an unchanged tree.
#
# Session identity: the transcript path (Claude) or session_id (Kimi) — either
# names this session's state file. Neither present = no identity = no throttle:
# read and write nothing, and let every escalation fire. Keying a shared file on
# an empty identity would make one repo-wide ladder that every future session
# inherits, silently suppressing wraps forever. A safety wrap fails toward review.
ident="${transcript:-$session_id}"
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
if [[ -n "$state" && -f "$state" ]]; then
  fired="$(sed -n '1p' "$state" 2>/dev/null || true)"
  investigated="$(sed -n '2p' "$state" 2>/dev/null || true)"
  prev_commits="$(sed -n '3p' "$state" 2>/dev/null || true)"
fi
case "$fired" in none|trivial|diff|large) ;; *) fired="none";; esac
[[ "$investigated" == "1" ]] || investigated=""
[[ "$prev_commits" =~ ^[0-9]+$ ]] || prev_commits=""

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

# Persist unconditionally, at every invocation — NOT only when emitting. A commit
# turn emits nothing; if the re-armed `fired` were written only from an emit
# branch, the re-arm would live in memory and die there, and the next unit of work
# reaching the same tier would be silently swallowed.
record_state() {
  [[ -z "$state" ]] && return 0
  mkdir -p "$proj/.agents" 2>/dev/null || true
  { printf '%s\n%s\n%s\n' "$1" "$2" "$commits" > "$state"; } 2>/dev/null || true
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

if [[ "$tier" == "diff" || "$tier" == "large" ]]; then
  if [[ "$escalated" == "yes" || "$report_every_turn" == "yes" ]]; then
    size="$count file(s)"
    [[ -n "$lines" ]] && size="$size, ~$lines changed lines"
    [[ -n "$binary" ]] && size="$size, binary"
    shown="$(printf '%s\n' "$changed" | head -20 | sed 's/^/  - /')"
    (( count > 20 )) && shown="$shown"$'\n'"  - … $((count - 20)) more"

    add "Uncommitted changes this session ($size):"
    add "$shown"
    add ""
    add "This crossed the '$tier' threshold. Ask the user — full session wrap, or skip?"
    add "(Claude: use AskUserQuestion.) Honor the answer; if they skip, stop here."
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
else
  # ──────────── no diff (or trivial): capture a long investigation ────────────
  # Length ≈ transcript line count (one line per exchange); schema-agnostic, so
  # any engine that hands us a transcript path works. Throttled by the
  # `investigated` flag: once per session, not once per turn.
  events=""
  [[ -n "$transcript" && -f "$transcript" ]] && \
    events="$(wc -l <"$transcript" 2>/dev/null | tr -d ' ' || true)"

  if [[ -n "$events" ]] && (( events >= HEAVY )) \
     && { [[ -z "$investigated" ]] || [[ "$report_every_turn" == "yes" ]]; }; then
    add "A long session (~$events exchanges) with no substantial diff — a debugging"
    add "or research session whose findings die with the context window."
    add ""
    add "Ask the user whether they want a session report (Claude: use AskUserQuestion)."
    add "If they want it: $wrap_dir/report-investigation.md"
    next_investigated="1"
  fi
fi

record_state "$next_fired" "$next_investigated"

[[ -z "$sections" ]] && exit 0
printf '%s' "$sections" >&2
exit 2
