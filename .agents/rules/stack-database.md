---
applyTo: '**/migrations/**,**/db/**,**/prisma/**,**/supabase/**,**/alembic/**,**/*seed*,**/firestore.rules,**/firestore.indexes.json,**/database.rules.json'
paths:
  - '**/migrations/**'
  - '**/db/**'
  - '**/prisma/**'
  - '**/supabase/**'
  - '**/alembic/**'
  - '**/*seed*'
  - '**/firestore.rules'
  - '**/firestore.indexes.json'
  - '**/database.rules.json'
detect:
  - '**/migrations/**'
  - '**/alembic.ini'
  - '**/prisma/schema.prisma'
  - '**/supabase/migrations/**'
  - '**/db/migrate/**'
  - '**/firestore.rules'
  - '**/firebase.json'
  - '**/database.rules.json'
detect-deps:
  - 'npm:mongoose'
  - 'npm:mongodb'
  - 'pypi:pymongo'
  - 'pypi:motor'
  - 'npm:typeorm'
  - 'npm:@prisma/client'
  - 'npm:firebase-admin'
  - 'pypi:firebase-admin'
  - 'pypi:sqlalchemy'
  - 'npm:knex'
  - 'npm:drizzle-orm'
  - 'npm:mysql2'
  - 'npm:pg'
  - 'npm:sequelize'
  - 'pypi:alembic'
  - 'pypi:django'
  - 'gem:pg'
  - 'gem:mysql2'
---

# Database Rules

## Business Invariants

### Any data store
- A migration that has been applied anywhere is never edited. A change is a new migration. Enforce it with a checksum ledger in the runner or a test that pins every applied revision by digest.
- A write to a hosted (staging or production) schema or data needs the user's yes in the current session. The command that performs it is declared in `.agents/policy.json`; a deploy that applies migrations is such a command.
- Name the database a command will hit before running it. Local env files point at local; the default target is never production; production needs an explicit flag or a typed confirmation.
- A bulk writer rehearses by default: a dry run or plan is the default and the write takes an explicit flag. `--dry-run` silences the publish guard only for scripts policy declares in `dry_run_commands`; never append it to a script that ignores it.
- Before a data write, back up the affected rows, check a precondition, read the result back, and keep the undo. A backup directory is never overwritten.
- Schema and data shape are applied only by committed tooling. No DDL at request time, no console or dashboard edits, no hand DDL on production; a hand-made production repair lands in the repository as a migration.
- Prove a change landed from live state: query the catalog, the ledger, or the document, or wait for the index to be ready. An exit status or the migration tree proves nothing.
- Order schema against code. Additive changes ship first; a destructive change ships after no running code uses what it removes. A deploy waits for the migration it needs, and a rollback target must still work against the new schema.
- The database builds from empty with the same tooling that migrates it, and CI proves it. Dev and test databases migrate together.
- A seed is idempotent declared data, never a hand insert: a second run changes nothing, and it refuses production unless explicitly told otherwise. The runtime role is not the migration role; the application never owns or alters schema, and a role's grants are tested as that role.

### SQL migrations
- Index builds on a live table use `CREATE INDEX CONCURRENTLY` outside a transaction, re-runnable (`IF NOT EXISTS`), and the runner refuses to record the file while an index is invalid. Set `lock_timeout` and `statement_timeout`; scope `SET LOCAL` so it does not leak into later migrations sharing a transaction.
- `CREATE ROLE` tolerates an existing role (`duplicate_object`). Roles are cluster-global, and a rerun or a shared test server meets them again.
- A generated schema file (`db/schema.rb`, `structure.sql`, a Prisma client, a schema dump) is never edited by hand. Change the migration or schema source and regenerate.
- A migration with a known data-loss cost declares it in code, and the runner refuses it against a populated database unless acknowledged.
- Never infer production's schema from the migration folder when production was ever changed out of band; diff the live database.

### Document stores (Firestore, MongoDB)
- Index and security-rules files (`firestore.indexes.json`, `firestore.rules`, `database.rules.json`) live in the repository and deploy from it. Deploy prunes what the file omits, so reconcile live drift into the file before deploying.
- A shape change ships with a backfill, and readers accept both shapes until the backfill is verified. Then delete the old field and its write sites.
- Validate documents at every read; the store does not enforce shape.
- Emulator versus hosted project targeting is explicit. Emulator mode uses a project id that cannot reach a real project (`demo-*`), and the emulator tests the rules production runs.

## Abnormal Cases and Rationale
- Applied migrations: some runners record only an identifier, so an edited file leaves every database that applied the old text unchanged and nothing notices.
- Hosted writes: a push or deploy that migrates counts, so "just pushing" is a production schema write.
- Targeting: a local `.env` copied from the hosted platform makes a local `migrate` alter staging.
- Rehearsal: a guard that trusts a literal `--dry-run` is bypassed by every script that ignores it, and a guard that does nothing is worse than none.
- Backup and undo: ad-hoc snippets against live databases drop fields silently, such as a whole-array replace that loses an entry. A DocumentReference written through plain JSON stores a dead map.
- Committed tooling: 31 request-time `ensureSchema` calls ran DDL in every cold function; the app role did not own the table, the `ALTER` was refused, and every paid request answered 503 for weeks. A refused DDL must page, and whether a column exists is settled by the query that reads it.
- Live state: `compose down` keeps a named volume, so an in-place edit to an applied file appears to apply and changes nothing; rebuild with `down -v`.
- Ordering: code writing a new column fails on every request until the column exists; a loader may deploy ahead of its migration only if it skips and logs the missing table.
- Empty build: legacy migrations written before the initial schema fail on a virgin database, and only a tested fresh-database path shows it.
- Seeds: a partial entry point that skipped the shared target check made a seed write to a real project. Put the production refusal in the shared resolver, not the caller. A runtime role without INSERT cannot upsert; the grant, not the statement, decides.
- Concurrent indexes: a failed concurrent build leaves an invalid index that `IF NOT EXISTS` then skips. A migration queued behind a long transaction stalls every table it locks.
- Roles: a migration role without BYPASSRLS sees no rows in a forced-RLS table, so a data statement there writes zero rows without error.
- Production drift: staging migration files once produced a false vulnerability report because production had never run them. Never `db push --linked` against a production whose history diverged.
- Index builds in a document store are asynchronous: a query relying on one before it is ready fails with `FAILED_PRECONDITION`. When a code-side sort will do, avoid needing the index.
- Document stores have no foreign keys or cascades; a deleted document leaves its references behind. Prefer subcollections over reference arrays for high-churn relations.
- Emulator rules: the repository rules and the live rules can differ, so an emulator running the wrong set misleads.

## Out of Scope
- Do not restate the hosted-write approval mechanism here. `.agents/playbooks/infrastructure.md` owns it, and the publish guard owns the verbs it asks about.
- Do not add store-specific rules for MongoDB or MySQL beyond the lists above; no repository has yet shown one is needed.
- Do not duplicate Rails' `db/schema.rb` rule; `stack-rails.md` owns it for Rails.
- ORM query and model design belongs to the language pack.
