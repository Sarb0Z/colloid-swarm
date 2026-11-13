# Agent deaths U1, lane 1: code review round 1

Unit U1 of `docs/handoff/2026-11-13-agent-deaths.md`, first lane
(`agent-deaths/u1-reader`): the reader that shows each background agent that
died having touched this checkout, from Claude Code's own records, at session
start and lead prompts, with `workloop.py dismiss`. One reviewer (opus) read
the scope whole and its seams, under the verbatim contract; Critical stakes,
since the lane changes the session-start and inbox hooks.

Covers: b7f8ca1..34c8bba

## Findings

| # | Sev | Finding | Evidence |
|---|---|---|---|
| 1 | P1 | A Git call that fails during one read (`worktree list`, `for-each-ref` or `diff-tree` returns None) makes `edits_left` report no edits and `belongs` report another checkout; `show_dead` then caches the agent as committed or `ELSEWHERE`, and later reads never judge it again (`agent_deaths.py:137-138,168-170`, `agent_leftovers.py:59-69,102-110,130-147`) | inspection |
| 2 | P2 | A read inside a session while the registry cannot be trusted leaves lost and parked agents out of `shown` and still saves the cache, so agents kept only by `shown` drop out (`agent_deaths.py:174,197-199`) | inspection |
| 3 | P2 | Dismissals are keyed by agent id alone, so a dismissed agent that is resumed and dies again within 30 days is not shown (`agent_dismissals.py:34-35`, `agent_deaths.py:162`) | inspection |
| 4 | P2 | The lane removes the `.agents/.cells-*` ignore line and the worktree heal pattern while 32 such files remain in the main checkout and nothing deletes them; they turn untracked, and a worktree holding one is kept by the sweep (`.gitignore:18`, `export/gitignore-fragment:25`, `worktree_heal.py:40`) | live |
| 5 | P2 | `newest_messages` parses a transcript's unfinished last line; the ValueError drops the agent from `agents`, and `Parents.keep` drops its notifications while the parent's read position stays advanced, so a `failed` "stalled" notice read then is lost (`agent_records.py:144-159`, `agent_deaths.py:150-156`, `agent_verdicts.py:100-110`) | inspection |
| 6 | P2 | The SessionStart hook can run before Claude Code writes the session's registry entry (15-46 ms on three sessions here), so a start could print "cannot tell live sessions"; a `/clear` start is unmeasured (`agent_sessions.py:73-85`) | theoretical |
| 7 | P2 | `hooks.workloop_inbox.enabled=false` turns off `AGENT DIED` lines at prompts but not at starts, and nothing says so (`workloop-inbox.sh:61-62`, `session-start.sh:203`) | inspection |
| 8 | P2 | A third copy of the control-character pattern (`readout.py:53`, `agent_activity.py:53`, `agent_leftovers.py:21`); `mtime_ns` twice (`agent_records.py:97`, `agent_leftovers.py:37`); `agent_deaths.py` imports `subprocess` and `tempfile` beside its logic, against `stack-python.md` | inspection |
| 9 | P2 | The plan's U1 cost gives N and per-run cost but no runs per day | inspection |

Measurements the reviewer reported: test files over 300 lines
(`test-agent-deaths.sh` 502, `test-workloop-inbox.sh` 776,
`test-session-start.sh` 1040); modules over 12 public entries
(`agent_records.py` 18, `agent_deaths.py` 17, `workloop-inbox.py` 14,
`agent_activity.py` 14); signatures over 4 parameters (`judge` 6,
`agent_leftovers.line` 6, `leftovers` 5, `show_dead` 5, `active_note` 6,
`lead_block` 6, `deliver` 5, `stamp_agent` 7, already 7 before the lane). No
function over 40 lines, no nesting over 4.

QA against Acceptance, by the reviewer: fixtures support 2, 4 (the digest
half), 5, 6, 8 and 16; 1 and 3 were running in the QA cell; 4's status-line
half is lane 2's; 12 misses the 300 ms cold budget at 415 ms, which the plan
records as accepted; 13 has `run --verify`, not `.agents/suite.sh` on the
landed tree.

AMBIGUITY: U1 "shown until it is resumed, left nothing, or is dismissed" — (a)
a dismissal covers the death it was given for, and a death after a resume
shows again; (b) a dismissal silences the agent id for 30 days; code: b.

HANDOFF (reviewer): QA of Acceptance 1, 3 and 13 on the landed tree, plus a
`/clear` start and a `claude --resume` start whose block has no "cannot tell
live sessions" line (finding 6). Disprove pass on finding 1.

## QA round 1

An independent QA cell (sonnet) at `59886a0`, real `claude -p` sessions
(haiku) in a scratch clone with a local remote, over about four hours with
the Mac asleep on battery and waking for seconds every 15-20 minutes:

