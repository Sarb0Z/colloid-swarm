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
# agent for a code-paired learning report — each decision paired with the real
# file:line that embodies it — for a junior who learns by reviewing. Produced
# INLINE by default; persisted to docs/learning/ via the learning-reporter
# subagent only when the user asks. Folded into this hook (one Stop hook, one exit
# 2) rather than a second Stop hook, whose competing stderr the engine merges
# unpredictably. Fires every substantial-diff turn; hooks.learning_report
# .cadence_turns=N throttles to every Nth (.agents/.learning-prompted counts).

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
   - Remove unused imports, dead branches, and unused variables anywhere in these
     files — pre-existing or introduced this session. The touched files are in
     scope as a whole; only files you did not edit are off-limits (see the header).
   - Delete comments that describe behavior you removed or replaced.
   - Delete TODO markers you wrote.
   - Delete temporary scripts, fixtures, or scratch files created for iteration.

2. Behavior-impact review on these files
   - Compare the new behavior to the prior behavior.
   - Flag any regressions or unintended consequences you find.
   - Update every downstream caller, test, and doc/instruction file in the touched domain that the change affects.
   - Stale behavior left in old code paths or docs is a regression.

3. Hostile review
   - Spawn a subagent to review the diff against the surrounding architecture.
     THE main question, before anything else: does the code actually do what it
     is supposed to do? Trace the change against its intent and the inputs and
     edge cases it must handle, and prove it correct — or pinpoint exactly where
     it does the wrong thing. A clean-looking diff that doesn't do its job is the
     worst defect. Only then hunt for these, each reported with file:line, why it
     bites, and the fix:
     - Dangerous patterns — data loss, unsafe deletes, auth/permission gaps,
       unvalidated input, injection, secrets in code, swallowed errors.
     - Scalability issues — unbounded growth, missing pagination, work that
       won't survive 100x load, per-request cost that should be amortized.
     - Race conditions — unguarded shared state, check-then-act, missing
       locks/transactions, non-atomic read-modify-write, ordering assumptions.
     - Suboptimal queries — N+1, full-table scans, missing indexes, SELECT *,
       queries inside loops, fetching far more rows than used.
     - Hard-to-debug code — silent failures, no logging at failure points,
       magic control flow, deep nesting, side effects hidden behind innocent names.
     - Weak architecture — leaky layer boundaries, tight coupling, duplicated
       sources of truth, logic in the wrong layer, abstractions that lie. For
       structural depth on this axis — abstraction quality, dramatic
       simplification, spaghetti growth, file-size smells — hand off to the
       thermo-nuclear-code-quality-review skill instead of duplicating it here.
   - Fold valid objections; escalate genuine disagreements to the user.

4. Session report
   - Root cause (for bugs): proximate and underlying.
   - What was done and why.
   - What changed or was verified.
   - Remaining blockers, risks, or next steps, if any.

5. Provide a commit message draft for the session's work in conventional style.
EOF

  # Pairing mode: append a learning-report request to the SAME stderr (one hook,
  # one exit 2). The toggle is the one OPT-IN here, so it reads .get("enabled",
  # False) — a missing/broken config leaves pairing mode OFF, never silently on
  # (every other hook fails toward enabled; this one must not). Read here, inside
  # the substantial branch, so trivial/no-diff sessions never spawn the check.
  #
  # Cadence: fires every substantial-diff turn by default (cadence_turns=1),
  # matching the wrap above. Set cadence_turns=N to fire on the first such turn,
  # then every Nth. Counting turns needs session identity (the transcript path) to
  # know when the count resets; with no transcript (non-Claude engine) we can't
  # count, so N>1 degrades to every turn. The report is produced INLINE by default
  # — no file, no subagent — and persisted only when the user asks.
  learning_cfg="$(CFG_PATH="$cfg_path" python3 <<'PY'
import json, os
cfg = {}
try:
    with open(os.environ["CFG_PATH"], encoding="utf-8") as f: cfg = json.load(f)
except Exception: pass
lr = cfg.get("hooks", {}).get("learning_report", {})
print("yes" if lr.get("enabled", False) else "no")
try:
    n = int(lr.get("cadence_turns", 1))
except (TypeError, ValueError):
    n = 1
print(n if n >= 1 else 1)
PY
)"
  learning_enabled="$(printf '%s\n' "$learning_cfg" | sed -n '1p')"
  cadence="$(printf '%s\n' "$learning_cfg" | sed -n '2p')"

  if [[ "$learning_enabled" == "yes" ]]; then
    emit_learning="yes"
    # N>1: count this session's substantial-diff turns, fire on 1, 1+N, 1+2N…
    # The marker holds the transcript path (session identity) + the count; a new
    # session, or an unreadable/old-format count, resets to 0.
    if [[ -n "${transcript:-}" ]] && (( cadence > 1 )); then
      lmarker="$proj/.agents/.learning-prompted"
      lprev_path=""; lprev_count=0
      if [[ -f "$lmarker" ]]; then
        lprev_path="$(sed -n '1p' "$lmarker" 2>/dev/null || true)"
        lprev_count="$(sed -n '2p' "$lmarker" 2>/dev/null || true)"
      fi
      [[ "$lprev_path" == "$transcript" ]] || lprev_count=0
      [[ "$lprev_count" =~ ^[0-9]+$ ]] || lprev_count=0
      lcount=$(( lprev_count + 1 ))
      mkdir -p "$proj/.agents" 2>/dev/null || true
      { printf '%s\n%s\n' "$transcript" "$lcount" > "$lmarker"; } 2>/dev/null || true
      (( (lcount - 1) % cadence == 0 )) || emit_learning="no"
    fi
    if [[ "$emit_learning" == "yes" ]]; then
      cat >&2 <<'EOF'

── Pairing mode: a learning report for the junior ────────────────────────
You are pair-coding with a junior who learns by reviewing, and you turned this
mode on deliberately. Produce the learning report INLINE this turn — it is a
SEPARATE deliverable from the wrap above, and the "full wrap, or skip?" choice
does NOT govern it. Even if the user skips the wrap, produce the report (only a
direct "skip the report too" cancels it).

Distill this session's engineering decisions, and pair EACH with the real code
that embodies it — the reasoning made legible against the lines that prove it:

- Decision — one line: what was chosen.
- Why — the tradeoff and the alternative you rejected; the *why* a cold reader
  could not recover from the diff alone.
- The code — a fenced excerpt of the REAL lines, headed with file:line. Lift it
  from the diff or a tracked file; never an excerpt you wish were there.
- How it works — the load-bearing mechanics, tied to lines in the excerpt.
- Pattern — name the reusable pattern ("fail-open guard", "throttle keyed by
  session"). Naming it is what makes it recognizable next time.
- Recognition cue — one line: "When you next see X, reach for Y."

Keep it scannable; lead each section with the decision in bold. A decision you
cannot tie to real code goes under a short "Open for discussion" trailer — never
fabricate an excerpt to fill the template.

Do NOT write a file. To persist this to docs/learning/ instead, the user only
has to ask — then delegate it (exempt from genome stamping — prepend NO stamp):
  Task(subagent_type='learning-reporter',
       prompt=<the decision-brief> + <the changed-file list above>)
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
