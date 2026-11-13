# Agents that die mid-work are found, shown and resumed

Workflow: Build · Stakes: Critical (what decides whether a dead agent's unsaved
work is seen; a change to the lead's cell lifecycle wording and to the commit
line injected into every cell).

**Gate: closed for U1 to U3**, ruled by the operator on 2026-11-13: Decision
1 (b), 2 (a), 3 (a), 4 (a); the decisions stood in for the `grill-me`
interview. **U4 is out of this delivery**, ruled by the operator after spike
S7: Acceptance 10's lid test adds one background session, and U4 returns as
a new plan only if it survives.

The ask, verbatim (2026-11-13), after background agent U3 in the tax-appeals-app
console died when the Mac's lid closed and no one noticed for two days: "Just
improve our harness so that it doesn't let us suffer from such problems moving
forward. Think broadly about the class of problem we're facing, what parts of
our design contribute to it and what parts don't adequately manage the problems
mentioned. Don't overfixate on this machine and environment's characteristics.
[…] Simply solve the problem on the level of the fact that sleeps, crashes and
lost connections are expected THEN adapt and test the harness to the expected
hardware. (Macbook and Ubuntu server)". Earlier: "We don't need to fix anything
on tax-appeals-app."

## The class of problem

Work in flight belongs to a process that can end without notice: an agent's API
stream (sleep, network loss, stall, usage limit) or its session's process
(quit, closed terminal, SSH drop, crash, reboot). In the last 30 days 88
background agents on this machine ended without completing (E1): 40 vanished
with their session, 18 hit the usage limit, 15 were stopped on purpose, 10 died
in sleep, 4 lost the network, 1 stalled. Files on disk survive every one of
these. The harm is that the death is invisible, so the work is neither resumed
nor found.

What in the harness makes it worse:

1. **Liveness is learned only from a turn ending normally.** The record of
   running agents (`.cells-<session>`) changes only on `SubagentStart` and
   `SubagentStop` (H1). A death by API error fires `StopFailure`, which only
   the parallel-writers gate reads (H2), so the lead's "worker has stopped"
   note cannot fire for it (H3). And `SubagentStop` means "its turn ended", so
   a writer that ends its turn to wait on its own background command reads as
   `stopped` even when its session then dies under it (E6).
2. **Every record lives inside the harness's own hooks and dies with the
   session.** The per-session records are deleted at that session's next start
   and read by no other session (H5, H6). A lead launched where the harness's
   hooks do not run, as U3's was in the tax-appeals-app product folder, leaves no
   record at all (E10).
3. **Silence is a number, not a verdict** (H4).
4. **The remedy re-sends instead of resuming** (H7), though Claude Code resumes
   a failed or orphaned agent with its context by `SendMessage` (N2, P2).
5. **Supervision shares fate with what it supervises** (H13, N6).
6. **Writers hold edits uncommitted for hours** (H11, H12, E8), and the line
   injected into every cell forbids a lone writer's commits (H18).

What already holds: the worktree sweep saves a dirty worktree to a `saved/`
branch before removing it (H10); lane containers are reaped by label; the
workloop state file is durable.

The reframe that removes most of this: **Claude Code already keeps a durable
record of every agent, verdict included** (P1, P3, P6): its `meta.json` and
transcript, the parent session's notification of how it ended, and a registry
of live sessions. The harness keeps a weaker copy of that record and throws it
away. It should read Claude Code's record at the moments someone is listening,
and keep nothing of its own but the operator's dismissals.

## Findings the plan rests on

Read at `d4b96dc` by three fresh read-only cells (run `agent-death-research`)
and checked by hostile reviewers at `61944b1` and `2d1ea60` (run
`agent-deaths-plan`); probes P1-P11 run by the lead on 2026-11-13 with Claude
Code 2.1.322. From `d4b96dc` to `dfd211b` no cited path changed but
`.github/workflows/ci.yml`, which gained one step; H14 re-read. External rows
read 2026-11-13.

