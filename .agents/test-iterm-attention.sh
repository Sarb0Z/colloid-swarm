#!/usr/bin/env bash
# Firing tests for the iTerm2 sidebar policy (hooks/policy/iterm-attention.sh,
# hooks/lib/iterm_attention.py), over a fixture checkout whose hooks are this
# repository's own and a fake it2 that keeps one tab's status: a script says
# what another writer wrote before each read, and set-status writes ours. Seams:
#   (a) the decision over fixture payloads and transcripts: precedence, gate
#       parsing with "+N more", the owed detail, the deaths first seen in this
#       turn, the turn's start and last message. Catches a wrong status or
#       detail; misses the writers' real race.
#   (b) the precondition with a scratch tab-state folder: no ITERM_SESSION_ID,
#       a `claude -p` session in a tab, another tab's session, the toggle off.
#       Catches a write from the wrong session, or an interpreter started where
#       none is needed; misses real tab records.
#   (c) the write protocol, twice. The watch alone, over a simulated tab and
#       clock, one case per native-writer pattern, each saying what it catches:
#       it has no wall-clock bound, and misses it2 itself. Then the policy
#       through the fake it2: the same patterns in call order, `background`,
#       turn_open null or set, it2 failing, Python crashing, and a death shown
#       only in the turn it is first seen. Both miss real timing and the real
#       writers, which QA reads in a real tab.
#   (d) the Stop and idle_prompt commands exactly as settings.json registers
#       them, through the adapter. Catches the registration and the
#       normalizer's fields.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR
unset CLAUDE_CONFIG_DIR CLAUDE_PROJECT_DIR ITERM_SESSION_ID CLAUDE_TAB_STATE_DIR ITERM_ATTENTION_IT2

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lib="$repo/.agents/hooks/lib"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }
export HOME="$scratch/home"
mkdir -p "$HOME"

# --- (a) the decision, imported --------------------------------------------
LIB="$lib" SCRATCH="$scratch" python3 - <<'PY' || fail "(a) the decision"
import json, os, sys
from pathlib import Path
sys.path.insert(0, os.environ["LIB"])
import iterm_attention as ia
scratch = Path(os.environ["SCRATCH"])

def check(got, want, what):
    if got != want:
        raise SystemExit(f"{what}: got {got!r}, want {want!r}")

def never():
    raise AssertionError("called although an earlier row decides")

message = ("Done with unit 2.\n\nneeds_confirmation: Operator OK on the spec — unit 3 waits — reply OK\n"
           "- `needs_confirmation: Push the branch — origin waits — say push`\n"
           "This line says no `needs_confirmation:` line is owed.\n"
           "needs_confirmation:   \n")
check(ia.gates_in(message), ["Operator OK on the spec", "Push the branch"], "two gates, a bullet in backticks")
check(ia.gates_in("`needs_confirmation: Rename the table`"), ["Rename the table"], "a whole gate line in backticks")
check(ia.gates_in("`needs_confirmation:` lines come last in a final message."), [], "prose about the marker is no gate")
check(ia.gates_in("needs_confirmation: Rename the table"), ["Rename the table"], "a gate with no dash")
check(ia.decide(ia.gates_in(message), never, never),
      ia.Plan("waiting", "decide: Operator OK on the spec (+1 more)"), "a gate outranks deaths and owed")
check(ia.decide([], lambda: ["Review the spec", "Read the logs"], never),
      ia.Plan("error", "agent died: Review the spec (+1 more)"), "a death of this turn outranks owed")
check(ia.decide([], lambda: [], lambda: "owed: review 2 · suite"), ia.Plan(None, "owed: review 2 · suite"), "owed")
check(ia.decide([], lambda: [], lambda: ""), None, "nothing to show")
long = ia.decide(["x" * 500] * 4, never, never).text
check((len(long), long.endswith("x… (+3 more)")), (ia.DETAIL_MAX, True), "a long gate is cut, the count kept")
check(ia.condense("a\n\n  b\tc"), "a b c", "whitespace runs as one space")

def status(state, detail="", turn=None):
    return {"status": state, "detail": detail, "turn_open": turn}

owed = ia.Plan(None, "owed: suite")
check(ia.write_args(owed, status("done")), ["--detail", "owed: suite"], "owed: the detail alone, the status kept")
check(ia.write_args(owed, status("background", "2 background tasks running")), None, "owed: nothing over background")
gate = ia.Plan("waiting", "decide: Base")
check(ia.write_args(gate, status("done")),
      ["--status", "waiting", "--dot-color", "#5f87ff", "--text-color", "#5f87ff", "--detail", "decide: Base"],
      "a gate: iTerm2's colors, no turn flag while it is null")
check(ia.write_args(gate, status("done", "", False))[-2:], ["--if-turn-open", "false"], "the turn flag once it is set")
check(ia.write_args(ia.Plan("error", "agent died: x"), status("background", "1 background task running"))[:4],
      ["--status", "error", "--dot-color", "#ff3b30"], "a death: iTerm2's error colors")


