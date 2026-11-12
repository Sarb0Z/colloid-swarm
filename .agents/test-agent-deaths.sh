#!/usr/bin/env bash
# Fixture tests for the agent-death reader (hooks/lib/agent_deaths.py): a
# synthetic Claude Code store (meta.json, agent and session transcripts, the
# session registry) and a fake `ps` drive its verdicts, its scope, its lines,
# its cache, and `workloop.py dismiss`. They miss a format change in Claude
# Code's real records; the real sessions of the plan's acceptance catch that.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }
export TZ=UTC

# The fixture library: a store under a scratch home, records built from
# relative times, and the reader called with fake effects.
cat > "$scratch/fx.py" <<'PY'
import json, os, subprocess, sys, time
from pathlib import Path

sys.path.insert(0, os.environ["LIB"])
import agent_deaths as ad  # noqa: E402
from workloop_size import GitBudget  # noqa: E402

NOW = time.time()
OWN = "own-session"
TRAILER = [{"type": "api-request", "id": "r"}, {"type": "attachment", "attachment": {"type": "x"}}]


def iso(at):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(at)) + ".000Z"


def compact(record):
    """A JSON line as Claude Code writes one, with no spaces between keys and values."""
    return json.dumps(record, separators=(",", ":"))


def prompt(at, text="do the task"):
    return {"type": "user", "timestamp": iso(at), "message": {"role": "user", "content": text}}


def call(at, name, tool_input, use):
    return {"type": "assistant", "timestamp": iso(at), "message": {"role": "assistant", "stop_reason": "tool_use",
            "content": [{"type": "tool_use", "id": use, "name": name, "input": tool_input}]}}


def result(at, use):
    return {"type": "user", "timestamp": iso(at), "message": {"role": "user",
            "content": [{"type": "tool_result", "tool_use_id": use, "content": "ok"}]}}


def answer(at, text="done"):
    return {"type": "assistant", "timestamp": iso(at), "message": {"role": "assistant", "stop_reason": "end_turn",
            "content": [{"type": "text", "text": text}]}}


def api_error(at, error, api):
    return {"type": "assistant", "timestamp": iso(at), "isApiErrorMessage": True, "error": error, "apiError": api,
            "message": {"role": "assistant", "content": [{"type": "text", "text": "API Error: Connection lost"}]}}


def edit(at, path, use):
    return call(at, "Edit", {"file_path": str(path), "old_string": "a", "new_string": "b"}, use)


def git(cwd, *args):
    subprocess.run(["git", "-C", str(cwd), "-c", "user.name=f", "-c", "user.email=f@x", *args], check=True, capture_output=True)


def checkout(path):
    """A Git checkout with three committed files."""
    path.mkdir(parents=True)
    git(path, "init", "-q", "-b", "main")
    for name in "abc":
        (path / f"{name}.txt").write_text(f"{name}\n")
    git(path, "add", ".")
    git(path, "commit", "-qm", "base")
    return path