| Line | Run | Result |
|---|---|---|
| Suite | the four hook tests and `port-public.py check` from the lane | pass: 96 `ok`, "generated starters match the tree" |
| 8 live | `dismiss nosuchagent`; `dismiss <id>`; the next start and prompt | pass: exit 1 "no agent nosuchagent touched this checkout and died…"; exit 0; no line at either |
| 1 | a background writer edits a file and waits; the proxy cuts every tunnel at 01:31:24Z | unverified: the headless session's own 10-minute background-wait ceiling stopped the writer before a connection error (`[Request interrupted by user]`); a start at 03:35Z showed one line, "session ended", with the resume-session and dismiss remedies, right for what happened; a start at 01:57Z showed none, the session's records being under 10 minutes quiet (rule 3) |
| 4 live | `agent_deaths.py show <main checkout>` | fail from the command: "1 agent that left nothing died this week", since `show` passes no runs and, with no session, judges nothing lost and prints no self-check line; through the hook's path with a live session and the real runs: `AGENT DIED: "Implement bundle-only server shipping" (implementer, a869dfbeebb5c3eae) … it holds lane mcp-bundle-ship/ship …`, no cache written in the main checkout |
| 3, 15 | SIGKILL and resume; `/exit`, Ctrl-C twice, pane kill | not run: the auto-mode classifier gave no verdict on the launches three times running |

| # | Sev | Finding | Evidence |
|---|---|---|---|
| Q1 | P2 | `show` reads no workloop runs, so a held lane never shows from the command | live |
| Q2 | P2 | `show` with no session judges nothing lost and prints no "cannot tell live sessions" line, which reads as no deaths | live |

## Disprove pass

A QA cell (sonnet) ran finding 1 in a scratch clone at `59886a0`, through
the fixture tests' own Git seam (`agent_deaths.Effects(git=...)`), with one
Git subcommand made to return None on read A and real Git on reads B and B2,
over one store and one cache. The control, real Git on all three reads,
showed the agent's line each time.

| Trigger | Label | Reads A, B, B2 |
|---|---|---|
| `worktree list` fails, agent's edits uncommitted in a linked worktree | confirmed | no line on any read, the agent cached as committed; with the agent's folder outside the checkout, cached `ELSEWHERE` |
| `diff-tree` fails, agent's edits saved on `saved/gone-lane` | confirmed | no line on any read |
| `for-each-ref` fails, edits in a live worktree | refuted in that shape | line on every read; `for-each-ref` feeds only the `saved/` list, and the case with a saved branch is trigger 3's effect, not run |

## Dispositions

No P0. The lead settles the AMBIGUITY as (a): the plan's state machine moves
a lost agent back to running on a resume, and the operator's dismissal was of
one death.

| # | Disposition |
|---|---|
| 1 | Adopted, confirmed by the disprove pass: `edits_left` and `belongs` answer "unknown" when a Git answer they rest on is None; that answer writes neither `committed` nor `ELSEWHERE`, so the next read judges the agent again, and a line shown meanwhile says its uncommitted count is unknown; fixture rows fail `worktree list`, `for-each-ref` and `diff-tree` once and expect the line on the next read |
| 2 | Adopted: a read that cannot trust the registry carries forward the previous `shown` and `dead` entries it could not judge |
| 3 | Adopted with the AMBIGUITY's (a): a dismissal records the dismissed verdict's time and covers verdicts no newer than it |
| 4 | Adopted as the reviewer's first option: the three `.cells-*` patterns stay, since every checkout that ran the old code carries the files, and the lead deletes the 32 here at landing |
| 5 | Adopted: `newest_messages` skips a last line with no newline, and an agent whose read fails keeps its previous cache entry and notifications |
| 6 | Adopted as a QA line of the rerun: a `/clear` start and a `claude --resume` start |
| 7 | Adopted in lane 2, which edits `.agents/README.md`: its inbox paragraph says the toggle also carries the `AGENT DIED` lines at prompts |
| 8 | Adopted: one shared control-character pattern and one `mtime_ns`; the Git and temporary-file effects move to the entry point and reach the logic as parameters |
| 9 | Adopted in the plan: about 100 runs a day here (95 lead prompts on 2026-11-11 at most in 7 days; 64 sessions in 7 days), about 4 s a day warm |
| Q1, Q2 | Adopted into the correction cycle: `show` reads the runs as the hooks do, and with no session prints the self-check line |
| Q3 | Adopted: the final turn's start of a background command is read from the agent's own `tool_use` (`run_in_background: true`), which both session kinds write; a fixture row with a headless-shaped transcript (no `toolUseResult`); the reader over QA round 2's scratch store lists B and C as "session ended" |
| QA | Rerun on the corrected tip: line 1 with `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`, lines 3, 15, 4 and 8 live, finding 6's `/clear` and `--resume` starts, the suite |
| Sizes | Accepted: the test files follow one file per hook, as before the lane; the writer makes module-internal helpers private while in the files; the long signatures stay, each parameter being an effect or a read the caller owns |

## The fixes

The writer (opus) landed `bbac86f` (finding 4: the three `.cells-*`
patterns back) and `34c8bba` (findings 1, 2, 3, 5 and 8, the sizes line, Q1
and Q2, the showcase and public tree regenerated):