# --- (c) the watch, over a simulated tab and clock --------------------------
class Tab:
    """A tab that other writers write at scripted times, in seconds from the hook's start. A
    read takes 0.21 s, as on iTerm2 3.7.7, and answers with what the tab shows when it ends; a
    write of ours lands at once. `writes` keeps each of ours as (time, status, detail)."""
    def __init__(self, first, *script):
        self.now, self.state, self.script, self.reads, self.writes = 0.0, first, list(script), 0, []
    def clock(self):
        return self.now
    def sleep(self, seconds):
        self.now += seconds
    def read(self):
        self.now += 0.21
        self.reads += 1
        while self.script and self.script[0][0] <= self.now:
            self.state = self.script.pop(0)[1]
        return dict(self.state)
    def write(self, args):
        options = dict(zip(args[::2], args[1::2]))
        self.state = status(options.get("--status", self.state["status"]), options["--detail"], self.state["turn_open"])
        self.writes.append((round(self.now, 2), self.state["status"], self.state["detail"]))
    def watched(self, plan):
        ia.watch(plan, self.read, self.write, self.sleep, self.clock)
        return self

message = status("done", "Unit 2 is built. needs_confirmation: Base — unit 3 waits — reply OK")
ours = status("waiting", "decide: Base")

# (a) Catches a hook that waits for a second native write: on the harness checkout iTerm2's
# `done | <message>` is the last one.
tab = Tab(status("working"), (1.0, message)).watched(gate)
check(len(tab.writes), 1, f"(a) working, then done | <message> and nothing after: one write ({tab.writes})")
check((1.0 <= tab.writes[0][0] <= 2.0, tab.writes[0][1:], tab.state), (True, ("waiting", "decide: Base"), ours),
      f"(a) ours lands within about 1 s of the done, and stays ({tab.writes})")
check((tab.now <= 6.25, tab.reads <= 30), (True, True), f"(a) the last read starts within 6 s ({tab.reads} reads, {tab.now:.2f} s)")

# (b) Catches a single early write that Claude Code's clear then covers.
tab = Tab(message, (0.5, status("done"))).watched(gate)
check(([at > 0.5 for at, *_ in tab.writes], tab.state), ([False, True], ours),
      f"(b) done | <message>, cleared 0.5 s later: ours is written again after the clear ({tab.writes})")

# (c) Catches a status of the last turn read as this turn's write.
tab = Tab(status("waiting", "decide: Old gate"), (0.5, message)).watched(gate)
check(([at > 0.5 for at, *_ in tab.writes], tab.state), ([False, True], ours),
      f"(c) a stale gate of ours, then iTerm2's done | <message>: the plan over each ({tab.writes})")
tab = Tab(ours, (0.5, message)).watched(gate)
check(([at > 0.5 for at, *_ in tab.writes], tab.state), ([True], ours),
      f"(c) a stale status equal to the plan is not written over, iTerm2's done after it is ({tab.writes})")

# (d) Catches a watch that ends once the tab shows the plan: at idle_prompt iTerm2 writes late.
tab = Tab(ours, (1.0, status("done", "None"))).watched(gate)
check(([at > 1.0 for at, *_ in tab.writes], tab.state), ([True], ours),
      f"(d) at idle, ours covered by done | None: written again ({tab.writes})")
tab = Tab(ours).watched(gate)
check((tab.writes, tab.reads > 20), ([], True), f"(d) at idle with no other writer: watched, nothing written ({tab.reads} reads)")

# (e) Catches a write into the next turn, or over a question.
for what, live in [("working", status("working")), ("idle", status("idle")),
                   ("iTerm2's waiting", status("waiting", "Which base?")),
                   ("Claude Code's waiting", status("waiting", "answer: Which base? (main, staging)"))]:
    tab = Tab(message, (1.0, live), (2.0, status("done", "The next turn's end."))).watched(gate)
    check(([at < 1.0 for at, *_ in tab.writes], tab.now < 2.0), ([True], True),
          f"(e) {what} after a turn end: the watch stops, no write after it ({tab.writes}, ended at {tab.now:.2f} s)")

# (f) Catches an unbounded wait, and a write over a turn that never ended.
for what, live in [("working", status("working")), ("a question", status("waiting", "Which base?"))]:
    tab = Tab(live).watched(gate)
    check((tab.writes, tab.reads > 20, tab.now <= 6.25), ([], True, True),
          f"(f) {what} for 6 s, no turn end: nothing written ({tab.reads} reads, {tab.now:.2f} s)")

tab = Tab(status("done", "All checks pass.")).watched(owed)
check((tab.writes, tab.state), ([(0.21, "done", "owed: suite")], status("done", "owed: suite")),
      "owed: written once on done, then read as ours")
tab = Tab(status("done", "owed: review 1 · suite")).watched(owed)
check(tab.state, status("done", "owed: suite"), "an owed detail of the last turn is replaced by this turn's")
tab = Tab(status("background", "1 background task running")).watched(owed)
check(tab.writes, [], "owed: nothing over background, for the whole watch")
tab = Tab(status("done", "", False))
written = []
ia.watch(gate, tab.read, lambda args: (written.append(args), tab.write(args)), tab.sleep, tab.clock)
check([args[-2:] for args in written], [["--if-turn-open", "false"]], "the turn flag once a read shows one")