| # | Claim | Evidence | Status |
|---|---|---|---|
| H1 | `.cells-<session>` records `live` on `SubagentStart` and `stopped` on `SubagentStop`, nothing else | `.agents/hooks/lib/workloop-inbox.py:94-114` | observed |
| H2 | `StopFailure` is registered once, for subagents, running only `parallel-writers-gate.sh` | `.agents/claude/settings.json:539-550`; `parallel-writers-gate.sh:504-508` | observed |
| H3 | The "worker X has stopped without submitting" note and the lane's Docker reap fire only for a claimant in `.cells` that is not `live` | `workloop-inbox.py:117-124,212-221` | observed |
| H4 | "silent Nm" is wall-clock minutes since the newest stamp; nothing turns it into a verdict | `agent_silence.py:29-43`; `workloop-inbox.py:222-232` | observed |
| H5 | `session-start.sh` deletes this session's `.cells-*` and related files at a startup or resume; no session reads another's | `session-start.sh:103-113` | observed |
| H6 | An agent outside a run exists only in those session files | H5; `workloop-inbox.py:249-270` | observed |
| H7 | At a startup or resume the digest offers `returned --failed` or `brief --again`; nothing marks a cell failed by itself | `workloop-inbox.py:163-196` | observed |
| H8 | A cell's record does not store its agent id; the stamp hook binds a cell by the brief header in its transcript's first record, and writes `activity_at` into run state | `agent_activity.py:11-17,131-160` | observed |
| H10 | A session end or sweep saves a dirty worktree to `saved/<name>` before removing it; the sweep runs before the digest at a start | `worktree_sweep.py:225-236`; `session-start.sh:125,198` | observed |
| H11 | `working-practice.md` and `implementer.md` carry no commit rule | `working-practice.md:1-7`; `implementer.md:23` | observed |
| H12 | No hook judges uncommitted edits by age | `workloop_size.py:21-26` | observed |
| H13 | The supervision `/loop` is prose only | `skills/workloop/SKILL.md:380-386` | observed |
| H14 | Production hooks use `ps -o lstart=`, `lsof` and mkdir locks; none uses pmset, sysctl or /proc; CI runs on `ubuntu-latest` and has no green run | `rg` over `.agents`; `.github/workflows/ci.yml:22-25` | observed |
| H16 | Nothing prunes `.cells-*`: 32 files here, the oldest from 1 November | `ls .agents/.cells-*`; `worktree_heal.py:40` | observed |
| H17 | `edit-record.sh` writes `<epoch>\t<path>` per editor write, with no agent id, read by `session-wrap.sh`, `owed.py` and `session-start.sh` | `edit-record.sh:12-17`; `rg -l wrap-edits` | observed |
| H18 | Every cell is told "a cell commits only in its own workloop worktree", while a lone writer works and commits in the main checkout by the workloop guide and a recorded decision | `style-inject.sh:30`; `skills/workloop/SKILL.md:113,121-123`; `decisions.md:186` | observed |
| H19 | The inbox runs only where a run exists: `workloop-inbox.sh:62` exits without a state file, `session-start.sh:198` calls it only with one, `workloop-inbox.py:296` renders only `if runs`; `ended_runs` reads worktree records, not `.cells`; the showcase and the public tree carry copies of both files, checked by `port-public.py check` in the suite | the cited lines; `workloop-inbox.py:179-196`; `demo/scaffold-showcase.html:718,797-809`; `check-all.sh:72` | observed |
| N2 | A failed or stopped subagent resumes by `SendMessage` to its id, under the same id with its history | code.claude.com/docs/en/sub-agents | observed |
| N4 | `StopFailure` carries `error` (`rate_limit`, `server_error`, …) and `last_assistant_message` | code.claude.com/docs/en/hooks | observed |
| N6 | `/loop` and `CronCreate` are session-scoped | code.claude.com/docs/en/scheduled-tasks | observed |
| N7 | After a wake Claude Code treats the connection as broken: "Connection lost while your computer was asleep" | code.claude.com/docs/en/errors | observed |
| N8 | Each busy `claude` process holds `caffeinate -i -t 300`, which blocks idle sleep only | `ps`; `man caffeinate` | observed |
| P1 | A background agent whose connection is reset mid-stream fires `StopFailure` with its `agent_id`; its transcript's last record has `isApiErrorMessage: true` with `error` and `apiError` fields; its `meta.json` reads `finished: true` | probe S1, a local proxy cutting tunnels | observed |
| P2 | A session killed with SIGKILL fires no `SessionEnd`; `claude --resume` of it reports the agent "stopped: didn't finish before the previous session ended"; `SendMessage` resumes it under the same id | probe S2 | observed |
| P3 | Every session, headless included, registers `<config>/sessions/<pid>.json` with `sessionId`, `cwd`, `procStart` and `startedAt`; a clean exit removes it; on macOS `procStart` equals `LC_ALL=C TZ=UTC ps -o lstart=` of that pid, trimmed | lead's probe; reviewer, all 9 live entries | observed |
| P4 | `meta.json` holds `description`, `agentType`, `requestShape`, `toolUseId`, and `finished` (completed or failed) or `stoppedByUser` | meta files of U3, P1, E6 and P8 | observed |
| P5 | An agent's records carry its session's cwd, not where it worked: all 824 of U3's say `/Users/alice/Projects/tax-appeals-app`; its edits name the worktree | U3 transcript | observed |
| P6 | Claude Code writes its verdict on a background agent into the parent's transcript: a `queue-operation` `enqueue` record, timestamped, holding `<task-notification>` with `<task-id>` and `<status>` `completed`, `failed`, `killed` or `stopped`. A foreground agent's verdict is its `Agent` call's result, `toolUseResult.status` | parents of `a7537318…`, `a85b9c54…`, `adde0b41…` | observed |
| P7 | A stalled agent reads `finished: true` with no API-error record and its newest record a tool result; only the parent's `failed` notification, "stalled: no progress for 600s", says it failed | `a85b9c545b90192dc` (E7) | observed |
| P8 | A session quit leaves its agent unfinished, with `stoppedByUser: true` and a last record `[Request interrupted by user]`; the resumed session's notification says `stopped`. An agent stopped by `TaskStop` reads `killed`, unfinished, with no `stoppedByUser` | `a6a8864e0d71b312a`, `ad83173e42c6eac64`; P11 | observed |
| P9 | `claude --resume` keeps the session id; `startedAt` marks the current process: session `b8be798a` was quit at 15:48:16Z and its new process started at 15:48:19Z, leaving its agent unfinished | registry; `a6a8864e…` | observed |
| P10 | Claude Code computes `procStart` with `ps -o lstart= -p <pid>` under `LC_ALL=C TZ=UTC`, trimmed, on every platform but Windows | the 2.1.322 binary | observed in code; not run on Linux |
| P11 | Of 858 agents changed in 7 days, 813 read completed from their own files: `finished`, and the newest record answers their `SubagentHandback` call or is a final answer; for none does the parent hold a newer other verdict. Of the other 45 the parent says 27 completed, 4 failed (2 with no API-error record), 3 killed, 2 stopped; 9 have no verdict since their last work. A cold scan reading every parent took 2.1 s | throwaway scan | observed; P12 qualifies it |
| P12 | An agent that ends its turn waiting on its own background command gets a parent notification `completed` with the summary "is waiting on its own background work"; its `meta.json` reads `finished: true`, its newest record is a final answer, and its final turn holds a tool result with `toolUseResult.backgroundTaskId`. 57 parent transcripts here hold such notifications | spike `bg-spike`, session `4363d9f0`; `rg -c` over the store | observed |
| P13 | A restarted background session writes a notification with no `<status>`: "was restarted after the previous session ended"; the agent then resumes under the same id | spike, session `e951c686` | observed |
| P14 | Background sessions, 2.1.322: `claude --bg -- "<prompt>"` starts one; `claude agents --json --all`, `logs`, `stop`, `respawn`, `rm` manage them. Each has `<config>/jobs/<id>/state.json` with `state` (`running`, `blocked`, `done`, `failed`, `stopped`, `crashed`), `sessionId`, `resumeSessionId`, `respawnFlags`. SIGHUP to the launching shell leaves it running. After SIGKILL the supervisor respawned it within about 1 s once (S6), and in three runs of S7 it settled `stopped` and the account's transient supervisor exited 5 s later; `claude stop` sets `stopped`, and `claude respawn` resumes it with its subagent under the same id. The commit, push and draft-PR behaviour is system-prompt text for a session that entered a worktree; with `worktree.bgIsolation: "none"` one run edited in place and made no worktree, commit or push. No setting turns off push or PR as such | spike `bg-spike` (8 sessions in a scratch repository with a local remote); the 2.1.322 binary | observed; one sample per run |
| P15 | This machine already holds 11 background-session jobs from the operator's own work; one records a push to a GitHub remote | `~/.claude-personal/jobs/*/state.json` | observed |
| P16 | `/bg` on a session with a background subagent out asks "1 local agent will be stopped"; going ahead kills it (exit 137), forks a new session id whose transcript copies the old one, and the new transcript gets `failed`, "didn't finish before the previous session ended". A background session runs in `default` permission mode: it waits `blocked` on every prompt, a Write and the publish guard's ask on `git push` included, until someone attaches and answers; the push did not leave the machine | spike S7 (`bg-spike-2`), a scratch clone with a local remote | observed |
| P17 | A background subagent waiting on a permission prompt in an ordinary session is named only by the `PermissionRequest` hook payload (`agent_id`, `agent_type`, `tool_name`, `tool_input`, no `tool_use_id`), which fires as the prompt opens. Its transcript ends on the `tool_use` with no result, as a running command's does; `meta.json`, the parent's transcript and the `Notification` hook (`permission_prompt`, "Claude needs your permission", no agent) record nothing that names it. An answer fires no hook of its own; the agent's next `PostToolUse` or its `SubagentStop` follows | spike S8, two agents in a scratch repository with logging hooks | observed |
| P18 | With the lid closed on battery the Mac dark-wakes every 15-20 minutes for a few seconds; three cells of this session stalled together over the two sleeps 01:40-01:56Z and 01:58-02:16Z, and each carried on at the next wake: Claude Code resent the cut-off turn with an `isMeta` user record "Your response above was cut off mid-stream…", four times in S8's transcript. None died; the run's watch flagged S8 silent 16 and 18 minutes | `pmset -g log`; the cells' transcripts | observed |
| P19 | A background session held on a permission prompt reads `state: "working"`, `tempo: "blocked"`, with `needs` set, in its job's `state.json`, and `kind: "bg"`, `status: "waiting"` in the registry; this machine also holds older blocked jobs whose sessions are gone | lane `u1-waiting`'s live run, job `175e009d` | observed |
| E1 | 88 agents in 30 days ended without completing: 40 session ended, 18 usage limit, 15 stopped by their parent, 10 sleep, 4 no network, 1 stall | cell scan of parent transcripts | observed |
| E4 | A sleep death reaches the parent at a dark wake, up to 460 min after the agent's last work | U3 transcript; `pmset -g log` | observed |
| E5 | U3's parent got the failure at 04:36Z, began a reply, its own turn died at 07:40Z, and it stayed open but idle | `2f0a4771-….jsonl:3675-3699` | observed |
| E6 | `mcp-bundle-ship`'s claimant ended its turn to wait on its own `suite.sh` run; `.cells` recorded it `stopped`; its session exited and the lane still reads active | session `14638b08`; `.cells-14638b08…` | observed |
| E7 | A stalled agent resumed by message at once went on to finish | food-app-core `a85b9c545b90192dc` | observed |
| E8 | Of 14 failed agents that edited files, 6 made no commit | cell transcript scan | observed |
| E10 | U3's lead ran in `/Users/alice/Projects/tax-appeals-app`, which is no git repository; 11 of about 50 transcripts with a death notice ran in such product folders | `git -C`, `rg -l` | observed |
| E11 | 856 agent `meta.json` files changed in the last 7 days; listing them takes 0.06 s | `fd --changed-within 7d` | observed |
| E12 | Three tax-appeals-app repositories say "Commit and push only when asked" | `tax-appeals-console/AGENTS.md:136` and two more | observed |
| E13 | The Contabo server has Claude Code 2.1.278 as root, logged in, last used 2026-09-19, with no live session | `ssh contabo-hop ls` | observed |
| B1 | A background session (`claude --bg`, `/bg`, seen in `claude agents`) keeps working after its terminal closes, is preserved across sleep, and stops at shutdown; within 48 h a reply or attach restarts it | code.claude.com/docs/en/agent-view | observed |
| B2 | A background session's background subagents carry over to its next process and resume on wake (2.1.198+) | agent-view | observed |
| B3 | A background session moves into a `.claude/worktrees/` worktree before it edits and, on finish, commits, pushes its branch and opens a draft PR | agent-view | observed in the docs; not probed |
| B4 | The session registry and `meta.json` are undocumented; issues #100824 and #94872 ask for both | github.com/anthropics/claude-code | observed |
| B5 | Background sessions run on macOS and Linux and need a stored credential and a trusted workspace | agent-view, troubleshooting | observed |
| B6 | No command revokes a `claude setup-token` token; it is removed by hand under claude.ai settings, and users report revocation does not always take effect | issues #48373, #57400, #43801; third-party guides | observed in issues; not tried |

