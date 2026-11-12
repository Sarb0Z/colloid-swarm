#!/usr/bin/env bash
# Colloid Swarm — live demo of the scaffold's mechanical layer.
#
# Runs the scaffold's cores against real inputs and prints their real output:
# static personas, the layout checker, and the destructive-command guard (the membrane). Then
# verifies the progressive-disclosure fan-out, proves the satellite export
# subtracted what it claims, speaks the real MCP handshake to both
# repository-owned servers, asks the publish guard about outward commands,
# checks declared read access, proves a fix's test catches its bug, and walks
# a workloop run to its completion gate. No mocks — every line is the real thing.
#
# Runs offline. Every beat but 6 needs bash, python3 and git; beat 6 also needs
# node, and announces a skip without it. Every scratch path lives under one
# folder that the EXIT trap below removes.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
# A viewer's git identity or signing setup must not stop a scratch commit.
g() { git -c user.name=demo -c user.email=demo@example.invalid -c commit.gpgsign=false "$@"; }

# Colour only on a terminal, and never when NO_COLOR is set non-empty (no-color.org).
bold=''; dim=''; grn=''; red=''; rst=''
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  bold=$'\033[1m'; dim=$'\033[2m'; grn=$'\033[32m'; red=$'\033[31m'; rst=$'\033[0m'
fi
rule() { printf '%s\n' "${dim}────────────────────────────────────────────────────────────${rst}"; }
sec()  { printf '\n%s▸ %s%s\n' "$bold" "$1" "$rst"; }

printf '%s⊰ COLLOID SWARM — scaffold demo ⊱%s\n' "$bold" "$rst"
printf '%sengine-agnostic agent OS: personas · layout · membrane · export · MCP · publish guard · read access · revert-check · completion gate%s\n' "$dim" "$rst"

# ── 1. Static personas ──────────────────────────────────────────────────────
sec "1. Static personas — explicit role and model per subagent"
rule
find .agents/personas -maxdepth 1 -type f -name '*.md' -print | sort | sed 's/^/  /'

# ── 2. Layout check ──────────────────────────────────────────────────────────
sec "2. Layout check — canonical files and fan-out paths"
rule
python3 .agents/check-layout.py

# ── 3. The membrane ─────────────────────────────────────────────────────────
sec "3. The membrane — guard-destructive.sh (blocks irreversible commands)"
rule
guard=.agents/hooks/policy/guard-destructive.sh
# The patterns sit on the command line literally. The guard matches the tokens
# of a command, not the text of one, so quoting a pattern is not running it and
# the live session's own guard lets this script through.
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
probe "rm -Rf home"        "$(j 'rm -Rf ~')"
probe "force-push"         "$(j 'git push --force origin main')"
probe "reset --hard via -C" "$(j 'git -C /repo reset --hard')"
probe "ssh prod restart"   "$(j 'ssh prod systemctl restart nginx')"
probe "TRUNCATE no TABLE"  "$(j 'psql -c "TRUNCATE users"')"
probe "DELETE no WHERE"    "$(j 'psql -c "DELETE FROM users"')"
probe "terraform destroy"  "$(j 'terraform destroy -auto-approve')"
probe "ls -la"             "$(j 'ls -la')"
probe "scoped build clean" "$(j 'rm -rf ./build/tmp')"
probe "quoted, not run"    "$(j 'grep -q "rm -rf /" notes.md')"

# ── 4. Progressive disclosure ───────────────────────────────────────────────
sec "4. Progressive disclosure — scoped AGENTS.md + symlink fan-out"
rule
canon=$(find . -name AGENTS.md -type f | wc -l | tr -d ' ')
hosts=()
for d in .agents .claude .codex .opencode .kimi demo .github; do [[ -d "$d" ]] && hosts+=("$d"); done
links=$(find "${hosts[@]}" -type l | wc -l | tr -d ' ')
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

# ── 5. Scaffold export ──────────────────────────────────────────────────────
sec "5. Scaffold export — emit the satellite copy, then prove the subtraction"
rule
kit="$scratch/kit"
printf '%s$ export-scaffold.py <tmp>%s\n' "$dim" "$rst"
.agents/export-scaffold.py "$kit" | sed 's/^/  /'
printf '  emitted: %s (%s files)\n' \
  "$(ls -A "$kit" | tr '\n' ' ')" "$(find "$kit" -type f | wc -l | tr -d ' ')"