folder = scratch / "agents"
folder.mkdir()
for aid, description, shape in [("a1", "Review the spec", "background"), ("a2", "Read the logs", "background"),
                                ("a3", "Foreground cell", "foreground")]:
    (folder / f"agent-{aid}.jsonl").write_text("{}\n")
    (folder / f"agent-{aid}.meta.json").write_text(json.dumps(
        {"agentType": "general-purpose", "description": description, "requestShape": shape, "toolUseId": f"toolu_{aid}"}))
deaths = ia.session_deaths(["gone", "a1", "a2", "a3"], folder)
check(deaths, [("a1", "Review the spec"), ("a2", "Read the logs")],
      "this session's background agents, newest first; another session's and a foreground one left out")

seen = ia.first_seen({}, deaths[:1], "turn-1")
check((seen, ia.found_this_turn(seen, deaths[:1], "turn-1")), ({"a1": "turn-1"}, ["Review the spec"]), "found this turn")
seen = ia.first_seen(seen, deaths, "turn-2")
check((seen, ia.found_this_turn(seen, deaths, "turn-2")), ({"a1": "turn-1", "a2": "turn-2"}, ["Read the logs"]),
      "the next turn: only the death first seen in it")
check(ia.first_seen(seen, deaths[1:], "turn-3"), {"a2": "turn-2"}, "a death the reader no longer reports is dropped")

record = scratch / "seen"
check(ia.read_seen(record), {}, "no record yet")
ia.write_seen(record, {"a1": "turn-1"})
check(ia.read_seen(record), {"a1": "turn-1"}, "the record read back")
ia.write_seen(record, {})
check(record.exists(), False, "an empty record removes the file")
record.write_text("not json")
try:
    ia.read_seen(record)
    raise SystemExit("a corrupt record read as valid")
except ValueError:
    pass

def row(role, content, **extra):
    return json.dumps(dict({"type": role, "message": {"role": role, "content": content}}, **extra))

transcript = scratch / "t.jsonl"
transcript.write_text("\n".join([
    row("assistant", [{"type": "text", "text": "a greeting before any prompt"}]),
]) + "\n")
check(ia.last_turn(str(transcript)), ("start", "a greeting before any prompt"), "before any prompt")
transcript.write_text("\n".join([
    row("user", "start the work", uuid="u-1"),
    row("assistant", [{"type": "text", "text": "needs_confirmation: Old gate — x — y"}]),
    row("user", "go on", uuid="u-2"),
    row("assistant", [{"type": "text", "text": "Looking."}]),
    row("assistant", [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {}}]),
    row("user", [{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}]),
    row("assistant", [{"type": "text", "text": "Done.\nneeds_confirmation: New gate — a — b"}]),
    row("assistant", [{"type": "text", "text": "a cell's"}], isSidechain=True),
    json.dumps({"type": "system", "subtype": "stop_hook_summary"}),
    '{"type": "assist',
]) + "\n")
turn, last = ia.last_turn(str(transcript))
check((turn, ia.gates_in(last)), ("u-2", ["New gate"]), "the last turn's start and its last message")
with transcript.open("a") as stream:
    stream.write(row("user", "next prompt", uuid="u-3") + "\n")
check(ia.last_turn(str(transcript)), ("u-3", ""), "a turn with no assistant text yet has no message, not the last turn's")

# (g) Catches a turn keyed "start": Claude Code writes api-request-blob rows after the prompt,
# each with a message and a role, and no uuid or timestamp.
def blob(role, content):
    return json.dumps({"type": "api-request-blob", "sessionId": "s", "hash": "0c087e4d", "message": {"role": role, "content": content}})
with transcript.open("a") as stream:
    stream.write("\n".join([
        row("assistant", [{"type": "text", "text": "Done.\nneeds_confirmation: Newest gate — a — b"}]),
        blob("system", [{"type": "text", "text": "SessionStart hook additional context"}]),
        blob("user", "next prompt"),
        blob("user", [{"type": "text", "text": "<system-reminder>instructions</system-reminder>"}]),
        blob("assistant", [{"type": "text", "text": "needs_confirmation: A blob's gate — a — b"}]),
    ]) + "\n")
turn, last = ia.last_turn(str(transcript))
check((turn, ia.gates_in(last)), ("u-3", ["Newest gate"]), "(g) blob rows after the prompt: the turn is the prompt's uuid, the message the turn's own")
PY
ok "(a) precedence, gates with +N more, prose about the marker, the owed detail, deaths first seen this turn, the cap"
ok "(c) the watch on a simulated tab and clock: (a) one write after a lone done | <message>, (b) again after Claude Code's clear, (c) over a stale status of ours and then iTerm2's, (d) again at idle over done | None, (e) none after working, idle or a question, (f) none and an end by 6 s with no turn end"
ok "(a) (g) api-request-blob rows after the prompt: the turn key is the prompt's uuid"

