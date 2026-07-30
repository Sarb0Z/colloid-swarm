# Unit 0 — Emergency guard + targeted quarantine: Implementation Plan

> Roadmap: docs/superpowers/plans/2026-07-03-spamhaus-remediation-roadmap.md (Unit 0).
> Status: plan drafted 2026-07-03, PENDING hostile review. Do not implement until findings are folded.

**Drop-dead: deployed to prod before 2026-07-06 00:07 UTC.** Rationale (postmortem `docs/SPAMHAUS_IP_BURN_POSTMORTEM.md`): CSS auto-expiry can flip `blacklist_status` clean on any 4-hourly check, the daily 00:07 UTC rate recompute zeroes the drained 7-day window (~07-07), and `check_all_blacklists` itself calls `update_ip_states` (`health_engine.py:694`) — the same task run that flips the status clean can resume the IP minutes later.

**Verified inventory of every path that can promote an IP into service** (grep of `state = "warmup"|"active"` over `backend/`, all sites read):

| # | Site | Transition | Treatment |
|---|---|---|---|
| 1 | `backend/services/health_engine.py:1074-1082` (`update_ip_states` — hourly `run_hourly` at :2115 AND 4-hourly via :694) | paused→warmup | shared helper |
| 2 | `backend/services/health_engine.py:369-377` (`update_ip_state_after_check` — manual recheck `api/ips.py:269`) | paused→warmup | shared helper |
| 3 | `backend/api/system_config.py:160-164` (`_reevaluate_states` — any health-config save, :316) | paused→warmup | shared helper |
| 4 | `backend/api/ips.py:322-371` (`set_ip_state`, manual) | any→warmup/active | precedence guard (409) |
| 5 | `backend/api/nodes.py:554-556` (heartbeat reconcile) | retired→warmup | one-line guard |
| 6 | `backend/services/ip_provisioner.py:624-625` (`add_ip`; note :622-623 force-sets `auto_reconcile=True`) | retired→warmup | one-line guard |
| 7 | `backend/services/node_provisioner.py:564-566` (provision reattach) | retired→warmup | one-line guard |
| — | `health_engine.py:2037-2046` graduation | warmup→active | no change: loop selects `state == "warmup"` only (:2010-2011); a held IP pinned at paused never enters it |
| — | `ips.py:869` emergency-capacity-relief | reads warmup/active only | no change |

Sites 5-7 are included because the hold must survive the retire fork: an operator may legally set the held IP to `retired` (pausedward moves stay allowed), and all three revival sites would then silently flip it retired→warmup — the exact auto-revival hazard the roadmap flags for Unit 6. Three one-line guards close it now.

---

## Part (a) — resume-hold mechanism

### 1. Column: `resume_hold` on `ip_addresses`

`backend/models/ip_address.py` — insert alongside `auto_pause_on_blacklist` (line 43):

```python
# Operator hold: pins the IP out of service. While true, NO automatic path
# (recovery release, threshold re-eval, retired-IP revival) and no manual
# set-state may move it to warmup/active; clear via POST /ips/{id}/resume-hold.
resume_hold = Column(Boolean, nullable=False, default=False, server_default=text("false"))
```

NOT NULL + `server_default` (not the repo's usual bare `default=`) because a nullable tri-state is wrong for a guard flag, and the server default keeps raw-SQL/`create_all` environments column-parity-safe (the concern migration 080's header documents). Requires adding `text` to the model's imports.

### 2. Migration: `alembic/versions/081_add_ip_resume_hold.py`

Latest revision is 080 (verified); revision `"081"`, `down_revision "080"`. Same file, same revision: add the column AND set the hold for 62.171.162.148 — the guard must never be deployed disarmed.

```python
def upgrade() -> None:
    bind = op.get_bind()
    inspector = sa.inspect(bind)
    cols = {c["name"] for c in inspector.get_columns("ip_addresses")}
    if "resume_hold" not in cols:   # 080-style guard against re-runs
        op.add_column(
            "ip_addresses",
            sa.Column("resume_hold", sa.Boolean(), nullable=False,
                      server_default=sa.text("false")),
        )
    # REPO GOTCHA: 3-arg op.execute(text(), params) unsupported — parameterize
    # via the raw connection (pattern: migration 080, bind.execute(text(), {...})).
    res = bind.execute(
        sa.text("UPDATE ip_addresses SET resume_hold = true WHERE address = :addr"),
        {"addr": "62.171.162.148"},
    )
    if res.rowcount == 0:
        # Fresh/dev DB without the row: warn, don't brick every future environment.
        # Prod verification (rollout step 3) is the mandatory gate that the hold is set.
        print("WARNING: 62.171.162.148 not found — resume_hold not applied (fresh DB?)")

def downgrade() -> None:
    op.drop_column("ip_addresses", "resume_hold")
```

