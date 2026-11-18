# Review: the phone link's server step (Tailscale exit node)

Scope: `setup-server.sh` step 7 and the helpers it shares with the Eternal
Terminal step, `apply`, `test.sh` and `tailscale-archive-keyring.asc` in
`.agents/iterm/server/`, uncommitted on `cbb461c`. Stakes: critical, because the
script runs as root on contabo-hop, which serves mail, nginx, Docker and GitMu.
One reviewer cell (Opus) worked under `.agents/playbooks/hostile-review.md`,
disprove pass included. Its upstream reading matched the shipped key with
`noble.asc` byte for byte. It also confirmed that the real tailscale 1.104.7
`.deb` ships `FLAGS=""` in `/etc/default/tailscaled`, and that
`deb-systemd-invoke` honours a `policy-rc.d` that answers 101.

Round 1 found one `P1` and nine `P2` items and no `P0`, so the fixes do not
re-enter review.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | The spec says `apply` undoes step 7; it installs only. The backup folder does not record the forwarding values from before the change. | Fixed. The spec's Setup containment is now a rollback runbook, and Undo points to it. The script writes `forwarding-before.txt` to the backup folder before it changes forwarding. |
| 2 | P2 | The comment cited `accept_ra 0` as proof that no route came from router advertisements. | Fixed by a probe on 2026-11-18: the IPv6 address has `valid_lft forever`, the default route via fe80::1 is `proto static`, and no route is `proto ra`. The comment now cites this. |
| 3 | P2 | Forwarding is safe only while ufw drops forwarded packets for IPv4 and IPv6, and nothing checked this. | Fixed. The script requires `DEFAULT_FORWARD_POLICY="DROP"` and `IPV6=yes` in `/etc/default/ufw`, and otherwise reports a problem and leaves forwarding alone. The live file holds both. Two tests cover it. |
| 4 | P2 | `--check` did not list the restart that a settings change causes, for both et and tailscaled. | Fixed at the root. The change flag is set before `change`, and one `service_up` helper does both services. Two tests cover it. |
| 5 | P2 | A stopped tailscaled with the operator's `FLAGS` was started with log upload on. | Fixed. The script does not start tailscaled in that case, and a test covers it. |
| 6 | P2 | `FLAGS` without quotes, with single quotes, or with a comment was read as empty and rewritten. | Fixed. Only the exact line `FLAGS=""` is rewritten. Four tests cover it. |
| 7 | P2 | On a first install the real postinst neither enables nor starts tailscaled, and the comment and the test stand-in said it did. | Fixed. The comment is corrected, and the stand-in enables the unit only on a reinstall of an enabled unit. A reinstall test checks that `FLAGS` is set before the first start. |
| 8 | P2 | Recommends installs `tailscale-archive-keyring`, a second key copy that the list does not read. | Fixed with `--no-install-recommends`. Manual key rotation is recorded as debt `tailscale-key-rotation`. |
| 9 | P2 | Test gaps: order, the restart preview, operator `FLAGS` forms, the stopped service, the backup of an older forwarding file, and `policy-rc.d` after the second install. | Fixed. Each one has a test. The suite has 201 checks. |
| 10 | P2 | The rewrite-a-file idiom appears three times, and the script is over 300 lines. | Deferred to `breadcrumbs.md`. The restart-or-start copy (the cause of finding 4) is extracted. |

The handoff asked for a run in a throwaway Ubuntu 24.04 VM with ufw and Docker.
No VM was run. The first real run is the operator's `apply --check`, then
`apply`, on contabo-hop, and its observable results are in the operator guide
of the session's final message.
