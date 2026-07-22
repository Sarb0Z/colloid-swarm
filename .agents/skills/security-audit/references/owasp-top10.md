# OWASP Top 10 — Detection Patterns for Code Review

Quick reference for the auditor. For each category: what to look for in code.

---

## A01 — Broken Access Control

**Code patterns to grep for:**
- Direct object references without ownership check: `findById(req.params.id)` with no `.where({ userId: req.user.id })`
- Role checks in UI only: `{isAdmin && <AdminPanel />}` but no server-side guard
- Method-level auth bypassed: middleware on router but individual handler skips it
- Mass assignment: `Model.update(req.body)` without `permit()`/`pick()`

**Test:** Change `:id` in URL to another user's resource ID. Change `role=user` to `role=admin` in request body.

**Mass-assignment framework guards** — spreading `req.body` into a model binds attacker-chosen fields (`role`, `isAdmin`, `tenant_id`, `email_verified`). Each framework has a native allowlist; the *absence* of the safe form is the finding:

| Framework | Unsafe (flag this) | Safe guard |
|---|---|---|
| Rails | `Model.update(params.permit!)` / raw `params` | `params.require(:x).permit(:a, :b)` |
| Django | `ModelForm` with `fields = '__all__'` | explicit `fields = [...]` allowlist |
| NestJS | DTO with no validation pipe | `ValidationPipe({ whitelist: true, forbidNonWhitelisted: true })` |
| Laravel | `$guarded = []` | `$fillable = [...]` allowlist |
| Mongoose | `new User(req.body)` / `User.create(req.body)` | pick fields explicitly before construct |

---

## A02 — Cryptographic Failures

**Code patterns:**
- `md5(password)`, `sha1(password)`, `sha256(password)` for password storage
- Secrets in code: `const SECRET = "abc123"`, `API_KEY = "sk-..."`
- HTTP URLs for sensitive endpoints
- `Math.random()` for token generation (not cryptographically secure)
- JWT `alg: none` accepted
- `verify: false` in TLS/HTTPS config

**Encryption at rest (IaC):**
- `aws_db_instance` / `aws_rds_cluster` without `storage_encrypted = true`
- `aws_s3_bucket` without server-side encryption (`server_side_encryption_configuration`) — low-severity hygiene, not proof of an exposure: S3 applies default SSE-S3 to all new objects since Jan 2023, so the missing block means "not explicit", not "unencrypted". Real gaps are a *disabled* config or a bucket needing SSE-KMS/CMK it doesn't have.
- `aws_ebs_volume` without `encrypted = true`

---

## A03 — Injection

**SQL Injection:**
```js
// VULNERABLE
db.query(`SELECT * FROM users WHERE email = '${req.body.email}'`)
// SAFE
db.query('SELECT * FROM users WHERE email = ?', [req.body.email])
```

**NoSQL Injection:**
```js
// VULNERABLE — user can pass { $gt: "" }
User.find({ email: req.body.email })
// SAFE — cast to string
User.find({ email: String(req.body.email) })
```

**Command Injection:**
```python
# VULNERABLE
os.system(f"convert {filename} output.pdf")
# SAFE
subprocess.run(["convert", filename, "output.pdf"])
```

---

## A04 — Insecure Design

- No rate limiting on sensitive endpoints
- No account lockout
- Password reset tokens that don't expire
- Predictable resource IDs (sequential integers)
- Business logic that can be replayed

---

## A05 — Security Misconfiguration

- `DEBUG = True` in production
- Default credentials not changed
- Stack traces exposed in error responses
- CORS `*` on authenticated APIs
- Unnecessary HTTP methods enabled
- Missing security headers

**Cloud storage — presigned URL TTL:**
- `getSignedUrl` / `generate_presigned_url` / `createPresignedPost` — judge the TTL against *proportionality*, not a fixed number: the shortest window the flow actually needs. An avatar upload wants seconds–minutes; a user-forwardable report export or email-embedded asset link legitimately runs 15 min–1 hr. Flag TTLs that are long *and* on sensitive/forwardable objects, or an obvious mismatch (a one-shot upload URL good for 24h) — not every `expiresIn > 300`.
- Raw `*.s3.amazonaws.com` URLs in code bypass the presign flow entirely — verify they're not serving private objects.

**Container hardening (Dockerfile / compose):**
- No `USER` directive (runs as root) or explicit `USER root`
- `FROM …:latest` or untagged `FROM` (implicit latest) — pin the version
- `ADD https://…` — prefer `COPY` + a verified download
- compose `privileged: true`, `network_mode: host`, `cap_add: SYS_ADMIN`

**Edge / infra-IP leak:**
- Public IPv4 literal in client-visible files (`frontend/`, `public/`, `static/`, `*.md`) lets an attacker bypass the edge and hit origin directly.
- `X-Powered-By` / `Server` / `X-Backend-Server` response headers — strip in prod.
- Public web routes must sit behind the CDN/proxy (e.g. Cloudflare `proxied = true`); a `proxied = false` DNS record on a public route exposes origin.

---

## A06 — Vulnerable Components

Run `npm audit`, `pip-audit`, `bundler-audit`. Flag any HIGH/CRITICAL severity findings.

Common high-risk packages: outdated `jsonwebtoken`, `lodash` (prototype pollution), `axios` (SSRF), `multer` (path traversal).

---

## A07 — Authentication Failures