- 1: a Git subcommand with no answer leaves `belongs` undecided, cached
  `unknown`, and `edits_left` adds "N edited files, uncommitted count
  unknown", so `committed` is never written; the read prints "agent deaths:
  Git gave no answer to <subcommands>, so what rests on it is read again next
  time".
- 2: the cache's `dead` becomes `judged` (state, cause, time, job); a read
  that cannot judge an agent keeps its last verdict while the agent has
  written nothing newer.
- 3: a dismissal line is `<time>\t<id>\t<death time>\t<reason>`, and covers
  verdicts no newer than that death.
- 5: the text after a transcript's last newline is skipped; an agent whose
  read fails keeps its cache entry and its session's notifications.
- 8: `agent_effects.py` holds the clock, `ps`, Git, the atomic write and the
  `show` entry point; `agent_deaths.py` imports none of `subprocess`,
  `tempfile` or `time`; `CONTROL` comes from `readout.py`, `mtime_ns` from
  `agent_records.py`.
- Q1, Q2: `show` reads the runs not torn down from the state file, and with
  no session prints "cannot tell live sessions on this host (this read runs
  in no Claude Code session)".

| Claim | Run | Result |
|---|---|---|
| New rows | `test-agent-deaths.sh`: `git-unknown` (five scenes), `untrusted` (with `show` naming a held lane), `unfinished`, a death after a resume in the dismiss block | 21 ok; each new row fails with its fix removed |
| Hook tests | `test-workloop-inbox.sh`, `test-session-start.sh`, `test-workloop.sh`, `test-readout.sh` | pass (25 s, 61 s, 241 s) |
| Copies | `port-public.py check`, `demo/check-inventory.py` | match |

## QA round 2

A second independent QA cell (sonnet) at `34c8bba`, real sessions (haiku)
in a fresh scratch clone with a local remote, the Mac awake:

| Line | Run | Result |
|---|---|---|
| 1 | an interactive session behind the proxy dispatches a writer; the cut at 06:11:48Z; a second session starts with the first still live | pass: the parent showed "Connection dropped (ECONNRESET)"; one line, `AGENT DIED: "QA-A writer" (general-purpose, a689a0ed477f2fadb) connection_failed at … session baa4f670-… (live); 1 of its 1 edited files uncommitted in …; resume session … (its open terminal) and message agent a689a0ed477f2fadb; … dismiss: …`; the four writers then under 10 minutes quiet not shown |
| 3 | a headless session (background-wait ceiling raised) SIGKILLed at 06:16:55Z; a start at 06:31Z; `claude --resume <id> -p` with a prompt that does not message the agent; another start | pass: "session ended … (ended)" with `claude --resume <id>` and the dismiss command, still shown after the resume |
| 15 | interactive writers ended by `/exit` ("Exit and stop tasks"), Ctrl-C twice, `tmux kill-pane`; a start 13 minutes later | pass: all three shown as session ended, none as stopped |
| Finding 6 | a fresh interactive start, `/clear`, `claude --resume <id> -p` | pass: no "cannot tell live sessions" line in any |
| 4 live | `show <main checkout>`; the same with the lead's session id | pass: the self-check line "this read runs in no Claude Code session"; then `AGENT DIED: "Implement bundle-only server shipping" (implementer, a869dfbeebb5c3eae) session ended … it holds lane mcp-bundle-ship/ship …`; the cache it wrote in the main checkout deleted |
| 8 live | `dismiss nosuchagent`; `dismiss <F's id>`; the next start | pass: exit 1 "no agent nosuchagent touched this checkout and died…"; exit 0; F's line gone, the others shown |
| Suite | the four hook tests and `port-public.py check` from the lane | pass |

Not run: `/exit`'s other choice, "Move to background and exit", which is
`/bg` (P16) and goes to the operator's lid check.

The QA cell reported that two headless runs whose background-wait ceiling was
0 ended their writers, B and C, within 45 s and showed no line, and read that
as a clean stop. The lead read their records. Each wrote its file with
Write, started `python3 -c "import time; time.sleep(900)"` with
`run_in_background`, and ended its turn saying the sleep was still running.
The parent got `completed`, "is waiting on its own background work", and the
session's exit killed the sleep. The lane's reader run over the scratch
store at `34c8bba` lists A, D, E and G and leaves out B and C, with their
files uncommitted.

| # | Sev | Finding | Evidence |
|---|---|---|---|
| Q3 | P1 | A headless session (`entrypoint: sdk-cli`) writes no `toolUseResult` on its subagents' records (B: 2 tool results, none with one; the interactive A and E: 2 of 2), so `_waiting` (`agent_records.py:172-187`) never finds a `backgroundTaskId`; an agent that ended its turn waiting on its own background command reads as a final answer, rule 2 calls it `completed`, and its death with uncommitted work is never shown | live: `agent_deaths.py show <scratch repo> <session>` at `34c8bba` |
