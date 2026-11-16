# Prompt pane: code review of workloop run `prompt-pane`

Unit 4 of `docs/notes/2026-11-15-iterm2-review-and-status-spec.md`, which the
operator approved on 2026-11-15; the operator started it on 2026-11-16. The
lead's build decisions are the spec's 4h (692df7e). Stakes: critical, since the
pane posts requests into the operator's Claude sessions and the lead acts on
them with the operator's authority (R19).

## Lane `pane`

Covers: 692df7e..17b1a85

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

The reviewer's readings: Acceptance 30's "Sent line" is the line after the
post, and finding 2 settles which; R13's "iTerm2's own review prompt" is the
saved review prompt, as finding 3 rules; 4h.2's "reports" means returning
findings with no file written, as finding 1 rules.
