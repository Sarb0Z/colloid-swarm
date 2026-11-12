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
# Every beat that prints a verdict compares it, and where an error could print
# the same verdict the reason it prints, with the ones it expects; the script
# exits 1 after the last beat when any differed, so a regression cannot hide
# behind a printed line.
#
# Runs offline. Every beat but 6 needs bash, python3 and git; beat 6 also needs
# node, and announces a skip without it. Every scratch path lives under one
# folder that the EXIT trap below removes.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
# A viewer's git identity, signing setup or global hooks must not stop a scratch commit.
g() { git -c user.name=demo -c user.email=demo@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
mkrepo() {  # <dir> <file> <content> <message>: a repository with one commit
  mkdir -p "$1/$(dirname "$2")"
  g -C "$1" init -q -b main
  printf '%s\n' "$3" > "$1/$2"
  g -C "$1" add -A
  g -C "$1" commit -qm "$4"
}

# Colour only on a terminal, and never when NO_COLOR is set non-empty (no-color.org).
bold=''; dim=''; grn=''; red=''; rst=''
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  bold=$'\033[1m'; dim=$'\033[2m'; grn=$'\033[32m'; red=$'\033[31m'; rst=$'\033[0m'
fi
rule() { printf '%s\n' "${dim}────────────────────────────────────────────────────────────${rst}"; }
sec()  { printf '\n%s▸ %s%s\n' "$bold" "$1" "$rst"; }
mismatch=0
expect() {  # <beat> <expected> <got> <what>: flag a result that is not the expected one
  [[ "$2" == "$3" ]] && return 0
  # On stderr: a caller that discards stdout, as the run's composed test does, still sees which beat.
  printf '  MISMATCH  beat %s expected %s, got %s: %s\n' "$1" "$2" "$3" "$4" >&2
  mismatch=1
}
saying() {  # <got> <output> <text>: <got>, marked when the output lacks the text the outcome must print
  if [[ "$2" == *"$3"* ]]; then printf '%s' "$1"; else printf '%s without "%s"' "$1" "$3"; fi
}
verdict() {  # <PASS|FAIL> <text>
  local colour="$grn"; [[ "$1" == FAIL ]] && colour="$red"
  printf '  %s%s%s  %s\n' "$colour" "$1" "$rst" "$2"
}

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
# Each pattern reaches the guard as quoted data and is never run. The guard reads
# a command's tokens, not its text, so the quoted pattern inside the probe line
# is not a command to it; and the live session's guard sees only
# `bash demo/demo.sh`, never the contents of this file.
probe() {  # <label> <payload> <BLOCK|PASS>
  local label="$1" payload="$2" want="$3" out rc got
  out="$(printf '{"command":%s}' "$payload" | "$guard" 2>&1)" && rc=0 || rc=$?
  if [[ $rc -eq 2 ]]; then
    got=BLOCK
    printf '  %sBLOCK%s  %-26s %s%s%s\n' "$red" "$rst" "$label" "$dim" "$out" "$rst"
  else
    got=PASS
    printf '  %sPASS %s  %-26s %s(exit %s)%s\n' "$grn" "$rst" "$label" "$dim" "$rc" "$rst"
  fi
  expect 3 "$want" "$got" "$label"
}
j() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
probe "rm -Rf home"        "$(j 'rm -Rf ~')" BLOCK
probe "force-push"         "$(j 'git push --force origin main')" BLOCK
probe "reset --hard via -C" "$(j 'git -C /repo reset --hard')" BLOCK
probe "ssh prod restart"   "$(j 'ssh prod systemctl restart nginx')" BLOCK
probe "TRUNCATE no TABLE"  "$(j 'psql -c "TRUNCATE users"')" BLOCK
probe "DELETE no WHERE"    "$(j 'psql -c "DELETE FROM users"')" BLOCK
probe "terraform destroy"  "$(j 'terraform destroy -auto-approve')" BLOCK
probe "ls -la"             "$(j 'ls -la')" PASS
probe "scoped build clean" "$(j 'rm -rf ./build/tmp')" PASS
probe "quoted, not run"    "$(j 'grep -q "rm -rf /" notes.md')" PASS

# ── 4. Progressive disclosure ───────────────────────────────────────────────
sec "4. Progressive disclosure — scoped AGENTS.md + symlink fan-out"
rule
# Tracked files only: lane worktrees under .agents/worktrees/ are not part of the scaffold.
tracked_links() { git ls-files -s -- "$@" | awk -F'\t' '$1 ~ /^120000/ {print $2}'; }
canon=$(git ls-files -s -- '*AGENTS.md' | awk -F'\t' '$1 !~ /^120000/' | wc -l | tr -d ' ')
hosts=()
for d in .agents .claude .codex .opencode .kimi demo .github; do [[ -d "$d" ]] && hosts+=("$d"); done
links=$(tracked_links "${hosts[@]}" | wc -l | tr -d ' ')
broken=""
while IFS= read -r link; do
  [[ -e "$link" ]] || broken+="$link"$'\n'
done < <(tracked_links .)
printf '  canonical AGENTS.md files: %s\n' "$canon"
printf '  fan-out symlinks:          %s\n' "$links"
if [[ -z "$broken" ]]; then
  verdict PASS "every symlink resolves to a canonical file"
  expect 4 PASS PASS "symlinks resolve"
else
  verdict FAIL "broken symlinks:"
  printf '%s' "$broken"
  expect 4 PASS FAIL "symlinks resolve"
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
results="$(python3 - "$kit" <<'PY'
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
)"
while IFS='|' read -r result text; do
  verdict "$result" "$text"
  expect 5 PASS "$result" "$text"