class Store:
    def __init__(self, home):
        self.home = Path(home)
        self.project = self.home / ".claude" / "projects" / "-fixture"
        self.registry = self.home / ".claude" / "sessions"
        self.project.mkdir(parents=True, exist_ok=True)
        self.registry.mkdir(parents=True, exist_ok=True)
        self.starts = {}
        self.pids = 100

    def parent(self, sid):
        return self.project / f"{sid}.jsonl"

    def transcript(self, sid, aid):
        return self.project / sid / "subagents" / f"agent-{aid}.jsonl"

    def append(self, path, record):
        with open(path, "a") as stream:
            stream.write(compact(record) + "\n")

    def session(self, sid, cwd):
        (self.project / sid / "subagents").mkdir(parents=True, exist_ok=True)
        self.append(self.parent(sid), dict(prompt(NOW - 7200), cwd=str(cwd), sessionId=sid))

    def agent(self, sid, aid, records, cwd, description="fixture task", kind="implementer", background=True,
              finished=True, quiet=1200):
        meta = {"agentType": kind, "description": description, "toolUseId": f"toolu_{aid}",
                "requestShape": "background" if background else "foreground"}
        if finished:
            meta["finished"] = True
        path = self.transcript(sid, aid)
        path.with_name(f"agent-{aid}.meta.json").write_text(json.dumps(meta))
        path.write_text("".join(compact(dict(r, cwd=str(cwd), agentId=aid, sessionId=sid)) + "\n" for r in records + TRAILER))
        self.age(sid, aid, quiet)

    def extend(self, sid, aid, records, cwd, quiet=1200):
        """More records, appended as an agent that works again writes them."""
        for record in records + TRAILER:
            self.append(self.transcript(sid, aid), dict(record, cwd=str(cwd), agentId=aid, sessionId=sid))
        self.age(sid, aid, quiet)

    def age(self, sid, aid, seconds):
        """Both transcripts last written `seconds` ago."""
        for path in (self.transcript(sid, aid), self.parent(sid)):
            os.utime(path, (NOW - seconds, NOW - seconds))

    def note(self, sid, aid, status, summary, at):
        content = (f"<task-notification>\n<task-id>{aid}</task-id>\n<status>{status}</status>\n"
                   f"<summary>{summary}</summary>\n</task-notification>")
        self.append(self.parent(sid), {"type": "queue-operation", "operation": "enqueue", "timestamp": iso(at),
                                       "sessionId": sid, "content": content})

    def foreground_result(self, sid, aid, status, at):
        self.append(self.parent(sid), {"type": "user", "timestamp": iso(at), "toolUseResult": {"status": status, "agentId": aid},
                                       "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": f"toolu_{aid}"}]}})

    def register(self, sid, started, live=True, lstart=None):
        """A registry entry; the fake ps reports its start while `live`."""
        self.pids += 1
        stamp = f"Thu Jan  1 00:{self.pids // 60:02d}:{self.pids % 60:02d} 2026"
        entry = {"pid": self.pids, "sessionId": sid, "cwd": "/x", "procStart": stamp,
                 "startedAt": int(started * 1000), "kind": "interactive", "entrypoint": "cli", "pidDomain": "darwin"}
        (self.registry / f"{self.pids}.json").write_text(json.dumps(entry))
        if live:
            self.starts[self.pids] = lstart or stamp
        return self.pids

    def read(self, repo, own=OWN, runs=None):
        effects = ad.Effects(now=time.time(), home=self.home, config_dir="", proc_start=self.starts.get, git=GitBudget().out)
        return ad.report(Path(repo), own, runs or {}, effects)


def expect(condition, message, report=None):
    if not condition:
        detail = f"\n--- block ---\n{report.block(None, True)}\n--- verdicts ---\n{report.verdicts}" if report else ""
        sys.exit(f"FAIL: {message}{detail}")
PY
export LIB="$repo/.agents/hooks/lib" PYTHONPATH="$scratch"

case_dir() { local d="$scratch/$1"; mkdir -p "$d"; printf '%s' "$d"; }

# Acceptance 16: a stall the parent reports reads failed; a killed agent is
# never shown; an agent of a live session whose newest record predates that
# process's start reads lost; the reader's own session failing the liveness
# test prints the cannot-tell line and judges nothing lost.
d="$(case_dir verdicts)"
python3 - "$d" <<'PY' || exit 1
import sys
from pathlib import Path
from fx import *
d = Path(sys.argv[1]); store = Store(d / "home"); repo = checkout(d / "repo")
store.session(OWN, repo); store.register(OWN, NOW - 7200)
# finished, its newest record a tool result, and the parent's "stalled" failure
store.session("s-stall", repo)
store.agent("s-stall", "astall", [prompt(NOW - 3000), edit(NOW - 2900, repo / "a.txt", "u1"), result(NOW - 2890, "u1")], repo, description="stalled writer")
store.note("s-stall", "astall", "failed", 'Agent "stalled writer" failed: Agent stalled: no progress for 600s (stream watchdog did not recover)', NOW - 2000)
(repo / "a.txt").write_text("changed\n")
# stopped by its parent: killed, unfinished, interrupted
store.agent("s-stall", "akilled", [prompt(NOW - 3000), edit(NOW - 2900, repo / "b.txt", "u2"), result(NOW - 2890, "u2")], repo, finished=False)
store.note("s-stall", "akilled", "killed", 'Background agent "x" was stopped', NOW - 2500)
(repo / "b.txt").write_text("changed\n")
# a live session restarted under a new process after the agent's last record
store.session("s-restarted", repo); store.register("s-restarted", NOW - 1500)
store.agent("s-restarted", "aorphan", [prompt(NOW - 3000), edit(NOW - 2900, repo / "c.txt", "u3"), result(NOW - 2890, "u3")], repo, finished=False)
(repo / "c.txt").write_text("changed\n")
r = store.read(repo)
expect(r.verdicts["astall"].state == "failed" and r.verdicts["astall"].cause == "stalled", "a parent-reported stall did not read failed (stalled)", r)
expect(r.verdicts["akilled"].state == "stopped" and "akilled" not in r.block(None, True), "a killed agent was shown", r)
expect(r.verdicts["aorphan"] == r.verdicts["aorphan"].__class__("lost", "session restarted", r.verdicts["aorphan"].at), "an agent its restarted session left behind did not read lost", r)
expect('AGENT DIED: "stalled writer" (implementer, astall) stalled at' in r.block(None, True), "the stall's line is missing", r)
expect("1 of its 1 edited files uncommitted in" in r.lines[r.shown.index("astall")], "the stall's uncommitted file is not counted", r)
print("ok    a parent-reported stall reads failed, a killed agent is never shown, an agent its restarted session left reads lost")
# The reader's own registry entry does not match ps: nothing is judged lost.
store.starts = {pid: "Fri Feb  2 00:00:00 2026" for pid in store.starts}
r = store.read(repo)
expect(r.problems and r.problems[0].startswith("agent deaths: cannot tell live sessions on this host (ps gives 'Fri Feb  2 00:00:00 2026' for pid"), "a mismatched own entry did not print the cannot-tell line", r)
expect(r.verdicts["aorphan"].state == "unknown" and not any(v.state == "lost" for v in r.verdicts.values()), "an agent was judged lost on an untrusted host", r)
store.starts = {}
for path in store.registry.glob("*.json"):
    path.unlink()
