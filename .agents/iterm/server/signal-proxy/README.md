# Signal TLS proxy on contabo-hop

signal-cli on the Mac reaches Signal through this proxy on
`62.171.166.213:8443`, with a Let's Encrypt certificate for the IP address.
The design, the facts behind it, the acceptance values and the undo are in
`docs/notes/2026-11-18-signal-tls-proxy-plan.md`.

| File | What it is |
|---|---|
| `compose.yaml` | Two pinned nginx containers: `terminate` (publishes 8443 only) and `relay`. |
| `terminate.conf` | The outer TLS, with lego's certificate, passed on to `relay:4433`. |
| `relay.conf` | Upstream's relay config, unchanged, vendored at the commit in `relay.pin` and checked against its sha256 before every run. |
| `lego.sh` | The one lego v5.6.0 command line that issues and renews, with the 80 h guard, the webroot check and the reload. |
| `signal-proxy-renew.service`, `.timer` | `lego.sh` twice a day. |
| `setup-proxy.sh` | Runs as root on the server and changes only what differs. |
| `apply-proxy` | Run it from the Mac. It sends this folder over ssh and runs `setup-proxy.sh`. |
| `test.sh` | The offline tests, with stand-ins for docker, lego, systemd, curl and openssl. |

`relay.conf` is vendored, not fetched on the server. Then `--check` and the
tests need no network, and the server needs no GitHub access. To move the pin,
fetch the file at the new commit, set its `commit` and `sha256` in `relay.pin`,
and review the diff:

```
curl -fsSL -o relay.conf https://raw.githubusercontent.com/signalapp/Signal-TLS-Proxy/<commit>/data/nginx-relay/nginx.conf
shasum -a 256 relay.conf
```

## Runbook

Run each step from the Mac, in this folder.

1. `./apply-proxy --check`: read the list of changes. Nothing changes and
   nothing is fetched.
2. `./apply-proxy --staging`: the proxy runs with a staging certificate.
   Check acceptance 1, 2 and 4 to 6 of the plan. For acceptance 5, on the server:

   ```
   systemctl set-environment SIGNAL_PROXY_FORCE=1
   systemctl start signal-proxy-renew
   systemctl unset-environment SIGNAL_PROXY_FORCE
   journalctl -u signal-proxy-renew -n 30
   ```

   `lego.sh` refuses `SIGNAL_PROXY_FORCE` against production.
3. `./apply-proxy`: the staging certificate is moved aside and a production
   certificate is issued. Check acceptance 3, then 7.
4. `../../install.sh --tls-proxy 62.171.166.213:8443`: the phone link's
   signal-cli uses the proxy. Check acceptance 8 to 10.

Each run writes the server's network state to
`/root/backups/signal-proxy-<date>/` before its first change.
Roll back when acceptance 1 or 2 fails. The plan's Undo section gives the steps.