done <<<"$results"

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
  expect 6 listed "${tools:+listed}" "$server lists its tools"
done

# Both guards refuse before they open a socket, so this runs with no network.
mcp_probe() {  # <label> <server> <tool> <args> <ALLOWED|REFUSED>
  local label="$1" server="$2" tool="$3" args="$4" want="$5" out got
  out="$(demo/mcp-probe.py ".agents/mcp-servers/$server" call "$tool" "$args")"
  # REFUSED only from an explicit refusal: security-mcp's allowed:false, or
  # research-mcp's ok:false with a policy failure. A failed fetch or a reply that
  # is not a JSON object is an ERROR, never a refusal.
  IFS='|' read -r got reason <<<"$(python3 -c 'import json,sys
try:
    d = json.loads(sys.stdin.read())
except ValueError:
    d = None
if not isinstance(d, dict):
    print("ERROR|the reply is not a JSON object")
else:
    if d.get("allowed") is True or d.get("ok") is True:
        got = "ALLOWED"
    elif d.get("allowed") is False or (d.get("ok") is False and d.get("failure") == "policy"):
        got = "REFUSED"
    else:
        got = "ERROR"
    print(got + "|" + str(d.get("reason") or d.get("error") or ""))' <<<"$out")"
  local colour="$red"; [[ "$got" == ALLOWED ]] && colour="$grn"
  printf '  %s%s%s  %-30s %s%s%s\n' "$colour" "$got" "$rst" "$label" "$dim" "$reason" "$rst"
  expect 6 "$want" "$got" "$server $label"
}
printf '\n%ssecurity-mcp validate_target — operator target policy:%s\n' "$dim" "$rst"
mcp_probe "loopback"        security-mcp validate_target '{"targetUrl":"http://127.0.0.1:3000"}' ALLOWED
mcp_probe "public host"     security-mcp validate_target '{"targetUrl":"https://example.com"}' REFUSED
mcp_probe "cloud metadata"  security-mcp validate_target '{"targetUrl":"http://169.254.169.254/"}' REFUSED
printf '\n%sresearch-mcp fetch_readable — SSRF guard:%s\n' "$dim" "$rst"
mcp_probe "cloud metadata"  research-mcp fetch_readable '{"url":"http://169.254.169.254/latest/meta-data/"}' REFUSED
mcp_probe "loopback ssh"    research-mcp fetch_readable '{"url":"http://localhost:22/"}' REFUSED
mcp_probe "file:// scheme"  research-mcp fetch_readable '{"url":"file:///etc/passwd"}' REFUSED
fi

# ── 7. The publish guard ────────────────────────────────────────────────────
sec "7. The publish guard — guard-publish.sh asks before anything leaves the machine"
rule
# The cwd is a scratch repository with one commit and no remote, so the push
# reason describes that repository. The guard also reads this checkout's
# hooks.guard_publish.enabled and prunes its expired approval tokens.
# The guard reads a script the session runs for a hosting provider's
# management-API host beside a write signal; no line of this demo names such a host.
pubrepo="$scratch/pub"
mkrepo "$pubrepo" file.txt demo 'one commit'
publish_probe() {  # <mode> <command> <ASK|DENY|QUIET>
  local mode="$1" command="$2" want="$3" out got reason=""
  out="$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"permission_mode":sys.argv[2],"cwd":sys.argv[3]}))' \
    "$command" "$mode" "$pubrepo" | .agents/hooks/policy/guard-publish.sh)"
  if [[ -z "$out" ]]; then
    got=QUIET
    printf '  %sQUIET%s %-7s %s\n' "$grn" "$rst" "$mode" "$command"
  else
    IFS='|' read -r got reason <<<"$(python3 -c 'import json,sys
d = json.loads(sys.stdin.read())["hookSpecificOutput"]
print(d["permissionDecision"].upper() + "|" + d["permissionDecisionReason"])' <<<"$out")"
    local colour="$red"; [[ "$got" == ASK ]] && colour="$dim"
    printf '  %s%-5s%s %-7s %s\n        %s%s%s\n' "$colour" "$got" "$rst" "$mode" "$command" "$dim" "$reason" "$rst"
  fi
  expect 7 "$want" "$got" "$mode $command"
}
publish_probe default "git push origin main" ASK
publish_probe default "gh pr merge 12" ASK
publish_probe default "npm publish" ASK
publish_probe default "vercel deploy --prod" ASK
publish_probe default "git status" QUIET
publish_probe default "gh pr view 12" QUIET
printf '\n%sthe same push where no human can answer a prompt:%s\n' "$dim" "$rst"
publish_probe auto "git push origin main" DENY

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
# Each outcome must also say why: a policy that fails to load fails too, but
# names no refused command.
for name in acc-merge acc-list; do
  if [[ "$name" == acc-merge ]]; then
    want=FAIL; why='`gh pr merge 1` in system github, read: refused'
  else
    want=PASS; why='every command passes the guards'
  fi
  printf '%s$ access.py check  %s(%s)%s\n' "$dim" "$dim" "$(python3 -c 'import json,sys; print(", ".join(json.load(open(sys.argv[1]))["systems"][0]["read"]))' "$scratch/$name/.agents/policy.json")" "$rst"
  if out="$(python3 .agents/access.py check --repo "$scratch/$name" 2>&1)"; then
    got=PASS; verdict PASS "$out"
  else
    got=FAIL; verdict FAIL "${out#FAIL: }"
  fi
  expect 8 "$want" "$(saying "$got" "$out" "$why")" "$name"