r = store.read(repo)
expect(r.problems and "no session registry entry names this session, own-session" in r.problems[0], "a missing own entry did not print the cannot-tell line", r)
print("ok    an own registry entry that is missing or fails ps prints the cannot-tell line, and nothing reads lost")
PY

# Acceptance 2 and the remaining verdict sources: a failed agent resumed and
# working is not shown; an API error read from its own files is; a foreground
# agent takes its Agent call's result; a failure after a resume says so.
d="$(case_dir resumed)"
python3 - "$d" <<'PY' || exit 1
import sys
from pathlib import Path
from fx import *
d = Path(sys.argv[1]); store = Store(d / "home"); repo = checkout(d / "repo")
store.session(OWN, repo); store.register(OWN, NOW - 7200)
(repo / "a.txt").write_text("changed\n")
store.agent(OWN, "aresumed", [prompt(NOW - 3000), api_error(NOW - 2900, "server_error", "computer_slept"),
                              prompt(NOW - 60), edit(NOW - 50, repo / "a.txt", "u1"), result(NOW - 40, "u1")], repo, quiet=30)
store.note(OWN, "aresumed", "failed", 'Agent "x" failed: API Error: Your computer went to sleep (error type server_error)', NOW - 2800)
r = store.read(repo)
expect(r.verdicts["aresumed"].state == "running" and not r.lines, "a failed agent resumed and working was shown", r)
print("ok    a failed agent that was resumed and is working again is not shown")
store.agent(OWN, "aslept", [prompt(NOW - 3000), edit(NOW - 2950, repo / "a.txt", "u2"), result(NOW - 2940, "u2"),
                            api_error(NOW - 2900, "server_error", "computer_slept")], repo)
r = store.read(repo)
expect(r.verdicts["aslept"].state == "failed" and r.verdicts["aslept"].cause == "computer_slept", "an API error in its own files did not read failed (computer_slept)", r)
line = r.lines[r.shown.index("aslept")]
expect("session own-session (live)" in line and "resume it: SendMessage to aslept" in line and "dismiss: .agents/workloop.py dismiss aslept --reason '<why>'" in line,
       "the own session's line lacks its state or remedy", r)
print("ok    an API error record read from the agent's own files reads failed with its class, and the own session is told to SendMessage")
store.agent(OWN, "afore", [prompt(NOW - 3000), call(NOW - 2900, "Bash", {"command": "x"}, "u3")], repo, background=False, finished=False)
store.foreground_result(OWN, "afore", "completed", NOW - 2800)
store.agent(OWN, "aagain", [prompt(NOW - 3000), edit(NOW - 2900, repo / "b.txt", "u4"), result(NOW - 2890, "u4")], repo)
store.note(OWN, "aagain", "failed", 'Agent "x" failed: Agent stalled: no progress for 600s', NOW - 2700)
store.note(OWN, "aagain", "failed", 'Agent "x" failed: Agent stalled: no progress for 600s', NOW - 2600)
(repo / "b.txt").write_text("changed\n")
r = store.read(repo)
expect(r.verdicts["afore"].state == "completed", "a foreground agent's Agent result did not decide its verdict", r)
expect(r.verdicts["aagain"].cause == "failed again after a resume (stalled)", "a failure after a resume did not say so", r)
print("ok    a foreground agent takes its Agent call's result, and a failure after an earlier one reads failed again after a resume")
PY

