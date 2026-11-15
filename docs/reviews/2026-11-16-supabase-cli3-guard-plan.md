# Supabase CLI 3 guard: plan review

Plan `docs/notes/2026-11-16-supabase-cli3-guard-plan.md`. Round 1 read the plan
at `a1a3ecd`; one reviewer (opus) read the plan, the guard and its tests, and
the supabase/cli source at v3.1.0 and v2.122.0. The lead checked the ticketing-app,
product-37-mobile and setup-guide facts on this Mac and read v2.78.1's
`pkg/config/config.go`.

## Round 1

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | In 2.x `migration repair`, `db pull` and `db dump` reach the linked project with no flag, so the plan's "either version" rule is false for them, and `migration repair` passes unasked on 2.122 today | Adopted: plan step 2, a hosted-unless-`--local` rule for `migration repair` and `db pull`; `db dump` stays a read that asks only with a target flag; findings F15 |
| 2 | P1 | The `db query --read-only` exemption keys on the token, but `--read-only=false` and `--read-only no` turn it off | Adopted: step 3 checks the flag's value |
| 3 | P1 | The CLI's parser lets a boolean flag consume a following boolean literal, which `positionals()` takes for the verb (`supabase --yes true db push`) | Adopted: step 4; findings F16 |
| 4 | P1 | `feedback add` sends a message to the Supabase team without asking, and the plan gated only `feedback delete` | Adopted: step 5 |
| 5 | P1 | `db test` is an unlisted alias of `test db` | Adopted: step 1 |
| 6 | P1 | Decision 1's recommended whole-file copy cannot run: product-37-mobile's guard differs by 462 diff lines and lacks the sibling modules | Adopted: decision 1 offers a port of the Supabase hunks; the lead confirmed the 462 lines and the same tables in product-37's copy |
| 7 | P2 | ticketing-app runs its own CLI 2.78.1 through npm, so "safe on 2.122" is not the version that reads ticketing-app's configuration | Adopted: v2.78.1 decodes with `UnmarshalExact` and has no `local_smtp` field (F18); the rename leaves the plan and becomes decision 2 |
| 8 | P2 | The pin is on `supabase/tap/supabase`, and the setup guide records it | Adopted: step 8 |
| 9 | P2 | The ask's reason text says "the linked project" and "the hosted database" for targets that are neither | Adopted: step 1 |
| 10 | P2 | `--local` silences the storage rule even beside a target flag | Adopted: the helper of step 2 serves storage too |

No `P0`. Every `P1` is settled in the plan before code; the operator's OK on
the amended plan and its two decisions comes next.
