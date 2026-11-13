# Agent deaths U1, lane 1: code review round 1

Unit U1 of `docs/handoff/2026-11-13-agent-deaths.md`, first lane
(`agent-deaths/u1-reader`): the reader that shows each background agent that
died having touched this checkout, from Claude Code's own records, at session
start and lead prompts, with `workloop.py dismiss`. One reviewer (opus) read
the scope whole and its seams, under the verbatim contract; Critical stakes,
since the lane changes the session-start and inbox hooks.

Covers: b7f8ca1..59886a0

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
| Sizes | Accepted: the test files follow one file per hook, as before the lane; the writer makes module-internal helpers private while in the files; the long signatures stay, each parameter being an effect or a read the caller owns |