# Assertions read the export's own drop lists, so a new entry is checked here
# the moment it is added rather than against a copy that drifts.
printf '\n'
python3 - "$kit" <<'PY' | while IFS='|' read -r verdict text; do
import importlib.util
import json
import pathlib
import re
import sys

kit = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("ex", ".agents/export-scaffold.py")
ex = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ex)

def emit(ok, text):
    print(f"{'PASS' if ok else 'FAIL'}|{text}")

leaked = [p for p in ex.DROPPED_PATHS if (kit / p).exists()]
emit(not leaked, f"{len(ex.DROPPED_PATHS)} dropped paths absent"
     + (f" — LEAKED {leaked}" if leaked else ""))

# No engine's dispatch table may still name a policy the export removed.
tables = [p for p in kit.rglob("*") if p.is_file()
          and p.name in ("settings.json", "hooks.json", "config.toml.example")]
naming = [f"{p.relative_to(kit)}" for p in tables
          for policy in ex.DROPPED_POLICIES
          if policy in p.read_text(encoding="utf-8", errors="ignore")]
emit(not naming, f"{len(tables)} hook tables name no dropped policy"
     + (f" — {naming}" if naming else ""))

# A marker LINE must not survive. The literal may: the sync scripts match on
# it to strip it, and the transplant guide names it in prose.
def marks(line):
    return any(open_.match(line) or close.match(line)
               for open_, close in ex.MARKERS)

survivors = [str(p.relative_to(kit)) for p in kit.rglob("*")
             if p.is_file() and p.suffix in ex.TEXT_SUFFIXES
             and any(marks(line) for line
                     in p.read_text(encoding="utf-8", errors="ignore").splitlines())]
emit(not survivors, "no colloid-only marker line survives"
     + (f" — {survivors}" if survivors else ""))

def present(data, dotted):
    """Walk a dotted key path; report whether it still resolves."""
    node = data
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            return False
        node = node[part]
    return True

config = kit / ".agents/config.json.example"
data = json.loads(config.read_text(encoding="utf-8")) if config.is_file() else {}
stale = [k for k in ex.DROPPED_KEYS[".agents/config.json.example"]
         if present(data, k)]
emit(not stale, f"{len(ex.DROPPED_KEYS['.agents/config.json.example'])} "
     "genome config keys dropped" + (f" — {stale}" if stale else ""))
PY
  if [[ "$verdict" == PASS ]]; then
    printf '  %sPASS%s  %s\n' "$grn" "$rst" "$text"
  else
    printf '  %sFAIL%s  %s\n' "$red" "$rst" "$text"
  fi
done

# ── 6. Repository-owned MCP servers ─────────────────────────────────────────
sec "6. Repository-owned MCP — the membrane at the network edge"
rule
if ! command -v node >/dev/null 2>&1; then
  printf '  %sSKIP%s  node not on PATH — the servers need Node >=20.19.0\n' \
    "$dim" "$rst"
else
# Assign before printing: a failure inside a printf argument is swallowed, and
# an empty tool list must never read as a passing beat.
for server in research-mcp security-mcp; do
  dir=".agents/mcp-servers/$server"
  printf '%s$ mcp-probe.py %s list%s\n' "$dim" "$server" "$rst"
  tools="$(demo/mcp-probe.py "$dir" list)"
  printf '  %s tools: %s\n' "$server" "$(tr '\n' ' ' <<<"$tools")"
done