Re-opened by the lead: H1, H2, H3, H5, H7, H14; P1-P11 run by the lead.

**Constraints.** No hook wakes an idle lead (H13). SIGKILL and power loss fire
nothing (P2); SIGTERM fires `SessionEnd` `other`. Hook work stays small: the
state lock waits about 1 s, git calls share a 5 s budget. Hooks stay bash 3.2
compatible and run on Ubuntu (H14). Claude Code's record formats are not
documented (B4), so the reader fails loudly when a field it needs is missing
and checks its liveness rule against its own session before trusting it.
Decisions in force: `worktrees-end-with-their-session`,
`teardown-tiered-by-restart-cost`, `lane-resources-reaped-by-ownership`,
`runs-record-every-cell`, and the lone writer in the main tree
(`decisions.md:186`).

## Options

- **A, recommended: read Claude Code's own records.** At every session start
  and lead prompt, a reader takes the agents changed in the last 7 days, gives
  each Claude Code's own verdict where one exists and a liveness verdict where
  none does, and shows the dead ones that touched this repository. The harness
  writes nothing but a list of dismissals. It works wherever the lead was
  launched, hooks or not (E10).
- **B: a harness ledger written by hooks** (the first draft). It cannot see a
  lead the harness's hooks never ran in (E10), duplicates Claude Code's record,
  and needs its own pruning and host stamps.
