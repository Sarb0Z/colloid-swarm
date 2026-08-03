# API Security Checklist

## Contents
- Response Bloat Audit
- Unnecessary Re-fetches
- Pagination Enforcement
- Redundant API Calls
- HTTP Method Enforcement
- Error Response Leakage
- API Versioning Risks
- File Upload Security
- Webhook & Callback URL Validation

## Response Bloat Audit

For the 5–10 most frequently called endpoints, ask:
1. How many fields does the client actually use?
2. How many fields are returned in the response?
3. Are any of these: internal IDs, hashed passwords, secret tokens, other users' data, system metadata?

**Common over-fetch patterns:**
- Returning entire `User` object when only `{ id, name, email }` is needed
- Nested relations included by default (`include: [Profile, Organization, Roles]`)
- ORM `.toJSON()` / `.serialize()` not excluding sensitive fields
- Admin APIs returning same shape as public APIs (no field filtering by role)

**Relation-hydration false-positive (read before scoring an over-share):** ORM relations are opt-in, not transitive — `relations: ["profile"]` (TypeORM), `include: { profile: true }` (Prisma) pulls *only* the listed relation. So when the credential-bearing entity is a **relation of the root you're fetching** (e.g. `orderRepo.findOne(id)` where `User` is a relation of `Order`), a query that doesn't hydrate it can't leak that relation's `passwordHash` — it was never loaded. Check the actual relation list before flagging *that* case. **But do not extend this to base columns of a directly-fetched entity:** `userRepo.findOne({ where: { id } })` returns `passwordHash` / `email` / `isAdmin` **by default** — they're columns on the entity itself, not a relation — unless each is `select: false` (TypeORM) / omitted from an explicit `select`/`omit` (Prisma). A bare fetch-then-serialize of the credential entity is a real leak, not a false positive; the "safe unless hydrated" logic never covers it.

---

## Unnecessary Re-fetches

Look for patterns where the entire list/page is reloaded after a small change:
- Adding a comment triggers a full page reload + re-fetch of all comments
- Updating one record in a table refetches the entire table
- Socket event triggers `fetchAll()` instead of updating local state

These are performance issues but often also indicate that pagination/filtering isn't enforced, leading to unbounded queries.

---

## Pagination Enforcement

Every list endpoint must:
1. Accept `page`/`limit` or `cursor`/`take` parameters
2. Have a **server-enforced maximum** page size (e.g. max 100 items)
3. Never return all records when no pagination params are supplied

```js
// VULNERABLE — returns all users if no limit supplied
const users = await User.findAll({ where: filters });

// SAFE
const limit = Math.min(parseInt(req.query.limit) || 20, 100);
const offset = parseInt(req.query.offset) || 0;
const users = await User.findAll({ where: filters, limit, offset });
```

---

## Redundant API Calls

Common patterns of redundant calls:
- `GET /me` called on every page load instead of caching
- `GET /permissions` called inside every protected component
- Multiple components independently fetching the same resource
- Polling endpoints that should be websockets (and vice versa)

---

## HTTP Method Enforcement

- `GET` routes must never mutate state
- `DELETE` routes must check ownership
- `PUT` vs `PATCH` — `PUT` replaces the full object (dangerous with partial input); `PATCH` is safer for updates
- Ensure `OPTIONS` doesn't expose unexpected allowed methods

**BFLA bypass playbook** — an admin/privileged function reachable by a lower-privilege or unauthenticated principal (OWASP API5). Admin-style patterns: `/admin`, `/internal`, `/manage`, `/actuator`. Run read-only:
1. Call each admin route **unauthenticated** — any 2xx is a critical break.
2. Call it as a **low-privilege** account — non-admin 2xx on an admin function is high.
3. **Method swap:** if `GET` is gated, try `HEAD`/`OPTIONS` (reason about `POST`/`PUT`/`DELETE` without executing) — gates are often method-specific.
4. **Header tricks:** replay with `X-Forwarded-For: 127.0.0.1`, `X-Real-IP`, `X-Original-URL: /admin`, `X-Rewrite-URL`, `X-Forwarded-Host`, `Role: admin`, `X-Role: admin`.
5. **Path normalization:** `/api/admin/..;/users`, `//admin`, `/Admin`, trailing `%2f`, `%2e` variants.

Verdict: VULNERABLE only on 2xx **with a body that differs from the gated baseline** (diff length/hash, not status alone). Never submit state-changing payloads on write verbs — inspect reachability (401/403 vs 2xx) only.

---

## Error Response Leakage

Production APIs must not return:
- Stack traces
- SQL query strings
- Internal file paths
- Library version information
- Raw DB error messages (e.g. "duplicate key violates unique constraint on column 'email'")

Instead, map to generic user-friendly messages and log the detail server-side.

---

## API Versioning Risks

- Are old API versions (`/api/v1/`) still active?
- Do old versions have the same auth guards as new versions?
- Were security patches applied to all versions?

---

## File Upload Security

```js
// Check for:
// 1. MIME type validated server-side (not just file extension)
// 2. File size limit enforced
// 3. Files stored outside webroot or with randomized names
// 4. No execution of uploaded files
// 5. Virus scanning for high-risk deployments
```

---

## Webhook & Callback URL Validation

If the app accepts URLs from users to send webhooks/callbacks:
- Validate against allowlist of domains
- Block private IP ranges: `10.x.x.x`, `172.16–31.x.x`, `192.168.x.x`, `127.x.x.x`, `169.254.x.x`
- Block `file://`, `gopher://`, `ftp://` schemes
- Prevent DNS rebinding attacks (resolve hostname, check resolved IP)