# --- the fixture checkout, tab records and fake it2 --------------------------
fx="$scratch/checkout"
mkdir -p "$fx/.agents" "$fx/.claude/hooks"
git -C "$fx" init -q -b main
ln -s "$repo/.agents/hooks" "$fx/.agents/hooks"
ln -s "$repo/.agents/claude" "$fx/.agents/claude"
ln -s ../../.agents/claude/adapter.sh "$fx/.claude/hooks/adapter.sh"
printf '{"owed": {"suite": "true"}}\n' > "$fx/.agents/policy.json"
log="$fx/.agents/.readout/.iterm-attention.log"
project="$HOME/.claude/projects/-fixture"
mkdir -p "$project"

sid="11111111-2222-4333-8444-555555555555"
other_sid="99999999-8888-4777-8666-555555555555"
tab="AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
other_tab="FFFFFFFF-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
tabs="$scratch/tabs"
mkdir -p "$tabs"
record() {  # <tab> <session>: claude-tab-state's record of the tab's interactive Claude
  printf '{"account": "work", "session_id": "%s", "transcript_path": "", "cwd": "%s", "pid": 1, "lstart": ""}' \
    "$2" "$fx" > "$tabs/$1.claude.json"
}
record "$tab" "$sid"
owes() { printf '1\tnotes.md\n' > "$fx/.agents/.wrap-edits-$(printf '%s' "$1" | cksum | tr -d ' ')"; }
owes_nothing() { rm -f "$fx/.agents/.wrap-edits-$(printf '%s' "$1" | cksum | tr -d ' ')"; }

