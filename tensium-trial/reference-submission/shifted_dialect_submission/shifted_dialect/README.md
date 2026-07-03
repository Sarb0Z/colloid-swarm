# shifted_dialect

An RL environment (verifiers format) that tests one specific, real weakness of
frontier coding models: **implementing a precise specification faithfully when
the specification deliberately conflicts with the model's priors.**

Each task gives the complete semantics of a small integer/boolean expression
language whose surface syntax is ordinary (C-style infix) but whose **operator
precedence, associativity, integer model, division rounding, comparison and
coercion rules are randomly sampled per instance**. The model must implement an
`evaluate(src) -> str` that matches a hidden reference interpreter. Because the
rules are randomised, the model cannot fall back on "this is like Python/C" —
it has to read the spec and follow it exactly.

> This is artifact **A** (the environment). The reasoning behind it — the
> capability it targets, the contamination argument, how I attacked the verifier,
> and a critique of the build template — is in the accompanying writeup
> (**Document B**, `WRITEUP.md`).

- **Single-turn.** One spec in, one Python implementation out.
- **Graded reward** = fraction of held-out programs whose output the model
  reproduces exactly (differential testing against a hidden oracle).
- **Procedurally generated**, so every instance is provably fresh (see
  *Contamination* below).

## Why this is a real gap, not just something hard

Coding models carry strong priors from training: `*` binds tighter than `+`,
`**` is right-associative and tighter than unary minus, `/` is true/floor
division, comparisons don't chain (except in Python), `&&` short-circuits, and
so on. When a spec **inverts** these, models frequently revert to the prior
instead of following the spec — especially on edge cases (overflow, division by
zero, chained comparisons, unary-vs-power, operand coercion). This is
instruction-following *in code under prior conflict*, and it is exactly what a
lab cares about when a model must implement an unfamiliar protocol, DSL, or
legacy system to spec.

