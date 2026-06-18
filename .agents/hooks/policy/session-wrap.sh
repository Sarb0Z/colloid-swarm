#!/usr/bin/env bash
# Engine-agnostic policy: end-of-session wrap-up, gated by magnitude.
#
# Input  (stdin JSON): {"project_dir": "...", "stop_hook_active": bool, "transcript_path": "..."}
# Output: exit 2 + stderr on a substantial session (the reason asks the agent to
#         check with the user before wrapping); exit 0 otherwise.
#
# Three outcomes on the first end-of-turn, so a one-line tweak or a quick
# question never triggers a hostile-review subagent, but a heavy session is
# never lost:
#   - code changes, trivial (few files + few lines)   -> skip silently
#   - code changes, substantial                       -> ask: full wrap or skip?
#   - no code changes but a long session              -> ask: want a report?
# "Long" is the transcript's line count — one line per exchange/event. It is
# schema-agnostic (no field parsing), so it works on any engine that passes a
# transcript path, and it can't crash on a malformed transcript. The no-diff ask
# is throttled to once per session (keyed by transcript path) so an active
# session isn't asked every turn.
#
# Tunable: WRAP_TRIVIAL_FILES (2), WRAP_TRIVIAL_LINES (30), WRAP_HEAVY_LINES (200).
#
# Pairing mode (opt-in, OFF by default): when hooks.learning_report.enabled is
# true in .agents/config.json, the substantial-diff branch additionally asks the
# agent to dispatch the learning-reporter subagent — a code-paired session report
# for a junior who learns by reviewing. Folded into this hook (one Stop hook, one
# exit 2) rather than a second Stop hook, whose competing stderr the engine
# merges unpredictably. Throttled once per session (.agents/.learning-prompted).

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cfg_path="$repo/.agents/config.json"
enabled="$(CFG_PATH="$cfg_path" python3 <<'PY'
import json, os
cfg = {}
try:
    with open(os.environ["CFG_PATH"], encoding="utf-8") as f: cfg = json.load(f)
except Exception: pass
print("yes" if cfg.get("hooks", {}).get("session_wrap", {}).get("enabled", True) else "no")
PY
)"
[[ "$enabled" == "no" ]] && exit 0

input="$(cat)"

parsed="$(HOOK_INPUT="$input" python3 <<'PY'
import json, os
d = json.loads(os.environ["HOOK_INPUT"] or "{}")
print(str(d.get("stop_hook_active", False)).lower())
print(d.get("project_dir", ""))
print(d.get("transcript_path", ""))
PY
)"
stop_active="$(printf '%s\n' "$parsed" | sed -n '1p')"
proj="$(printf '%s\n' "$parsed" | sed -n '2p')"
transcript="$(printf '%s\n' "$parsed" | sed -n '3p')"

if [[ "${stop_active:-false}" == "true" ]]; then
  exit 0
fi

[[ -z "$proj" ]] && proj="$PWD"
cd "$proj"

# Load config thresholds (env vars still override).
thresholds="$(CFG_PATH="$cfg_path" python3 <<'PY'
import json, os
cfg = {}
try:
    with open(os.environ["CFG_PATH"], encoding="utf-8") as f: cfg = json.load(f)
except Exception: pass
sw = cfg.get("hooks", {}).get("session_wrap", {})
print(sw.get("trivial_files", 2))
print(sw.get("trivial_lines", 30))
print(sw.get("heavy_lines", 200))
PY
)"
cfg_trivial_files="$(printf '%s\n' "$thresholds" | sed -n '1p')"
cfg_trivial_lines="$(printf '%s\n' "$thresholds" | sed -n '2p')"
cfg_heavy_lines="$(printf '%s\n' "$thresholds" | sed -n '3p')"

# The kit's own transient state files are not session work — exclude them by name
# (precise, so a real file that merely sits in .agents/ is never hidden). Generated
# learning reports under docs/learning/ are tooling output too, not the user's
# diff, so they never inflate the next magnitude check that triggers them.
markers='(\.agents/\.(genome-ledger|mutagen-ledger|sources-ledger|compaction-pending|wrap-prompted|learning-prompted)$|^docs/learning/)'

changed=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  changed="$(git status --porcelain=v1 --untracked-files=all 2>/dev/null \
    | awk 'NF { sub(/^.. /, ""); print }' \
    | sed 's/^"//; s/"$//' \
    | grep -v '^$' \
    | grep -Ev "$markers" || true)"
fi

# ───────────────────────── code changes present ─────────────────────────
if [[ -n "$changed" ]]; then
  count="$(printf '%s\n' "$changed" | wc -l | tr -d ' ')"

  TRIVIAL_FILES="${WRAP_TRIVIAL_FILES:-$cfg_trivial_files}"
  TRIVIAL_LINES="${WRAP_TRIVIAL_LINES:-$cfg_trivial_lines}"

  # Churn = tracked diff lines (vs HEAD) + untracked file lines. A binary change
  # reports no line count, so its presence alone forces "substantial".
  lines=""
  binary=""
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

  # Trivial -> skip silently. A binary change, or churn we cannot measure (no
  # commit yet), counts as substantial: a safety wrap fails toward more review.
  if [[ -z "$binary" && -n "$lines" ]] && (( count <= TRIVIAL_FILES && lines <= TRIVIAL_LINES )); then
    exit 0
  fi

  shown="$(printf '%s\n' "$changed" | head -30 | sed 's/^/  - /')"
  more=""
  if (( count > 30 )); then
    more=$'\n  - … '"$((count - 30))"" more"
  fi
  size="$count file(s)"
  [[ -n "$lines" ]] && size="$size, ~$lines changed lines"
  [[ -n "$binary" ]] && size="$size, binary"

  cat >&2 <<EOF
