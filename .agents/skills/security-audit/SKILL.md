---
name: security-audit
description: >
  Comprehensive source-only adversarial security review of a full-stack codebase. Use this skill
  to inspect application code, configuration, and dependencies for authentication, authorization,
  rate limiting, input validation, role-based access, session handling, or API risks. It triggers
  for "security review", "security audit", "check my codebase", "find vulnerabilities", or a
  request to assess pasted code. It does not contact a live target; use dynamic-security-scan for
  an explicitly authorized localhost or staging scan.
---

# Security Audit Skill

A systematic, adversarial, full-stack security audit covering every layer, from Phase 1 through Phase 10.

---

## Phase 0 — Orient Before You Act

Before writing any audit output:
1. `ls` / `tree` the project root to understand the stack (Next.js? Django? Express? Laravel?)
2. Identify: auth framework, DB layer, ORM, session store, role model, and any external services
3. Read `package.json`, `requirements.txt`, `Gemfile`, `go.mod`, or equivalent to spot dependency risks
4. Note `.env.example` / config files — never print secrets, just flag patterns
5. Build a **feature map**: list every route, controller, model, and role you can find before auditing

Document your findings in `security-audit-report.md` from the very first step and **keep updating it continuously** throughout the audit. Never batch findings at the end.

---

## Execution Contract

Read this before starting Phase 1 — it defines how findings get recorded, not just what to look for.

### Work feature by feature, not file by file

For each feature:
1. Identify the frontend components / pages
2. Trace to the API endpoint(s)
3. Trace to the controller / service
4. Trace to the DB query
5. Apply the relevant checklists from Phases 1–10
6. Record every finding in `security-audit-report.md` immediately

### Finding severity levels

Use these consistently in the report:

| Level | Meaning |
|-------|---------|
| 🔴 CRITICAL | Direct unauthorized data access, auth bypass, RCE |
| 🟠 HIGH | Privilege escalation, persistent XSS, IDOR |
| 🟡 MEDIUM | Rate limit missing on sensitive endpoint, info disclosure |
| 🔵 LOW | Minor info leak, missing security header, UX-only issue |
| ⚪ INFO | Best practice gap, not exploitable but worth fixing |

### Report Format

Keep `security-audit-report.md` updated continuously. Use this structure:

```markdown
# Security Audit Report — [Project Name]
**Date:** [date]  
**Auditor:** Claude  
**Stack:** [detected stack]

## Summary
- 🔴 Critical: N
- 🟠 High: N  
- 🟡 Medium: N
- 🔵 Low: N
- ⚪ Info: N

## Findings

### [SEVERITY] [Short Title]
**File/Location:** `path/to/file.js:42`  
**Description:** What the issue is and why it matters.  
**Reproduction:** How to trigger it (request, UI steps, etc.)  
**Recommendation:** Concrete fix with code snippet if helpful.  
**Status:** Open

---
[repeat for each finding]

## Coverage Log
[List each feature/module audited and the date/time it was completed]
```

---

## Standing Invariant — Never Trust the Client

Every security-relevant decision — role, auth state, ownership, input validity — must be
enforced server-side. A client-side equivalent (hidden button, disabled field, browser
validation, a role read from `localStorage`) is a UX convenience, not a control. The
checklists below apply this per phase; where a phase names a specific vector (role in a
request payload, token storage, unvalidated input), that is the concrete check — this
invariant is why it matters.

---

## Phase 1 — Authentication & Session Security

### Checklist
- [ ] Password hashing: bcrypt/argon2 with proper cost? Never MD5/SHA1/plaintext
- [ ] Tokens (JWT/session): signed, short-lived, secret stored securely?
- [ ] Sessions invalidated on logout AND on user disable/delete?
- [ ] Sessions invalidated after password change?
- [ ] Concurrent session limits respected?
- [ ] "Remember me" tokens: stored hashed, expiry enforced?
- [ ] OAuth / SSO: state param validated? redirect_uri whitelisted?
- [ ] MFA: bypass possible? backup codes single-use?
- [ ] Account lockout after N failed attempts?
- [ ] User enumeration via login error messages?
- [ ] Logged-in users auto-redirected away from `/login`, `/register`?