# Acceptance 5 and 6: scope and leftovers.
d="$(case_dir scope)"
python3 - "$d" <<'PY' || exit 1
import sys
from pathlib import Path
from fx import *
d = Path(sys.argv[1]); store = Store(d / "home"); repo = checkout(d / "repo"); outside = d / "product"
outside.mkdir()
git(repo, "worktree", "add", "-q", "-b", "lane", str(d / "lane"))
store.session(OWN, repo); store.register(OWN, NOW - 7200)
# launched from a folder outside the repository, editing in one of its worktrees (E10)
store.session("s-outside", outside)
store.agent("s-outside", "aoutside", [prompt(NOW - 3000), edit(NOW - 2900, d / "lane" / "a.txt", "u1"), result(NOW - 2890, "u1")], outside)
(d / "lane" / "a.txt").write_text("changed\n")
# launched from outside, editing only outside: another checkout's agent
store.agent("s-outside", "astranger", [prompt(NOW - 3000), edit(NOW - 2900, outside / "x.txt", "u2"), result(NOW - 2890, "u2")], outside)
# two of its three edited files left uncommitted
store.session("s-gone", repo)
store.agent("s-gone", "atwo", [prompt(NOW - 3000), edit(NOW - 2900, repo / "a.txt", "u3"), result(NOW - 2890, "u3"),
                               edit(NOW - 2880, repo / "b.txt", "u4"), result(NOW - 2870, "u4"),
                               edit(NOW - 2860, repo / "c.txt", "u5"), result(NOW - 2850, "u5")], repo, description="two of three")
(repo / "a.txt").write_text("changed\n"); (repo / "b.txt").write_text("changed\n")
# edited nothing
store.agent("s-gone", "anothing", [prompt(NOW - 3000), call(NOW - 2900, "Read", {"file_path": str(repo / "a.txt")}, "u6")], repo, finished=False)
r = store.read(repo)
block = r.block(5, False)
expect("aoutside" in r.shown and f"1 of its 1 edited files uncommitted in {(d / 'lane').resolve()}" in r.lines[r.shown.index("aoutside")],
       "an agent from outside the repository that edited one of its worktrees was not shown", r)
expect("astranger" not in r.verdicts and "astranger" not in block, "another checkout's agent was judged here", r)
line = r.lines[r.shown.index("atwo")]
expect(f"2 of its 3 edited files uncommitted in {repo.resolve()}" in line, "two of three uncommitted files were not counted", r)
expect("session s-gone (ended)" in line and "resume session s-gone (`claude --resume s-gone`) and message agent atwo" in line, "an ended session's remedy is wrong", r)
expect("anothing" not in r.shown and "1 agent that left nothing died this week." in block, "an agent that edited nothing was not only counted", r)
print("ok    an agent from outside that edited a worktree is shown, another checkout's is not judged, 2 of 3 uncommitted files are counted")
git(repo, "add", "a.txt", "b.txt"); git(repo, "commit", "-qm", "theirs")
r = store.read(repo)
expect("atwo" not in r.shown and "2 agents that left nothing died this week." in r.block(5, True), "committed leftovers still showed", r)
print("ok    once its files are committed the agent stops showing and is counted")
PY

