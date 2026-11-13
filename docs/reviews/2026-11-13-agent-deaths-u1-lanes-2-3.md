# Agent deaths U1, lanes 2 and 3: code review round 1

The rest of unit U1 of `docs/handoff/2026-11-13-agent-deaths.md`, run
`agent-deaths-2`, two lanes on disjoint files from `49eb623` (lane 1 landed):
`u1-waiting` shows an agent stuck on a permission prompt, or a background
session held on one, as `WAITING ON YOU:` at prompts and starts and as
waiting in `workloop.py watch`, through a new `PermissionRequest` hook;
`u1-words` shows `<run>/<lane> died <cause>` in the statusline readout, tells
the lead in the workloop guide to resume a dead cell by `SendMessage` first,
and adds a `decisions.md` entry and README paragraphs. One reviewer (opus)
read both lanes whole and their seams with the landed reader, under the
verbatim contract; Critical stakes, since the lanes add a hook and change a
contract the lead follows.

Covers: 49eb623..9fb7184
Covers: 49eb623..a629263

## Findings

### Lane u1-waiting

| # | Sev | Finding | Evidence |
|---|---|---|---|
| 1 | P1 | A wait closes only on a newer user or assistant record or the session's end, and an approved command writes neither until it finishes, so the `WAITING ON YOU:` line and the watch's "waiting on the operator" stay up while an approved long command runs, and a command that then hangs is never reported silent (`agent_waits.py:119-128`, `workloop_messages.py:118-124`) | inspection |
| 2 | P2 | `claude --resume` keeps the session id, and the wait's liveness test ignores `startedAt`, so a wait open when its session was killed stays open for the resumed session's life, beside the agent's `AGENT DIED:` line (`agent_waits.py:122`, `agent_effects.py:78-88`) | inspection |
| 3 | P2 | `cmd_watch` calls `agent_effects.waiting` unguarded, so an unreadable `.agent-waits` or a transcript format change kills `workloop.py watch` with a traceback and every lane's silence check with it (`workloop_messages.py:118`) | inspection |
| 4 | P2 | A cell's `agent_id` is written at its first tool batch, which a prompted first call never reaches, so the watch reports such a cell `UNSTAMPED`, not waiting (`workloop_messages.py:104-110`, `agent_activity.py:135-152`) | inspection |
| 5 | P2 | The README paragraph says every lead prompt shows the line; with `hooks.workloop_inbox.enabled` off only session start does (`README.md:273`) | inspection |
| 6 | P2 | `readout.py prune` deletes non-`.json` files in `.readout/` older than 7 days by mtime, and the append-mode lock's mtime never moves, so the lock in use can be pruned and a second writer lock a new file (`agent_waits.py:93`, `readout.py:233-238`) | theoretical |
| 7 | P2 | `agent_effects.waiting` re-reads the registry and every job file and runs `ps` per open wait at each prompt, beside the death reader's own read; Acceptance 12's 50 ms warm budget is unmeasured with it | inspection |

### Lane u1-words

| # | Sev | Finding | Evidence |
|---|---|---|---|
| 8 | P1 | The guide's kept sentence "No cell outlives its session, so a cell still out at a startup or resume is named with `--failed` or `--again`", and the digest's same remedy (`workloop-inbox.py:149`), contradict the new paragraph: at a start inside the reader's 10-minute window the lead re-sends instead of resuming (`SKILL.md:158-160` against `:162-172`) | inspection |
| 9 | P1 | The paragraph makes `SendMessage` the first step for every `AGENT DIED:` line and allows `brief --again` or `release-stale` once it fails; for an agent of another session it always fails, so the lead re-sends while the owning session could still resume the original, against the plan's "only the owning session re-sends"; "or when the line says the agent cannot be resumed" matches nothing the reader prints (`SKILL.md:163-167`) | inspection |
| 10 | P2 | `judged_dead` and `death_segments` turn five exception types into empty, so a corrupt or reshaped cache silently drops every dead lane from the strip, while a bad readout shows `<name>: unreadable` (`agent_deaths.py:228-238`, `readout.py:184-194`) | inspection |
| 11 | P2 | The strip judges a cell dead without the digest's `out_since` filter, so after `brief --again` it keeps naming the earlier agent's death (`readout.py:199-208` against `agent_verdicts.dead_since`) | inspection |
| 12 | P2 | The resume-without-asking rule names `connection_failed`, "a network error" and "a stall", while the reader prints raw error classes; a sleep death's class is unobserved, so the lead must guess (`SKILL.md:167-171`) | inspection |

Measurements: `readout.py` 319 lines on u1-words (under 300 before);
`workloop-inbox.py` 299 on u1-waiting; already over 300 before the lanes:
`test-workloop.sh`, `session-start.sh`, `README.md`, `settings.json`,
`SKILL.md`, `decisions.md`; `normalize-hook.normalize` over 40 lines before
and 9 longer.