The receipt for "real gap": across generated instances, a solver that perfectly
implements *standard* (Python/C) semantics and ignores the spec scores **~0** on
the scored tests (`prior_baseline` in each instance's stats; see the soundness
report's `prior_default` cheat, mean reward ≈ 0.08). The tests are deliberately
selected to concentrate on programs where the sampled dialect disagrees with the
prior.

## Anatomy

| part | file | held back from model? |
|---|---|---|
| Semantics sampler (the dialect) | `shifted_dialect/semantics.py` | n/a |
| Lexer + precedence-climbing parser | `shifted_dialect/syntax.py` | — |
| **Reference oracle** (ground truth) | `shifted_dialect/oracle.py` | **yes** |
| Spec renderer (the task text) | `shifted_dialect/spec.py` | shown |
| Dataset generator (held-out tests) | `shifted_dialect/generate.py` | tests held back |
| Sandbox (isolated execution) | `shifted_dialect/sandbox.py` | — |
| Differential scorer (the verifier) | `shifted_dialect/scoring.py` | — |
| verifiers integration | `shifted_dialect/environment.py` | — |
| Reference solver generator | `shifted_dialect/refsolver.py` | honest control |

The oracle outputs and the test inputs are computed in the trusted parent and
**never** handed to the sandbox; the model's code receives only program strings.
A "pass" therefore requires actually computing the right value — there is no
stdout/self-report channel for the grader to trust.

## Install and run

Requires Python 3.10–3.13 (verifiers constraint).

```bash
python3.12 -m venv .venv && . .venv/bin/activate
pip install verifiers
pip install -e .            # installs this environment ("shifted-dialect")
```

Load it programmatically:

```python
from shifted_dialect import load_environment
env = load_environment(n_train_per_difficulty=12, n_eval_per_difficulty=8, n_tests=60)
```

Or evaluate a model with the verifiers CLI (any OpenAI-compatible endpoint,
e.g. Groq):

```bash
export OPENAI_API_KEY=$GROQ_API_KEY
export OPENAI_BASE_URL=https://api.groq.com/openai/v1
vf-eval shifted-dialect -m openai/gpt-oss-120b -n 6 -r 3
```

## Reproducing the receipts

All analysis scripts run from this directory with the package importable
(`pip install -e .`). Outputs land in `analysis/out/`.

**One command, no API key**, runs the engine tests + soundness + contamination +
env-load + an honest-vs-cheat demo and prints PASS/FAIL:

```bash
bash verify.sh            # or: bash verify.sh 45   (more soundness instances)
```

Individual receipts:

```bash
# Soundness receipt: cheat battery + false-accept/false-reject with CIs
python -m analysis.soundness --instances 45 --tests 80 --workers 8

# Contamination check: n-gram overlap train vs eval, intra-split duplication
python -m analysis.contamination

# Capability leaderboard + best-of-N + variance.
# Results are SHIPPED as receipts (analysis/out/leaderboard.{md,json},
# rollouts.jsonl) -- no API key is included or needed to read them.
# To RE-RUN, use ANY OpenAI-compatible endpoint with YOUR OWN key:
export OPENAI_API_KEY=...                       # your key, any provider
export OPENAI_BASE_URL=https://api.groq.com/openai/v1   # or OpenAI/OpenRouter/...
python -m analysis.leaderboard_run --problems-per-diff 6 --rollouts 5 \
    --models "llama-3.1-8b-instant,llama-3.3-70b-versatile,openai/gpt-oss-120b"
python -m analysis.leaderboard_report

# Engine self-tests (parser/oracle hand-checked + fuzz)
python -m pytest tests/ -q      # or: python tests/test_core.py
```

## Sandbox manifest

Untrusted model code runs in `shifted_dialect/sandbox.py` with:

- **Isolation:** a fresh `python -S -E` subprocess — the standard library only.
  site-packages are not on the child's path, so the installed `shifted_dialect`
  package (the oracle) is unimportable, and the spec's "stdlib only" rule is
  enforced. An explicit `meta_path` blocker rejects `shifted_dialect` imports as
  belt-and-suspenders. The child runs in a fresh temp working directory with an
  empty environment (no `PYTHONPATH`).
- **Resource limits:** `RLIMIT_CPU` (default 12s) and `RLIMIT_AS` (default
  512 MB; not enforced on macOS) via `preexec_fn`; a per-call wall-clock
  `SIGALRM` (default 0.5s) to localise a single hanging input; an overall
  wall-clock timeout that kills the process group.
- **Network egress:** **not** isolated at the OS level by this local runner.
  This is safe for *scoring* soundness because the held-out inputs and the
  reference answers never exist on disk or any reachable network — they live in
  the parent process and are never sent to the child. For untrusted execution at
  scale, run the child under a container/microVM (Docker+seccomp, gVisor, or
  Firecracker) with egress disabled; the runner is a drop-in for that.
- **Observation:** the child writes per-call JSONL results to a file (not
  stdout), flushed each line, so partial results survive a kill.

The import-block and answer-isolation are tested by the `read_reference` cheat
class in the soundness battery (all such cheats score 0).

## Contamination

Every instance is generated by a seeded procedural generator
(`sample_params(seed, difficulty)` using a stable string-seeded RNG). The
specific dialects therefore did not exist before generation; there is no public
corpus of them by construction. Train and eval are drawn from **disjoint seed
ranges** (`0..` vs `1_000_000..`), so no dialect appears in both. `analysis/
contamination.py` reports n-gram overlap between splits and intra-split
duplication to back this up empirically. Ship the seed list and this generator
and every number regenerates identically.

## What the reward does and does not prove

- It **does** prove the model produced a general implementation that matches the
  reference on held-out programs it never saw — a direct measure of
  spec-faithful evaluation.
- It **does not** prove the model "understands" the language, nor that high
  reward transfers to other instruction-following tasks. The leaderboard shows
  the reward separates models with capability; it is not a training-transfer
  claim (that requires a training loop this environment does not include).

## Layout

```
shifted_dialect/        # the installable environment package (the wheel)
analysis/               # soundness, leaderboard, contamination scripts + out/
tests/                  # engine self-tests
pyproject.toml          # hatchling build, verifiers dependency
```

## Known limitations

- The "no false-reject from spec ambiguity" claim is checked with a reference
  solver written by the same author as the spec; a *fully* independent reader
  (a strong model implementing from the spec) reaches ~0.97, which is evidence
  but not proof of zero ambiguity. See the writeup.
- The local sandbox does not isolate network; see the manifest.
- Long-horizon variants are out of scope by design (this is single-turn).
```