- **C: an external supervisor** (a launchd or systemd timer). A sleeping Mac
  runs no timer, and Claude Code ships one already (B1).
- **D, prevention beside A: long unattended work runs as a background
  session** (B1, B2). It would absorb most sleep and session-ended deaths, but
  it pushes and opens a draft PR on finish (B3), which this repository's
  approval rule forbids without the operator's OK. The operator ruled it in
  as U4 (Decision 1 (b)), which probes and configures that first; A is needed
  either way, for deaths D does not prevent (shutdown, usage limit, network).

## Units

Built in order; each works end to end before the next starts.

### U1: every dead agent that touched this repository is shown until it is resumed, left nothing, or is dismissed

- **Reader.** New `.agents/hooks/lib/agent_deaths.py`. Inputs: every Claude
  config folder (`$CLAUDE_CONFIG_DIR` and each `~/.claude*`), each read once by
  its real path: its `projects/` root, the store, and its `sessions/`
  registry; and this checkout. Effects passed in as parameters.
- **Verdict per agent**, decided in this order; every agent gets exactly one.
  1. **Claude Code's verdict.** The newest `<task-notification>` for the agent
     in its parent's transcript, or a foreground agent's `Agent` call result
     (P6). When it is no older than the agent's newest user or assistant
     record, it decides: `completed`; `killed` → `stopped`, never shown;
     `failed` → `failed <cause>`; `stopped` → `lost` (P8). A `completed`
     notification saying the agent "is waiting on its own background work"
     (P12) and a notification with no status (P13) are no verdict.
  2. **The agent's own files**, when it has worked since any verdict or has
     none. `completed`: `finished`, its newest record answers its
     `SubagentHandback` call or is a final answer, and its final turn started
     no background command (P12). `failed <cause>`: `finished`, and its
     newest record has `isApiErrorMessage` (P1).
  3. **Liveness**, for the rest, which are in flight. `running` while its
     session is live and its newest record is later than the session's
     `startedAt` (P9); `lost` once either fails and both transcripts have been
     quiet for 10 minutes; `running` within those 10 minutes.
  - `stoppedByUser` decides nothing: it marks a session quit (P8).
  - Cost order: rule 2's `completed` test runs first and reads no parent; for
    none of 813 such agents did the parent hold a newer other verdict (P11).
    Parents are read only for the rest, from the byte offset the cache reached
    last time, since a transcript only grows.
  - A session is live when a registry entry in any config folder names it and
    `LC_ALL=C TZ=UTC ps -o lstart= -p <pid>`, trimmed, equals its `procStart`
    (P3, P10), which rejects a stale entry left by a kill. The reader first
    checks this against its own session. If its own entry is missing or does
    not match, it prints `agent deaths: cannot tell live sessions on this host
    (<why>)` and judges no agent `lost`.
  - The cause is the class in the API-error record's `error` and `apiError`
    fields (`rate_limit`, `computer_slept`, `connection_failed`, …), else the
    parent notification's summary, shortened (P7). An agent the parent marks
    `failed` after a resume reads "failed again after a resume".
  - `parked`: the agent would read `lost`, but its session is a background
    session whose job reads `state: "stopped"` in `<config>/jobs/<id>/
    state.json`, matched by `sessionId` or `resumeSessionId` (P14); the
    reader reads the file and runs no `claude` command. Shown with the remedy
    `claude respawn <id>`. A killed background session either respawns, and
    its agent's new records read `running`, or settles `stopped` and reads
    `parked` (P14).
