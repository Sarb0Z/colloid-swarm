# Intent — muscle-app brand-video swap and MuscleMap → urmusclemate rename

Source session: `/Users/mac/.claude/projects/-Users-mac-Projects-muscle-app/21e886a1-81aa-4b4e-a2c2-01dd6af6d148.jsonl` (2026-07-17)

Artifact under review: `artifact.diff` — the diff of commits `9b69c93..98ef843`
(three commits), excluding `assets/videos`.

## User request (verbatim, transcript line 7)

> We updated the videos to align with the brand more. [/Users/mac/Downloads/Muscles\ Logo-20260716T142533Z-1-001.zip]
> Please integrate them with supabase and codebase.
> references to ai generated videos can be removed as well now.
> When done. Give us the app.

## Mid-task decision by the user

The new clips carried a watermark logo reading **urmusclemate**, which did not match the
app's name. The implementer flagged this before transcoding (transcript line 68). The
user's answer, as the implementer recorded it (transcript line 78):

> The user's answer is in: proceed now, rename later.

The rejected alternative, per the implementer's own wrap report (transcript line 697):

> The rejected alternative was cropping/masking the watermark; you chose to ship as-is
> and rename the app instead.

## Intent statement given to the reviewer (verbatim, transcript line 593)

> Intent of the change (verify it actually achieves this, and flag where it doesn't):
>
> 1. Replaced 42 exercise demo videos with new brand-watermarked versions; re-transcoded
>    via scripts/bundle-exercise-videos.mjs into assets/videos/ and re-uploaded to
>    Supabase Storage via scripts/fetch-catalog-media.mjs.
> 2. Removed all "AI-generated" provenance: deleted 42 mediaCredits entries from
>    src/data/catalog.json (only the free-exercise-db image credit should remain),
>    removed the AI_GENERATED credit constant + its addCredit() call, renamed AI_VIDEO_*
>    identifiers → DEMO_VIDEO_* and the --ai-video flag → --demo-video.
> 3. Renamed the app MuscleMap → urmusclemate everywhere (display name, in-app copy) and
>    changed identifiers: android.package + ios.bundleIdentifier → com.urmusclemate.app,
>    deep-link scheme muscleapp:// → urmusclemate://.
> 4. Fixed eslint.config.js so supabase/functions/**/*.ts (Deno) and scripts/*.mjs (Node)
>    don't throw no-undef/no-unresolved.

## Review instruction (verbatim, transcript line 593)

> Do NOT edit anything. Report findings ranked most-severe first, each with file:line,
> the concrete failure it causes, and the fix. If something is actually fine, say so
> briefly — don't invent problems.

## Why this fixture matters

Two of the three findings were **DECLINED** by the lead as deliberate and already
tracked. This is ground-truth noise: a review-prompt design that produces more findings
of this shape is not thereby better. See `ground-truth.md`.
