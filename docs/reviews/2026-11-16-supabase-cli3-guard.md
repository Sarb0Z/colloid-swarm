# Supabase CLI 3 guard: code review of workloop run `supabase3-guard`

The operator approved `docs/notes/2026-11-16-supabase-cli3-guard-plan.md` on
2026-11-16. This round reviews plan steps 1-6, the publish guard's rules for
Supabase CLI 3 beside 2.x, before the product-37-mobile port and the CLI upgrade.

## Lane `guard` (critical)

Covers: 761afe10a557..e3ca5d73a6d0

A fable writer built steps 1-4 (68850a0, 0178c83, 661090f, c09c875). Step 5's
seven hosted-only verbs need seven `permissions.ask` rules in
`.agents/claude/settings.json`, since the guard's suite requires a rule for
each gated vendor verb and a gated verb for each rule; the plan did not name
that file, so the lead widened the lane to it and landed step 5 (5289449).
The suite passed, 1,372 rows. Mutations turned the expected rows red: the
writer's three batches (19, 22 and 19 failures) and the lead's removal of
`feedback add` (2 failures).

QA (sonnet) drove every Acceptance 1-9 command through
`.agents/hooks/policy/guard-publish.sh` with a PreToolUse payload: all pass.
`npx`, `bunx`, `cd x &&`, `bash -c`, an env prefix and `--yes` after the verb
ask on hosted commands and stay quiet on local ones. `db pull --local=TRUE`
asks; the reviewer found the CLI's boolean literals case-sensitive, so `TRUE`
is no true value there and the ask stands. The lead reran `--yes TRUE`,
`True`, `YES` and `1` before `db push`: each asks.

One reviewer (fable) read the five commits and their seams with the other
vendors, `database-target.py` and the hook entry, against supabase/cli v3.1.0
and v2.122.0. The disprove pass (sonnet) ran npm `supabase@3.1.0` and
`supabase@2.122.0` in a Linux container with no token and no home, so no
keychain and no hosted project was reached.

The fix round landed findings 1, 2, 3, 5 and 6 as trailing commits: the writer's
9a8bc93, b22b343, 82deb0e, 36e3d2f and c2e8424, and the lead's 8e23cff, since
`compute deploy`'s `permissions.ask` rule changes the permission settings the
writer runs under. 8ea2305 types `positionals()`'s flag sets, so a set passed
by the new callers type-checks. The suite passed, 1,395 rows; the writer's five
mutations, applied together on disjoint rows, turned the 13 predicted rows red,
and the lead's removal of `compute deploy` turned 2. The table checks moved
out of `rule_bash` into `table_reason`, which shortens it.

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | The plural group `migrations` and `compute deploy` pass unasked, though the CLI resolves them to `migration` and `compute push` | Disprove pass: `confirmed` for `migrations` (both versions print the same help and the same hosted-target errors for both spellings, e.g. 3.1.0 `migrations up --remote` gives "Cannot find project ref. Have you run supabase link?"); `unverified` for `compute deploy`, absent with all of `compute` from the npm 3.1.0 build. The lead read v3.1.0 `apps/cli/src/commands/experimental/compute/push/push.command.ts:66-67`, `Command.make("push", config).pipe(Command.withAlias("deploy")`, inside the experimental `compute` group. Adopted: the guard reads `migrations` as `migration`, and `compute deploy` joins `DEPLOY_VERBS` with its ask rule |
| 2 | P1 | `supabase seed --remote <ref> buckets` passes unasked: the guard takes the ref for the verb | Disprove pass: `confirmed`. 3.1.0 `seed --remote staging buckets --debug` and `seed --remote=staging buckets --debug` print the same "Cannot resolve \"staging\"" target error; `seed --remote abcdefghijklmnopqrst buckets --debug` prints "Target: project abcdefghijklmnopqrst" and then asks for a token. Adopted: the guard also reads the word after a bare `--remote` as its value and asks when either reading names a gated verb; the comment over `REMOTE_FLAG_VERBS` gives both forms |
| 3 | P2 | 2.x's `db remote commit` runs `db pull` against the linked project by default, and the guard matches only two-word verbs | Adopted: three-word phrases, and `db remote commit` joins the hosted-unless-`--local` verbs |
| 4 | P2 | The showcase quotes `guard-publish.py`, `breadcrumbs.md` and `decisions.md`, and is stale on main, so `demo/check-inventory.py` and `port-public.py check` fail | Adopted: rebuilt after this round's fixes land |
| 5 | P2 | `feedback add` asks with "deploys or mutates the hosted project"; it sends a message to the Supabase team (plan F6), and `pull --dry-run` is a read | Adopted: a reason per step-5 verb, with a test row on the text |
| 6 | P2 | `flag_on` reads a `--local` or `--read-only` written after a bare `--`, where the CLI's parser has stopped reading flags | Adopted, since the fix round edits `flag_on`'s file: `flag_on` stops at the first bare `--` |
| 7 | P2 | `guard-publish.py` is 1,216 lines and `rule_bash` 105, both over the limits before this lane | Accepted: this lane grew them by 86 and 6 lines and added no function over 40 lines; splitting the guard is its own unit |
| 8 | — | The fix round's writer: a target flag written after a bare `--` still counts (`db reset -- --remote` asks) | Accepted: it only adds an ask, and no honest command writes a target flag after `--` |
| 9 | — | Reviewer ambiguity: the ask may mean fewer prompts, while steps 1-6 only add asks | The plan the operator approved reads it: the guard asks when either CLI version would reach a hosted project, so bare `db pull` and `migration repair` ask on 3.x too. The keychain prompts come from Management API calls (plan F19), which steps 1-6 do not touch |