- **Which agents a checkout shows.** An agent is this repository's when its
  parent session's cwd is inside this checkout or one of its worktrees, when
  any path it edited (its `Edit`, `Write`, `MultiEdit` and `NotebookEdit`
  calls) lies there (P5), or when it claims a lane or is bound to a cell of a
  run in this checkout. Agents whose transcript changed in the last 7 days are
  read, and an agent once shown stays in the cache, and shown, until it is
  resolved or dismissed, however old.
- **Shown.** At every session start and every lead prompt, and in the
  statusline readout, one line per dead agent that left something: uncommitted
  edits; a `saved/<name>` branch the worktree sweep made that holds any of its
  edited paths (H10), named in the line; a claimed lane or a bound cell; or a
  failure in this very session. `AGENT DIED: "<description>" (<type>, <agent
  id>) <cause> at <local time>, session <id> (<live|ended>); <k> of its <n>
  edited files uncommitted in <worktree>; <remedy>`. Five at most, then "and N
  more". Dead agents that left nothing go into one summary line, "N agents
  that left nothing died this week". An agent whose leftovers get committed
  stops showing by itself.
- **Remedy.** Only the owning session re-sends. In the agent's own session:
  "resume it: `SendMessage` to <id>". From any other session: "resume session
  <id> (`claude --resume <id>` if it ended, or its open terminal) and message
  agent <id>; to send the work again instead, dismiss this first". Both end
  with `workloop.py dismiss <id> --reason '<why>'`.
- **Runs.** A lane whose claimant is `failed` or `lost` reads "<lane>'s worker
  <id> died (<cause>) without submitting: resume it, or release-stale <run>
  <lane>", and its labelled containers stay for the resume; a claimant that
  finished without submitting is reaped as today. A cell out whose agent died
  reads "cell <name>'s agent died (<cause>): resume it, or brief <run> <name>
  --again". The stamp hook writes the agent id onto a cell when it binds it
  (H8); hooks write only liveness fields, and the lead's commands still change
  run state.
- **Replaced.** `.cells-<session>` goes: its writer (`record_cell`), its
  reader (`dead_claimants`) and its delete in `session-start.sh:103-113` move
  to the reader; `ended_runs` reads worktree records and stays (H19). The
  inbox's three run-only gates lift so the reader runs in a checkout with no
  run: `workloop-inbox.sh:62`, `session-start.sh:198` and
  `workloop-inbox.py:296`. The showcase (`demo/scaffold-showcase.html`) and
  the public tree (`.agents/public/tree/`) are regenerated from the changed
  files. Lane 1 adds no hook event and no `settings.json` change; the
  waiting line's `PermissionRequest` registration is lane 2's.
- **Dismissals.** `workloop.py dismiss <agent-id> --reason '<why>'` appends,
  under an `fcntl` lock as `agent_activity.py` takes, to
  `.agents/.agents-dismissed` (gitignored, and listed in
  `.agents/export/gitignore-fragment`); a rewrite that drops entries older
  than 30 days holds the same lock. The verdict cache in `.agents/.readout/`
  is replaced atomically.
- **Cost.** N is about 860 agents (P11). Each is a `meta.json` read and a tail
  read back to its newest message record; parents and edited paths are read
  only for the 45 or so that are not plainly completed. Verdicts of agents
  whose files have not changed come from the cache. Runs: each session start
  and lead prompt: at most 95 lead prompts a day here in the last 7 days
  (2026-11-11) and 64 sessions in 7 days, so about 100 runs a day, about 4 s
  warm. Budget, measured in QA: 300 ms with an empty cache, 50 ms warm.
- **Lead behaviour.** The workloop guide's cell lifecycle (`SKILL.md:152-160`)
  says to resume a dead cell by `SendMessage` first and, under Decision 3, that
  the lead resumes a transient failure once without asking.
