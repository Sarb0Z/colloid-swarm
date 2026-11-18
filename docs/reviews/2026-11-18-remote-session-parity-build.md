# Review: the remote session parity build, round 1

Covers: `f67df9b..remote-parity/server-setup` (fa94e55..81adb02) and
`f67df9b..remote-parity/panes` (59fb395..1a3b8de); fixes trail in 62d013d,
56122ee (server-setup) and ff5b051, 23b70e4, d4076e2, dd3c4a4 (panes).

Spec: `docs/notes/2026-11-18-remote-session-parity-spec.md`, units 1–4.
Stakes: critical, because `setup-server.sh` runs as root on a live server, the
policy helper runs at every Claude Code start there, and `pane-run` hands
requests to a Claude session with the operator's authority.

One reviewer cell (Opus) read both lanes whole under
`.agents/playbooks/hostile-review.md`. It ran no test, so its five `P1` items
came back unverified; each was fixed with a test that fails without the fix,
and the lead re-read the three that guard the server: the absolute `//` path
form in `server-asks.json` (Claude Code's permissions page: `/path` is relative
to the settings source), the hook command that exits 0 without `it2`, and the
connection loop's stop on ssh's refusal messages.

Round 1 found five `P1` items, eleven `P2` items and no `P0`.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | A staged JSON file jq cannot read left `/etc/claude-code/policy.json` empty, and the helper that names it would stop Claude Code from starting. | Fixed in 56122ee: every staged JSON is parsed first, results are assigned before writing, and `managed-settings.json` is written last. |
| 2 | P1 | The `~/apps` Edit and Write asks used `/path`, which Claude Code reads as relative. | Fixed in 62d013d: `//home/openclawops/apps/**`, with a test on the path form. |
| 3 | P2 | The helper needs `/usr/bin/jq`; setup checked jq on PATH. | Fixed in 56122ee. |
| 4 | P2 | No check for `gh`, and the https rewrite could catch `apply`'s clone. | Fixed in 56122ee: `gh` checked, login state printed, the clone runs without the global config. |
| 5 | P2 | The iTerm2 hook failed on every tool call before `it2` exists. | Fixed in 56122ee: the hook exits 0 without `it2` and reports a failing `it2` on stderr. |
| 6 | P2 | The hook merge replaced a whole entry and lost its matcher and other hooks. | Fixed in 56122ee: only the matching inner hook is replaced. |
| 7 | P2 | A comment said no GitHub login is stored on the server. | Fixed in 56122ee. |
| 8 | P2 | Acceptance 8 read the ask list from `managed-settings.json`. | Fixed in 3bf43d2 on `main`. |
| 9 | P1 | ssh exits 255 for a refused key, so the loop retried it 40 times against a rate-limited port 22. | Fixed in 23b70e4: ssh's refusal messages stop the loop. |
| 10 | P1 | Nothing installed `connect/dev-server`, which the profile names. | Fixed in ff5b051: `install.sh` links it to `~/.local/bin/dev-server`. |
| 11 | P1 | A single folder match in another tmux window got the request with no confirmation. | Fixed in d4076e2: only sessions in the pane's window, or its workgroup leader's, are used without the menu. |
| 12 | P2 | Server mode followed the tab-state folder's absence. | Fixed in d4076e2: the platform decides. |
| 13 | P2 | The server's `~/.claude`, another person's login, counted as an account folder. | Fixed in d4076e2. |
| 14 | P2 | `catalog.json` holds a second copy of the saved "Default" prompt. | Accepted: the server has no iTerm2 preferences to read; the copy is named as the server's source in `pane-run --help`. |
| 15 | P2 | The `pane-diff` test never reached the `/usr/bin/nvim` fallback. | Fixed in dd3c4a4. |
| 16 | P2 | The delay resets after a connection over 60 s, not after each attach. | Accepted: a link that drops within 60 s counts as a failed try, so a flapping link cannot hammer port 22; the code says so. |

Stop condition: no `P0`; every `P1` fixed with a test that goes red without it.
QA of the live acceptance (1–7, 9–12) waits for the operator's `apply` and the
iTerm2 steps.