fake="$scratch/fake"
it2="$scratch/it2"
mkdir -p "$fake"
cat > "$it2" <<'SH'
#!/usr/bin/env bash
# A stand-in for iTerm2's it2 that keeps one tab's status in $IT2_FAKE/tab and logs each call.
# Line n of $IT2_FAKE/script is what another writer wrote before the nth get-status: a status
# as JSON, `-` or nothing for no write, FAIL for a read that fails. set-status writes ours.
printf '%s\n' "$*" >> "$IT2_FAKE/calls"
case "$2" in
  get-status)
    n=$(( $(cat "$IT2_FAKE/n" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$IT2_FAKE/n"
    wrote="$(sed -n "${n}p" "$IT2_FAKE/script")"
    [[ "$wrote" != FAIL ]] || { echo "Error: Get status failed: No such session" >&2; exit 1; }
    [[ -z "$wrote" || "$wrote" == - ]] || printf '%s\n' "$wrote" > "$IT2_FAKE/tab"
    cat "$IT2_FAKE/tab" ;;
  set-status)
    [[ ! -e "$IT2_FAKE/set-fails" ]] || { echo "Error: Set status failed" >&2; exit 1; }
    shift 4
    filter='.'
    while (( $# )); do
      case "$1" in
        --status) filter+=" | .status = \"$2\"" ;;
        --detail) filter+=' | .detail = $d'; detail="$2" ;;
      esac
      shift 2
    done
    jq -c --arg d "${detail:-}" "$filter" "$IT2_FAKE/tab" > "$IT2_FAKE/tab.new" && mv "$IT2_FAKE/tab.new" "$IT2_FAKE/tab"
    echo "Status set." ;;
esac
SH
chmod +x "$it2"
st() {  # <status> [<detail>] [<turn_open>]: a tab status, as get-status prints it
  jq -nc --arg s "$1" --arg d "${2:-}" --argjson t "${3:-null}" \
    '{status: $s, turn_open: $t, detail: (if $d == "" then null else $d end), text_color: "#ff9500", background_tasks: 0, dot_color: "#ff9500"}'
}
# <what another writer wrote before each read>...: after them comes one read with no write,
# then the next turn's `working`, which ends a watch that has seen a turn end.
tab_shows() { rm -f "$fake/calls" "$fake/n" "$fake/set-fails" "$fake/tab"; printf '%s\n' "$@" - "$(st working)" > "$fake/script"; }
calls() { cat "$fake/calls" 2>/dev/null || true; }
order() { calls | awk '{sub(/-status/, "", $2); printf "%s ", $2}'; }  # the calls in order: "get set get "
sets() { calls | grep '^session set-status ' || true; }

iterm="w0t0p0:$tab"
policy_env() { envs=(HOME="$HOME" PATH="$PATH" CLAUDE_TAB_STATE_DIR="$tabs" ITERM_ATTENTION_IT2="$it2" IT2_FAKE="$fake"); [[ -z "$iterm" ]] || envs+=(ITERM_SESSION_ID="$iterm"); }
policy() {  # <normalized payload>: the policy run as the adapter runs it; sets rc
  policy_env
  rc=0
  printf '%s' "$1" | env -i "${envs[@]}" bash "$fx/.agents/hooks/policy/iterm-attention.sh" >"$scratch/out" 2>"$scratch/err" || rc=$?
  [[ "$rc" -eq 0 && ! -s "$scratch/out" ]] || fail "the policy exited $rc or printed on stdout: $(cat "$scratch/out")"
}
best_ms() {  # <normalized payload>: the fastest of three policy runs, in milliseconds, for the report
  policy_env
  printf '%s' "$1" > "$scratch/payload"
  python3 - "$fx/.agents/hooks/policy/iterm-attention.sh" "$scratch/payload" "${envs[@]}" <<'PY'
import subprocess, sys, time
script, payload, *pairs = sys.argv[1:]
env = dict(pair.split("=", 1) for pair in pairs)
best = None
for _ in range(3):
    start = time.perf_counter()
    subprocess.run(["bash", script], stdin=open(payload), env=env, check=True, capture_output=True)
    best = min(best or 1e9, (time.perf_counter() - start) * 1000)
print(round(best))
PY
}
transcript_of() { printf '%s/%s.jsonl' "$project" "$1"; }
prompt() {  # <session> <turn uuid>: the user prompt that starts a turn, appended to the session's transcript
  jq -nc --arg u "$2" '{type: "user", uuid: $u, message: {role: "user", content: "go"}}' >> "$(transcript_of "$1")"
}
answer() {  # <session> <text>: the assistant's message, appended to the session's transcript
  jq -nc --arg m "$2" '{type: "assistant", message: {role: "assistant", content: [{type: "text", text: $m}]}}' >> "$(transcript_of "$1")"
}
stop() {  # <session> <message>
  jq -nc --arg p "$fx" --arg s "$1" --arg m "$2" --arg t "$(transcript_of "$1")" \
    '{project_dir: $p, event: "Stop", notification_type: "", session_id: $s, transcript_path: $t, last_assistant_message: $m}'
}
idle() {  # <session>
  jq -nc --arg p "$fx" --arg s "$1" --arg t "$(transcript_of "$1")" \
    '{project_dir: $p, event: "Notification", notification_type: "idle_prompt", session_id: $s, transcript_path: $t, last_assistant_message: ""}'
}
gate_message=$'Unit 2 is built.\nneeds_confirmation: Operator OK on the spec — unit 3 waits — reply OK\nneeds_confirmation: Push the branch — origin waits — say push'
gate_detail="decide: Operator OK on the spec (+1 more)"
iterm_done="$(st 'done' 'Unit 2 is built. needs_confirmation: Operator OK on the spec — unit 3 waits — reply OK needs_confirmation: Push the branch — origin waits — say push')"
waiting_set() {  # <detail>: the set-status line for a gate
  printf 'session set-status --session %s --status waiting --dot-color #5f87ff --text-color #5f87ff --detail %s' "$tab" "$1"
}
prompt "$sid" turn-1
answer "$sid" "$gate_message"

# --- (b) the precondition --------------------------------------------------
tab_shows "$(st 'done')"
owes "$sid"; owes "$other_sid"

iterm=""
policy "$(stop "$sid" "$gate_message")"
[[ -z "$(calls)" && ! -s "$scratch/err" ]] || fail "(b) with no ITERM_SESSION_ID it2 was called: $(calls)"
# Most hook runs are outside a tab, so that path must end before any interpreter starts.
mkdir -p "$scratch/bin"
printf '#!/bin/sh\ntouch "%s/python-ran"\nexit 1\n' "$scratch" > "$scratch/bin/python3"
chmod +x "$scratch/bin/python3"
stop "$sid" "$gate_message" | env -i HOME="$HOME" PATH="$scratch/bin:$PATH" ITERM_ATTENTION_IT2="$it2" IT2_FAKE="$fake" \
  bash "$fx/.agents/hooks/policy/iterm-attention.sh" 2>"$scratch/err" || fail "(b) the policy exited non-zero"
[[ ! -e "$scratch/python-ran" && ! -s "$scratch/err" ]] || fail "(b) with no ITERM_SESSION_ID the policy started python3"
ok "(b) no ITERM_SESSION_ID (a session outside iTerm2): no it2 call and no interpreter, exit 0, $(best_ms "$(stop "$sid" "$gate_message")") ms"

iterm="w0t0p0:$tab"
policy "$(stop "$other_sid" "$gate_message")"
[[ -z "$(calls)" && ! -s "$scratch/err" ]] || fail "(b) a session the tab's record does not name called it2: $(calls)"
ok "(b) a claude -p session in this tab (the record names the interactive one): no it2 call, $(best_ms "$(stop "$other_sid" "$gate_message")") ms"

iterm="w0t1p0:$other_tab"
policy "$(stop "$sid" "$gate_message")"
[[ -z "$(calls)" && ! -s "$scratch/err" ]] || fail "(b) a tab with no record called it2: $(calls)"
record "$other_tab" "$other_sid"
policy "$(stop "$sid" "$gate_message")"
[[ -z "$(calls)" && ! -s "$scratch/err" ]] || fail "(b) another tab's session called it2: $(calls)"
ok "(b) a tab with no record, and a tab whose record names another session: no it2 call, $(best_ms "$(stop "$sid" "$gate_message")") ms"

iterm="w0t0p0:$tab"
it2_real="$it2"; it2="$scratch/missing-it2"
policy "$(stop "$sid" "$gate_message")"
it2="$it2_real"
[[ ! -s "$scratch/err" && ! -e "$log" ]] || fail "(b) with no it2 the policy went on: $(cat "$scratch/err")"
printf '{"hooks": {"iterm_attention": {"enabled": false}}}\n' > "$fx/.agents/config.json"
policy "$(stop "$sid" "$gate_message")"
[[ -z "$(calls)" && ! -s "$scratch/err" ]] || fail "(b) hooks.iterm_attention.enabled false still ran: $(calls) $(cat "$scratch/err")"
printf 'not json\n' > "$fx/.agents/config.json"
policy "$(stop "$sid" "$gate_message")"
[[ -z "$(calls)" && "$(cat "$scratch/err")" == *"hooks.iterm_attention.enabled is unknown"* ]] \
  || fail "(b) an unparsed config.json: calls '$(calls)', stderr '$(cat "$scratch/err")'"
grep -q "session $sid Stop: policy.json or config.json does not parse" "$log" || fail "(b) the unparsed config left no log line"
rm "$fx/.agents/config.json"
ok "(b) no executable it2, the toggle off, and a config.json that does not parse (stderr and a log line): no it2 call"

# --- (c) the write protocol ------------------------------------------------
tab_shows "$(st working)" "$iterm_done"
policy "$(stop "$sid" "$gate_message")"
[[ "$(order)" == "get get set get get " && "$(sets)" == "$(waiting_set "$gate_detail")" ]] || fail "(c) Stop with a gate, iTerm2 the only other writer: $(calls)"
calls | grep -q -- "get-status --session $tab" || fail "(c) get-status did not name the tab's session"
ok "(c) Stop where iTerm2's done | <message> is the last native write: one waiting write with iTerm2's colors, right after it"

tab_shows "$(st working)" "$iterm_done" "$(st 'done')"
policy "$(stop "$sid" "$gate_message")"
[[ "$(order)" == "get get set get set get get " && "$(sets | uniq)" == "$(waiting_set "$gate_detail")" ]] || fail "(c) Stop with a gate, Claude Code clearing the detail: $(calls)"
ok "(c) Stop where Claude Code clears the detail after iTerm2's write: written over each"

tab_shows "$iterm_done" "$(st working)" "$(st 'done' 'The next turn is done.')"
policy "$(stop "$sid" "$gate_message")"
[[ "$(order)" == "get set get " ]] || fail "(c) working after a turn end: $(calls)"
ok "(c) working after a turn end: the watch stops, and the next turn's done gets no write"

tab_shows "$(st 'done' "" false)"
policy "$(stop "$sid" "$gate_message")"
[[ "$(sets)" == "$(waiting_set "$gate_detail") --if-turn-open false" ]] || fail "(c) turn_open false at Stop: $(sets)"
ok "(c) --if-turn-open false once the read shows a turn flag"

tab_shows "$(st working)" "$(st 'done' 'All checks pass.')"
policy "$(stop "$sid" "All checks pass.")"
[[ "$(sets)" == "session set-status --session $tab --detail owed: suite" && "$(order)" == "get get set get get " ]] || fail "(c) owed at Stop: $(calls)"
ok "(c) owed: 'owed: suite' as the detail over iTerm2's message, the status left as done"

tab_shows "$(st working)" "$(st background "1 background task running")"
policy "$(stop "$sid" "$gate_message")"
[[ "$(sets)" == "$(waiting_set "$gate_detail")" ]] || fail "(c) a gate over background: $(calls)"
tab_shows "$(st background "1 background task running")"
policy "$(stop "$sid" "All checks pass.")"
[[ "$(order)" == "get get get " ]] || fail "(c) owed over background: $(calls)"
ok "(c) a turn that ends with background work running: a gate goes over background, owed does not"

tab_shows "$(st waiting "$gate_detail")" "$(st 'done' None)"
policy "$(idle "$sid")"
[[ "$(order)" == "get get set get get " && "$(sets)" == "$(waiting_set "$gate_detail")" ]] || fail "(c) idle_prompt over its own gate: $(calls)"
ok "(c) idle_prompt: the gate read from the transcript is written again once iTerm2's done | None covers it"

owes_nothing "$sid"
tab_shows "$(st 'done')"
policy "$(stop "$sid" "All checks pass.")"
[[ -z "$(calls)" ]] || fail "(c) nothing to show still called it2: $(calls)"
ok "(c) no gate, no death, nothing owed: it2 is not called at all"

: > "$log"
tab_shows FAIL
policy "$(stop "$sid" "$gate_message")"
if ! { [[ -z "$(sets)" && "$(grep -c . "$log")" -eq 1 ]] && grep -q "it2 session get-status exited 1: Error: Get status failed" "$log"; }; then
  fail "(c) a failing get-status: calls '$(calls)', log '$(cat "$log")'"
fi
tab_shows "$(st 'done')"
touch "$fake/set-fails"
: > "$log"
policy "$(stop "$sid" "$gate_message")"
if ! { [[ "$(grep -c . "$log")" -eq 1 ]] && grep -q "it2 session set-status exited 1" "$log" && grep -q "set-status exited 1" "$scratch/err"; }; then
  fail "(c) a failing set-status: log '$(cat "$log")', stderr '$(cat "$scratch/err")'"
fi
: > "$log"
printf '#!/bin/sh\nexit 3\n' > "$scratch/bin/python3"
policy_env
stop "$sid" "$gate_message" | env -i "${envs[@]/#PATH=*/PATH=$scratch/bin:$PATH}" bash "$fx/.agents/hooks/policy/iterm-attention.sh" 2>"$scratch/err" \
  || fail "(c) a crashing interpreter made the policy exit non-zero"
if ! { [[ "$(grep -c . "$log")" -eq 1 ]] && grep -q "iterm_attention.py exited 3" "$log"; }; then
  fail "(c) a crash left no log line: '$(cat "$log")'"
fi
ok "(c) a failing get-status or set-status, or a crashing interpreter: exit 0, one log line and stderr, no write after a failed read"

# Background agents of a session that died, as Claude Code records them: a failure notice in
# the session's transcript, the agent's own transcript and meta beside it, in the fixture checkout.
dead_sid="dddddddd-2222-4333-8444-555555555555"
seen="$fx/.agents/.readout/.iterm-deaths-$dead_sid"
record "$tab" "$dead_sid"
owes "$dead_sid"
prompt "$dead_sid" turn-1
died() {  # <agent id> <description> <seconds ago it died>
  FX="$fx" PROJECT="$project" SID="$dead_sid" python3 - "$@" <<'PY'
import json, os, sys, time
from pathlib import Path
aid, description, ago = sys.argv[1], sys.argv[2], float(sys.argv[3])
project, sid, cwd = Path(os.environ["PROJECT"]), os.environ["SID"], os.environ["FX"]
def iso(at):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(at)) + ".000Z"
def line(record):
    return json.dumps(dict(record, cwd=cwd, sessionId=sid), separators=(",", ":")) + "\n"
now = time.time()
agents = project / sid / "subagents"
agents.mkdir(parents=True, exist_ok=True)
(agents / f"agent-{aid}.meta.json").write_text(json.dumps(
    {"agentType": "general-purpose", "description": description, "toolUseId": f"toolu_{aid}",
     "requestShape": "background", "finished": True}))
(agents / f"agent-{aid}.jsonl").write_text(
    line({"type": "user", "timestamp": iso(now - ago - 20), "agentId": aid, "message": {"role": "user", "content": "work"}}) +
    line({"type": "assistant", "timestamp": iso(now - ago - 10), "agentId": aid, "message": {"role": "assistant",
          "content": [{"type": "tool_use", "id": "u1", "name": "Read", "input": {"file_path": cwd}}]}}))
note = (f"<task-notification>\n<task-id>{aid}</task-id>\n<status>failed</status>\n"
        f"<summary>Agent \"{description}\" failed: overloaded (error type overloaded_error)</summary>\n</task-notification>")
with (project / f"{sid}.jsonl").open("a") as stream:
    stream.write(line({"type": "queue-operation", "operation": "enqueue", "timestamp": iso(now - ago), "content": note}))
PY
}
error_set() {  # <detail>
  printf 'session set-status --session %s --status error --dot-color #ff3b30 --text-color #ff3b30 --detail %s' "$tab" "$1"
}
died adead1 "Survey the hooks" 60
tab_shows "$(st 'done')"
policy "$(stop "$dead_sid" "All checks pass.")"
[[ "$(sets)" == "$(error_set "agent died: Survey the hooks")" ]] || fail "(c) a death found in this turn, at Stop: $(calls) $(cat "$scratch/err")"
tab_shows "$(st error "agent died: Survey the hooks")" "$(st 'done')"
policy "$(idle "$dead_sid")"
[[ "$(sets)" == "$(error_set "agent died: Survey the hooks")" ]] || fail "(c) the same death at idle_prompt: $(calls) $(cat "$scratch/err")"
[[ "$(jq -r .adead1 "$seen")" == turn-1 ]] || fail "(c) the first-seen record: $(cat "$seen")"
ok "(c) a death first seen in this turn shows at Stop and again at idle_prompt; the record keeps the turn it was found in"

prompt "$dead_sid" turn-2
tab_shows "$(st 'done')"
policy "$(stop "$dead_sid" "All checks pass.")"
[[ "$(sets)" == "session set-status --session $tab --detail owed: suite" ]] || fail "(c) the next turn's Stop: $(calls) $(cat "$scratch/err")"
died adead2 "Read the logs" 600
tab_shows "$(st 'done')"
policy "$(stop "$dead_sid" "All checks pass.")"
[[ "$(sets)" == "$(error_set "agent died: Read the logs")" ]] || fail "(c) a death found late: $(calls) $(cat "$scratch/err")"
ok "(c) the next turn shows owed instead; a death that happened earlier but is first seen now (as at --resume) shows in this turn alone"

prompt "$dead_sid" turn-3
printf 'not json' > "$seen"
: > "$log"
tab_shows "$(st 'done')"
policy "$(stop "$dead_sid" "All checks pass.")"
if ! { [[ "$(sets)" == "$(error_set "agent died: Survey the hooks (+1 more)")" ]] && grep -q "is read as empty" "$log"; }; then
  fail "(c) a corrupt record: $(calls), log '$(cat "$log")'"
fi
prompt "$dead_sid" turn-4
tab_shows "$(st 'done')"
policy "$(stop "$dead_sid" "All checks pass.")"
[[ "$(sets)" == "session set-status --session $tab --detail owed: suite" ]] || fail "(c) after a corrupt record, the next turn: $(calls)"
ok "(c) a corrupt first-seen record: one log line, its deaths show once, in that turn, and not in the next"
record "$tab" "$sid"
owes "$sid"

# --- (d) the commands settings.json registers, through the adapter ---------------
settings="$repo/.agents/claude/settings.json"
registered() {  # <event> <matcher or empty>: the one iterm-attention command of that group, async
  jq -r --arg e "$1" --arg m "$2" '[.hooks[$e][] | select((.matcher // "") == $m) | .hooks[]
    | select(.command | endswith("adapter.sh\" --agent main iterm-attention.sh")) | select(.async == true) | .command] | if length == 1 then .[0] else empty end' "$settings"
}
stop_cmd="$(registered Stop "")"
idle_cmd="$(registered Notification idle_prompt)"
[[ -n "$stop_cmd" && -n "$idle_cmd" ]] || fail "(d) settings.json must register iterm-attention.sh once, async, with --agent main, on Stop and Notification idle_prompt"
[[ "$(jq '[.. | strings | select(contains("iterm-attention.sh"))] | length' "$settings")" -eq 2 ]] \
  || fail "(d) iterm-attention.sh is registered somewhere else too"
