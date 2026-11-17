# Phone link spec: plan review rounds

Plan `docs/notes/2026-11-17-phone-link-spec.md`, before any implementation.
Critical stakes. One reviewer per round, a fresh cell that read the plan whole
against the repository, the machine files it cites and the external sources it
could reach. No code exists yet, so this record carries no `Covers:` line.

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
