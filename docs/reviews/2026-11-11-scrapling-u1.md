# Scrapling unit 1: code review round 1

Unit 1 of `docs/handoff/2026-11-11-scrapling-review-fixes.md`: a launcher,
`.agents/scrapling-mcp.py`, narrows Scrapling 0.5.1's MCP server (no launch
options, `cdp_url` or `new_context`; required `session_id`; the five denied
tools removed; `http`/`https` only with cloud-metadata hosts refused); the
registry launches it through `uvx ... python -I`; a firing test,
`.agents/test-scrapling-launcher.sh`, and a CI step. Commit `0041094` on
`30a74af`. Three reviewers, one axis each: security (opus), fidelity to
upstream Scrapling (opus), tests and CI (sonnet).

## Findings

| # | Sev | Finding | Evidence |
|---|---|---|---|
| C1 | P0 | `.github/workflows/ci.yml` uses `astral-sh/setup-uv@v10`, a tag that does not exist (`v10.0.0`..`v10.3.3` only); the job fails at "Set up job", so no scaffold suite gates | reproduced (`git ls-remote --tags`) |
| S1 | P1 | The metadata refusal compares the raw `url` string: `http://2852039166/`, `0xA9FEA9FE`, `0251.0376.0251.0376`, `169.254.43518`, a trailing dot, a percent-encoded host and `http://169.254.169.254\@example.invalid/` pass, and Chromium normalizes each to the metadata host; `extra_headers` supplies the headers Azure and Google require | reproduced with the loopback equivalents through the launcher (security; upstream at P2) |
| S2 | P2 | The `proxy` parameter of `browser_open` and `browser_fetch_once` sends every request to an unchecked host and port | reproduced |
| S3 | P2 | Redirects, navigation through `browser_evaluate` or `browser_actions`, and in-page `fetch` reach any host; the docstring's "cannot … fetch … a cloud-metadata host" is false outside the `url` argument; Playwright's blocked origins cover in-page navigation, so the launcher is weaker there | reproduced |
| S4 | P2 | The environment scrub misses `NODE_OPTIONS` (a planted `--require` ran in Patchright's driver) and `PLAYWRIGHT_BROWSERS_PATH` (chooses the Chromium binary) | reproduced |
| S5 | P2 | Names that resolve to a metadata address (`metadata.google.internal`, `instance-data`, `169.254.169.254.nip.io`) and other providers' addresses (`169.254.170.2`, `100.100.100.200`) pass; Playwright's list has the same gap | reproduced at the check |
| U1 | P2 | Upstream's server instructions, which Claude Code puts in the system prompt, still tell the model to start with HTTP and use `make_request`; `browser_open`'s kept description offers "remote" sessions | live |
| T1 | P1 | The test stays green when `browser_fetch`'s URL check, the `_resolve_executable_path` override or the `PROGRAM_ENV` removal is deleted | reproduced (three mutations) |
| T2 | P1 | The refusal rows try only `file:` and the two literal metadata addresses: no `ftp:`, `data:`, uppercase `FILE:`, IPv4-mapped form, and no address that must not be refused, so a launcher that refuses everything passes | reproduced (three mutations) |
| T3 | P2 | Only the five denied tools are asserted absent; the other twelve are not asserted present, `browser_fetch`'s schema is never read, and types and defaults are not compared with upstream's | reproduced |
| T4 | P2 | Dropping `==0.5.1` or `--exclude-newer` from the registry leaves the test green: the upstream side is built from the same arguments | reproduced |
| T5 | P2 | SIGTERM to the test leaves `uvx` and the launcher running; `os.killpg` raising `PermissionError` on macOS is uncaught | reproduced |
| T6 | P2 | In a satellite whose registry has no `scrapling` entry the test fails with `KeyError` instead of a visible skip; the test ships in the kit | inspection |
| T7 | P2 | The launcher's stderr is piped and never drained; more than a pipe buffer of stderr blocks the test until its 240-second timeout | inspection |

AMBIGUITY: "Their descriptions keep upstream's text" (the plan, unit 1) — (a)
word for word, even where the text names a removed capability; (b) except
where it describes something the narrowing removed; code: a.

Held, with evidence: no call launches a named program or passes launch
arguments (a `browser_fetch_once` with `executable_path`, `additional_args` and
`cdp_url` returned 200 from the bundled Chromium); no tool attaches to a running
browser or reaches a profile; `file://` is refused, a redirect to it fails with
`net::ERR_UNSAFE_REDIRECT`, and in-page navigation to it does not happen;
`python -I` keeps `.agents/` off `sys.path`; ten of twelve tool schemas equal
upstream's and the other two differ only by the narrowing; `session_id`'s
pattern is enforced by pydantic on the server; a dropped argument a client sends
is ignored; `remove_tool` raises on an absent name; `main()` matches
`scrapling.cli`'s stdio path.

## Review of the review

A fourth cell (opus), given the artifact and this table, reran every
reproducible finding and labelled none unsupported.

- **C1 is P1, not P0**: the job fails closed and loudly at "Set up job". It
  also found that no CI job has started since 2026-11-10: GitHub refuses them
  because the account's payments failed or its spending limit was reached
  (`gh run view 42797186652`), so a fixed workflow gives no signal until that
  is settled.
- **S1 stands, with one more form**: `http:\\169.254.169.254\` gives `urlsplit`
  an empty host. `extra_headers` delivered both providers' metadata headers.
- **S3 carries S1's severity**: a redirect reaches the same host with no
  encoding at all, so canonicalising the `url` argument alone leaves the
  docstring false.
- **T1 is P2 and partly unsupported**: deleting `_resolve_executable_path` or
  the `SCRAPLING_EXECUTABLE_PATH` removal changes no behaviour, because
  `main()` passes no program and the other layer covers it; the real gaps are
  `browser_fetch`'s URL check and `PLAYWRIGHT_NODEJS_PATH`.
- **T2 is P2**: a launcher that refuses everything fails closed on first use;
  uppercase `FILE:` is already caught, since `urlsplit` lowercases the scheme.
- **T7 is theoretical**: eight real fetches wrote about 3.5 KB of stderr.

It named two gaps:

| # | Sev | Finding |
|---|---|---|
| N1 | P2 | The launcher's "Claude only: the registry lists `scrapling` for no other host" is false until unit 5: `mcp_opencode.payload()` renders every enabled server |
| N2 | P2 | The test's client `select`s on the descriptor while a second JSON-RPC line may already sit in the text buffer, and asserts the next line is the reply, so a notification before a reply hangs or fails it |

## Dispositions

C1 and S1 block; the adopted P2s are fixed in the same correction, which
trails `0041094` (five commits sit on top of it, two of them recorded tips of
other runs).

| # | Disposition |
|---|---|
| C1 | Adopted at P1: pin `astral-sh/setup-uv@v10.3.3`. The billing stop goes to the operator |
| S1, S3 | Adopted together: a block inside the browser, set by the launcher on each browser context, aborts every request whose URL, as the browser canonicalised it, names a metadata host, so navigation through `browser_evaluate` or `browser_actions` and in-page `fetch` are covered. The `url` check stays as an early refusal with a clear message, reading the host as the browser would (percent-decoded, a trailing dot dropped, the numeric IPv4 forms `inet_aton` accepts) and refusing any URL containing `\`. Redirects stay open, as for Playwright; the docstring says so |
| S2 | Adopted: a `proxy` whose host is a metadata address is refused by the same reading |
| S4 | Adopted: the launcher removes every variable beginning `NODE_`, `PLAYWRIGHT_`, `PATCHRIGHT_`, `SCRAPLING_`, `DYLD_` or `LD_`; an allowlist was weighed and not taken, since it would also strip proxy and locale variables a run may need |
| S5 | Breadcrumb: metadata names and other providers' addresses, for this list and Playwright's together |
| U1 | Adopted, settling the ambiguity as (b): the server instructions drop the HTTP-first and `make_request` advice, `browser_open`'s description drops "or remote", and the test compares each description with upstream's after exactly those edits |
| T1 | Adopted at P2: rows for `browser_fetch`'s refusal, and an import check that the environment removal and `_resolve_executable_path` hold |
| T2 | Adopted at P2: `ftp:`, `data:`, the IPv4-mapped form, every S1 spelling, the backslash forms, and addresses that must pass |
| T3 | Adopted: the twelve tools asserted present, and each schema compared with upstream's minus the narrowing |
| T4 | Adopted: the registry's launch arguments asserted literally |
| T5 | Adopted: SIGTERM stops both processes; `PermissionError` from `killpg` is caught |
| T6 | Adopted: a registry with no `scrapling` entry prints a visible SKIP |
| T7 | Adopted: stderr goes to a file, since the test file changes anyway |
| N1 | Adopted: the sentence leaves the launcher; the hosts list (unit 5) is the one place that says where Scrapling runs |
| N2 | Adopted: the client reads lines until the reply's id, buffering what it has read |

## Round 2: the correction

The correction `9bd01dd` and `7a91eae` (lane `fix` of run `scrapling-u1-fix`)
put the block in a subsystem round 1 did not cover, a route inside the
browser, so it re-entered review. One reviewer (opus) drove patchright's
bundled Chromium and real Chrome against local servers on port 0, with every
session sent through a local catch proxy so no request reached a real metadata
address.

| # | Sev | Finding | Evidence |
|---|---|---|---|
| B1 | P1 | A `browser_fetch` of a page that redirects to `169.254.169.254`, with `extra_headers` carrying `Metadata: true` and `Metadata-Flavor: Google`, returns the metadata body to the model; Chromium's `--host-resolver-rules` with `MAP <host> ~NOTFOUND`, passed through Scrapling's `extra_flags`, blocks IP literals, numeric spellings, redirect hops and WebSockets in the network layer | reproduced; the flag reproduced with `MAP` to a local server on bundled Chromium |
| B2 | P2 | The page route is removed and re-added on each `browser_fetch`: 6 requests escaped across ten fetches on a page requesting the metadata host in a loop, and `Route.abort: Route is already handled!` tracebacks followed; once, through direct calls, the pool page stayed busy and later calls hung | reproduced twice |
| B3 | P2 | WebSocket handshakes and SharedWorker fetches never reach the route; the docstring and the test's `ws://` regex row claim them | reproduced on both browsers |
| B4 | P2 | `http:169.254.169.254/`, `http:/…`, `http:///…` and `https:169.254.169.254` pass the `url` check with an empty host, which Chromium reads as the metadata host; only the route stops them | reproduced |
| B5 | P2 | NAT64 `[64:ff9b::a9fe:a9fe]` and IPv4-compatible `[::a9fe:a9fe]` pass every check | reproduced; whether a cloud routes them is theoretical |
| B6 | P2 | The context route turns on request interception for every session, which disables the HTTP cache by Playwright's `route` documentation; nothing says so | inspection |
| B7 | P2 | The live rows run without a catch proxy, so a regression sends requests to the machine's real metadata service; no live row for a redirect, WebSocket, SharedWorker, iframe, form, `browser_actions` click, service worker or `url` navigation; CI installs no browser | inspection |
| B8 | P2 | `test-scrapling-launcher.sh` is 483 lines, and `_narrowed` takes 5 parameters | measured |

Held, with evidence: a page route outranks the context route, the newest
first (patchright 1.64.4 `_page.py`); Scrapling's own `route.continue_()`
cannot pass the launcher's page route; in-page `fetch` in both worlds, XHR,
`img`, `script`, iframe, `sendBeacon`, EventSource, prefetch, a dedicated
worker, a service worker's fetches, `window.open`, a link click through
`browser_actions`, a form POST, a meta refresh and `location.href` through
`browser_evaluate` are each blocked with `ERR_BLOCKED_BY_CLIENT` on both
browsers; the address reading matches Chromium on every round 1 spelling,
over-refusing only U+2024 and a trailing space; renaming either replaced
upstream method fails at import.

### Review of the review, round 2

A second cell (opus), given the artifact and the eight claims, reproduced each
through the same catch proxy, and tested the resolver rule with loopback
stand-ins only, since the rule does not apply under a proxy. Every finding is
supported at its severity.

- **B1**: the redirect read is reproduced on both browsers, the headers reaching
  the redirected hop. With `--host-resolver-rules=MAP 127.0.0.1 ~NOTFOUND`, an
  IP literal, its decimal spelling, a redirect to it, an in-page fetch, a
  WebSocket and a SharedWorker fetch each fail with `ERR_NAME_NOT_RESOLVED` on
  bundled Chromium 156 and real Chrome 157, and the server sees none. IPv6
  entries must be written without brackets (`MAP ::1`, not `MAP [::1]`), and
  the IPv4-mapped form needs its own hex entry. Under a proxy the rule does not
  apply: the request reached the catch proxy on both browsers.
- **B2**: one escape and two double-abort tracebacks on bundled Chromium, 29
  escapes and 81 tracebacks on real Chrome; in another run 4 of 10 calls did
  not return within 60 s, because an exception after the pool marks its one
  page busy skips `mark_ready`. With `blocked_domains` set, the chained aborts
  wrote 548 MB of stderr in five minutes. With only the context route: one
  escape, no hang.
- **B3**: a SharedWorker's fetch body came back through `browser_evaluate`, but
  only because the catch proxy sent `Access-Control-Allow-Origin: *`; a real
  metadata service sends none, so it is a request without a read.
- **B6**: scope corrected: `browser_fetch_once` keeps the session's ad list,
  whose own route already disabled the cache there.
- **B4, B5, B7, B8** reproduced or measured as stated.
- With the rule written without brackets and no proxy set, the route blocks
  nothing the rule misses. Under a proxy it still blocks direct, decimal,
  mapped, popup, iframe, worker and service-worker requests, and never
  redirects, WebSockets or SharedWorkers.

It named three gaps:

| # | Sev | Finding |
|---|---|---|
| G1 | P2 | In CI, where the live rows skip, only which methods are installed and an `isinstance(…, re.Pattern)` check gate the block: an installed but ineffective block stays green, against `.agents/rules/testing.md` |
| G2 | P2 | With a proxy on loopback or inside the network, a redirect, WebSocket or SharedWorker is resolved by the proxy, so B1's read stays open from that network; `_refuse_proxy` refuses metadata hosts only |
| G3 | P2 | Under a socks5 proxy, patchright's driver adds its own `--host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE <proxy host>"`; a second switch from the launcher collides with it |

### Dispositions, round 2

B1 blocks, so lane `fix` is reopened at P1. The round 1 line "Redirects stay
open, as for Playwright" is withdrawn: a native block exists.

| # | Disposition |
|---|---|
| B1 | Adopted: the launcher starts every browser it opens without a proxy with `--host-resolver-rules` mapping each metadata address, written without brackets, to `~NOTFOUND`, through Scrapling's `extra_flags`, which no tool exposes. What a session with a proxy gets is the operator's ruling (G2) |
| B2, B3, B6 | Moot with G2's ruling: they are defects of the route, which is removed |
| B4 | Adopted: an http(s) URL with an empty host is refused, with a row for each of the four spellings |
| B5 | Breadcrumb, with S5: the NAT64 and IPv4-compatible forms join the other providers' addresses |
| B7, G1 | Adopted: behavioural rows replace the method-identity rows. The rule-building function takes its address list, so a live row can pass loopback stand-ins and see each request kind fail while the server sees nothing, and a fast row asserts the list `main()` passes |
| B8 | Accepted: the rows B7 removes shrink the test; `_narrowed`'s fifth parameter is `doc`, a keyword with a default |
| G2 | Ruled by the operator: any proxy is kept and the gap is stated. The route and the two replaced upstream methods are removed; the launcher's docstring says that under a proxy the proxy resolves every address, so a redirect reaches the metadata service of the proxy's network. Recorded in the `scrapling-stealth-tier` decision |
| G3 | Adopted with B1: the rule is left out when a proxy is set, where it does not apply and the driver sets its own |

## Round 3: the resolver rule

The correction `7035000` replaced the route with the resolver rule on every
browser started without a proxy. Two reviewers, one axis each, since the
round opened before `review-at-delivery-boundaries` landed: the block (opus),
probing bundled Chromium, Chrome for Testing and real Chrome against servers
on 127.0.0.1 and ::1 and a local catch proxy; and the tests (sonnet), by 15
mutants through the whole script.

| # | Sev | Finding | Evidence |
|---|---|---|---|
| C1 | P1 | A `proxy` that proxies nothing, `{"server": "ftp=localhost:1"}` or `"http://ftp=localhost:1"`, passes `_refuse_proxy` and Scrapling's validation, so the launcher leaves the rule out; Chromium reads `--proxy-server=http://ftp=localhost:1` as a per-scheme list with no http entry and connects directly, and a redirect from a page reaches the stand-in address | reproduced on both browsers, with a dead real proxy as control |
| C2 | P1 | `_refuse_proxy` reads a dictionary `server` with `urlsplit`, patchright with the WHATWG URL parser: `http:H:P`, `http:/H:P`, `http:///H:P`, `//H:P` and `HTTP:H` pass the refusal, and the browser uses H as its HTTP proxy | reproduced with a catch proxy at 127.0.0.1 |
| C3 | P2 | The premise of G3's disposition is false: the rule applies to a proxy's own address, patchright writes its socks5 switch with literal double quotes so it maps nothing on macOS, the launcher's flags come later and the later switch is in effect, and a socks5 session launches with the rule | reproduced |
| C4 | P2 | "Without a proxy" ignores a system or environment proxy, which Chromium uses when no `--proxy-server` is given; `fd00:ec2::254` is not link-local, so it goes to that proxy | mechanism reproduced through a catch proxy; no system proxy on this machine |
| C5 | P2 | The test grew from 483 to 584 lines, against B8's premise | measured |
| D1 | P2 | The stdio refusal rows send a real request toward `169.254.169.254` when `METADATA_HOSTS` loses that address, since the refusal and the rule read one list, or when the proxy check regresses | reproduced by mutant |
| D2 | P2 | No fast row covers `proxy=""` or `{}`; `is None` in place of `not` stays green | reproduced by mutant |
| D3 | P2 | In CI, with no browser installed, the block is gated by the rule's exact text and the seam, not by Chromium's behaviour | inspection |
| D4 | P2 | No live row exercises a middle-compressed IPv6 address such as `fd00:ec2::254`; the real list's text is pinned by the literal row alone | inspection |
| D5 | P2 | The same measurement as C5 | measured |

The block reviewer named C2 the third round in which a Python check reads an
address differently from the browser, after round 1's S1 and round 2's B4.

### Review of the review, round 3

A third cell (opus), given the artifact and the findings, reproduced C1 to C4
and D4 under `sandbox-exec` with a profile that refuses every connection off
loopback, checked against a control.

- **C1, C2, C3, C4, C5, D1, D3, D4 and D5 are supported.** C3 holds with one
  nuance: a request sent through a proxy is still resolved by the proxy, not
  by the rule. D1's trigger is narrower than stated: a regression of the url
  check alone is still stopped by the rule.
- **D2 is unsupported**: the mutant is green but behaves the same, because
  `proxy=""` and `{}` fail at launch ("proxy: expected object, got string";
  "proxy.server: expected string, got undefined"), so no browser runs without
  the rule.
- **The three-round claim holds**: S1, B4 and C2 are one shape, and C1, where
  the launcher's "a proxy is set" disagrees with Chromium's "this proxy covers
  http", is a fourth case of it.
- With the rule passed on every launch, the cell found no new defect: a socks5
  session through a local socks server fetched a name and an address, a named
  proxy off the list worked, and a proxy at a listed address in any C2 spelling
  failed with `ERR_PROXY_CONNECTION_FAILED`. Mapping each real entry to
  127.0.0.1 and everything else to `~NOTFOUND`, nine spellings of the real
  addresses, `[fd00:ec2::254]` middle-compressed and in full among them,
  reached the local server. Windows is unverified: there patchright's own
  socks5 switch takes effect, and the launcher's, passed later, replaces it.

It named two gaps:

| # | Sev | Finding |
|---|---|---|
| H1 | P2 | `exercise()` in the live layer is 66 lines with 6 parameters, past the contract's 40-line and 4-parameter limits |
| H2 | P2 | The test encodes C1 and C2 as correct: a row asserts that any proxy launches with no rule, and `REFUSED_PROXIES` holds none of C2's spellings |

### Dispositions, round 3

C1 and C2 block, and the same shape has returned three rounds running, so the
choice went to the operator, who ruled on 2026-11-12 for the rule on every
launch, proxy or not, with the Python checks kept only as early, readable
refusals; recorded in the `scrapling-stealth-tier` decision. Lane `fix` is
reopened at P1.

| # | Disposition |
|---|---|
| C1 | Adopted, by the ruling: the launcher passes the rule whatever the proxy, so a proxy that proxies nothing leaves the rule in place |
| C2 | Adopted: the rule closes it, since the browser resolves its proxy through the rule. A dictionary `server` also gets the string form's early refusal: it must read as `<scheme>://<host>` with a scheme Scrapling accepts, so each C2 spelling is refused by name |
| C3 | Adopted with C1: the proxy branch is removed and the docstrings say what the rule covers. G3's disposition is withdrawn. Windows stays a reopen condition of the decision |
| C4 | Adopted: the launcher's docstring and the decision count a system or environment proxy as a proxy |
| C5, D5, H1 | Breadcrumb: B8's acceptance is withdrawn; the live and unit layers move into files the shell runs, and `exercise()` is split, as their own unit |
| D1 | Adopted: the metadata-address refusals move to the unit layer, which calls `_refuse_address` and `_refuse_proxy` directly and launches nothing; the stdio rows keep the refusals that send nothing when they fail (`file:///`, a backslash, `ftp:`) |
| D2 | Moot: unsupported, and with the rule on every launch a fast row asserts it for every proxy value, `""`, `{}` and C1's included |
| D3 | Accepted and recorded in the decision: CI checks the rule's text, a machine with the browser installed checks Chromium's behaviour |
| D4 | Adopted: a live row per browser maps each of the launcher's real entries to the local server and everything else to `~NOTFOUND`, first confirms that a `localhost` fetch fails to resolve, then sends the nine spellings and requires each to reach the server |
| H2 | Adopted: the row asserting no rule under a proxy is inverted; fast and live rows cover C1's values and C2's spellings |

### The correction, round 3

`ebce5b9` lands the adopted rows; `e8e2786` regenerates the demo starters that
other sessions' commits had left stale. The implementer ran its four mutants
through the whole script under a sandbox profile that refuses every
connection off loopback, checked against a control (curl to 127.0.0.1
succeeded, to 1.1.1.1 failed). Each mutant went red: the proxy branch
restored (7 rows), the shape refusal removed (12), an IPv6 entry in brackets
(26), and the D4 interlock off with the switch dropped (20, every
metadata-named request refused by the sandbox). The unchanged control was
green with 172 rows. The lead reran the script as committed (exit 0, 172
`ok`) and with the proxy branch restored (exit 1, the same 7 rows). A trailing
commit narrows one docstring, which claimed Linux behaves as macOS does,
untested. The correction settles `P1`s inside the subsystem this round
reviewed, under the operator's ruling, so it does not re-enter review.
Unverified: Windows and Linux; a live system or environment proxy; live rows
for C2's other four spellings, which unit rows cover.

QA (qa-verifier, sonnet) drove the launcher over stdio JSON-RPC, with every
launcher in a sandbox refusing connections off loopback, checked against a
control. A scratch copy stood in 127.0.0.1 and ::1 for the metadata
addresses. Across 84 calls on both browsers, with proxy
`http://ftp=localhost:1` or none, redirects and image requests to the
stand-ins recorded no hit; a copy without the rule hit every one. The five C2
spellings were refused by name through both tools. A socks5 session through
a local socks server fetched a local page with the real rule on. The run
`scrapling-u1-fix` passed `check` at `bc7b740` and is torn down.
