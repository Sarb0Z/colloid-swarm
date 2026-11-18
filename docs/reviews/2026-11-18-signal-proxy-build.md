# Review: the Signal TLS proxy module and its Mac side

Covers: 3c9e773..78ecbc5

Scope: commits `fb1fdd6`, `0c7ddbb`, `7c314e2` and `78ecbc5`. They cover:
- `.agents/iterm/server/signal-proxy/` (compose, terminate config, vendored
  relay config, `lego.sh`, renew units, `setup-proxy.sh`, `apply-proxy`,
  tests);
- on the Mac, `install.py --tls-proxy` and the daily certificate check in
  `phone_link.py`.

Contract: `docs/notes/2026-11-18-signal-tls-proxy-plan.md`, revision 2.

Stakes: critical. `setup-proxy.sh` runs as root on a production server.

One reviewer cell (Opus) read the scope whole. It ran `nginx -t` on both
configs in the pinned image, the lego `run --help` of the pinned image, and a
bind-mount probe in a throwaway container. The relay config's sha256 matched
upstream at the pinned commit. A `qa-verifier` cell ran the offline acceptance
and found the same defect as finding 1 on its own.

Round 1 found one `P1` and six `P2` items, and no `P0`.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | The switch from staging to production renames the certificate folder. The running `terminate` container's bind mount stays on the renamed folder, so the reload serves the staging certificate again. | Adopted. Move the files, not the folder. After every reload, compare the certificate served on 8443 with the file, and fail on a difference. The test asserts the folder is the same one. |
| 2 | P2 | The folder is moved aside before the webroot check, so a refused run leaves no certificate. | Adopted: move only after the check passes. |
| 3 | P2 | Toggling between staging and production issues a new production certificate each time, and can reach Let's Encrypt's limit of 5 a week. | Adopted: `--staging` is refused while a production certificate has more than 80 h left, unless a deliberate flag is given. |
| 4 | P2 | A failed `docker compose ps` skips the reload silently and exits 0. | Adopted: the `ps` exit status is checked. |
| 5 | P2 | `SIGNAL_PROXY_FORCE` left in systemd's environment stops production renewals. | Adopted: force is an argument of one run (`systemd-run --wait … --force`), not environment. |
| 6 | P2 | An unexpected exception in the read thread stops the daily check, and a failed stamp write restart-loops the link. | Adopted: every exception sets a result, and a failed stamp write is logged, not raised. |
| 7 | P2 | The plan says the relay config is fetched; the module vendors it. | Adopted: the plan line is corrected. |

QA's cosmetic note, `in -8 h` for an expired certificate, is also adopted: it reads `expired 8 h ago`.