### How to verify
Search for session creation/destruction code and trace what happens when `is_active=false` or equivalent is set. Grep for logout handlers and confirm they call `session.destroy()` / `invalidateToken()` / equivalent.

---

## Phase 2 — Authorization & Role-Based Access Control (RBAC)

### Checklist
- [ ] Every API endpoint has an explicit auth check — no implicit "if logged in, allowed"
- [ ] Roles are assigned at login and attached to the session — not re-fetched from a client-supplied param
- [ ] Privilege escalation: can a regular user create an admin user?
- [ ] Horizontal privilege escalation: can User A access User B's data by changing an ID in the URL/body?
- [ ] Every hidden or disabled UI element (admin pages, role-gated buttons/fields) is matched by a server-side block on the same action?
- [ ] Role checks enforced server-side (not from a client-supplied `role` field)?
- [ ] Insecure Direct Object Reference (IDOR): `GET /api/invoice/:id` — does it check ownership?
- [ ] Soft-deleted / disabled records: can they still be fetched via direct ID lookup?
- [ ] Role hierarchy enforced: can a manager grant permissions above their own level?

### How to verify
Pick 3–5 CRUD endpoints. For each: find the route handler, check that the auth middleware is applied, check that the ownership/role check is present inside the handler (not just at the router level), and confirm the DB query scopes to the current user/org.

---

## Phase 3 — Password Reset & Account Recovery

### Checklist
- [ ] Reset tokens: cryptographically random (not sequential IDs, not predictable hashes)?
- [ ] Reset tokens: single-use — invalidated immediately after first use?
- [ ] Reset tokens: short TTL (≤1 hour)?
- [ ] Reset link: does it still work after the user has already reset their password?
- [ ] No rate limit on `/forgot-password` → account enumeration / email bombing
- [ ] Reset form: does accepting the token automatically log the user in (skipping password entry)?
- [ ] Email oracle: does `/forgot-password` behave differently for registered vs unregistered emails?

---

## Phase 4 — Rate Limiting & Abuse Prevention

### Checklist
- [ ] Login endpoint rate-limited (per IP, per username)?
- [ ] Password reset rate-limited?
- [ ] OTP / verification code rate-limited (no brute force)?
- [ ] Expensive API operations (search, export, email send) rate-limited?
- [ ] File upload size & type limits enforced server-side?
- [ ] No endpoint accepts unbounded list operations (always paginated)?
- [ ] GraphQL: query depth / complexity limits?
- [ ] Webhooks / callback URLs validated to prevent SSRF?

---

## Phase 5 — Input Validation & Injection

### Checklist
- [ ] All user input validated and sanitized server-side?
- [ ] SQL injection: raw queries with string interpolation? ORM used everywhere? Parameterized queries?
- [ ] NoSQL injection: `{ $where: userInput }` patterns?
- [ ] XSS: user content rendered as raw HTML? `dangerouslySetInnerHTML`? `v-html`? `innerHTML`?
- [ ] Command injection: `exec()`, `shell_exec()`, `subprocess` with user input?
- [ ] Path traversal: `../` in file paths, user-controlled filenames?
- [ ] SSRF: URLs constructed from user input and then fetched server-side?
- [ ] XXE: XML parsing with external entities enabled?
- [ ] Open redirect: `?next=`, `?redirect=` not validated against allowlist?
- [ ] Mass assignment: `User.update(req.body)` without field allowlist?

### Dates & Time Fields
- [ ] Date inputs validated to prevent nonsensical values (e.g. start > end, dates far in future/past)?
- [ ] Timezone handling consistent — all stored as UTC?
- [ ] Date math handles edge cases (leap years, DST transitions)?

---

## Phase 6 — API Design & Data Exposure

### Checklist
- [ ] Response objects scoped — no returning full DB row when only 3 fields are needed
- [ ] Internal IDs, hashes, or system metadata not leaked in API responses
- [ ] List endpoints paginated with max page size enforced?
- [ ] Filtering parameters validated — no arbitrary column injection into queries?
- [ ] Verbose error messages in production? Stack traces exposed?
- [ ] HTTP methods restricted: `GET` routes not performing mutations?
- [ ] CORS: `Access-Control-Allow-Origin: *` on authenticated endpoints?
- [ ] Content-Type enforced on uploads?
- [ ] API versioning — old/deprecated endpoints still active and unprotected?
- [ ] Unnecessary data returned: audit the 5 most-used endpoints for over-fetching