- **Waiting on you** (operator's ruling after S7). An agent stuck on a
  permission prompt is alive and silent, and rules 1-3 read it `running`
  (P16; the first U4 spike sat 20 minutes on the publish guard's ask). A
  live background session working in this checkout whose job is held on a
  prompt (P19) is shown as `WAITING ON YOU: "<description>" (<job id>) <its
  needs text, else its detail>; claude attach <id>`. For an agent inside an
  ordinary session only the `PermissionRequest` hook names it (P17), so lane
  `u1-waiting` registers one that records the session, the agent, the tool
  and its command in the gitignored `.agents/.readout/`. The agent shows
  `WAITING ON YOU: "<description>" (<agent id>) <tool>: <command>` until it
  writes a message record newer than the request (its tool result after an
  answer, its text after a deny) or its session ends; the run's watch names
  such a lane or cell waiting on the operator, not silent. A session that
  started before the hook was registered shows nothing new.
- **Lanes.** The first (`u1-reader`, landed at `49eb623`) built the reader,
  its wiring at each start and prompt, and the `.cells` removal. Two more ran
  at once on disjoint files and landed at `8ab2460`, with the showcase's
  `agent-waits` card at `906ab72`: `u1-waiting` builds the waiting line with its
  `PermissionRequest` hook and the watch's waiting cells (Acceptance 17);
  `u1-words` builds the readout's `died <cause>` (Acceptance 4's statusline
  half), the workloop guide's cell-lifecycle wording with its headless test
  (Acceptance 9 (a)), the `decisions.md` entry, and `.agents/README.md`'s
  inbox paragraph saying its toggle also carries the `AGENT DIED` lines at
  prompts (review finding 7).
- **Scope.** Claude Code only; Codex and Kimi keep today's behaviour.

### U2: writers commit as they go

- `working-practice.md` gains: "Commit each piece once its narrow acceptance
  passes: stage your lane's paths by path and commit on the branch of the tree
  your lane names, unless this repository says commits wait for the operator."
  As built (`7dff597`) it adds "before you start the next piece": under the
  line above, fresh implementers committed both pieces at the end in 4 of 4
  runs, and with the addition piece by piece in 2 of 2
  (`.agents/knowledge/research/2026-11-13-commit-as-you-go-wording.md`).
- The line `style-inject.sh:30` injects into every cell becomes: "Commits in
  the lead's tree are the lead's, except a lane's writer, which commits its
  lane's paths by path in the tree its lane names; a cell with no lane never
  commits." That matches the lone writer the workloop guide and
  `decisions.md:186` already describe (H18), and the injected line is the one
  that changes.
- At the tool batch of an agent that claimed a lane, the inbox hook reads that
  agent's new transcript records since its last check for edited paths, and
  runs `git status --porcelain -- <paths>` within the 5 s budget. When its
  oldest uncommitted edit is over 30 minutes old, it delivers, at most every
  30 minutes: `COMMIT: <n> of your edited files have been uncommitted since
  <time> (<m> min). Commit each piece whose acceptance passes, staging by
  path.` Edits come from the agent's transcript, as in U1, not from a second
  record (H17).
- `hooks.commit_nudge.enabled` in `policy.json`, on in
  `config.json.example`. A repository whose contract waits for the operator
  turns it off (E12), and the death report still names its uncommitted files.

### U3: tested on the hardware the harness runs on

- **Linux.** The touched hook tests, `test-workloop-inbox.sh`,
  `test-session-start.sh` and the reader's tests run in `ubuntu:24.04`
  under Docker. CI already runs them on `ubuntu-latest` and stays the merge
  gate in principle; it has no green run (H14), so the local container stands
  in until it does.
- **Real deaths on this Mac**, run by the agent: Acceptance 1, 3 and 15.
- **Real sleep**, run by the operator: Acceptance 10.
- **No real Linux session** (Decision 4 (a)): Acceptance 14 runs P10's
  `procStart` rule on Linux `ps` in the container, and the reader's self-check
  guards a real server.

### U4: long unattended work runs as a background session

**Out of this delivery** (operator, after S7): Acceptance 10's lid test adds
one background session with a writer out, and U4 returns as a new plan only
if it survives. The design that met its stop condition was:
the operator moves the lead to the background with `/bg` when its cells must
outlive their attention, `worktree.bgIsolation: "none"` keeps it in the
checkout, and the readout hints when to do it. Spikes S6 and S7 (P12-P16)
found:

- `/bg` kills the cells out (P16), so the hint would advise the one moment it
  destroys work; the design's stop condition, "`/bg` drops the cells out", is
  met.
- After SIGKILL the supervisor respawned the session once in four runs; in
  three it settled `stopped` (P14). `claude respawn <id>` resumed it each
  time, which U1's `parked` line already prints.
- What held: a background session ignores its terminal closing; with
  `bgIsolation: "none"` it edited in place and made no worktree, commit or
  push; the publish guard stopped its `git push` and nothing left the
  machine (P14, P16).
- A background session waits `blocked` on every permission prompt until
  someone attaches (P16), so a backgrounded lead in default mode stalls on
  its first ordinary write.
- Whether a background session's agents resume after a real sleep (B2) is
  documented, not observed.

### Test seams

- **Reader tests against a fixture store** (synthetic `meta.json`,
  transcripts, parent notifications and registry entries, fake `ps`). They
  catch verdict precedence, scoping, line text, run integration, the cache and
  the dismiss lock; they miss a format change in Claude Code's real records.
- **Headless and tmux-driven real sessions** (Acceptance 1, 3, 9, 15). They
  catch the real records and order; they miss a real sleep.
- **The Ubuntu container.** It catches GNU, procps and bash 5 differences; it
  misses a real Linux Claude Code session (Decision 4 (a)).
- **The operator's lid test.** It catches a real sleep end to end.

## Acceptance

1. A headless session in a scratch clone of this repository, with no workloop
   run, dispatches a background writer whose connection is then cut. The next
   session started there shows exactly one `AGENT DIED:` line with the agent's
   description, the cause class and `SendMessage to <agent id>` or the
   resume-session remedy.
2. A failed agent that is resumed and goes on working has no `AGENT DIED:`
   line at the next prompt.
3. A headless session dispatches a background writer and is SIGKILLed. A new
   session in the same checkout shows the agent as died, "session <id>
   (ended)", with `claude --resume <id>` and the dismiss command. After
   `claude --resume <id>` with no `SendMessage`, the line still shows. An
   agent of a live session that is running is never shown. An agent of a
   stopped background session reads `parked`, with `claude respawn <id>`.
4. A lane whose claimant died reads "<lane>'s worker <id> died (<cause>)
   without submitting" in the digest and `died <cause>` in the statusline
   readout, and its labelled containers stay; a claimant that finished
   without submitting is still reaped (the existing test stays green). A cell
   out whose agent died reads "cell <name>'s agent died (<cause>)". A lane
   whose claimant ended its turn waiting on a background command and whose
   session then ended reads as died (E6).
5. An agent launched from a session outside this repository that edited files
   in one of its worktrees is shown in this repository's sessions (E10).
6. A dead agent with 2 of its 3 edited files uncommitted says so; once they
   are committed it stops showing; one that edited nothing is counted in the
   summary line only.
7. With `hooks.commit_nudge.enabled` on, a lane's writer whose oldest
   uncommitted edit is over 30 minutes old gets one `COMMIT:` line at its next
   tool batch, none again within 30 minutes, and none once those files are
   committed; with it off, none.
8. `workloop.py dismiss <id> --reason '…'` removes the line from every later
   start and prompt; an id the reader does not know exits non-zero with "no
   agent <id> touched this checkout".
9. Contract wording, each in two fresh headless sessions on the model that
   reads it, graded from tool order: (a) a lead shown a cell that failed on a
   lost connection calls `SendMessage` to it before any `brief --again`; under
   Decision 3 (a) it does so without asking and does not resume an agent that
   reads "failed again after a resume"; (b) an `implementer` in a one-writer
   lane in the main checkout, given a two-piece task, commits the first piece
   by path before starting the second; (c) a generic cell with no lane, told
   to edit two files, commits nothing.
10. Operator, on the Mac: start a background writer on a long task, close the
    lid on battery for at least 20 minutes, open it and send a prompt. The
    `AGENT DIED:` line says it lost its connection while the computer slept,
    and `SendMessage` to it continues its work. In the same lid closing, a
    session started with `claude --bg` with a writer out: whether the writer
    finishes with no resume is U4's evidence.
11. In `ubuntu:24.04` the reader's tests, the touched hook tests,
    `test-workloop-inbox.sh` and `test-session-start.sh` pass.
12. With an empty cache the reader takes at most 300 ms over this machine's
    store, and at most 50 ms warm. Measured on lane `u1-reader`: 415 ms
    cold, 1,221 ms with a cold disk cache, 36-43 ms warm; the lead accepts
    the cold miss, since a checkout's cache is empty once.
13. `.agents/suite.sh` passes on the landed tree, `port-public.py check`
    included.
14. In the `ubuntu:24.04` container, the reader's self-check passes against a
    registry entry whose `procStart` was taken from that container's
    `LC_ALL=C TZ=UTC ps -o lstart=` for a live process, and prints the
    `cannot tell` line against a mismatched one.
15. On the Mac, an interactive session in a tmux pane dispatches a background
    writer and is ended, in three runs, by `/exit`, by Ctrl-C twice and by
    killing its pane (SIGHUP). Each time the next session shows the agent
    died, never as stopped.
16. Reader fixtures: an agent with `finished`, a tool result as its newest
    record and a parent `failed` "stalled" notification reads `failed`; a
    `killed` one is not shown; an agent of a live session whose newest record
    predates `startedAt` reads `lost`; a registry entry for the reader's own
    session whose `procStart` does not match prints the `cannot tell` line and
    no `lost`; a dead agent with uncommitted edits whose transcript is 8 days
    old is still shown; one whose worktree was saved names its `saved/`
    branch; two dismissals written at once both survive; an agent the parent
    marks `failed` after a resume reads "failed again after a resume"; an
    agent whose newest notification says it "is waiting on its own background
    work", and whose session then ended, reads `lost`; a status-less "was
    restarted" notification gives no verdict; an agent of a session whose
    job reads `stopped` reads `parked`.
17. A live background session in this checkout held on a prompt (P19) shows
    a `WAITING ON YOU:` line with its needs text and `claude attach <id>`, and
    none once it is
    answered; a background subagent of an ordinary session waiting on a
    permission prompt (a Bash command outside the allow list) shows one
    naming its tool and command within one prompt, the watch names its cell
    waiting, and the line is gone after the prompt is answered or denied.

## Lenses

- **Higher-level abstraction:** Claude Code already records every agent and
  its verdict durably; the harness reads that record instead of keeping a
  copy. This replaced the first draft's ledger and removed every new hook
  registration.
- **Irreducible constraints:** nothing fires at a kill or power loss (P2), no
  hook wakes an idle lead (H13), and the lead may run where the harness has no
  hooks (E10). So the facts must come from a record that exists regardless,
  read wherever the operator next works in the repository.
- **Carve at the joints:** how an agent ended is Claude Code's verdict (P6);
  whether an agent with no verdict is still running is liveness, read by one
  module; the delegation's state is the workloop run, changed by the lead's
  commands; hooks write only liveness fields (`activity_at`, a cell's agent
  id).
- **Principal architect:** delete `.cells-<session>` rather than keep a second
  liveness record beside the reader.
- **Implicit state machines:** Claude Code's own: launched → `completed` |
  `failed` | `killed` | `stopped`, and any of them → working again on a
  resume, which writes records newer than the verdict. The reader adds one
  machine for work with no verdict since: `running` → `lost` (session gone or
  replaced by a new process, then 10 quiet minutes) → `running` (resumed);
  `lost` → `parked` when a supervisor can restart it; dismissed. The writers
  gate keeps its own machine for edit permission (H2), filed below.
- **Concession drift:** no external alert, no automatic re-send, and reading
  only at a start or prompt mean a death while the operator is away is learned
  on return, in any session of the repository. That holds because the work
  survives on disk, the line names what was left, and the lead resumes
  transient failures once (Decision 3), counted from Claude Code's record so
  a lead that lost its context cannot resume a failing agent repeatedly.
  Declining Decision 2 (a) also leaves deaths of agents that never touched a
  harness repository unseen.

## Decisions for the operator

Ruled on 2026-11-13: 1 (b), 2 (a), 3 (a), 4 (a). After spike S7: U4 out of
this delivery and tested at the lid check; a waiting-on-you line added to U1.

1. **Approval of the plan, and whether background sessions join it.**
   - (a) Recommended: approve U1 to U3; background sessions for long
     unattended work (option D) become a follow-up unit that first probes and
     turns off their automatic push and draft PR (B3).
   - (b) Approve U1 to U3 and add option D as U4 now.
   - (c) Revise the plan first.
2. **Which sessions show a death.**
   - (a) Recommended: every session in a repository carrying the harness shows
     each dead agent that touched it, wherever its lead was launched. Nothing
     is installed outside the repository.
   - (b) Also every session anywhere on each machine, product folders
     included: a user-level hook in each machine's Claude settings runs the
     carrier's reader. An install step outside the repository, per machine.
3. **Whether the lead resumes a failed agent without asking.**
   - (a) Recommended: on a lost connection, a network error or a stall, the
     lead resumes the cell once by `SendMessage`; "failed again after a
     resume", a usage limit or a lost session goes to the operator.
   - (b) The lead only reports.
4. **How far the Ubuntu test goes.**
   - (a) Hook tests in an `ubuntu:24.04` container only. A wrong `procStart`
     rule on Linux would then show as the reader's `cannot tell` line, not as
     false deaths.
   - (b) Recommended: (a), plus one real Claude Code session in a `--rm`
     container, with a credential the operator creates for the run, kept in a
     0600 file outside the repository, mounted read-only and deleted after:
     an Anthropic Console API key (revoked at once in the Console; billed per
     token, cents for this run) or a `claude setup-token` token (uses the
     subscription; removed by hand under claude.ai settings, which users
     report does not always take effect, B6).
   - (c) (a), plus a real session on the Contabo server, where Claude Code
     2.1.278 is already logged in as root (E13): no new credential, but
     copying the branch there and upgrading Claude Code are remote writes
     needing their own approval, as root on the server that runs GitMu.

## Out of scope, reported

- A dead session's background servers and processes are not listed to the next
  session.
- The parallel-writers gate keeps its own liveness record (`.writers-live`);
  moving it to the reader is a change to a gate.
- A usage-limit death could be resumed at its reset time; that needs a
  scheduler outliving the session.
- `mcp-bundle-ship`'s lane reads active with a dead claimant (E6); its lead
  holds that run.
- 32 stale `.cells-*` files sit in this checkout (H16); they go with the code
  that writes them.

## Review

**Round 1** at sha256 `7287c743…7472` of the first draft (cell `plan-review`,
opus): 1 `P0`, 4 `P1`, 12 `P2`, all adopted. The `P0` (the plan missed U3
itself: its lead ran where no hook runs and stayed alive) gave option A, which
reads Claude Code's records and scopes by edited paths (E10, P5). The `P1`s
gave `finished` and liveness over `SubagentStop` (E6), a verdict a recovery
moves on, `hooks.commit_nudge.enabled` with the rule's exception (E12), and
Acceptance 9. The `P2`s gave corrected H16, the registry over host stamps,
the cost budget, the summary line, renumbered acceptance, edits read from the
transcript (H17), the restated joint, why the container stands in for CI, the
token's handling, the named consumers, re-sending by the owning session only,
and option D with `parked` (B1-B5).

**Round 2** at sha256 `d971b020…bdaf1` (cell `plan-review-2`, opus): 4 `P1`,
9 `P2`. The lead reproduced the three verdict `P1`s on this machine's records
before adopting them (P6-P9, P11).

1. `P1`, an unfinished agent of a resumed session reads `running`. Adopted:
   rule 1 reads the parent's `stopped` verdict and rule 3 compares the agent's
   newest record with `startedAt` (P9); Acceptance 3 and 16.
2. `P1`, a session quit is filed as a deliberate stop. Adopted: Claude Code's
   verdict decides, `killed` alone is `stopped`, and `stoppedByUser` decides
   nothing (P8); Acceptance 15.
3. `P1`, a stall reads `completed`. Adopted: rule 1 (P6, P7); Acceptance 16.
4. `P1`, the commit rule contradicts the injected line. Adopted: the injected
   line changes to match `decisions.md:186` (H18); Acceptance 9 (b) and (c).
5. `P2`, one store and `~/.claude*` registries only. Adopted: every config
   folder's store and registry, by real path.
6. `P2`, a Linux `procStart` mismatch reads as deaths. Adopted: the
   self-check and its `cannot tell` line; P10 read the rule from Claude Code's
   code, and Decision 4 (a) states what remains.
7. `P2`, causes by text and an unbounded resume loop. Adopted: the cause class
   from `error` and `apiError`, and "failed again after a resume".
8. `P2`, the 7-day window drops old deaths. Adopted: transcripts, not meta
   files, set the window, and a shown agent stays until resolved.
9. `P2`, the inbox's gates and copies. Adopted: H19, U1 Replaced, Acceptance
   1 and 13.
10. `P2`, the sweep's saved branch hides leftovers. Adopted: the `saved/`
    branch counts and is named.
11. `P2`, overlapping verdicts. Adopted: the ordered rules, "newest user or
    assistant record", and the 10-minute `running` catch-all.
12. `P2`, the token in the container's configuration. Adopted: Decision 4 (b)
    uses a mounted file and a `--rm` container, and names the revocation and
    its limit (B6).
13. `P2`, lost dismissals and cache writes. Adopted: the lock and the atomic
    replace.

The `P1` fixes land in U1 and U2, which round 2 covered, and no `P0` was
found, so no third round runs (`hostile-review.md:110-113`). The reviewer's
hand-off to QA stands: Acceptance 1 to 16 are unrun until U1 to U3 are built.
