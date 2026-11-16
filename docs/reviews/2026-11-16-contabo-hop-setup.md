# contabo-hop development server: code review of `.agents/iterm/server`

The operator approved the Unit 5 runbook in `~/.config/docs/TERMINAL-SPEC.md`
on 2026-11-16 ("confiremed"). The runbook makes `contabo-hop` the development
server, as `openclawops`, with Eternal Terminal, tmux and four Claude Code
accounts. The host is live: it runs KumoMTA mail, nginx, the bakery, GitMu and
Docker, and it is the jump host for `mail-via-hop`. So steps 1-5 are one
committed, rerunnable script. The operator runs it from the Mac with `apply`,
because the agent's ssh is read-only by guard.

Covers: 692df7e..b8fb647
Covers: 10ff853..bb31be3

The first range holds the script (366b7e7) and the archive fix (b8fb647). It
also carries the other session's 390b8c1 (prompt-pane docs), which this review
did not read, and which touches no critical path. The second range is the fix
round, and it touches only `setup-server.sh` and `test.sh`.

Before the review, the operator ran `apply --check` against the server. It
printed the 19 predicted `would:` lines and `check: 19 change(s) to make;
nothing was changed`, and tmux 3.4 accepted `tmux.conf`. The server's GNU tar
printed seven "unknown extended header keyword
'LIBARCHIVE.xattr.com.apple.provenance'" warnings. b8fb647 drops the tags with
`--no-xattrs`, and the test reads what `apply` sends (7 tags before the fix, 0
after).

One reviewer (fable) read both commits against the runbook and the server,
read-only. It ran the suite from archives of 366b7e7 and b8fb647, and read the
server's ufw backend, ET 7.1.1's source and the package's postinst.

The disprove pass for finding 1 was a read on the server. Port 22's rule in
`/etc/ufw/user.rules` is `-m recent --set` and `--update --seconds 30
--hitcount 6` with no `--name`. `/proc/net/xt_recent/` holds one list,
`DEFAULT`. So a second `limit` rule counts into the same per-address list. ET
7.1.1's reconnect loop is `while (true)`. The finding was not reproduced live,
because reproducing it means locking the Mac out of port 22.

The fix round is bb31be3, by the lead. The suite passes, 98 rows. Each of nine
mutations, one per fix, turned rows red (3, 28, 2, 2, 3, 1, 1, 2 and 1). The
scratch-folder test passed its mutation at first: macOS `mktemp -d` without a
template ignores `TMPDIR`. An explicit template fixed it, and the mutation then
failed one row.

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | `ufw limit 2022/tcp` shares port 22's rate-limit list per address, and ET retries a stopped etserver about once a second, so the Mac would be refused on 22 as well | Escalated. The operator ruled `ufw allow 2022/tcp` (TERMINAL-SPEC Decision 8). Keeping `limit` with handling rules, and a separately named list, were declined |
| 2 | P2 | apt writes to the ssh connection, so a dropped connection can stop dpkg mid-configure on the live host | Adopted: `add-apt-repository`, `apt-get update` and `apt-get install` write to logs in the backup folder; a failure prints the last 20 lines |
| 3 | P2 | A rerun replaces a `settings.json` that Claude Code has written to since | Adopted: an existing file gets the shipped `env` keys merged with `jq`, and keeps its other keys |
| 4 | P2 | The runbook's Undo restores ufw's files before deleting the rule, stops et before the rule goes, leaves `/etc/et.cfg`, and omits the Claude Code update | Adopted: Undo is reordered and completed in the runbook |
| 5 | P2 | A PPA file with no fetched lists makes every rerun die at the install | Adopted: with the PPA listed and no candidate, the script runs `apt-get update` |
| 6 | P2 | The package's postinst starts etserver while `/etc/et.cfg` still says `telemetry = true` | Adopted: a temporary `policy-rc.d` answering 101 holds that start, and the script starts et after setting telemetry off. An existing `policy-rc.d` stops the run |
| 7 | P2 | `--check` cannot show the install set before the PPA is added, and the run installs with no stop | Adopted as a fix rather than accepted: after the PPA, the script prints `apt-get -s install et` and dies before installing anything that would upgrade or remove an installed package. The reviewer read today's set as `et` plus `libprotobuf32t64` |
| 8 | P2 | The apt stand-in did not enable et as the real package does, so the branch the server takes was untested | Adopted: the stand-in enables the unit and starts it unless `policy-rc.d` answers 101 |
| 9 | P2 | `--check` leaves a tmux socket under `/tmp/tmux-0/` | Adopted: the tmux check uses `-S` in a scratch folder that it removes. One socket from the operator's first check stays on the server, `/tmp/tmux-0/unit5-check-3654527` |
| 10 | P2 | tmux-continuum saves from `status-right`, which a `tmux -CC` client may never draw | Deferred to the probe: step 8 looks for a save file under `~/.tmux/resurrect/` after 15 minutes attached. Recorded as a known gap |
| 11 | P2 | `git` and `claude` run as `openclawops` from `/root` (mode 700) with root's `USER`, `LOGNAME` and `XDG_RUNTIME_DIR` | Adopted: the script works from the user's home, and `as_user` sets the user's names and unsets `XDG_RUNTIME_DIR` |
| 12 | P2 | A `.bashrc` with the block's first line but not its last would lose every line after it | Adopted: the script refuses to touch it and names the file |
| 13 | — | Reviewer ambiguity: whether Claude Code's auto-updater or the script moves the shared install | The script does, since `DISABLE_AUTOUPDATER` stops the updater; the runbook's step 5 now says so |
| 14 | — | Measurement: `setup-server.sh` is 360 lines, over 300 | Accepted: it runs straight through in the runbook's step order, with no function over 40 lines, and splitting it would add a layer between the runbook and its steps |

QA comes after the operator's real `apply`, from the reviewer's handoff. The
operator ran `apply` at bb31be3 on 2026-11-16. The first run stopped at the PPA,
when `add-apt-repository` timed out reaching Launchpad's API (log in the
backup folder). It left only the key step done. The rerun finished at
13:36 +0100. Results, read-only:
- A second `apply` prints "nothing to change": waits for the operator's `apply --check`.
- `ssh contabo-dev id` logs in as `openclawops`: passed.
- Port 2022 listens: passed. etserver is on IPv4 and IPv6, and a TCP connect from the Mac succeeds. `ufw` is outside the agent's ssh allowlist, so the agent compared the files ufw loads instead. `user.rules` and `user6.rules` differ from their backups only by the 2022 `allow` rule.
- No restart of mail, nginx, the bakery, GitMu or Docker in the journal for 13:26-13:40: passed. The only service started was `et`, once, at 13:35:59, two seconds after `telemetry = false` was written. The bakery's system unit ran throughout (up since 2026-11-14, no restarts). The lines that say "Started bakery.service" every 5 seconds come from a stale user unit of the same name. It points at a removed folder, and it was failing long before the run (restart counter 476,143). The operator ruled to disable it (TERMINAL-SPEC Decision 13).
- `openclawops`' `~/.claude` unchanged: failed, narrowly. `.claude.json` is untouched, last written 2026-07-12, but `claude update` created the empty folders `~/.claude/commands` and `~/.claude/agents` at 13:36:06, although it ran with `CLAUDE_CONFIG_DIR` set to `~/.claude-work`. The test stand-in for `claude` cannot show this, so the suite does not cover it.
- The Claude Code update reached the Mac's version: passed (2.1.325).
- `.tmux.conf` and the four `settings.json` files are byte-identical to the shipped files, and both plugins sit at their pinned commits: passed.
- Probe step 8: waits for the operator.
