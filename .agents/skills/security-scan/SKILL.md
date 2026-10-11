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

A high-precision, commit-time gate that stops a secret leak before it reaches
`git push`. A secret that reaches the remote is compromised even if reverted:
the revert removes it from the tip, not from the history every clone and fork
already holds, and the only remedy left is to rotate the key. That asymmetry —
a block costs a minute, a leak costs a rotation — is why this is a **hard
gate**, never a suggestion.

## Hard rules

- **Block on any high-confidence secret match.** No exceptions, and no "looks
  like a test value" override without the user's explicit approval in the chat.
  Looking like a test value is a property of the string, not of where it came
  from, and a live key can have it.
- **Scan staged content only** — `git diff --cached`, never the working tree.
  The working tree holds what the user has not chosen to commit; do not re-flag
  secrets the user already cleared.
- **Report the line and a masked preview**: enough to identify the leak without
  exposing it again in the chat, which is itself a log.
- **Treat the dependency check as advisory.** Report known vulnerabilities and
  warn; do not block. CI and dedicated dependency tooling own that gate, and a
  vulnerable transitive dependency is not a line the user can unstage.

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

For high-entropy values, prefer a real entropy measure (Shannon ≥ ~4.0
bits/char) to raw length, so long but structured values (UUIDs, base64 test
fixtures) do not false-fire. A gate that cries wolf on every UUID teaches its
user the override, and the override is how the real key gets through.

### Medium-confidence — WARN (exit 1)

- Hardcoded URLs to localhost or internal IPs in non-test code, which leak infrastructure topology.
- Email and password pairs in source.
- Private-range IPv4 (`192.168.*`, `10.*`, `172.16–31.*`) outside test code.
- Comments such as `// TODO remove before commit`, `// real key:`, `# hardcoded creds`.

## Execution

### 1. Pull the staged diff

```bash
git diff --cached --unified=0
git diff --cached --name-only --diff-filter=ACMR
```

### 2. Match added lines only

Scan the diff-body lines that begin with `+` — **not** the `+++` file headers,
and never the removed (`-`) lines: a commit that deletes a secret is the remedy,
not the leak. For each hit capture:
- file and line number;
- class name (such as "Stripe live key");
- masked preview: first 4 chars + `***` + last 4 chars.

### 3. False-positive allowlist

Downgrade a match to INFO — reported, not blocked — when any of these holds:

- The file path contains `test`, `spec`, `fixture`, `mock`, `example`, `sample`, `__snapshots__`.
- The value is an obvious placeholder: `xxxxxxxxxxxx`, `your-key-here`, `changeme`,
  `<API_KEY>`, `${ENV_VAR}`, `process.env.X`, `os.environ[...]`, `import.meta.env.X`.
- The value is an env-var reference, not a literal (`${...}`, `$VAR`, template interpolation).
- The line sits inside a comment explicitly marked `// example:` or `# example:`.

Still report these as INFO so the user can verify them: the allowlist judges
the path and the shape, never the value, and a real key pasted into a `test`
file is still a real key.

### 4. Dependency check (advisory)

When a manifest is staged (`package.json`, `requirements.txt`, `pyproject.toml`,
`go.mod`, `Gemfile`, `Cargo.toml`, `pom.xml`, …), run the project's native audit
command — pick it from the manifest; do not hardcode a package manager. The
agent chooses among such commands as `npm audit --audit-level=high`,
`pnpm audit`, `yarn npm audit`, `bun audit`, `pip-audit`, `osv-scanner`,
`govulncheck`, `bundler-audit`, `cargo audit`.

Report high and critical findings only. Never block on a dependency
vulnerability.

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

The exit code is the contract a pre-commit hook keys on, and the hook reads
nothing else: `2` must stop the commit; `1` is informational and lets it
through. A scan that prints HARD BLOCK and exits `1` has blocked nothing.

## Output style

Scan output stays plain prose. A leaked secret is a factual finding: report it
precisely, mask it, and give the one concrete remediation step. No drama, no
essay — the user who has just staged a key needs the line number, not the
lecture.