# Acceptance 16: a shown agent outlives the 7-day window; a saved branch is named.
d="$(case_dir retained)"
python3 - "$d" <<'PY' || exit 1
import sys
from pathlib import Path
from fx import *
d = Path(sys.argv[1]); store = Store(d / "home"); repo = checkout(d / "repo")
store.session(OWN, repo); store.register(OWN, NOW - 7200)
store.session("s-old", repo)
store.agent("s-old", "aold", [prompt(NOW - 3000), edit(NOW - 2900, repo / "a.txt", "u1"), result(NOW - 2890, "u1")], repo, finished=False)
(repo / "a.txt").write_text("changed\n")
expect(store.read(repo).shown == ["aold"], "the fresh dead agent was not shown")
store.age("s-old", "aold", 8 * 86400)
r = store.read(repo)
expect(r.shown == ["aold"], "a shown agent whose transcript is 8 days old dropped out", r)
print("ok    a dead agent with uncommitted edits stays shown after its transcript is 8 days old")
# A removed worktree's work saved on saved/<name>, as worktree_removal.py commits it.
gone = d / "gone-lane"
(repo / "a.txt").write_text("a\n")
tree = subprocess.run(["git", "-C", str(repo), "write-tree"], capture_output=True, text=True, check=True).stdout.strip()
git(repo, "update-index", "--add", "--cacheinfo", f"100644,{subprocess.run(['git', '-C', str(repo), 'hash-object', '-w', '--stdin'], input='saved\n', capture_output=True, text=True, check=True).stdout.strip()},x.txt")
tree = subprocess.run(["git", "-C", str(repo), "write-tree"], capture_output=True, text=True, check=True).stdout.strip()
git(repo, "read-tree", "HEAD")
commit = subprocess.run(["git", "-C", str(repo), "-c", "user.name=f", "-c", "user.email=f@x", "commit-tree", tree, "-p", "HEAD",
                         "-m", f"Save unsaved work from worktree {gone}\n\nCommitted when the session ended."],
                        capture_output=True, text=True, check=True).stdout.strip()
git(repo, "update-ref", "refs/heads/saved/gone-lane", commit)
store.session("s-saved", repo)
store.agent("s-saved", "asaved", [prompt(NOW - 3000), edit(NOW - 2900, gone / "x.txt", "u2"), result(NOW - 2890, "u2")], d / "elsewhere", finished=False)
r = store.read(repo)
expect("asaved" in r.shown and f"its edits in {os.path.realpath(gone)} were saved on saved/gone-lane" in r.lines[r.shown.index("asaved")],
       "the saved branch holding a dead agent's edits was not named", r)
print("ok    a dead agent whose worktree was saved names its saved/ branch")
PY

# The cache: a second read reuses it and still sees what was added since;
# the cap shows five lines and counts the rest.
d="$(case_dir cache)"
python3 - "$d" <<'PY' || exit 1
import sys
from pathlib import Path
from fx import *
d = Path(sys.argv[1]); store = Store(d / "home"); repo = checkout(d / "repo")
store.session(OWN, repo); store.register(OWN, NOW - 7200)
store.session("s-many", repo)
for n in range(6):
    store.agent("s-many", f"a{n}", [prompt(NOW - 3000), call(NOW - 2900 + n, "Bash", {"command": "x"}, f"u{n}")], repo, finished=False)
r = store.read(repo, own="s-many-not-registered")
expect(r.problems and "cannot tell" in r.problems[0], "an unregistered own session was trusted")
store.register("s-many-not-registered", NOW - 7200)
r = store.read(repo, own="s-many-not-registered")
expect(len(r.dead) == 6 and not r.lines, "six lost agents that left nothing were not counted", r)
# Only a running session writes its agents' files; a killed one leaves its entry, which ps rejects.
store.register("s-many", NOW - 7200, live=False)
store.extend("s-many", "a0", [edit(NOW - 2800, repo / "a.txt", "u9"), result(NOW - 2790, "u9")], repo)
(repo / "a.txt").write_text("changed\n")
for n in range(1, 6):
    store.extend("s-many", f"a{n}", [edit(NOW - 2800 + n, repo / "b.txt", f"v{n}"), result(NOW - 2790 + n, f"v{n}")], repo)
(repo / "b.txt").write_text("changed\n")
r = store.read(repo, own="s-many-not-registered")
block = r.block(5, False)
expect(len(r.lines) == 6, "changed transcripts were not read again", r)
expect(block.count("AGENT DIED:") == 6 and "AGENT DIED: and 1 more; every line: python3 .agents/hooks/lib/agent_deaths.py show" in block,
       "the sixth line was not cut to a count", r)
# Unreadable but unchanged transcripts: a read that opened them would name each as unreadable.
for n in range(6):
    store.transcript("s-many", f"a{n}").chmod(0)
r = store.read(repo, own="s-many-not-registered")
expect(not r.problems and len(r.lines) == 6, "an unchanged transcript was opened again", r)
for n in range(6):
    store.transcript("s-many", f"a{n}").chmod(0o644)
store.extend("s-many", "a3", [answer(NOW - 10)], repo)
store.note("s-many", "a3", "completed", 'Agent "fixture task" finished', NOW)
r = store.read(repo, own="s-many-not-registered")
expect("a3" not in r.dead and r.verdicts["a3"].state == "completed", "a verdict written since the last read was missed", r)
print("ok    a second read reuses the cache, rereads only what changed, and five lines are shown with the rest counted")
PY

