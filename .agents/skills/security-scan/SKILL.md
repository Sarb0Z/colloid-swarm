---
name: security-scan
description: >
  Commit-time secret-and-dependency gate. Scans the staged diff for hardcoded
  secrets, credentials, API keys, and known-vulnerable dependencies, then hard-blocks
  the commit when a secret is present and warns on vulnerable deps. Use when the user
  types "security-scan", "/security-scan", "secret check", "scan for secrets", "did I
  stage a key", or as a pre-commit / pre-push gate before code leaves the machine.
---

# Security scan

A high-precision, commit-time gate: stop secret leaks before they reach `git push`.
A secret that reaches the remote is compromised even if reverted, so this is a
**hard gate**, never a suggestion.

## Hard rules

- **Block on any high-confidence secret match.** No exceptions, and no "looks like
  a test value" override without the user's explicit approval in the chat.
- **Scan staged content only** — `git diff --cached`, never the working tree. Do
  not re-flag secrets the user already cleared.
- **Report the line and a masked preview:** enough to identify the leak without
  exposing it again in the chat.
- **The dependency check is advisory.** Report known vulnerabilities; warn, never
  block. CI and dedicated dependency tooling own that gate.

## Secret corpus

### High-confidence — HARD BLOCK (exit 2)

| Class | Pattern |
|-------|---------|
| AWS access key id | `AKIA[0-9A-Z]{16}` |
| AWS secret key | `aws_secret_access_key\s*=\s*[A-Za-z0-9/+=]{40}` |
| GCP service account | `"type":\s*"service_account"` |
| Private key block | `-----BEGIN (RSA\|DSA\|EC\|OPENSSH\|PGP)? ?PRIVATE KEY-----` |
| GitHub token | `gh[pousr]_[A-Za-z0-9_]{36,}` |
| GitHub fine-grained PAT | `github_pat_[A-Za-z0-9_]{82}` |
| Slack token | `xox[abprs]-[A-Za-z0-9-]+` |
| Stripe live key | `sk_live_[A-Za-z0-9]{24,}`, `rk_live_[A-Za-z0-9]{24,}` |
| OpenAI key | `sk-[A-Za-z0-9]{32,}` |
| Anthropic key | `sk-ant-[A-Za-z0-9-_]{90,}` |
| JWT in code | `eyJ[A-Za-z0-9_=-]+\.eyJ[A-Za-z0-9_=-]+\.[A-Za-z0-9_=-]+` |
| DB URL with creds | `(postgres\|postgresql\|mysql\|mongodb(\+srv)?)://[^:\s]+:[^@\s]+@` |
| `.env` file staged | any staged path matching `**/.env`, `**/.env.*` — except `.env.example`, `.env.template`, `.env.sample` |
| Generic high-entropy | a string ≥ 32 chars matching `[A-Za-z0-9+/=_-]+` assigned to a var named `*secret*`, `*token*`, `*key*`, `*password*`, `*passwd*`, `*api_key*`, `*apikey*`, `*auth*` |

For high-entropy values, prefer a real entropy measure (Shannon ≥ ~4.0 bits/char)
to raw length, so long but structured values (UUIDs, base64 test fixtures) do not
false-fire.

### Medium-confidence — WARN (exit 1)

- Hardcoded URLs to localhost / internal IPs in non-test code (leaks infra topology)
- Email + password pairs in source
- Private-range IPv4 (`192.168.*`, `10.*`, `172.16–31.*`) outside test code
- Comments like `// TODO remove before commit`, `// real key:`, `# hardcoded creds`

## Execution

### 1. Pull the staged diff

```bash
git diff --cached --unified=0
git diff --cached --name-only --diff-filter=ACMR
```

### 2. Match added lines only

Scan diff-body lines beginning with `+` — **not** `+++` file headers, and never
removed (`-`) lines. For each hit capture:
- File + line number
- Class name (e.g. "Stripe live key")
- Masked preview: first 4 chars + `***` + last 4 chars

### 3. False-positive allowlist

A match is downgraded to INFO (reported, not blocked) when any of these hold:

- File path contains `test`, `spec`, `fixture`, `mock`, `example`, `sample`, `__snapshots__`
- Value is an obvious placeholder: `xxxxxxxxxxxx`, `your-key-here`, `changeme`,
  `<API_KEY>`, `${ENV_VAR}`, `process.env.X`, `os.environ[...]`, `import.meta.env.X`
- The value is an env-var reference, not a literal (`${...}`, `$VAR`, template interpolation)
- The line is inside a comment explicitly marked `// example:` / `# example:`

Still report these as INFO: a real key pasted into a `test` file is still a real
key.

### 4. Dependency check (advisory)

If a manifest is staged (`package.json`, `requirements.txt`, `pyproject.toml`, `go.mod`,
`Gemfile`, `Cargo.toml`, `pom.xml`, …), run the project's native audit command — pick it
from the manifest; do not hardcode a package manager. Examples the agent chooses among:
`npm audit --audit-level=high`, `pnpm audit`, `yarn npm audit`, `bun audit`, `pip-audit`,
`osv-scanner`, `govulncheck`, `bundler-audit`, `cargo audit`.

Report high and critical findings only. Never block on a dependency vulnerability.

### 5. Output format

```
security-scan results

HARD BLOCK — secrets detected:
  src/config.ts:14 — Stripe live key — sk_l***x2Qa
  .env:3 — staged .env file — FILE BLOCKED

WARN — review before commit:
  src/api.ts:88 — possible internal IP — 10.0.***.42

INFO — allowlisted match (sanity-check only):
  tests/fixtures/keys.ts:5 — high-entropy string in test path — ab12***f9c0

INFO — dep vulnerabilities (advisory):
  axios@0.21.1 — CVE-2021-3749 (high) — upgrade to ≥ 0.21.4

Action: unstage the offending lines with `git restore --staged <file>`,
remove the secret, and move it to an env var or secrets manager.
```

### 6. Exit-code contract

| Code | Meaning |
|------|---------|
| `0` | clean — no HARD findings |
| `1` | only WARN / INFO findings |
| `2` | HARD BLOCK — secrets present, refuse the commit |

The exit code is the contract a pre-commit hook keys on. `2` must stop the commit;
`1` is informational and lets it through.

## Output style

Scan output stays plain prose. A leaked secret is a factual finding: report it
precisely, mask it, and give the one concrete remediation step. No drama, no essay.
