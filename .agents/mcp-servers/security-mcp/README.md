# Security MCP

This directory contains the repository-owned security MCP server. The server exposes three tools:

- `validate_target`
- `security_scan`
- `list_security_prompts`

The server permits loopback targets. Set `SECURITY_MCP_ALLOWED_HOSTS` to a comma-separated list of exact staging hostnames. Configured staging hosts must use HTTPS and must resolve only to public addresses. The server rejects production-like hostnames.

The scan is read-only and sequential. It does not create accounts, call an LLM, load a `.env` file, write a report, or persist credentials. The server removes each supplied credential value and its common URL-encoded forms before it extracts data, matches templates, creates findings, records errors, or serializes an MCP result.

The result contains coverage for the root, crawl, content-discovery, and template phases. A root request or asset-loader failure returns `ok:false` and an MCP error. A later request failure increments its phase failure count and adds a redacted failure record. A response that exceeds the body limit is stopped and marked `truncated`.

The scanner accepts zero or one credential set. It does not run principal-to-principal differential tests. The coverage result marks IDOR, BOLA, BFLA, privilege escalation, and tenant isolation as untested. The prompt catalog keeps the instructions for a separate authorized workflow, but the scanner does not emit findings for these classes.

Use Node.js 20.19 or newer. Run these commands from this directory:

```sh
npm ci --ignore-scripts
npm run check
```

`dist/` is committed. The MCP client starts this server at session start, and no step in that path installs dependencies or builds first, so the tracked bundle must run from a clone with no install and no network. Commit `dist/` together with the source that produced it.

`npm run build` creates `dist/server.js` and copies the tracked templates and wordlist below `dist/`. The bundled server reads its assets from `dist/`, so the copies must stay in the commit. `npm run check:bundle` first verifies each current distribution file against `.build-manifest.json`. It then proves that the verified distribution matches a clean build. `npm run sbom` creates `sbom.cdx.json` from `package-lock.json` without a timestamp or random identifier.

The hard environment limits are:

- `SECURITY_MCP_REQUEST_TIMEOUT_MS`: 250 to 30000; default 10000.
- `SECURITY_MCP_MAX_REQUESTS`: 1 to 100; default 25.
- `SECURITY_MCP_MAX_DEPTH`: 0 to 3; default 2.
- `SECURITY_MCP_MAX_REDIRECTS`: 0 to 5; default 3.
- `SECURITY_MCP_MAX_BODY_BYTES`: 1024 to 1048576; default 262144.

The scanner sends one request at a time. Tool input cannot increase these limits or add an authorized host. A deep scan reserves separate request budgets for crawl, content discovery, and template checks. One phase cannot consume another phase's reserved requests.
