# Ground truth — muscle-app rebrand + brand videos

Reviewer output: transcript line 637 (background subagent `af6ef08d3ac30f338`,
56750 tokens, 14 tool uses).
Artifact reviewed: `artifact.diff` (1597 lines, 32 files) = `git diff 9b69c93..98ef843 -- . ':(exclude)assets/videos'`.
3 findings. Reviewer's own severity labels preserved in parentheses.

**High-value property of this fixture: 2 of 3 findings were DECLINED.** The lead's
summary of the round (transcript line 643):

> The hostile review found **no correctness bugs** — catalog integrity, credit-consumer
> guards, `runDemoVideos` plumbing, the ESLint fix, and every partial rename all verified
> sound. Three items surfaced; two I'd already flagged to you (the Supabase scheme
> allowlist and the `/musclemap/` legal URLs — both deliberate/tracked). The third is
> genuinely actionable and cheap.

---

## 1. (HIGH) Scheme rename has an unfulfilled external dependency

ROUND: 1 (single-round episode)
FINDING: The `urmusclemate://` deep link works only once the Supabase dashboard redirect
allow-list is updated; until then email confirmation and password reset land dead.
CLASS: QUALITY
DISPOSITION: DECLINED
EVIDENCE: "That's external config the diff can't carry. Until someone does it, email-confirmation and password-reset links land on a dead scheme"
DECLINE REASON: Not a code defect and already tracked. The reviewer itself cleared the
code side — "The **code side is fine** — `src/features/auth/actions.ts:26,47` derives the
redirect via `Linking.createURL('/')`... there are zero hardcoded `muscleapp://` left
anywhere in `src/` or `supabase/`" — and conceded the item was already logged:
"`submission-checklist.md:81` already lists `urmusclemate://` as a to-do, so it's
tracked". The lead had raised it with the user before the review ran.
DISPOSITION NOTE: No code change was made. The item was carried to the user in the wrap
report as release blocker 1 (transcript line 697): "**Supabase Auth** — add
`urmusclemate://*` to the redirect allowlist, or magic-link sign-in and password reset
break. I can't do this via MCP."

---

## 2. (MEDIUM) Legal URL slug is a half-rename

ROUND: 1 (single-round episode)
FINDING: `src/constants/links.ts:8-11` still points at
`https://www.thesoftaims.com/musclemap/{privacy,terms,support,delete-account}` while the
surrounding comment was rebranded.
CLASS: AMBIGUITY
DISPOSITION: DECLINED
EVIDENCE: "the surrounding text was touched but the `/musclemap/` path slug was left"
DECLINE REASON: Deliberate and tracked. The reviewer itself allowed the ambiguity — "The
legal docs themselves are marked \"Draft — not yet published,\" so whoever hosts them
controls the slug and this may be deliberate" — and its proposed fix is a decision, not
a code change: "decide the public slug and make `links.ts` + the store-listing docs
agree". The lead had already flagged it to the user.
CLASS NOTE: Classed AMBIGUITY because the intent says "renamed... everywhere" but is
silent on the public URL slug, which is owned by whoever hosts the unpublished legal
pages. Resolving it needs a product decision, not an engineering one.

---

## 3. (MEDIUM) Two-generator trap and a misleading self-authored header

ROUND: 1 (single-round episode)
FINDING: `bundle-exercise-videos.mjs` writes `exercise-videos.ts` in a different order
than `prebuild.mjs`, yet its header names itself the authoritative generator.
CLASS: QUALITY
DISPOSITION: ADOPTED
EVIDENCE: "anyone following that instruction rewrites the file into a churny reordered diff that the next build silently reverts"
DISPOSITION NOTE: Adopted and fixed the same session, going past what the reviewer asked
for. The reviewer noted it was already deferred knowingly — "This is logged in
`.agents/debt-log.md` as `video-map-two-generators` (deferred knowingly), but the bundle
script's self-authored \"do not edit by hand\" header is the actively misleading part."
The lead chose the full fix instead of the header-only patch (transcript line 643):
"Rather than leave a misleading header, let me apply the real fix from the debt-log —
have the bundle script delegate to `prebuild.mjs` instead of writing its own copy."
Landed as commit `7971292`, proven by a byte-identical before/after map diff
(transcript line 678), after which the `video-map-two-generators` debt entry was deleted
as paid down (transcript line 679).

---

## Reviewer's explicit non-findings (recorded so a grader does not credit them as misses)

The reviewer ran a section headed "Things that are actually fine (checked, not invented)"
covering: `catalog.json` integrity (valid JSON, 42 exercises, 42 `video_url`, exactly 1
`mediaCredits` entry, zero "AI-generated" strings); credit consumers not breaking on
`undefined` (`exercise-video.tsx:76` guards with `{credit ? ...}`); `runDemoVideos()`
plumbing still coherent with no dangling `AI_GENERATED` reference; the ESLint fix
verified by running it (0 errors); and — most relevant to grading — the intentional
partial renames:

> **Intentional partial renames confirmed correct, not misses:** AsyncStorage keys
> (`musclemap.*` ...) — renaming would orphan existing user data, correctly left. IAP
> product IDs `musclemap.pro.{monthly,yearly}` ... arbitrary store-registered strings,
> fine to keep. `ImportFormat 'musclemap'` key + export filenames
> `musclemap-export.json` — internal, cosmetic. Emulator AVD `musclemap_api35` —
> external. All left deliberately.

A review prompt that reports any of these as defects is producing false positives, since
the reviewer was explicitly asked to distinguish deliberate from broken half-renames.

---

## NOTE — artifact fidelity

`artifact.diff` is RECOVERED with high confidence, not reconstructed by replay. It is the
byte-for-byte output of the command written in the review prompt itself
(`git diff 9b69c93..HEAD -- . ':(exclude)assets/videos'`) with `HEAD` resolved to
`98ef843`, which was the tip when the review was dispatched (transcript line 593; the
prompt says "three commits", and `9b69c93..98ef843` is exactly `38df792`, `b92182c`,
`98ef843`).

Contamination is impossible here: the fix for finding 3 landed in the **later, separate**
commit `7971292`, which is outside the reviewed range. This episode is the one case in
this fixture set where git is a safe source for the pre-review state.
