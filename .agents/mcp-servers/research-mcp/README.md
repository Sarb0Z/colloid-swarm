# research-mcp

Repository-owned MCP server for reading the public web. Two tools:

| Tool | Job |
| --- | --- |
| `fetch_readable` | Fetch a page or PDF, return the main text without navigation, advertising or boilerplate. Reads Wayback captures for dead URLs. |
| `resolve_open_access` | Resolve a DOI or paper title to legally readable open-access copies through Crossref, Unpaywall and arXiv. |

## Why it exists

A plain fetch hands an agent a full HTML document: navigation, consent banners,
advertising markup, and the article. Extraction cuts a 414 KB Wikipedia page to
36 KB of text, and a 934 KB news page to 10 KB. The agent spends its context on
the content instead of the chrome.

`resolve_open_access` covers the other half: a publisher landing page is often
paywalled while a legal open copy exists in a repository. The tool finds that
copy, and `fetch_readable` reads it — including PDFs, which most fetch tools
cannot parse at all.

## Configuration

All knobs are environment variables. Every one has a working default except the
contact address.

| Variable | Default | Meaning |
| --- | --- | --- |
| `RESEARCH_MCP_CONTACT_EMAIL` | unset | A real mailbox. Enables Unpaywall and puts Crossref calls in its polite pool. |
| `RESEARCH_MCP_REQUEST_TIMEOUT_MS` | `20000` | Per-request timeout. |
| `RESEARCH_MCP_MAX_BODY_BYTES` | `8388608` | Response size cap. |
| `RESEARCH_MCP_MAX_REDIRECTS` | `5` | Redirect hops permitted. |
| `RESEARCH_MCP_MIN_HOST_INTERVAL_MS` | `350` | Minimum gap between requests to one host. |
| `RESEARCH_MCP_RETRIES` | `2` | Extra attempts per redirect hop. Set `0` to disable retrying. |
| `RESEARCH_MCP_RETRY_BASE_DELAY_MS` | `500` | First backoff delay. Each further attempt doubles it. |
| `RESEARCH_MCP_RETRY_MAX_DELAY_MS` | `8000` | Ceiling for a backoff delay. A `Retry-After` header is honoured up to four times this value. |
| `RESEARCH_MCP_FETCH_BUDGET_MS` | `120000` | Wall-clock ceiling for one fetch, shared by every redirect hop and retry. |

Each value must be an integer in its permitted range. The server refuses to
start when one is not, and names the variable.

The budget bounds one fetch. A single `fetch_readable` call makes up to three:
the live page, the archive index, and the capture. Size the value against one
fetch, not against the whole tool call.

Unpaywall rejects placeholder addresses, so the server refuses to start with an
`example.com`-class domain rather than fail on every lookup. Without the
variable set, Unpaywall is skipped and each result says so; Crossref and arXiv
still work.

## Network policy

The server is handed URLs by pages it does not control and follows their
redirects, so the address guard runs on **every hop**, not once at entry:

- Only `http:` and `https:`. No credentials in the URL.
- Every address a hostname resolves to must be public. One private answer in a
  multi-record reply rejects the whole name.
- Loopback, RFC 1918, carrier-grade NAT, link-local (including cloud metadata at
  `169.254.169.254`), multicast and reserved ranges are refused, in IPv4, IPv6,
  and IPv4-mapped IPv6 form.
- Connections are pinned to the addresses the guard validated, and sockets are
  never pooled, so a name cannot resolve to a public address and then connect to
  a private one.
- A failed live fetch may fall back to the archive; a **policy** rejection never
  does, because the archive would otherwise be a way around the guard.
- A hop may be attempted more than once. Each retry re-acquires the per-host
  interval, so retrying cannot send requests faster than the configured pace.
- A live page that is an anti-bot challenge counts as a block, not as content.
  The server reports `failure: "blocked"` and reads the archive instead.

Requests identify themselves as `colloid-research-mcp/<version>`, with the
contact address when one is configured.

## Build

```sh
npm install
npm run build      # after any change under src/
npm run check      # typecheck, lint, test, deterministic bundle, SBOM
```

`dist/server.js` is committed and self-contained: it runs from a clone with no
install step. The MCP client starts this server at session start, and no step in
that path installs dependencies or builds first, so the tracked bundle must run
with no install and no network.

`npm run check` does not build. `npm run check:bundle` proves the committed
bundle matches a clean rebuild, so a stale `dist/` fails the check instead of
being overwritten by it. Build first, then commit `dist/` with the source that
produced it.
