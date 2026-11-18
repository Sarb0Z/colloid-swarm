# Review: plan for Signal through a TLS proxy on contabo-hop

Scope: `docs/notes/2026-11-18-signal-tls-proxy-plan.md`, revision 1 (`3c9e773`).
Stakes: critical. The plan changes a production server that also serves
websites, Docker workloads and GitMu, and it carries the phone link.

One reviewer cell (Opus) checked the plan's facts against the upstream sources.
It read the server over ssh, and it ran the upstream configs and lego in local
throwaway containers. Each `P1` was confirmed by a run.

Round 1 found three `P1` and eleven `P2` items, and no `P0`.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | The override keeps ports 80 and 443 (Compose appends ports). Upstream's terminate config fails `nginx -t` without its certbot container and `options-ssl-nginx.conf`. lego's file names differ from what upstream expects. | Fixed in revision 2. The terminate config is the repository's own, `ports: !override`, and the lego files are mounted read-only. |
| 2 | P1 | lego v5 has no `renew` command and no `--disable-cn`. A renewal must repeat `--profile shortlived` and the http flags. | Fixed. One `run` command line in `lego.sh`, pinned v5.6.0, rendered exactly by a test. |
| 3 | P1 | There was no `Acceptance:` block, no `Lenses:` block, and no observed or documented labels. | Fixed. Ten acceptance values, the lenses, and a label on each fact. |
| 4 | P2 | Docker's published ports bypass ufw, so the ufw step did nothing. | Fixed. There is no ufw rule; the published port is the control. |
| 5 | P2 | A failed renewal is visible only in the journal. | Fixed. `phone_link.py` warns on Signal and in `errors.log` when less than 48 h are left. The timer checks the webroot before calling Let's Encrypt. |
| 6 | P2 | The reload after a renewal was not specified; lego writes the two files separately. | Fixed. A hash compare, then `nginx -t` and a reload in the container, after both files are written. |
| 7 | P2 | The flag would come after `daemon`, and an install run without it would drop it. | Fixed. The flag goes before `daemon` and is saved in the install's state; `none` clears it. |
| 8 | P2 | The test did not cover signal-cli's other connections, and "stop the daemon" was not specified. | Fixed. Acceptance 7 uses `launchctl bootout`, a send with an attachment, and the server's `ss`. |
| 9 | P2 | Not safe to run twice: a re-issue at each run could reach Let's Encrypt's limit, `--check` called outside, and the files were missing from `apply`. | Fixed. A module of its own with its own `apply-proxy`. It issues only when the certificate has 80 h or less left, `--check` reads only, and a test covers it. |
| 10 | P2 | The backup missed the firewall tables and Docker networks, and lived outside the script's backup folder. | Fixed. |
| 11 | P2 | The undo was incomplete: no Mac side, no order, no rule for when. | Fixed. An ordered undo, a rollback trigger, and the Tailscale state named. |
| 12 | P2 | The approved spec still prescribes the exit node (R26, Setup, Q5). | Adopted. The spec edits are listed in the plan and land with it. |
| 13 | P2 | No other option was weighed (tailnet only, a DNS name). | Weighed in the plan. The operator ruled for the public port on 2026-11-18. |
| 14 | P2 | `setup-server.sh` and `install.py` are already over 300 lines. | Fixed for the server: the proxy is a module of its own. `install.py` gains the flag only. |

Out of scope: three containers on the server are open to the internet,
`tourism-postgres` on 5433 among them. This is recorded in `.agents/breadcrumbs.md`;
the operator deferred it.