done

# ── 9. A test that catches its bug ──────────────────────────────────────────
sec "9. A test that catches its bug — revert-check.sh"
rule
rcrepo="$scratch/rc"
mkrepo "$rcrepo" lib.txt bad 'the bug'
base="$(g -C "$rcrepo" rev-parse HEAD)"
printf 'good\n' > "$rcrepo/lib.txt"
printf '%s\n' '[[ "$(cat lib.txt)" == good ]] || { echo "assertion failed: lib.txt is not good"; exit 1; }' > "$rcrepo/asserts.sh"
printf '%s\n' 'test -f lib.txt' > "$rcrepo/imports.sh"
g -C "$rcrepo" add -A
g -C "$rcrepo" commit -qm 'the fix and its tests'
# revert-check also exits 1 when it cannot build its scratch worktree, so the
# weak test's verdict must carry its reason.
for t in asserts.sh imports.sh; do
  if [[ "$t" == asserts.sh ]]; then
    want="exit 0"; why='revert-check: pass:'
  else
    want="exit 1"; why='the test does not catch the defect'
  fi
  printf '%s$ revert-check.sh <bug commit> --tests %s -- bash %s%s\n' "$dim" "$t" "$t" "$rst"
  rc=0
  out="$(cd "$rcrepo" && "$repo/.agents/revert-check.sh" "$base" --tests "$t" -- bash "$t" 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]]; then verdict PASS "exit 0"; else verdict FAIL "exit $rc"; fi
  sed 's/^/    /' <<<"$out"
  expect 9 "$want" "$(saying "exit $rc" "$out" "$why")" "$t"
done

# ── 10. The completion gate ─────────────────────────────────────────────────
sec "10. The completion gate — workloop.py check names what blocks completion"
rule
wlrepo="$scratch/wl"
mkrepo "$wlrepo" src/app.txt a base
# --state and --repo keep the run out of this checkout's own worktrees and readouts.
wl() { python3 .agents/workloop.py --state "$scratch/workloop-state.json" "$@"; }
step() { printf '%s$ workloop.py %s%s\n' "$dim" "$*" "$rst"; }
gate() {  # <expected exit code> <text the verdict must print> <args...>: check exits 1 while blocked
  local want="$1" why="$2" out rc=0
  shift 2
  step "$@"
  out="$(wl "$@" 2>&1)" || rc=$?
  sed 's/^/  /' <<<"$out"
  expect 10 "exit $want" "$(saying "exit $rc" "$out" "$why")" "workloop.py $*"
}
wl init demo --objective 'ship one change' --acceptance 'reviewed, QA observed' \
  --repo "$wlrepo" --verify 'test -f src/app.txt' --lane solo --worker implementer \
  --path src >/dev/null
wl claim demo solo --agent demo-writer | sed 's/^/  /'
printf 'b\n' >> "$wlrepo/src/app.txt"
g -C "$wlrepo" commit -qam change
wl submit demo solo --evidence 'ran the change' | sed 's/^/  /'
gate 1 qa:missing check --recorded demo
mkdir "$wlrepo/docs"
printf 'accepted\n' > "$wlrepo/docs/review.md"
g -C "$wlrepo" add docs/review.md
g -C "$wlrepo" commit -qm 'review record'
tip="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runs"]["demo"]["lanes"]["solo"]["tip"])' "$scratch/workloop-state.json")"
wl review demo solo --reference docs/review.md --result accept --tip "$tip" | sed 's/^/  /'
wl qa demo --evidence 'scenario observed' | sed 's/^/  /'
gate 0 PASS check demo
printf 'c\n' >> "$wlrepo/src/app.txt"
g -C "$wlrepo" commit -qam 'a later change'
wl submit demo solo --evidence 'ran the later change' | sed 's/^/  /'
printf '%sthe tip moved, so the review and the QA record no longer cover it:%s\n' "$dim" "$rst"
gate 1 qa:stale check --recorded demo

printf '\n%s⊱ every line above is live output — no mocks, no slides ⊰%s\n' "$bold" "$rst"
if [[ $mismatch -ne 0 ]]; then
  printf 'one or more beats printed a result other than the expected one; each MISMATCH line above names it\n' >&2
  exit 1
fi
