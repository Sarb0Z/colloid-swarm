# Prompt pane: code review of workloop run `prompt-pane`

Unit 4 of `docs/notes/2026-11-15-iterm2-review-and-status-spec.md`, which the
operator approved on 2026-11-15; the operator started it on 2026-11-16. The
lead's build decisions are the spec's 4h (692df7e). Stakes: critical, since the
pane posts requests into the operator's Claude sessions and the lead acts on
them with the operator's authority (R19).

## Lane `pane`

Covers: f5e2def300c6..16c4b6323808

A fable writer built `pane-run`, `review-snapshot`, `prompt-catalog` and
`catalog.json` in three commits (b835c8b, 1142bf5, 8705fef), all under
`.agents/iterm/`. The suite passed with 229 rows; the writer inverted 61
refusal and outcome rules one at a time, and every rule a test could reach
turned the suite red. One real post reached a fixture session the writer
started: its transcript records the request as a message from another session
(`origin.kind: peer`, `from: prompt-pane`). Another session resumed from this
conversation sent a duplicate writer into the lane's worktree for about five
minutes before stopping it; the writer read every file before committing and
kept only its own work.

One reviewer (opus) read the lane whole and its seams with
`worktree_records.py`, the session-end sweep, `pane-base`, `install.sh`,
iTerm2's saved-prompt store and Code Review pane, and Claude Code's
cross-session messaging, and reran the suite (exit 0, 229 rows). It found no
`P0` or `P1`, so the round has no disprove pass. QA runs Acceptance 18-33 live
beside it.

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 1 | P2 | `catalog.json` makes `security-audit` a background skill, though its `SKILL.md` writes `security-audit-report.md` into the repository; `thermo-nuclear-code-quality-review` and `scalability-audit` can also write | Adopted: background is only for a skill whose cell reads, returns its findings and writes no file (R1: background cells get work that only reads). The three become inline; spec 4h.2 now says so |
| 2 | P2 | In bypass mode, busy-to-busy prints "Sent." though Claude Code holds every message that asserts no mode; busy-to-waiting tells the operator to approve whatever dialog shows, which may be a permission prompt (C5) | Adopted: with the transcript's last mode `bypassPermissions`, the pane always says the message is held and names the dialog to approve as the one that shows this request, after any other prompt; other modes keep the status comparison and never tell the operator to approve an unnamed dialog. Spec 4a.7 and Acceptance 30 now say so |
| 3 | P2 | The R13 brief is `\(codeReviewSystemPromptFile)`, which holds iTerm2's instructions to post findings as clippings with `it2` on the session the reviewer runs in, here the Chat session, and holds no review criteria | Adopted on R13 and R7: the brief is iTerm2's own review prompt, the saved prompt "Default", read from iTerm2's preferences without writing them; results return to the lead as R7 rules. `pane-run` no longer takes the file, and the runbook's Code Review command drops it. The operator's walk-through covers it |
| 4 | P2 | `review-snapshot` hashes every untracked file into `.git/objects` and checks out a second copy with no size bound; `worktree_removal.py` caps the same save at 200 MB | Adopted: the same cap, with the size printed on refusal |
| 5 | P2 | Acceptance 31 cannot pass in ticketing-app: its `staging` checkout has no `hostile-review.md` and does not ignore `.agents/worktrees/` | Adopted: Acceptance 31 runs in claims-app, which carries both; QA was redirected |
| 6 | P2 | `skill=` and `playbook=` gate the send but the message never names them, so a typed entry whose text does not name its skill leaves the lead without it | Adopted: the message names the header's skill or playbook (spec 4h.6) |
| 7 | P2 | The transcript's mode scan re-searches a growing buffer, quadratic over a transcript with no mode line | Adopted: the fix round changes its caller; each step searches the new chunk and the pattern's overlap |
| 8 | P2 | A session list without `window_id` or `tab_id` matches every session to the pane's tab, so one live record anywhere would receive the request with no menu | Adopted: a session that lacks either key is not in the tab |
| 9 | P2 | `--probe` hides values by variable name only, so a URL's userinfo and names such as `*_AUTH` or `*_PAT` print | Adopted before the operator runs P1 |
| 10 | P2 | `pane-run` is 452 lines with 23 public names, two functions over 40 lines, and the third copy of the tab liveness check | Accepted: one script per pane command; the copies are recorded as `debt: iterm-tab-liveness-copies`, since `claude-tab-state` lives outside the repository. The fix round keeps the functions it touches within 40 lines |
| 11 | P2 | Runs per day of `pane-run` are not stated | Accepted: Starts are the operator's own presses; spec 4h.7 states the per-Start cost |