- No brute-force protection on login
- Weak password policy (or none)
- Session not invalidated on logout
- Insecure "remember me" implementation
- Credentials in URL parameters

**Timing oracle on auth:**
- Plain `==` / `===` on `password` / `token` / `secret` / `api_key` — use `crypto.timingSafeEqual` / `hmac.compare_digest`.
- User-not-found path short-circuits (`if (!user) return`) *before* the password hash runs → response time distinguishes "no such user" from "wrong password". Always run a dummy hash compare on the not-found branch.
- The real fixes are the two above — constant-time compare + a dummy-hash on the not-found branch. Random jitter (`setTimeout(r, 200 + Math.random()*100)`) is cosmetic: an attacker averaging over many requests sees through it. It does **not** substitute for a constant-time compare; treat a `==` on a secret as unhandled even if jitter is present.

---

## A08 — Software and Data Integrity Failures

- No integrity checks on downloaded packages/plugins
- Deserialization of user-supplied data without validation
- CI/CD pipeline modifications without review

**Webhook signature verification:**
- A `/webhook` / `/callback` / `/hook` handler with no signature check (`verifySignature`, `constructEvent`, `x-hub-signature`, `crypto.createHmac`, `hmac.compare_digest`) — anyone can forge events. Verify the HMAC/provider signature against the **raw** body before processing.

**CI security-scan step:**
- `.github/workflows/*` with no scanner (`trivy`, `snyk`, `gitleaks`, `trufflehog`, `semgrep`, `codeql`, `grype`, `bandit`, `safety`, `npm audit`, `pip-audit`) — vulns and secrets ship unblocked. Add a scanner job that gates the pipeline.

---

## A09 — Security Logging Failures

- No logging of failed login attempts
- No logging of access control failures
- Log injection: user input written directly to logs without sanitization
- Sensitive data (passwords, tokens) written to logs

---

## A10 — SSRF

```python
# VULNERABLE
response = requests.get(user_supplied_url)

# Check for: internal URLs, cloud metadata endpoints
# 169.254.169.254 (AWS metadata)
# 127.0.0.1, localhost, 0.0.0.0
# Internal hostnames
```

Validate URLs against an allowlist of permitted domains and block internal IP ranges.

---

## Dynamic-only vuln classes (DAST)

These need a running target — static code review can't confirm them. Non-destructive probes only.

**Verdict rule (applies to every probe below):** VULNERABLE only on `2xx` **plus** the privileged effect or foreign data actually present in the body. A bare `2xx` is NOT proof — read the object back, or diff body length/hash against a gated baseline (guards against soft-200 error pages). `401`/`403` = secure, `405` = method-blocked, `404` = ambiguous-but-denied.

**Web cache deception / poisoning** (high) — append a static-looking suffix to a sensitive authenticated page (`/account/profile.css`, `/account/profile/x.js`, `;.css`). If private content still returns AND a cache header shows it was edge-cached (`Age>0`, `X-Cache: HIT`, `CF-Cache-Status: HIT`), another user can pull the cached response. Poisoning: unkeyed headers (`X-Forwarded-Host`, `X-Forwarded-Scheme`) that influence the body but aren't in the cache key. Detection only — never persist harmful content.

**GraphQL abuse** (medium→high) — endpoint at `/graphql` / `/graphiql`. Send minimal introspection `{__schema{queryType{name} types{name}}}`; if it answers in prod, the full attack map is exposed. Then check: field-level auth gaps (role sees data it shouldn't), query batching/aliasing to bypass rate limits (login aliased 100×), unbounded nested/recursive queries (no depth/complexity cap), mutations without auth or accepting `role`/`isAdmin` args. No destructive mutations or huge nested queries.

**SSTI** (critical) — user input rendered through a server-side template engine (Jinja2, Twig, Freemarker, ERB, Handlebars, Razor); escalates to RCE. Submit a guarded arithmetic canary across syntaxes at once — `{{7*7}}${7*7}#{7*7}<%=7*7%>`. If the response contains `49` (not the literal `{{7*7}}`), the engine evaluated it. `7*7` is sufficient proof — no RCE/file-read gadgets.

**XXE** (high) — endpoint parsing XML/SVG/SOAP/DOCX/XLSX/RSS. POST a **benign internal** entity only: `<!DOCTYPE t [<!ENTITY x "CANARY">]>` referenced as `&x;`. If `CANARY` appears expanded, the parser resolves entities. Never use `SYSTEM`/external/parameter entities or `file://`/`http://` — internal expansion is enough. Fix: disable DTD/external entities in the parser.

**Clickjacking** (medium) — HTML page with neither `X-Frame-Options: DENY/SAMEORIGIN` nor CSP `frame-ancestors` can be framed by any origin (UI redress against authenticated actions). Prioritize login/account/admin/payment pages. Header presence is deterministic → high confidence.

**CRLF / response splitting** (high) — user input reflected into a response header. Inject `\r\n` (`%0d%0a`) in a header-bound value; if a following `X-Injected: yes` header appears in the response, the server split it. Enables header injection and cache poisoning.

**TOCTOU / race condition** (high) — non-atomic check-then-act (gift-card redemption, balance deduction, voucher use). Fire ≤3 parallel identical requests (localhost/staging only, never prod payment endpoints); if the balance/counter goes below zero or the token is consumed twice, the guard isn't atomic. Confidence high only with a reproduced race.