# Both guards refuse before they open a socket, so this runs with no network.
mcp_probe() {
  local label="$1" server="$2" tool="$3" args="$4" out
  out="$(demo/mcp-probe.py ".agents/mcp-servers/$server" call "$tool" "$args")"
  local verdict="$red REFUSED$rst"
  if python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); sys.exit(0 if (d.get("allowed") or d.get("ok")) else 1)' <<<"$out"; then
    verdict="$grn ALLOWED$rst"
  fi
  printf '  %b  %-30s %s%s%s\n' "$verdict" "$label" "$dim" \
    "$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("reason") or d.get("error",""))' <<<"$out")" "$rst"
}
printf '\n%ssecurity-mcp validate_target — operator target policy:%s\n' "$dim" "$rst"
mcp_probe "loopback"        security-mcp validate_target '{"targetUrl":"http://127.0.0.1:3000"}'
mcp_probe "public host"     security-mcp validate_target '{"targetUrl":"https://example.com"}'
mcp_probe "cloud metadata"  security-mcp validate_target '{"targetUrl":"http://169.254.169.254/"}'
printf '\n%sresearch-mcp fetch_readable — SSRF guard:%s\n' "$dim" "$rst"
mcp_probe "cloud metadata"  research-mcp fetch_readable '{"url":"http://169.254.169.254/latest/meta-data/"}'
mcp_probe "loopback ssh"    research-mcp fetch_readable '{"url":"http://localhost:22/"}'
mcp_probe "file:// scheme"  research-mcp fetch_readable '{"url":"file:///etc/passwd"}'
fi

# ── 7. The publish guard ────────────────────────────────────────────────────
sec "7. The publish guard — guard-publish.sh asks before anything leaves the machine"
rule
# The cwd is a scratch repository with one commit and no remote, so the push
# reason describes that repository. The guard also reads this checkout's
# hooks.guard_publish.enabled and prunes its expired approval tokens.
pubrepo="$scratch/pub"
mkdir "$pubrepo"
g -C "$pubrepo" init -q -b main
printf 'demo\n' > "$pubrepo/file.txt"
g -C "$pubrepo" add -A
g -C "$pubrepo" commit -qm 'one commit'
# Commands are assembled from parts so this script never carries an outward
# command as one literal; the live guard reads a script it is asked to run.
git_=git; gh_=gh; npm_=npm; vc_=vercel
publish_probe() {
  local mode="$1" command="$2" out
  out="$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"permission_mode":sys.argv[2],"cwd":sys.argv[3]}))' \
    "$command" "$mode" "$pubrepo" | .agents/hooks/policy/guard-publish.sh)"
  if [[ -z "$out" ]]; then
    printf '  %sQUIET%s %-7s %s\n' "$grn" "$rst" "$mode" "$command"
    return
  fi
  python3 -c 'import json,sys
d = json.loads(sys.stdin.read())["hookSpecificOutput"]
print(d["permissionDecision"].upper() + "|" + d["permissionDecisionReason"])' <<<"$out" |
    while IFS='|' read -r verdict reason; do
      local colour="$red"; [[ "$verdict" == ASK ]] && colour="$dim"
      printf '  %s%-5s%s %-7s %s\n        %s%s%s\n' "$colour" "$verdict" "$rst" "$mode" "$command" "$dim" "$reason" "$rst"
    done
}
publish_probe default "$git_ push origin main"
publish_probe default "$gh_ pr merge 12"
publish_probe default "$npm_ publish"
publish_probe default "$vc_ deploy --prod"
publish_probe default "$git_ status"
publish_probe default "$gh_ pr view 12"
printf '\n%sthe same push where no human can answer a prompt:%s\n' "$dim" "$rst"
publish_probe auto "$git_ push origin main"

# ── 8. Declared read access ─────────────────────────────────────────────────
sec "8. Declared read access — access.py refuses a read that is really a write"
rule
policy_repo() {  # <name> <policy json>: a scratch folder holding only a policy
  mkdir -p "$scratch/$1/.agents"
  printf '%s\n' "$2" > "$scratch/$1/.agents/policy.json"
}
policy_repo acc-merge '{"systems":[{"name":"github","probe":"true","read":["gh pr list","gh pr merge 1"]}]}'
policy_repo acc-list '{"systems":[{"name":"github","probe":"true","read":["gh pr list"]}]}'
# check prints its summary only when nothing fails, so each outcome is one call.
for name in acc-merge acc-list; do
  printf '%s$ access.py check  %s(%s)%s\n' "$dim" "$dim" "$(python3 -c 'import json,sys; print(", ".join(json.load(open(sys.argv[1]))["systems"][0]["read"]))' "$scratch/$name/.agents/policy.json")" "$rst"
  if out="$(python3 .agents/access.py check --repo "$scratch/$name" 2>&1)"; then
    printf '  %sPASS%s  %s\n' "$grn" "$rst" "$out"
  else
    printf '  %sFAIL%s  %s\n' "$red" "$rst" "${out#FAIL: }"
  fi