The fix round landed findings 1-9 as trailing commits: eb0df95 (1), 8c965d6
(4) and 17b1a85 (2, 3, 5, 6, 7, 8, 9, whose hunks interleave in one script).
The suite passed with 254 rows. The new tests run against the three scripts
and `catalog.json` at 8705fef gave 35 failures; finding 6 changes no
behaviour, so its boundary test passes on both. The lead read the diff: the
background list is `review-animations` and `web-design-guidelines`; a
bypass-mode lead always gets the line that names this request's dialog; the
R13 brief is read with `defaults export` and never written; the size cap is the
repository's own `SAVE_CAP`, 200 MB here. One case stays open for QA: Claude
Code also holds a message for a lead in plan mode while bypass is available
(spec E9), and there the pane prints "Sent." without the five-minute limit.
The device policy does not disable bypass, so QA's Acceptance 30 rerun tries a
plan-mode lead, and the line changes only if a hold shows.

QA (opus) ran Acceptance 18-33 live at 8705fef, from a frozen copy once the
fix round started. Each test lead ran in a tab QA opened, with the pane
simulated by a split of that tab and `it2 session run`. Passed: 18-24, 26-29,
31-33, 4h.1 and 4h.4.
- 18: a background reviewer cell on opus, account unchanged.
- 19: a pending `git push` prompt stayed pending until QA answered it.
- 20: a half-typed draft stayed in the input line.
- 21: the snapshot and the index stayed apart, and `/exit` removed the snapshot.
- 22: `committed: yes` wrote `Covers: 692df7e..1606c64`, and `owed.py` cleared
  the file; `committed: no` wrote nothing.
- 23: a plain repository, with QA's own brief file at 8705fef.
- 26: on a copy of the preferences, "Default" first and unchanged, then the
  groups in order.
- 27: two messages in order; an identical third within 30 s was dropped.
- 31: claims-app.
- 32: six stale records, each named.
- 33: 2 of 2, no `git push` and no SendMessage.

25 failed once: a lead with a long history asked two questions before its
first edit, both raised by conflicts in QA's own entry (a passive line against
the documentation rule, and a commit without the suite). A fresh lead passed.
30 cannot run here: `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` forces every session
to the default mode, so no lead bypasses permissions and no message is held.
That also closes the plan-mode case above. The bypass line stays covered by
the suite.

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 12 | P2 | QA: `review-snapshot --help` makes a real snapshot: it made `.agents/worktrees/pane-review-20261116-165204-47194` in the main checkout, recorded under the lead's session | Adopted: `-h` and `--help` print the usage, and any other argument is a usage error. The stray snapshot is clean, and the session's end removes it |
| 13 | P2 | QA: `pane-run --help` takes `--help` as an entry and shows the one-key menu of live sessions; a key press would post it | Adopted: `-h` and `--help` print the usage; a single argument that starts with `-` and holds no space is refused as an unknown option |
| 14 | P2 | QA, raised by the test lead in 22: step 4 writes `Covers:` even when step 2 says the record cannot stand in for the delivery review, and `owed.py` clears an owed review by that line | Adopted on R18 and C2: the record has a `Covers:` line only under the full procedure, and otherwise says why (spec 4d step 4) |
| 15 | — | QA: a pane review in the default permission mode asks the operator about ten times | Noted for the operator: an allow rule for `review-snapshot` is the operator's decision |
| 16 | — | QA: two of its split panes closed by themselves, and sessions in other tabs ended with reason `other` during the run | Not explained: the system log shows no memory-pressure kill; each ended session's tab record remains, so `claude-tab-state reopen` can resume it |
| 17 | — | QA, for unit 2: while a background shell ran, a gate turn showed `working · 1 background task running` for 20 s instead of `decide:` | Filed in `breadcrumbs.md` |

The second fix round landed findings 12-14 as 6f0f121 (12) and 8fe1ad3 (13
and 14). The suite passed with 274 rows; the new tests gave 20 failures
against the scripts at 17b1a85. The lead read the diff.

The reviewer's readings: Acceptance 30's "Sent line" is the line after the
post, and finding 2 settles which; R13's "iTerm2's own review prompt" is the
saved review prompt, as finding 3 rules; 4h.2's "reports" means returning
findings with no file written, as finding 1 rules.
