# Review: the remote session parity spec, round 1

Covers: `docs/notes/2026-11-18-remote-session-parity-spec.md`, first draft
(uncommitted, read at `c979561`).

Stakes: critical, because the spec grants a live server API access to iTerm2
on the Mac, puts a GitHub credential on that server, and changes the Claude
settings of four accounts there.

One reviewer cell (Opus) read the draft whole under
`.agents/playbooks/hostile-review.md`, with iTerm2's `v3.7.7` source and
GitHub's token documentation, and ran no server command. The lead re-ran three
load-bearing claims: the device policy holds 145 ask rules against 60 in the
shared settings; the workgroup's Diff and Code Review commands are absolute
Mac paths; and the server's work and personal launchers are signed in to the
same account. All three held.

Round 1 found nine `P1` items, seven `P2` items and no `P0`.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | iTerm2's remote installer writes hooks to `~/.claude`, not to the four launcher folders, so the sidebar stays empty. | Fixed: F14 and default 5. `apply` writes the hook into each account; P3 adds it by hand to one account first. |
| 2 | P1 | The one global workgroup runs Mac paths, so its panes fail on the server, and `pane-run` depends on Mac-only state. | Fixed: F12, F15 and default 6. Unit 3 makes the commands host-neutral and gives `pane-run` a server path. |
| 3 | P1 | The SSH Integration grant lets any `openclawops` process read and type into local Mac tabs. | Escalated. The operator accepted the chain as written (ruling 3, confirmed). F13 states it, and P6 measures it from a process outside the connection. |
| 4 | P1 | The Mac's effective asks are the device policy's 145, not the shared settings' 60; the counter-pressure prompt and two privacy keys were missing. | Fixed: F10, unit 2, acceptance 8. The device payload goes to root-owned managed settings. |
| 5 | P1 | Server logins do not match the Mac's launchers; the guest denial had no mechanism. | Fixed: F16, unit 2 sign-in step, acceptance 9; the denial is keyed by account through a helper port, settled by a probe. |
| 6 | P1 | One global git identity on the server, and a fine-grained token cannot reach collaborator repositories. | Escalated, then fixed. The operator chose a classic token (ruling 4, confirmed). Unit 4 sets the author per owner; acceptance 10. |
| 7 | P1 | With asks on every push and the lid closed, a Claude push waits for wake, so acceptance 7 could not run. | Escalated. The operator kept the token on that basis (ruling 4). Acceptance 7 now runs in a plain shell, plus an attached Claude push that shows the ask. |
| 8 | P1 | A user-wide `https` rewrite would change the live services' git remotes. | Fixed: unit 4 scopes the rewrite to `~/Projects` with `includeIf`; F18 and acceptance 11 inventory the services' remotes first. |
| 9 | P1 | The reconnect loop had no rule, and the detach answer contradicted ruling 3. | Fixed: unit 1 adopts `TERMINAL-SPEC.md`'s loop with numbers and sets `tmuxWindowsShouldCloseAfterDetach` to Always; acceptance 6's limit follows from them. |
| 10 | P2 | P5 would not separate the hypotheses, and a stale client could stall the hook. | Fixed: P5 records clients, exit node and call rate with predictions; the hook has a 5 s timeout. |
| 11 | P2 | Undo named a wrong backup path, and the menu uninstall strips the Mac's own integration. | Fixed: Undo lists every unit's steps and strips server hooks by hand. |
| 12 | P2 | `etserver` stays listening, and agent forwarding defeats the token's scope while attached. | Fixed: unit 1 removes `et` after it passes and states the forwarding residual. |
| 13 | P2 | No asks for production verbs on a live host. | Fixed: server-only asks in unit 2; Constraints says Bash-prefix asks are no security boundary. |
| 14 | P2 | The scope table left out several parity items. | Fixed: each has a row, marked same, not the same, or out of scope. |
| 15 | P2 | Unit 0 claimed no probe writes before P2. | Fixed: unit 0 lists each probe's writes. |
| 16 | P2 | Acceptance missed live services, local-tab regression, undo, and exact values. | Fixed: acceptance 1, 2, 4, 11 and 12. |

Stop condition: no `P0`; every `P1` fixed or ruled by the operator. The spec
goes to the operator's review.
