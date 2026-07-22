---
name: security-scan
description: >
  Commit-time secret-and-dependency gate. Scans the staged diff for hardcoded
  secrets, credentials, API keys, and known-vulnerable dependencies, then HARD-BLOCKS
  the commit when a secret is present and warns on vulnerable deps. Use when the user
  types "security-scan", "/security-scan", "secret check", "scan for secrets", "did I
  stage a key", or as a pre-commit / pre-push gate before code leaves the machine.
---

# Security Scan Skill

A high-precision, commit-time gate. Stop secret leaks before they reach `git push`.
Once a secret hits the remote it is compromised even if reverted — so this is a
**hard gate**, never a suggestion.

---

## Hard Rules

- **Block on any high-confidence secret match.** No exceptions. No "looks like a test
  value" override without an explicit, in-chat user confirmation.
- **Scan staged content only** — `git diff --cached`, never the working tree. Don't
  re-flag secrets the developer already cleared.
- **Surface line + masked preview.** Show enough to identify the leak without
  re-exposing it in chat.
- **Dependency check is advisory.** Flag known vulns; warn, don't block. CI and
  dedicated dep tooling own that gate.

---

## Secret Corpus

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

For high-entropy: prefer a real entropy check (Shannon ≥ ~4.0 bits/char) over raw
length so long-but-structured values (UUIDs, base64 test fixtures) don't false-fire.

### Medium-confidence — WARN (exit 1)

- Hardcoded URLs to localhost / internal IPs in non-test code (leaks infra topology)
- Email + password pairs in source
- Private-range IPv4 (`192.168.*`, `10.*`, `172.16–31.*`) outside test code
- Comments like `// TODO remove before commit`, `// real key:`, `# hardcoded creds`

---

## Execution Steps

### 1. Pull the staged diff

```bash
git diff --cached --unified=0
git diff --cached --name-only --diff-filter=ACMR
```

### 2. Match added lines only

Scan lines beginning with `+` in the diff body — **not** `+++` file headers, and never
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

Still surface these as INFO so the developer can sanity-check — a real key pasted into
a `test` file is still a real key.

### 4. Dependency check (advisory)

If a manifest is staged (`package.json`, `requirements.txt`, `pyproject.toml`, `go.mod`,
`Gemfile`, `Cargo.toml`, `pom.xml`, …), run the project's native audit command — pick it
from the manifest, don't hardcode a package manager. Examples the agent chooses among:
`npm audit --audit-level=high`, `pnpm audit`, `yarn npm audit`, `bun audit`, `pip-audit`,
`osv-scanner`, `govulncheck`, `bundler-audit`, `cargo audit`.

Report high/critical findings only. Never block on a dep vuln.

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

---

## Output Style

Scan output stays plain prose. A leaked secret is a factual finding — report it
precisely, mask it, and give the one concrete remediation step. No drama, no essay.
