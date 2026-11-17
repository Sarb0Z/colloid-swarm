# Phone link spec: plan review rounds

Plan `docs/notes/2026-11-17-phone-link-spec.md`, before any implementation.
Critical stakes. One reviewer per round, a fresh cell that read the plan whole
against the repository, the machine files it cites and the external sources it
could reach. No code exists yet, so this record carries no `Covers:` line.

Tip: `fd2aac2`, with every finding of rounds 1–3 dispositioned. No round found
a `P0`, and round 3 covered every subsystem its fixes touch, so the fixes do
not reopen review (`hostile-review.md`).

## Round 1 (`99fd4e6`, spec sha256 `e4378a15…`, reviewer on `fable`)

`CONFORMANCE: no`. 9 `P1`, 14 `P2`, 2 ambiguities.

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | A typed gate answer could start with `!` (shell mode) or `/`, or hold a newline, so a phone message ran a command that no permission prompt sees | Adopted: one printable line of at most 500 characters, refused when it starts with `!`, `/`, `#` or `@` or holds a control byte; acceptance 16 |
| 2 | P1 | Any session registered a typing target from an inherited `ITERM_SESSION_ID` or `TMUX_PANE`, so a nested or child session's answer could be typed into the parent's tab | Adopted: typing only into a terminal session that passes the existing ownership test, checked again before typing; acceptance 18 |
| 3 | P1 | The typed line did not name its gate, and one message can hold several gates | Adopted: `Answer to "<gate text>": <text>`; acceptance 14 |
| 4 | P1 | `signal-cli`'s defaults print every chat's messages to stdout, keep attachments, and serve the last 1,000 events over HTTP to any local process | Adopted: the ignore flags, stdout discarded, and a `0700` socket by the operator's ruling R31; acceptance 7 |
| 5 | P1 | Sessions that cannot show a dialog would wait and could be approved, with no ruling | Ruled R32: any session, approvable |
| 6 | P1 | "The first answer wins" was measured only for an allow at the Mac; a deny at the Mac had no settle signal | Probed (L15): No and Esc stop the hook, the call does not run, and no hook fires; the link settles on the hook's closed socket; acceptance 5 |
| 7 | P1 | Only permission events had transitions; a question answered at the Mac blocked every later gate answer | Adopted: a transition table for each kind; `refused` is a reply, not a state |
| 8 | P1 | A gate key was alerted once a session and never forgotten, against R12 | Ruled R34: each turn's gate is a new event; acceptance 12 |
| 9 | P1 | The 590 s answer window had no ruling | Ruled R33: one hour, probed first (Q6) |
| 10 | P2 | Any tool event of the session settled a permission event | Adopted: settle on the hook's socket or the registry status (Q7) |
| 11 | P2 | Messages could replay after a wake or a reconnect | Adopted: the Signal timestamp is stored; duplicates act once, messages older than 15 minutes are refused; acceptance 10 |
| 12 | P2 | The session list was lost at a restart | Adopted: every hook line carries the session facts, and the list is kept in a file |
| 13 | P2 | Hook cost on every tool call was not stated | Adopted: no hook on every tool call unless Q7 fails; limits stated |
| 14 | P2 | The hooks would reach the satellites, with no default and no named files | Adopted: `hooks.phone_link.enabled` off by default, on in `config.json` only; parts and files named |
| 15 | P2 | The iTerm2 Python API added a second route | Adopted: `it2 session send`; Q3 covers sending |
| 16 | P2 | Cut before mask, no cut mark, no preview for tools other than Bash | Adopted: mask, then cut with a mark; a preview for each tool; acceptance 9 |
| 17 | P2 | `help` had no answering machine, and the handle rule disagreed with its examples | Adopted: the Mac answers; handle rule defined |
| 18 | P2 | A request held or dropped by Claude Code was reported as sent | Adopted: the inbox outcomes; acceptance 20 |
| 19 | P2 | Findings table: L6 overstated, L10 unprobed, L1–L3 uncited, parts missing | Adopted: rows corrected, Q8 added, the note cited, Constraints and Open questions added |
| 20 | P2 | No alternatives for the lead's choices, and R28's text changed without a note | Adopted: a decisions section, and R28 marks the lead's proposal for the operator's OK |
| 21 | P2 | 3a needed the server's daemon for Q2 and acceptance 7 | Adopted: those move to 3d; 3a lists its server prerequisite |
| 22 | P2 | No containment for an exit node that is down, and Undo left keys behind | Adopted: a containment line and both folders in Undo |
| 23 | P2 | The R30 shape was asserted, not shown | Adopted: one worked example for each feature |
| A1 | — | A gate restated in a later turn | Ruled R34 |
| A2 | — | Whether background cells' prompts count | Ruled R32 |

