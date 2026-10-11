# Review: register rewrite of the harness (workloop `register-rewrite`)

## core-p1-voice

**P1 — instructions lose their force.** The core lane recasts imperatives addressed to the agent as agentless passives or indicative descriptions: "never edit through a symlink" → "nothing is edited through a symlink" (`.agents/AGENTS.md`); "Keep the scaffold small" → "The scaffold stays small"; "Gloss each repository name" → "Each repository name … is glossed"; "Commit each logical chunk" → "Each logical chunk of work is committed" (`output-style.md`); "Make the smallest complete change. Preserve unrelated work." → "The change is the smallest … unrelated work stays as it was" (`personas/implementer.md`). The approved model (root `AGENTS.md`) commands directly — "Build one working thing at a time", "Tie every fix to observed evidence". Raising the register means a wider, exacter vocabulary and argued sentences, not a change of mood.

Rule for every lane: an instruction to the agent stays in the imperative (or "never"/"no X" for prohibitions) and names its actor when it is not the reader. The declarative "definition-as-law" form is for definitions and invariants of the system ("`.agents/` is canonical"), not for what the agent must do.

## core-p1-meaning

**P1 — a restrictive clause became non-restrictive.** `.agents/AGENTS.md`: "Prefer testing observable behavior over mutation machinery that tests the test harness" (only such machinery) → "Prefer a test of observable behavior to mutation machinery, which tests only the test harness" (all mutation machinery). Meaning is fixed by the brief; restrictive and non-restrictive clauses, quantifiers, and modal strength must survive the rewrite exactly.

## playbooks-p1-voice

**P1 — same defect as core-p1-voice.** Stack packs and playbooks: "Do not migrate untouched code or change project configuration" → "Untouched code stays unmigrated and project configuration unchanged" (`rules/stack-python.md`); "Do not restate environment or package management here" → "Environment and package management are not restated here"; "Keep one longer … and say which" → "One stays up longer … and the report names which" (`playbooks/processes.md`). Restore the imperative for every instruction to the agent across the lane.

## register-p0-bar

**P0 — the register did not rise.** Operator review, 2026-10-11: "this doesn't really seem like raising the vocabulary bar … would computer scientist Dostoevsky or software architect Ellen Ullman write this?" The accepted core and playbooks lanes amount to term substitutions (check→verify, subagent→cell) and a repaired voice defect; the prose is not argued, voiced or exact in the way the ruling asks. Both accepts are withdrawn. The bar is set by `/tmp/register-exemplars.md`.

## second-pass

Second pass against `/tmp/register-exemplars.md`. skills-a (head `da64a68`): code blocks, links and identifiers byte-identical to `76457ad` by script; imperatives and modals intact; added reasons cited to each skill's AGENTS.md or references; uncitable phrases removed. Accepted. core (head `1b4e744`, held as reviewed by the controller): reasons cited to code and tests, two false drafts dropped by the writer; reviewed in the integration diff.

## hooks-second-pass

hooks (head `d32c90e`): every pinned string byte-exact with no test changed; `bash -n` clean; four messages fired by hand (teardown block, wrap menu, research-prime JSON, guard-publish deny JSON); added reasons drawn from each hook's header comment or the root contract. Accepted. playbooks (head `7ca9d37`, held as reviewed): reasons cited to code or citable facts, structure of review-axes.md preserved; reviewed in the integration diff.

## third-pass

Compression pass under `/tmp/register-precision.md` (operator: appended glosses unjustified; ~50% of files changing is acceptable). Every owned file in every lane is at or below its `76457ad` word count; appended explanations removed; imperatives, quantifiers, pins and mirrors intact per each lane's checks. skills-b (head `c124334`) accepted; core, playbooks, hooks, skills-a carry their third-pass commits on the reviewed lane branches.