QA against Acceptance, by the reviewer: 17's background-session half has no
"none once answered" run; its subagent half rests on the writer's run with
no long approved command; 4's statusline half is fixture-only; 9 (a) ran the
paragraph alone, never the whole guide or an other-session line; the
writers report no run of the changed `test-workloop.sh`,
`test-session-start.sh` or `test-workloop-inbox.sh` beside their own tests
(u1-waiting's report does name all four).

AMBIGUITY: Acceptance 17 "the line is gone after the prompt is answered" —
(a) gone as soon as the operator answers; (b) gone once the answered call
writes its result; code: b.

HANDOFF (reviewer): QA of an approved `sleep 120` read during the sleep
(finding 1); a `claude --bg` job's line gone once answered; a killed and
resumed session with a waiting subagent (finding 2); the strip from a cache
the reader wrote live (Acceptance 4); warm prompt-hook timing with the wait
read (Acceptance 12, finding 7); the whole guide loaded with an
other-session line (findings 8, 9).

## QA round 1 and the disprove pass

An independent QA cell (sonnet) at `9fb7184` and `a629263`, real sessions in
scratch clones with a local remote (haiku for the sessions under test, Opus
for the wording):

| Line | Run | Result |
|---|---|---|
| 17, ordinary session | a run `qa-run` with cell `c1`; an interactive session's background subagent, bound to `c1`, prompted on `touch prompted.txt`; Yes, a deny, a kill | pass: the pane stayed on "Do you want to proceed?"; a second start showed `WAITING ON YOU: "touch probe" (a0e3d61be50924178) …`; `watch qa-run` printed `WAITING ON THE OPERATOR — qa-run/c1: its cell's agent waits on a permission prompt for 15s, Bash: …`; gone after the deny (the file never created) and after the kill |
| 17, background session | `claude --bg` job `f25326e9` held on `touch bgprompt.txt` | pass: `WAITING ON YOU: "touch bgprompt.txt" (f25326e9) approve Bash: touch bgprompt.txt; claude attach f25326e9` in the clone, none from the main checkout; gone after `claude attach` and Yes |
| 4, statusline half | `readout.py strip /Users/alice/Projects/colloid-swarm qa-session` from the u1-words lane, over the cache the landed reader wrote | pass: `1 agent out, oldest silent 888m  ·  mcp-bundle-ship/ship died session ended`; nothing written in the main checkout |
| 9 (a), whole guide | the lane's whole `SKILL.md` as a skill, a stub controller, Opus, one run per case | pass: case A, `SendMessage` to the id with no question before it, no `--again`; case B, no `SendMessage`, no `--again`, "this one is your call" |
| Suites | each lane's hook tests; `lint-decisions.py`, `lint-skills.sh` | pass |

| Finding | Probe | Label |
|---|---|---|
| 1 | `touch approved.txt && python3 -c "import time; time.sleep(150)"` approved at 07:35:23; read 43 s later | confirmed: the transcript stayed at 30 lines with a `tool_use` newest, `approved.txt` existed, a start still printed `WAITING ON YOU: "sleep probe" (acf8504ec8710c721) …` and `watch` "waits on a permission prompt for 1m"; both cleared once the command finished (37 lines) |
| 8 | case C, two Opus runs, whole guide: the digest's "1 cell out (trace); no cell outlives its session: returned … --failed '<why>', or brief … --again" and the cell's agent id, no `AGENT DIED:` line | refuted: both ran `SendMessage` to the id first and `returned … --failed` only after it failed ("No transcript found") |
| 9 | case D, two Opus runs, whole guide: an `AGENT DIED:` line naming session `s-other-77` | refuted: one sent one `SendMessage`, which failed, then told the operator to resume in `s-other-77` or choose to re-send; the other sent none and said the restart belongs in that terminal; neither ran `--again` or `release-stale` |

The QA cell killed the default tmux server with a `pkill -n -f "claude
--model haiku"` whose newest match was the server, taking another session's
`stopprobe` tmux session (cwd `/tmp/stop-attended.MdxegQ`) with it; the
operator is told.

## Dispositions

No P0. The lead settles the AMBIGUITY as (a): the operator's answer ends the
wait, since a running approved command is the agent working, and the silence
check must see it again.

| # | Disposition |
|---|---|
| 1 | Adopted, confirmed: a wait also closes when its session's registry entry reports a status other than waiting (`status`, `statusUpdatedAt`, which interactive and background entries both carry) updated after the request; the writer probes what the entry reads before and after an approval first, and a fixture row and the long-command scenario follow |
| 8 | Refuted in two runs; adopted as wording anyway, since the kept sentence and the paragraph still disagree on the page: the guide's sentence and the digest's remedy for cells out of an ended session point at their `AGENT DIED:` lines; to the operator's walk-through with case C's command |
| 9 | Refuted in two runs; adopted as wording anyway: a line naming another session is resumed in that session, and a re-send follows only a dismiss, as the line says; the unmatched condition goes; to the operator's walk-through with case D's command |
| 2 | Adopted: a wait closes when its session's registry entry started after it |
| 3 | Adopted: `cmd_watch` prints the reader's error on stderr and goes on with no waits |
| 4 | Adopted: `waiting_agents` binds an unbound cell by the brief header in the waiting agent's transcript, as the stamp hook does |
| 5 | Adopted in u1-waiting's paragraph |
| 6 | Adopted in u1-words: `prune` keeps `*.lock` |
| 7 | Adopted: the fix round measures the warm prompt hook on this machine's store; over 50 ms, `waiting` takes the death reader's registry, jobs and hosts instead of reading them again |
| 10 | Adopted: a missing cache is empty; any other failure shows `deaths: unreadable` in the strip |
| 11 | Adopted: `death_segments` uses `dead_since` with the cell's `out_since` |
| 12 | Adopted: the lead resumes once without asking for any cause but "failed again after a resume", a usage limit (`rate_limit`) and a lost session ("session ended", "session restarted"), which go to the operator |
| Sizes | Accepted: `readout.py` passes 300 by the strip's death join; the files already over 300 are outside these lanes' growth |
