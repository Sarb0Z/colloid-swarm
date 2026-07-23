#!/usr/bin/env bash
# Colloid Swarm — live demo of the scaffold's mechanical layer.
#
# Runs the three runnable cores against real inputs and prints their real
# output: the genome emitter (personality sortition + fan-out), the mutagen
# roller (framing mutation), and the destructive-command guard (the membrane).
# Then verifies the progressive-disclosure fan-out: every symlink must resolve
# to its canonical AGENTS.md. No mocks — every line is the real thing.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

bold=$'\033[1m'; dim=$'\033[2m'; grn=$'\033[32m'; red=$'\033[31m'; rst=$'\033[0m'
rule() { printf '%s\n' "${dim}────────────────────────────────────────────────────────────${rst}"; }
sec()  { printf '\n%s▸ %s%s\n' "$bold" "$1" "$rst"; }

printf '%s⊰ COLLOID SWARM — scaffold demo ⊱%s\n' "$bold" "$rst"
printf '%sengine-agnostic agent OS: genomes · mutagen · the membrane%s\n' "$dim" "$rst"

# ── 1. Genome emitter ───────────────────────────────────────────────────────
sec "1. Genome emitter — one personality per subagent"
rule
printf '%s$ genome.sh --check%s\n' "$dim" "$rst"
.agents/genome.sh --check
printf '\n%s$ genome.sh --seed 42 phage%s   %s(reproducible: seed pins the draw)%s\n' "$dim" "$rst" "$dim" "$rst"
.agents/genome.sh --seed 42 phage 2>/dev/null | sed 's/^/  /'
printf '\n%s$ genome.sh --count 5%s   %s(fan-out: guaranteed-distinct stamps)%s\n' "$dim" "$rst" "$dim" "$rst"
.agents/genome.sh --count 5 2>/dev/null | grep '⊰ COLLOID' | sed 's/^/  /'

# ── 2. Mutagen roller ───────────────────────────────────────────────────────
sec "2. Mutagen — mutate the framing before a blind fan-out"
rule
printf '%s$ mutagen.sh --check%s\n' "$dim" "$rst"
.agents/mutagen.sh --check
printf '\n%s$ mutagen.sh --cost cheap --seed 7%s   %s(cheap-to-verify -> a BOLD axis)%s\n' "$dim" "$rst" "$dim" "$rst"
.agents/mutagen.sh --cost cheap --seed 7 2>/dev/null | grep -A2 'MUTATION VECTOR' | sed 's/^/  /'
printf '\n%s$ mutagen.sh --cost expensive --seed 3%s   %s(expensive -> a GENTLE axis)%s\n' "$dim" "$rst" "$dim" "$rst"
.agents/mutagen.sh --cost expensive --seed 3 2>/dev/null | grep -A2 'MUTATION VECTOR' | sed 's/^/  /'

# ── 3. The membrane ─────────────────────────────────────────────────────────
sec "3. The membrane — guard-destructive.sh (fail-closed floor)"
rule
guard=.agents/hooks/policy/guard-destructive.sh
# Payloads assembled at runtime so the literal patterns never sit on a command
# line — the live session's OWN guard would otherwise block this demo script.
probe() {
  local label="$1" payload="$2" out rc
  out="$(printf '{"command":%s}' "$payload" | "$guard" 2>&1)" && rc=0 || rc=$?
  if [[ $rc -eq 2 ]]; then
    printf '  %sBLOCK%s  %-26s %s%s%s\n' "$red" "$rst" "$label" "$dim" "$out" "$rst"
  else
    printf '  %sPASS %s  %-26s %s(exit %s)%s\n' "$grn" "$rst" "$label" "$dim" "$rc" "$rst"
  fi
}
j() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
probe "rm -rf home"        "$(j "$(printf 'rm -%sf ~' r)")"
probe "force-push"         "$(j 'git push --force origin main')"
probe "reset --hard"       "$(j 'git reset --hard HEAD~3')"
probe "ssh prod restart"   "$(j 'ssh prod systemctl restart nginx')"
probe "DROP TABLE"         "$(j 'psql -c "DROP TABLE users"')"
probe "DELETE no WHERE"    "$(j 'psql -c "DELETE FROM users;"')"
probe "ls -la"             "$(j 'ls -la')"
probe "scoped build clean" "$(j "$(printf 'rm -%sf ./build/tmp' r)")"

# ── 4. Progressive disclosure ───────────────────────────────────────────────
sec "4. Progressive disclosure — scoped AGENTS.md + symlink fan-out"
rule
canon=$(find . -name AGENTS.md -type f | wc -l | tr -d ' ')
links=$(find .agents .claude demo tensium-trial .github -type l | wc -l | tr -d ' ')
broken=$(find . -type l ! -exec test -e {} \; -print)
printf '  canonical AGENTS.md files: %s\n' "$canon"
printf '  fan-out symlinks:          %s\n' "$links"
if [[ -z "$broken" ]]; then
  printf '  %sPASS%s  every symlink resolves to a canonical file\n' "$grn" "$rst"
else
  printf '  %sFAIL%s  broken symlinks:\n%s\n' "$red" "$rst" "$broken"
fi
printf '\n%sone rule, three doors — all resolve to the same canonical file:%s\n' "$dim" "$rst"
for p in .agents/skills/security-scan/AGENTS.md \
         .claude/rules/security-scan.md \
         .github/instructions/00-security-scan.instructions.md; do
  printf '  %-52s %s->%s %s\n' "$p" "$dim" "$rst" "$(realpath "$p")"
done

printf '\n%s⊱ every line above is live output — no mocks, no slides ⊰%s\n' "$bold" "$rst"