## Round 2 (`256fefe`, spec sha256 `d4e3f8b3…`, reviewer on `fable`)

`CONFORMANCE: no`. 4 `P1`, 15 `P2`, 3 ambiguities. The reviewer named one
class behind round 1's findings 2, 6, 7 and 10 and this round's 2, 3 and 4: the
link acted on a fact recorded earlier instead of the live state. The spec now
states a design principle against it, and the lead probed the two claims the
new design rests on (probes 7 and 8 in
`.agents/knowledge/research/2026-11-17-permission-request-hook-timing.md`).

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | The log kept raw, unmasked tool input, and no file modes were stated | Adopted: no raw input kept; `0700` folder and `0600` files; acceptance 11 |
| 2 | P1 | The Mac's terminal test read a record written at session start, so Ctrl+Z or a reused pid passed it | Adopted: a live test at each use (process, start time, not stopped, foreground group, tty); acceptance 24 |
| 3 | P1 | One registry status field for each session settled several prompts | Adopted: each hook finds its own call in the transcript and watches that call's result (probes 7, 8); acceptance 6 |
| 4 | P1 | A question event could stay `open` for ever and block gate answers | Adopted: closed on the next `Stop`, `UserPromptSubmit` or `SessionStart`, on a drop and on a restart; a reply for each closed state |
| 5 | P2 | `UserPromptSubmit` settled gates that nobody answered | Adopted: the row is gone; `UserPromptSubmit` with the typed answer marks the gate answered |
| 6 | P2 | The gate text in the typed line was not checked | Adopted: a cleaned label of at most 120 characters, and the whole line checked again |
| 7 | P2 | `done` was sent before the effect was seen | Adopted: type, read back, then Return; `done` when `UserPromptSubmit` shows the prompt |
| 8 | P2 | A stop of the hook might not reach a grandchild process | Probed (probe 7): Esc stopped a Python grandchild behind `bash -c '… \| cat'`; the client also exits when its parent ends |
| 9 | P2 | "Still idle" after 5 s was not "the same turn" | Adopted: compare the transcript's last assistant message |
| 10 | P2 | No matcher; `ExitPlanMode` and `AskUserQuestion` need `updatedInput`; sandbox network prompts fire no hook | Adopted: both tools excluded; plan approvals alert only; the network gap is out of scope; Q1 covers both tools |
| 11 | P2 | `delivered` was not observable, and the envelope check stayed in `pane-run` | Adopted: reply `sent` with the hold notes; the check moves into `inbox.py`; L9 corrected |
| 12 | P2 | The phone-only device check waited until unit 3d | Adopted: `sourceDevice` checked from 3a (Q2); the two-daemon check stays in 3d (Q10) |
| 13 | P2 | Declining the R28 proposal would void R32 and R33 | Asked; the operator ruled the hook decision |
| 14 | P2 | No alert or waiting-hook cap, and loop values missing | Adopted: 6 alerts a minute, 20 waiting hooks, and a cost table |
| 15 | P2 | Handles could collide, and differed from the terminal's name | Adopted: the registry `name`, read at each use, checked against every live handle |
| 16 | P2 | Hook paths, the flag source and review coverage | Adopted: `hooks/policy/`, the flag from `config.json` only, new critical paths |
| 17 | P2 | A closed socket was read as an answer at the Mac; deadline races; no time zone | Adopted: `closed` state, a deadline 60 s before the timeout, minutes left and a configured zone |
| 18 | P2 | Acceptance gaps | Adopted: lines 6, 8, 9, 11, 15, 16, 19, 24, 25, 27, 28 |
| 19 | P2 | One module with seven jobs | Adopted: seven modules named |
| A1 | — | Which "gate text" | Decided by the lead: the alert carries the whole line; the typed label is the part before ` — ` |
| A2 | — | R12 for sessions that have ended | Ruled R35: an information alert |
| A3 | — | Which "turn" R34 means | Decided by the lead: from one prompt (`prompt_id`) to the `Stop` that no hook continues |