Uncommitted changes this session ($size):
$shown$more

This is more than a trivial edit. Ask the user — full session wrap, or skip it?
— and honor the answer (Claude: use the AskUserQuestion tool). If they skip, stop
here. If they want the wrap, walk this checklist against the files this session
actually touched; do not sweep files you did not edit.

1. Clean-up on these files
   - Remove unused imports, dead branches, and variables you introduced.
   - Delete comments that describe behavior you removed or replaced.
   - Delete TODO markers you wrote.
   - Delete temporary scripts, fixtures, or scratch files created for iteration.

2. Behavior-impact review on these files
   - Compare the new behavior to the prior behavior.
   - Update every downstream caller, test, and doc/instruction file in the touched domain that the change affects.
   - Stale behavior left in old code paths or docs is a regression.

3. Hostile review
   - Spawn a subagent to review the diff against the surrounding architecture.
   - Fold valid objections; escalate genuine disagreements to the user.

4. Session report
   - Root cause (for bugs): proximate and underlying.
   - What was done and why.
   - What changed or was verified.
   - Remaining blockers, risks, or next steps, if any.

5. Provide a commit message draft for the session's work in conventional style.
EOF

  # Pairing mode: append a learning-report dispatch to the SAME stderr (one hook,
  # one exit 2). The toggle is the one OPT-IN here, so it reads .get("enabled",
  # False) — a missing/broken config leaves pairing mode OFF, never silently on
  # (every other hook fails toward enabled; this one must not). Read here, inside
  # the substantial branch, so trivial/no-diff sessions never spawn the check.
  # Throttled once per session (keyed by transcript path, like the no-diff ask):
  # the junior gets one consolidated report, not one per turn. No transcript
  # (non-Claude engine) means no throttle key, so skip the section, keep the wrap.
  learning_enabled="$(CFG_PATH="$cfg_path" python3 <<'PY'
import json, os
cfg = {}
try:
    with open(os.environ["CFG_PATH"], encoding="utf-8") as f: cfg = json.load(f)
except Exception: pass
print("yes" if cfg.get("hooks", {}).get("learning_report", {}).get("enabled", False) else "no")
PY
)"
  if [[ "$learning_enabled" == "yes" && -n "${transcript:-}" ]]; then
    lmarker="$proj/.agents/.learning-prompted"
    lprev=""
    [[ -f "$lmarker" ]] && lprev="$(head -n1 "$lmarker" 2>/dev/null || true)"
    if [[ "$lprev" != "$transcript" ]]; then
      mkdir -p "$proj/.agents" 2>/dev/null || true
      { printf '%s\n' "$transcript" > "$lmarker"; } 2>/dev/null || true
      cat >&2 <<'EOF'

── Pairing mode: a learning report for the junior ────────────────────────
You are pair-coding with a junior who learns by reviewing, and you turned this
mode on deliberately. The junior's learning report is a SEPARATE deliverable
from the wrap above — the "full wrap, or skip?" choice does NOT govern it. Even
if the user skips the wrap, produce the report this turn (only a direct "skip
the report too" cancels it). DELEGATE it; do not write it inline:

1. Distill this session's engineering decisions into a brief. For each: what was
   chosen, the tradeoff, and the alternative(s) you rejected — the *why* you hold
   in context that a cold reader could not recover from the diff alone.
2. Dispatch the reporter (exempt from genome stamping — prepend NO stamp):
     Task(subagent_type='learning-reporter',
          prompt=<the decision-brief> + <the changed-file list above>)
   It pairs each decision with the actual code (file:line) and writes the report
   to docs/learning/. Pass the brief in full — it cannot see this conversation.
3. Surface the path it returns to the user.

Fires once per session. To regenerate, delete .agents/.learning-prompted.
EOF
    fi
  fi
  exit 2
fi

# ─────────────── no code changes: capture a long session ───────────────
# A debugging or research session leaves no diff but is still worth a report.
# Length ≈ transcript line count (one line per exchange/event); schema-agnostic,
# so any engine that hands us a transcript path works.
HEAVY="${WRAP_HEAVY_LINES:-$cfg_heavy_lines}"

events=""
if [[ -n "$transcript" && -f "$transcript" ]]; then
  events="$(wc -l <"$transcript" 2>/dev/null | tr -d ' ' || true)"
fi

# No transcript exposed (e.g. Kimi) or a short session -> stay silent.
if [[ -z "$events" ]] || (( events < HEAVY )); then
  exit 0
fi

# Throttle: ask once per session, keyed by transcript path.
marker="$proj/.agents/.wrap-prompted"
prev=""
[[ -f "$marker" ]] && prev="$(head -n1 "$marker" 2>/dev/null || true)"
if [[ -n "$transcript" && "$prev" == "$transcript" ]]; then
  exit 0
fi
mkdir -p "$proj/.agents" 2>/dev/null || true
{ printf '%s\n' "$transcript" > "$marker"; } 2>/dev/null || true

cat >&2 <<EOF
This was a long session (~$events exchanges) with no code changes — a debugging or
research session worth capturing. Ask the user whether they want a session report
(Claude: use the AskUserQuestion tool). If they skip, stop. If they want it, write
one:

1. The question — what was being investigated, and why.
2. Findings — the answer, root cause, or conclusion reached, each tied to the
   evidence (the files, commands, or sources that establish it).
3. Ruled out — dead ends and why, so the next investigator skips them.
4. Open questions, risks, and the recommended next step.
EOF
exit 2