fire() {  # <command> <raw Claude Code payload>
  policy_env
  rc=0
  printf '%s' "$2" | (cd "$fx" && env -i "${envs[@]}" CLAUDE_PROJECT_DIR="$fx" bash -c "$1") >"$scratch/out" 2>"$scratch/err" || rc=$?
  [[ "$rc" -eq 0 && ! -s "$scratch/out" ]] || fail "(d) the registered command exited $rc: $(cat "$scratch/out") $(cat "$scratch/err")"
}
raw_stop="$(jq -nc --arg s "$sid" --arg t "$(transcript_of "$sid")" --arg c "$fx" --arg m "$gate_message" \
  '{session_id: $s, transcript_path: $t, cwd: $c, permission_mode: "default", hook_event_name: "Stop", stop_hook_active: false, last_assistant_message: $m}')"
tab_shows "$(st working)" "$(st 'done')"
fire "$stop_cmd" "$raw_stop"
[[ "$(sets)" == "$(waiting_set "$gate_detail")" ]] || fail "(d) Stop through the adapter: $(calls) $(cat "$scratch/err")"
tab_shows "$(st working)" "$(st 'done')"
fire "$stop_cmd" "$(jq -c '. + {agent_id: "a1", agent_type: "general-purpose"}' <<<"$raw_stop")"
[[ -z "$(calls)" ]] || fail "(d) a subagent's Stop reached it2: $(calls)"
tab_shows "$(st waiting "$gate_detail")" "$(st 'done')"
fire "$idle_cmd" "$(jq -nc --arg s "$sid" --arg t "$(transcript_of "$sid")" --arg c "$fx" \
  '{session_id: $s, transcript_path: $t, cwd: $c, hook_event_name: "Notification", message: "Claude is waiting for your input", notification_type: "idle_prompt"}')"