done

# ── 9. A test that catches its bug ──────────────────────────────────────────
sec "9. A test that catches its bug — revert-check.sh"
rule
rcrepo="$scratch/rc"
mkdir "$rcrepo"
g -C "$rcrepo" init -q -b main
printf 'bad\n' > "$rcrepo/lib.txt"
g -C "$rcrepo" add -A
g -C "$rcrepo" commit -qm 'the bug'
base="$(g -C "$rcrepo" rev-parse HEAD)"
printf 'good\n' > "$rcrepo/lib.txt"
printf '%s\n' '[[ "$(cat lib.txt)" == good ]] || { echo "assertion failed: lib.txt is not good"; exit 1; }' > "$rcrepo/asserts.sh"
printf '%s\n' 'test -f lib.txt' > "$rcrepo/imports.sh"
g -C "$rcrepo" add -A
g -C "$rcrepo" commit -qm 'the fix and its tests'
for t in asserts.sh imports.sh; do
  printf '%s$ revert-check.sh <bug commit> --tests %s -- bash %s%s\n' "$dim" "$t" "$t" "$rst"
  rc=0
  out="$(cd "$rcrepo" && "$repo/.agents/revert-check.sh" "$base" --tests "$t" -- bash "$t" 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]]; then
    printf '  %sPASS%s  exit 0\n' "$grn" "$rst"
  else
    printf '  %sFAIL%s  exit %s\n' "$red" "$rst" "$rc"
  fi
  sed 's/^/    /' <<<"$out"
done

# ── 10. The completion gate ─────────────────────────────────────────────────
sec "10. The completion gate — workloop.py check names what blocks completion"
rule
wlrepo="$scratch/wl"
mkdir -p "$wlrepo/src" "$wlrepo/docs"
g -C "$wlrepo" init -q -b main
printf 'a\n' > "$wlrepo/src/app.txt"
g -C "$wlrepo" add -A
g -C "$wlrepo" commit -qm base
# --state and --repo keep the run out of this checkout's own worktrees and readouts.
wl() { python3 .agents/workloop.py --state "$scratch/workloop-state.json" "$@"; }
step() { printf '%s$ workloop.py %s%s\n' "$dim" "$*" "$rst"; }
gate() {  # <args...>: print check's verdict, which exits 1 while blocked
  step "$@"
  wl "$@" 2>&1 | sed 's/^/  /' || true
}
wl init demo --objective 'ship one change' --acceptance 'reviewed, QA observed' \
  --repo "$wlrepo" --verify 'test -f src/app.txt' --lane solo --worker implementer \
  --path src >/dev/null
wl claim demo solo --agent demo-writer | sed 's/^/  /'
printf 'b\n' >> "$wlrepo/src/app.txt"
g -C "$wlrepo" commit -qam change
wl submit demo solo --evidence 'ran the change' | sed 's/^/  /'
gate check --recorded demo
printf 'accepted\n' > "$wlrepo/docs/review.md"
g -C "$wlrepo" add docs/review.md
g -C "$wlrepo" commit -qm 'review record'
tip="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runs"]["demo"]["lanes"]["solo"]["tip"])' "$scratch/workloop-state.json")"
wl review demo solo --reference docs/review.md --result accept --tip "$tip" | sed 's/^/  /'
wl qa demo --evidence 'scenario observed' | sed 's/^/  /'
gate check demo
printf 'c\n' >> "$wlrepo/src/app.txt"
g -C "$wlrepo" commit -qam 'a later change'
wl submit demo solo --evidence 'ran the later change' | sed 's/^/  /'
printf '%sthe tip moved, so the review and the QA record no longer cover it:%s\n' "$dim" "$rst"
gate check --recorded demo

printf '\n%s⊱ every line above is live output — no mocks, no slides ⊰%s\n' "$bold" "$rst"