# A record that lacks a field the reader needs is named, not skipped.
d="$(case_dir broken)"
python3 - "$d" <<'PY' || exit 1
import json, sys
from pathlib import Path
from fx import *
d = Path(sys.argv[1]); store = Store(d / "home"); repo = checkout(d / "repo")
store.session(OWN, repo); store.register(OWN, NOW - 7200)
store.agent(OWN, "abroken", [prompt(NOW - 3000)], repo, finished=False)
meta = store.transcript(OWN, "abroken").with_name("agent-abroken.meta.json")
meta.write_text(json.dumps({k: v for k, v in json.loads(meta.read_text()).items() if k != "description"}))
r = store.read(repo)
expect(any("agent abroken could not be read" in p and "has no description" in p for p in r.problems), "a meta.json without a description was not named", r)
print("ok    a record lacking a field the reader needs is named in the block")
PY

# Acceptance 8: dismissal from the command line, and two at once.
d="$(case_dir dismiss)"
python3 - "$d" <<'PY' || exit 1
import sys
from pathlib import Path
from fx import *
d = Path(sys.argv[1]); store = Store(d / "home"); repo = checkout(d / "repo")
store.session(OWN, repo); store.register(OWN, NOW - 7200)
store.session("s-gone", repo)
for aid, name in (("adone1", "a.txt"), ("adone2", "b.txt")):
    store.agent("s-gone", aid, [prompt(NOW - 3000), edit(NOW - 2900, repo / name, "u"), result(NOW - 2890, "u")], repo, finished=False)
    (repo / name).write_text("changed\n")
expect(sorted(store.read(repo).shown) == ["adone1", "adone2"], "both dead agents were not shown")
PY
fake_home="$d/home"; checkout="$d/repo"
mkdir -p "$checkout/.agents"
cp "$repo/.agents/workloop"*.py "$checkout/.agents/"
cp -R "$repo/.agents/hooks" "$checkout/.agents/"
dismiss() { (cd "$checkout" && HOME="$fake_home" python3 .agents/workloop.py dismiss "$@"); }
if out="$(dismiss anobody --reason 'not ours' 2>&1)"; then fail "an unknown agent was dismissed: $out"; fi
[[ "$out" == *"no agent anobody touched this checkout"* ]] || fail "the unknown agent's refusal is wrong: $out"
dismiss adone1 --reason 'superseded by lane two' > "$scratch/d1.out" 2>&1 &
dismiss adone2 --reason 'done by hand' > "$scratch/d2.out" 2>&1 &
wait
grep -q $'\tadone1\tsuperseded by lane two$' "$checkout/.agents/.agents-dismissed" || fail "the first of two dismissals at once was lost: $(cat "$checkout/.agents/.agents-dismissed" "$scratch"/d*.out)"
grep -q $'\tadone2\tdone by hand$' "$checkout/.agents/.agents-dismissed" || fail "the second of two dismissals at once was lost: $(cat "$checkout/.agents/.agents-dismissed" "$scratch"/d*.out)"
python3 - "$d" <<'PY' || exit 1
import sys
from pathlib import Path
from fx import *
d = Path(sys.argv[1]); store = Store(d / "home"); repo = d / "repo"
store.register(OWN, NOW - 7200)
r = store.read(repo)
expect(not r.lines and not r.dead, "a dismissed agent was shown again", r)
PY
python3 - "$checkout/.agents" <<'PY' || exit 1
import os, sys, time
from pathlib import Path
sys.path.insert(0, os.environ["LIB"])
import agent_dismissals
folder = Path(sys.argv[1])
old = time.strftime(agent_dismissals.STAMP, time.gmtime(time.time() - 31 * 86400))
with open(folder / agent_dismissals.FILE, "a") as stream:
    stream.write(f"{old}\taancient\told\n")
agent_dismissals.dismiss(folder, "anew", "fresh", time.time())
kept = agent_dismissals.dismissed(folder)
if "aancient" in kept or not {"adone1", "adone2", "anew"} <= kept:
    sys.exit(f"FAIL: the 30-day rewrite kept {sorted(kept)}")
PY
ok "dismiss refuses an agent that touched nothing here, two dismissals at once both survive, a dismissed agent is not shown, and entries past 30 days go"