## Round 3 (`a12d460`, spec sha256 `1a4dffdb…`, reviewer on `fable`)

`CONFORMANCE: no`. 6 `P1`, 13 `P2`, 2 ambiguities. Class verdict: the
recorded-fact class is gone from permission prompts, questions and requests,
and came back for the third time in typed gate answers (findings 5, 7, 8). The
playbook's stop-patching rule applied; the lead brought the choice to the
operator, who ruled to keep typed answers and fix the findings (R36).

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | A Note to Self message from a linked device may not notify a locked iPhone | Adopted: probe Q11 before the 3a build, the send mode it proves, acceptance 1 needs a lock-screen notification; if neither mode notifies, the operator rules the route again |
| 2 | P1 | Lead decision A3 made every machine turn re-alert and void the id being answered (counts in L23) | Ruled R37: the event stays open through machine turns; acceptance 21 |
| 3 | P1 | A subagent's call is in its own transcript, so its hook could not settle and held a cap slot | Adopted: the agent's file under `subagents/`, a bounded search, an unbound branch with a 10-minute limit; Q7 before 3a; acceptance 7 |
| 4 | P1 | A failed Signal send left a session waiting an hour for an alert nobody received | Adopted: the hook exits at once on a failed send; `errors.log` and the sidebar; gate alerts retried; acceptance 11 |
| 5 | P1 | Typing acted on the gate text read at `Stop` (recorded-fact class) | Adopted under R36: the event is bound to its row; a second `Stop` of the same turn replaces it; the last assistant row is re-read before typing |
| 6 | P1 | A live session that is not a terminal got the R35 `ended` alert | Adopted: `ended` separated from "not a terminal"; an `ended` state; acceptance 27, 29 |
| 7 | P2 | After a failed read-back the link sent clearing keys | Adopted: it sends nothing more; acceptance 30 |
| 8 | P2 | A restart closed gates that still waited | Adopted: open gates rebuilt from each live session's last row; acceptance 31 |
| 9 | P2 | The leading-character rule guarded nothing, `@` mid-text, conflicting limits, no wait limit for `done` | Adopted: `@` refused anywhere, 300 and 500 limits, 30 s for `done` |
| 10 | P2 | Transition holes: a `no` after a Mac allow, plan approvals, a question settled at the Mac with no watcher | Adopted: Q12 classifies how a call ended; a `plan` kind; question rows close on the next hook line |
| 11 | P2 | Alerts past the rate limit, and unmasked gate text | Adopted: a queue, nothing dropped; every outgoing text masked and cut; acceptance 18 |
| 12 | P2 | Refused messages left no replay record | Adopted: `messages.jsonl` holds every phone message's timestamp and result |
| 13 | P2 | Installers outside the critical paths | Adopted: both added; `normalize-hook.py` is not used, since the hooks are not repository hooks (R39) |
| 14 | P2 | "Exits when stdin closes" would end the hook at once under the adapter | Adopted: the hook watches the registered `claude` pid and start time |
| 15 | P2 | `it2` from a launchd agent may need a consent step; the tty source was unnamed | Adopted: Q3 runs from the agent; the tty from `it2 session get-var` |
| 16 | P2 | The combined exposure was not laid out | Ruled R38: accepted; one paragraph in the high-stakes block; L17's evidence corrected |
| 17 | P2 | The handle followed a mutable name | Adopted: fixed for the session's life |
| 18 | P2 | Cost of the gate-answer scan and the 21st session | Adopted: the scan reads only rows after the gate's row; a 50-session cap |
| 19 | P2 | Server changes left to a runbook; no server containment or undo | Adopted: `setup-server.sh` and `apply` own the packages and forwarding; server containment and undo |
| A1 | — | Which sessions the link covers | Ruled R39: sessions whose folder carries the harness, colloid-swarm included, through hooks installed once for each machine |
| A2 | — | When a permission prompt alerts | Ruled R40: at once |