`ALTER TABLE ADD COLUMN` with a constant default is metadata-only on this Postgres version — instant, no rewrite. Idempotent: column-existence guard + re-running the UPDATE is a no-op. Deployed by the approved path — `scripts/deploy.sh:194` runs `alembic upgrade head` before service restart.

### 3. Shared release predicate — a helper, used at all three paused→warmup sites

Three call sites with an identical four-term condition justify the helper (DRY-after-YAGNI). Extract the FULL predicate, not just the hold check, so the release condition has exactly one definition. Module-level in `backend/services/health_engine.py`, adjacent to `update_ip_state_after_check` (:349):

```python
def ip_eligible_for_recovery(ip, recovery_thresh: float) -> bool:
    """The ONLY predicate that may auto-release a paused IP back to warmup.
    resume_hold pins the IP paused regardless of blacklist/bounce recovery
    (Unit 0 emergency guard — see docs/SPAMHAUS_IP_BURN_POSTMORTEM.md)."""
    return (
        ip.state == "paused"
        and not ip.resume_hold
        and ip.blacklist_status == "clean"
        and ip.bounce_rate < recovery_thresh
    )
```

Call-site rewrites (semantics identical when `resume_hold` is false — the guard is provably the only change):

- **Site 1** `health_engine.py:1074-1078`: replace the three-line `if` with `if ip_eligible_for_recovery(ip, recovery_thresh):`. Add the observability branch so a blocked release is visible in the hourly log instead of silently not happening:
  ```python
  elif ip.state == "paused" and ip.resume_hold \
          and ip.blacklist_status == "clean" and ip.bounce_rate < recovery_thresh:
      logger.info(f"[RESUME_HOLD] {ip.address}: recovery conditions met but resume_hold is set — staying paused")
  ```
  (Logs only when the hold is the binding constraint; one line per hour per held IP.)
- **Site 2** `health_engine.py:369-373`: replace the `elif (...)` with `elif ip_eligible_for_recovery(ip, recovery_thresh):`.
- **Site 3** `backend/api/system_config.py:160-161`: replace the inline condition with `elif ip_eligible_for_recovery(ip, bounce_recovery):`; add `ip_eligible_for_recovery` to the function-local health_engine import at :113. No cycle — that import already exists.

Note the rebalance re-check at `health_engine.py:1113-1117` tests `state == "warmup"` on already-released IPs — not a release site, unchanged.

### 4. `set_ip_state` precedence (`backend/api/ips.py:322`)

**Decision: an operator may NOT move a held IP to warmup/active in the same call — the hold must be cleared by a separate, explicit call first.** Rationale: the entire point of an emergency hold is friction; a same-call override collapses two deliberate actions back into one fat-fingerable one, and this endpoint takes bare query params (no body to carry an explicit `clear_hold` acknowledgment idiomatically). Never silent either way.

Insert after the 404 check (:334), before any mutation:

```python
if state in ("warmup", "active") and ip.resume_hold:
    raise HTTPException(
        status_code=409,
        detail=(
            f"IP {ip.address} has resume_hold set (emergency guard). "
            f"Clear it first: POST /api/ips/{ip_id}/resume-hold?hold=false"
        ),
    )
```

Moves to `paused`/`retired` remain allowed with the hold set.

### 5. Hold API surface — one minimal endpoint

New endpoint after `set_ip_state` (~:372), mirroring the `assign-pool` shape, permission `ips.update`, audited via the existing `log_action` (pattern at `ips.py:790`):

```python
@router.post("/{ip_id}/resume-hold")
async def set_resume_hold(ip_id: uuid.UUID, hold: bool, request: Request,
                          db: AsyncSession = Depends(get_db),
                          user: User = Depends(require_permission("ips.update"))):
```
Body: fetch IP (404 if missing), `ip.resume_hold = hold`, `logger.warning` the change with user email, `await db.commit()`, `log_action(action="ip.resume_hold", details={"ip": ip.address, "hold": hold})`, commit, return `{"ip", "resume_hold"}`. No state transition, no rebalance, no redeploy — setting/clearing the hold never itself moves state (clearing it lets the next hourly evaluation release the IP if conditions hold, which is the honest semantic).

### 6. API/UI exposure