---

## Phase 7 — Frontend Security

### Checklist
- [ ] Auth state only from server-verified token — not from `localStorage.role`?
- [ ] Sensitive data (tokens, PII) in `localStorage`? (prefer `httpOnly` cookies)
- [ ] React / Vue / Angular: no `dangerouslySetInnerHTML` / `v-html` with untrusted data?
- [ ] CSP headers set?
- [ ] CSRF protection on state-changing requests (especially form submissions)?
- [ ] Secrets (API keys, service credentials) in frontend bundle? (`grep -r "sk-" src/`)
- [ ] Hardcoded URLs, IDs, or credentials in source?
- [ ] Route guards: protected routes redirect unauthenticated users?
- [ ] Field validation runs on both client AND server?
- [ ] Invalid/disabled actions: buttons disabled appropriately (can't submit a form in wrong state)?
- [ ] Dead-end routes: pages with no back button / navigation?
- [ ] Error states handled gracefully with meaningful user messages?

---

## Phase 8 — Database & Data Layer

### Checklist
- [ ] DB credentials not hardcoded in source; loaded from environment
- [ ] DB user has minimum required permissions (not root/superuser for app queries)?
- [ ] No direct DB access from frontend/client?
- [ ] Migrations run in transactions? Rollback possible?
- [ ] Sensitive fields (passwords, SSNs, tokens) encrypted at rest?
- [ ] Soft-deleted records inaccessible via app unless explicitly intended?
- [ ] Indexes on foreign keys and frequently filtered columns?
- [ ] No raw SQL strings built from user input in the ORM layer?
- [ ] DB connection pooling configured to prevent resource exhaustion?

---

## Phase 9 — Infrastructure & Configuration

### Checklist
- [ ] No secrets committed to git (scan with `git log --all -S "password"` style checks)
- [ ] `.env` in `.gitignore`?
- [ ] Debug mode / verbose logging disabled in production config?
- [ ] Dependency vulnerabilities: run `npm audit`, `pip-audit`, `bundler-audit`, or equivalent
- [ ] HTTPS enforced? HSTS headers set?
- [ ] Security headers present: `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`?
- [ ] Docker: running as root? Unnecessary ports exposed?
- [ ] File permissions on config files appropriate?
- [ ] Third-party integrations: API keys scoped to minimum permissions?

---

## Phase 10 — Business Logic & User Flows

This is where real-world bugs hide that automated scanners miss.

### Key questions per feature
- Can a user take an action they shouldn't at this point in the workflow?
- What happens if they submit a form twice (duplicate actions)?
- What happens with edge cases: same email twice, same name twice, empty string, null, very long string?
- Are there status transitions that should be one-way (e.g. "cancelled" → "active" should be blocked)?
- Can a user interfere with another user's in-progress action?
- Are financial/quota calculations done server-side?

### Specific flows to check every time
1. **Registration** → duplicate email, SQL chars in name, very long inputs
2. **Login** → lockout, enumeration, case sensitivity of email
3. **Password reset** → full Phase 3 checklist
4. **Role creation/assignment** → can a non-admin assign admin role?
5. **Delete / archive** → are downstream references cleaned up? Can a deleted user still act?
6. **Export / download** → scoped to current user's data only?
7. **Search** → injection, result scoping, exposure of other users' data?
8. **Notifications / emails** → triggered by other users' actions inappropriately?

---

## Tools to Use During Audit

Run `npm audit`/`pip-audit`/`bundler-audit` (or the stack equivalent) plus targeted greps for
secrets, hardcoded values, routes, auth middleware, and raw SQL — see
`references/grep-patterns.md` for starting commands and how to adapt their globs to the
detected language.

---

## Reference Files

For deep dives on specific vulnerability classes, read:
- `references/owasp-top10.md` — OWASP Top 10 with detection patterns
- `references/rbac-patterns.md` — Common RBAC implementation flaws
- `references/api-checklist.md` — API-specific security checklist
- `references/grep-patterns.md` — starting grep commands for dependency, secret, and route discovery

These are loaded only when needed to keep context lean.
