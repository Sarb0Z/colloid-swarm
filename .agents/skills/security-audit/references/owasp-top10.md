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

---

## A02 — Cryptographic Failures

**Code patterns:**
- `md5(password)`, `sha1(password)`, `sha256(password)` for password storage
- Secrets in code: `const SECRET = "abc123"`, `API_KEY = "sk-..."`
- HTTP URLs for sensitive endpoints
- `Math.random()` for token generation (not cryptographically secure)
- JWT `alg: none` accepted
- `verify: false` in TLS/HTTPS config

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

---

## A08 — Software and Data Integrity Failures

- No integrity checks on downloaded packages/plugins
- Deserialization of user-supplied data without validation
- CI/CD pipeline modifications without review

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