Add `resume_hold: bool = False` to `IPResponse` (`ips.py:69-92`) so GET `/api/ips` surfaces it for ops and the done-gate check. **UI deferred**: `frontend/src/pages/IPs.tsx` renders explicit columns only — nothing auto-surfaces, and a UI toggle for a one-IP emergency flag is not needed before 07-06. YAGNI.

---

## Part (b) — targeted quarantine script

New file `scripts/quarantine_2026_07_incident.py`, modeled line-for-line on the conventions of `scripts/cleanup_resurrected_seeds.py` (argparse `--apply` with dry-run default, `create_worker_session`, per-ESP breakdown prints, docstring with run instructions). **Not a migration** — data volume is tens of thousands of rows per class; runs via the approved deploy path on the server from `/opt/email-system`.

### Key design decisions

- **Reversible + attributable:** sets `is_active=false, deactivated_reason='quarantine_2026_07_incident_<class>'`. Classes: `catch_all`, `bounce_domain`.
- **Does NOT touch `verification_status`** (unlike the cleanup script, which stamps `'bounced'`). Quarantine is exposure control, not a verdict — Unit 2a's probes must later re-adjudicate these rows on their real status; overwriting it would destroy the `catch_all` class marker the roadmap's decision 2 depends on.
- **Constraint safety (migration 071, read and verified):** the CHECK is `NOT (is_active AND last_bounced_at IS NOT NULL)` — it forbids *active* previously-bounced rows. We only ever set `is_active=false`, which moves rows strictly INTO the allowed region; the update cannot trip it. The documented **reversal** SQL is where the constraint bites, so it must carry the guard (see header below).
- **Idempotent:** every selection predicate includes `is_active = true`; re-runs match 0 rows. Also preserves prior attributions (never overwrites `deactivated_reason` on already-inactive rows, e.g. `'resurrected_cleanup'`).
- **Class order:** catch_all first, then bounce_domain — overlap rows get deterministic `catch_all` attribution (first writer wins because the second pass filters `is_active=true`).
- **Downstream interactions (verified, no code needed):** reverify worker selects `is_active==True` (`smartlead_reverify_worker.py:106-122`) — quarantined rows drop out of the sweep; warmup prefetch filters `is_active.is_(True)` (`warmup_engine.py:2192-2196`) — they stop being mailed on the next prefetch. Accepted residuals, stated in the header: (1) already-queued warmup jobs may mail a handful of quarantined addresses once; (2) quarantine is operational, not structural — `smartlead_accounts.py` bulk-activate could resurrect these rows (it gates only on `last_bounced_at`); Unit 2a makes it structural. Do not bulk-activate until then.

### Selection SQL

**Class 1 — catch_all** (batched ORM update):

```sql
UPDATE smartlead_accounts
SET is_active = false, deactivated_reason = 'quarantine_2026_07_incident_catch_all'
WHERE id IN (SELECT id FROM smartlead_accounts
             WHERE verification_status = 'catch_all' AND is_active = true
             LIMIT :batch)
```

**Class 2 — bounce-evidence domains.** Phase A (read once per account, result held in Python — ~7.5k domains per postmortem):

```sql
SELECT DISTINCT lower(split_part(to_email, '@', 2)) AS dom
FROM send_logs
WHERE account_id = :acct
  AND created_at >= '2026-06-01'
  AND status = 'bounced'
  AND to_email <> ''
  AND (bounce_reason ILIKE '%user unknown%'
    OR bounce_reason ILIKE '%does not exist%'
    OR bounce_reason ILIKE '%null MX%'
    OR bounce_reason ILIKE '%prohibited_hosts%'
    OR bounce_reason ILIKE '%recipient unrecognized%'
    OR bounce_reason ILIKE '%not found%')
```

**Index reasoning (verified against migrations 055/066/068):** deliberately does NOT filter `bounce_type IN ('hard','spam')` — the agent's classifier (`agent/stats_collector.py:519-544`) can leave null-MX/`prohibited_hosts` rejections typed `unknown`/`soft` (no pattern match, non-5xx local rejections), so leaning on the tiny partial bounce indexes from 066 would silently drop exactly the loopback class. Instead the query is account-scoped with a `created_at` range so it rides `ix_send_logs_account_created (account_id, created_at DESC)` (migration 055) — a bounded ~1-month range scan (~600k rows) with status/reason as filters, not a full-table scan. `created_at >= 2026-06-01` is safe: warmup sends bounce same-day, and the incident bounces are 06-26 onward. The script loops `SELECT DISTINCT account_id FROM smartlead_accounts` for account scoping. Session prep: `await set_statement_timeout(db, 300_000)` (`backend/database.py:74` — session-level, survives the per-batch commits; the connection default is 30s).

