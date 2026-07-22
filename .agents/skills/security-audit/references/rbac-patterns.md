# Common RBAC Implementation Flaws

## Flaw 1 — Role set at login but never re-checked

The role is stored in the JWT/session at login time. If the admin changes the user's role in the DB, the user's old token still works until expiry.

**Fix:** Either short-lived tokens with refresh, or check role from DB on each sensitive request.

---

## Flaw 2 — Role carried in client-supplied payload

```js
// VULNERABLE — attacker sends role: "admin" in body
const { userId, role } = req.body;
if (role === 'admin') { ... }

// SAFE — role comes from verified session only
const role = req.user.role; // set by auth middleware from DB
```

---

## Flaw 3 — UI-only role checks

Admin functionality hidden in the UI but the underlying API has no guard:
```js
// Frontend
{user.role === 'admin' && <DeleteUserButton />}

// Backend — MISSING CHECK:
router.delete('/users/:id', async (req, res) => {
  // No role check! Any authenticated user can call this directly.
  await User.destroy({ where: { id: req.params.id } });
});
```

---

## Flaw 4 — Middleware applied at router level but skipped by a sub-route

```js
// Auth applied here...
router.use('/admin', authenticate);

// ...but this specific route somehow bypasses it
router.get('/admin/stats', (req, res) => { // no middleware
```

Always verify the middleware chain reaches the handler.

---

## Flaw 5 — Privilege escalation via role assignment endpoint

```js
// Can a regular user call this?
router.put('/users/:id/role', async (req, res) => {
  await User.update({ role: req.body.role }, { where: { id: req.params.id } });
});
```

Check: who can call role-update endpoints? What roles can they assign? Can a `manager` grant `admin`?

---

## Flaw 6 — Multi-tenant: org ID not validated

```js
// VULNERABLE — user from Org A can access Org B's data
const project = await Project.findByPk(req.params.projectId);

// SAFE
const project = await Project.findOne({
  where: { id: req.params.projectId, orgId: req.user.orgId }
});
```

---

## Flaw 7 — Roles not defined on login response

Frontend doesn't receive role info on login, so it can't render the right UI until a second request. This often leads to a flash of incorrect UI or inconsistent role enforcement.

---

## Flaw 8 — Disabled user sessions still active

When an admin disables a user account, their existing sessions/tokens should be immediately invalidated. Check:
- Is there a `is_active`/`is_enabled` check in the auth middleware?
- If using stateless JWT, is there a token blacklist or short expiry?
- Does the "disable user" endpoint also revoke all their active tokens?

---

## Flaw 9 — Mass assignment → `role=admin` → account takeover

The create/update handler binds the whole request body to the user model, so `role` (or `isAdmin` / `permissions` / `scope`) rides along:

```js
// VULNERABLE — attacker POSTs { email, password, role: "admin" }
const user = await User.create(req.body);

// SAFE — allowlist server-side; role is never client-supplied
const user = await User.create({
  email: req.body.email,
  password: hash(req.body.password),
  role: 'user', // fixed
});
```

Self-registration + mass assignment = anyone signs up as admin. Check every `create`/`update` that touches the user/identity model for an explicit field allowlist. **Test:** submit `role=admin` at signup, then read the account back — if the field is honored, it's critical.

---

## Flaw 10 — Role validated at registration but not on profile update

The signup path correctly forces `role='user'`, but the profile-update path trusts the body:

```js
// Registration — SAFE
await User.create({ ...allowlisted, role: 'user' });

// PATCH /me — VULNERABLE, same field now writable
await User.update(req.body, { where: { id: req.user.id } });
```

The guard on one write path does not cover the others. **Test:** `PATCH /me` (or `/profile`, `/account`) with `role`/`isAdmin`/domain-role (`student→teacher`, `member→owner`); read back to confirm the field was ignored. Every write path that reaches the identity model needs the same allowlist — validate the escalation-bearing field on all of them, not just registration.