[[ "$(sets)" == "$(waiting_set "$gate_detail")" ]] || fail "(d) idle_prompt through the adapter: $(calls) $(cat "$scratch/err")"
ok "(d) the Stop and idle_prompt commands settings.json registers write the gate; a subagent's Stop writes nothing"

fire_ms() {  # <command> <raw payload>: the fastest of three runs of a registered command, in milliseconds
  policy_env
  printf '%s' "$2" > "$scratch/raw"
  python3 - "$1" "$scratch/raw" "$fx" "${envs[@]}" <<'PY'
import subprocess, sys, time
command, payload, cwd, *pairs = sys.argv[1:]
env = dict((pair.split("=", 1) for pair in pairs), CLAUDE_PROJECT_DIR=cwd)
best = None
for _ in range(3):
    start = time.perf_counter()
    subprocess.run(["bash", "-c", command], stdin=open(payload), env=env, cwd=cwd, check=True, capture_output=True)
    best = min(best or 1e9, (time.perf_counter() - start) * 1000)
print(round(best))
PY
}
owes_nothing "$sid"
quiet_ms="$(fire_ms "$stop_cmd" "$(jq -c '.last_assistant_message = "All checks pass."' <<<"$raw_stop")")"
iterm=""
outside_ms="$(fire_ms "$stop_cmd" "$raw_stop")"
ok "(d) a registered Stop run, adapter and normalizer included: ${outside_ms} ms outside iTerm2, ${quiet_ms} ms in the tab with nothing to show (deaths and owed read); a run with something to show lasts as long as its watch"

printf 'PASS: iterm-attention\n'