Phase B (batched write, domains bound as an array param):

```sql
UPDATE smartlead_accounts
SET is_active = false, deactivated_reason = 'quarantine_2026_07_incident_bounce_domain'
WHERE id IN (SELECT id FROM smartlead_accounts
             WHERE account_id = :acct AND is_active = true
               AND lower(split_part(email, '@', 2)) = ANY(:doms)
             LIMIT :batch)
```

### Batching, output, reversal

- **Batching:** `BATCH = 5000`, loop each class until `rowcount == 0`, `commit()` per batch. Bounds row-lock hold time on a table the warmup prefetch reads continuously; naturally crash-re-entrant (updated rows leave the `is_active=true` predicate, so a rerun resumes where it died).
- **Output:** dry-run prints, per class: matching-active count broken down by ESP (mirroring the cleanup script's table), bad-domain count for class 2, and the class-1/class-2 overlap count (rows matching both, attributed catch_all). `--apply` prints committed per-class totals. These numbers go into the unit notes (done-gate: "prod shows hold set + quarantine counts").
- **Reversal procedure, documented verbatim in the script header:**
  ```sql
  -- Reversal (per class; run only when a probe path exists for the class):
  UPDATE smartlead_accounts
  SET is_active = true, deactivated_reason = NULL
  WHERE deactivated_reason = 'quarantine_2026_07_incident_catch_all'   -- or _bounce_domain
    AND last_bounced_at IS NULL;  -- REQUIRED: migration 071 CHECK forbids
                                  -- reactivating previously-bounced rows
  ```
  Header also states run commands (env sourcing + `PYTHONPATH=/opt/email-system venv/bin/python`, per cleanup script header) and that per roadmap decision 2 the catch_all slice stays out durably until a probe path exists.

---

## Part (c) — prod falsification snapshot (rollout step, read-only)

Recorded in the unit notes via `ssh -F ssh_config mailstation` + `psql` SELECT. Exact queries:

```sql
-- 1. Hold + IP state (done-gate)
SELECT address, state, resume_hold, blacklist_status, bounce_rate, warmup_day
FROM ip_addresses WHERE address = '62.171.162.148';

-- 2. Current Gmail ramp stage
SELECT account_id, config->'warmup_esp_ramp'->'gmail' AS gmail_ramp
FROM system_configs WHERE category = 'warmup';

-- 3. Post-quarantine pool composition (per-class counts cross-check)
SELECT esp, verification_status, is_active, deactivated_reason, count(*)
FROM smartlead_accounts
GROUP BY 1,2,3,4 ORDER BY 5 DESC LIMIT 40;

-- 4. Post-quarantine bounce composition by ESP (re-run daily for a few days;
--    falsification target: user-unknown/null-MX class shrinks toward zero on warmup traffic)
SELECT esp_detected, bounce_type, count(*),
       count(*) FILTER (WHERE is_warmup) AS warmup_bounces
FROM send_logs
WHERE status = 'bounced' AND bounced_at >= now() - interval '7 days'
GROUP BY 1,2 ORDER BY 3 DESC;
```

---

## Test plan

Repo test style (verified): no DB fixtures; functional tests `exec()` the module source with fakes (`tests/test_health_engine.py:15-56`), structural tests assert exact source strings (`tests/test_reputation_guardrails.py`). Extend those two files; no new test files.

**Extend `tests/test_health_engine.py`:**
1. `test_ip_recovery_helper_truth_table` — exec `health_engine.py`, call `ip_eligible_for_recovery` with a FakeIP across: hold clear/all-clean → True; hold set → False; state warmup → False; listed → False; bounce ≥ thresh → False.
2. `test_manual_recheck_release_honors_resume_hold` (site 2, functional both ways): FakeIP(paused, clean, bounce 0.0, warmup_day 30, `resume_hold=True`) through `update_ip_state_after_check` → returns None, state stays paused, warmup_day untouched; identical fake with `resume_hold=False` → returns "warmup", warmup_day 23 (−7 stepback). Same fixture, one flag flipped — proves the guard is the only change.
3. `test_all_release_sites_use_shared_predicate` (sites 1 & 3, structural — they are async+DB-bound): `health_engine.py` contains `def ip_eligible_for_recovery(` and ≥2 call sites `ip_eligible_for_recovery(ip, recovery_thresh)`; `system_config.py` contains `ip_eligible_for_recovery(ip, bounce_recovery)` and — the no-bypass proof — `"ip.blacklist_status"` absent from system_config source (its only prior occurrence was the inline release predicate at :160).
4. `test_set_state_blocks_promotion_under_hold` — `ips.py` source: the 409 guard string with `ip.resume_hold` preceding promotion, `resume_hold: bool` in IPResponse, route `"/{ip_id}/resume-hold"` present.
5. `test_retired_revival_paths_honor_hold` — exact guarded-condition strings in `nodes.py`, `ip_provisioner.py`, `node_provisioner.py` (`== "retired" and not ….resume_hold`).
6. `test_migration_081_arms_the_hold` — 081 source: `revision: str = "081"`, `resume_hold` add_column with `server_default`, parameterized `bind.execute` carrying `"62.171.162.148"`.

**Extend `tests/test_reputation_guardrails.py`** (it already reads migration 071 and script/worker sources):

7. `test_quarantine_script_is_constraint_safe_and_reversible` — split script source on the module docstring; the **code** section sets `is_active` only to `False` and never assigns `verification_status`; both class predicates carry the `is_active` true-filter (idempotency key); reason literals are exactly `quarantine_2026_07_incident_catch_all` / `quarantine_2026_07_incident_bounce_domain`; the **header** reversal SQL contains `last_bounced_at IS NULL` (071-CHECK-safe reversal); `--apply` flag exists (dry-run default). Also re-assert 071's constraint direction string `NOT (is_active AND last_bounced_at IS NOT NULL)` next to a comment stating why `is_active=false` cannot trip it.
8. `test_quarantine_selection_matches_incident_evidence` — all six ILIKE patterns, the `2026-06-01` window, `split_part(email, '@', 2)` matching, `account_id`-scoped send_logs query (index contract with `ix_send_logs_account_created`), and absence of any `bounce_type` filter (documented reason above).

Script idempotency is additionally proven operationally: rollout runs `--apply` twice; second run must report 0 per class.

---

## Rollout order (all before 2026-07-06 00:07 UTC)

1. **Land the PR** (guards + migration 081 + script + tests); `pytest` green.
2. **Deploy via `scripts/deploy.sh`** (the approved path): it rsyncs, runs `alembic upgrade head` (:194) — column added and hold armed in the same revision — then restarts services. Known minutes-wide window where old code (hold-ignorant) runs against the migrated DB: acceptable, because the release conditions cannot self-satisfy before ~07-06 (IP still `listed` as of 07-03 08:30; bounce window drains ~07-07).
3. **Verify the hold on prod** (query c-1). Expect `paused, resume_hold=t`. This is the mandatory gate backing the migration's warn-don't-fail rowcount choice.
4. **Run the quarantine script** on the server: dry-run → review per-class counts → `--apply` → immediate re-run showing 0/0 (idempotency proof). Record counts in unit notes.
5. **Take the part-(c) snapshot** (queries c-2..c-4); record in unit notes.
6. **Done-gate check** against the roadmap: three release sites tested under hold (none releases) and without hold (all release), prod hold set, quarantine counts recorded, snapshot taken.

---

## File-by-file change list (with anchors and token sizing)

| File | Change | Anchor | Size |
|---|---|---|---|
| `alembic/versions/081_add_ip_resume_hold.py` | new migration (column + arm hold) | after 080 | ~450 tok |
| `backend/models/ip_address.py` | `resume_hold` column + `text` import | :43 | ~50 tok |
| `backend/services/health_engine.py` | `ip_eligible_for_recovery` helper; rewrite sites at :369-373 and :1074-1078; blocked-release log line | :349, :369, :1074 | ~300 tok |
| `backend/api/system_config.py` | site 3 uses helper; extend import | :113, :160-161 | ~120 tok |
| `backend/api/ips.py` | IPResponse field; set-state 409 guard; `resume-hold` endpoint | :69-92, :334, :372 | ~500 tok |
| `backend/api/nodes.py` | revival guard | :554 | ~40 tok |
| `backend/services/ip_provisioner.py` | revival guard | :624 | ~40 tok |
| `backend/services/node_provisioner.py` | revival guard | :564 | ~40 tok |
| `scripts/quarantine_2026_07_incident.py` | new one-shot script | — | ~1,400 tok |
| `tests/test_health_engine.py` | tests 1-6 | append | ~800 tok |
| `tests/test_reputation_guardrails.py` | tests 7-8 | append | ~450 tok |

Diff total ~4.2k tokens; comfortably inside the unit's 25-35k budget with review/iteration headroom.
