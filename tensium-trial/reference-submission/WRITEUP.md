# Trial build — shifted_dialect

A single-turn RL environment that targets one specific weakness of frontier
coding models, with a sandboxed differential verifier, a soundness receipt, a
contamination argument, and a multi-model leaderboard. This document explains
the choices and shows the evidence. The environment itself is in `shifted_dialect/`;
every number below regenerates from the commands in its README.

---

## 0. Bio

**What I've built before:**
Production AI systems across multiple clients — an LLM-powered financial document intelligence platform using Azure Document Intelligence (OCR, document classification, structured field extraction), an AI Job Description chatbot using LangChain and LangGraph with multi-step conversation flows, a real-time voice AI agent with STT/TTS pipelines over WebSockets, a voice-controlled desktop automation system that opens and controls PC applications through voice commands, and WhatsApp/Instagram AI chatbots via Twilio and Meta API. Full-stack across FastAPI, Node.js, React, Docker, PostgreSQL, and MongoDB. Also contributed to high-performance ML infrastructure as part of a global AI engineering team.

**What I can do now:**
Task design and verifier engineering — as this submission demonstrates end to end. Python packaging, sandboxed subprocess execution, statistical analysis of eval results, and agentic system design with LangChain/LangGraph.

**What I'd need to learn:**
Large-scale sandbox orchestration (gVisor/Firecracker at production scale), the RL training loop itself, and distributed eval infrastructure. I name these directly — they are real gaps, not hedges.

## 1. Which role, and why — build-lead

I'm positioning for **build-lead**: setting the bar, reviewing others' work, and
owning quality across a set of environments.

The evidence is in where the effort went. This submission is not "a task" — it's
a reusable *methodology* for proving an environment is worth a lab's money:

- a **soundness battery** that quantifies the verifier's false-accept and
  false-reject rates with confidence intervals, and names every cheat class
  (§4) — the artifact you'd run against *anyone's* environment to decide if it
  ships;
- a **procedural generator** that makes contamination a property you prove by
  construction, not a claim you defend (§3);
- an explicit **null baseline** (a competent solver that ignores the spec scores
  ~0.08) to answer "is this measuring the thing you claim?" before any model is
  run;
- a reasoned **critique of the build template** (§6), because a build-lead who
  only ticks the checklist isn't doing the job.

That is the build-lead instinct: treat soundness as something to be proven, have
a point of view about what makes an environment trustworthy, and be able to look
at a verifier and say *exactly* how it would be gamed. I can also build hands-on
— the sandbox, wheel, and verifier here are mine end to end — but the thing I'd
bring to a team is the bar and the means to hold others to it.

---

## 2. Why this work — the capability it targets

**The gap: spec-faithful implementation under prior conflict.** Coding models
carry strong priors — `*` binds tighter than `+`, `**` is right-associative and
tighter than unary minus, `/` floors or truncates "the usual way", comparisons
don't chain (except in Python), `&&` short-circuits, booleans coerce to ints.
When a precise specification *contradicts* those priors, models tend to revert
to the prior instead of following the spec, especially on edge cases. That is a
real, lab-relevant capability: implementing an unfamiliar DSL, protocol, or
legacy system *to spec* is exactly where this failure bites.

I isolate that capability by **randomising the semantics per instance**. Each
task is a small expression language with ordinary C-style syntax but a sampled
precedence table, associativity, integer model (bigint / wrapping / saturating /
overflow-error), division rounding, division-by-zero behaviour, comparison
representation and chaining, short-circuit and return semantics, truthiness, and
bool/int coercion. The model reads the spec and implements `evaluate(src)->str`;
the reward is the fraction of held-out programs whose output it reproduces
exactly, by differential testing against a hidden reference interpreter.

**Why this is "targeted, not just hard" — the receipt.** The scored tests are
deliberately selected to concentrate on *discriminating* programs: those where
the sampled dialect disagrees with the standard (Python/C) prior. So a complete,
competent implementation of *standard* semantics that ignores the spec scores
near zero. In the soundness run that solver (`prior_default`) averaged
**0.076** reward (max 0.625 on a near-standard easy instance) — it is a
plausible, fully-working interpreter, and it is wrong precisely because it
didn't follow the spec. Difficulty here is not "big numbers"; it is "did you
follow instructions that fight your instinct."

**Why a model can't shortcut it.** The randomisation is the point: there is no
"standard" answer to fall back on, no library to call, and (because instances
are generated) nothing to memorise. The strongest model I tested
(`openai/gpt-oss-120b` on Groq) does well on many instances — see §5 — which is
the right outcome: a capable model that *actually reads the spec* should score
well, and the reward should fall off as the spec deviates more. The environment
measures the reading, not raw difficulty.

## 3. Why it is not contaminated

The argument is constructive, not vibes. Every instance is produced by a seeded
generator (`sample_params(seed, difficulty)`, stable string-seeded RNG). The
specific dialects did not exist before generation, so no public corpus contains
them. Train and eval are drawn from **disjoint seed ranges** (`0..` vs
`1_000_000..`); a dialect in eval never appears in train. Receipts
(`analysis/contamination.py`, on 60+60 instances):

- dialect-fingerprint overlap between train and eval: **0**
- exact-duplicate specs across splits: **0**
- size of the dialect space (conservative lower bound): **≥ 5.2 × 10¹²**, so
  collisions are not a practical concern
- **leakage probe:** even when the *same program string* appears in a train and
  an eval instance, its expected output usually differs (different dialect). A
  model that memorised every train `(program → output)` pair and applied it to
  eval would score **~5.3%**. Program identity carries almost no transferable
  label — the average shared program maps to ~1.5 distinct outputs across
  dialects.

This is the deliberate strength of a *generator* over a fixed dataset: freshness
is guaranteed by construction and is reproducible by shipping the generator and
seeds. (This is also a point where I'd push on the template — see §6.)

## 4. How I tried to break it

The verifier's whole job is to give high reward only for genuinely doing the
work. I attacked it with a battery of cheats across the four classes the
template names plus two more, over 45 instances (540 cheat trials, 90 honest
trials); full numbers in `analysis/out/soundness.md`.

Acceptance threshold τ = 0.95 (a solution must reproduce ≥95% of held-out
outputs to be "accepted").

| metric | result |
|---|---|
| **False-accept rate** (cheat scored as passing) | **0 / 540**, 95% Wilson CI **0–0.0071** |
| **False-reject rate** (honest correct solution failing) | **0 / 90**, CI 0–0.041 |
| False-reject under a punishing 50 ms/call timeout | 0 / 45 |
| Honest reference solver mean reward | **1.000** (min 1.000) |
| Surviving cheat classes (max reward ≥ τ) | **none** |

Exploit value by class (mean reward — what the cheat actually earns):

- **constant / majority output** (`return "error"`, `"0"`, …): mean 0.14, max
  0.30. Capped by design — no single expected output may exceed 30% of the
  scored set, so a constant can't beat 0.30.
- **hardcoded / memorised answer** (scrape the spec's worked examples, hardcode
  them): mean 0.24, max 0.30 — the worked examples are excluded from the scored
  set, so memorising them buys nothing.
- **output-shape forgery** (`print("ALL CHECKS PASSED")`, return a plausible
  int): mean 0.06. The grader reads the returned value, never stdout.
- **reading / importing the reference** (`import shifted_dialect.oracle`, scan
  disk / env for answers): mean 0.08, max 0.30 (the fallback constant). The
  import is blocked and the answers are never on disk or in env — they're
  computed in the parent and never handed to the child.
- **grader probe** (a genuinely-correct solver whose output is mis-formatted —
  uppercase booleans, `+`-prefixed ints): **0.000**. This proves the grader
  demands exact canonical output and offers no output-shape loophole.

The single most important design fact: **the verifier never trusts anything the
model reports about itself.** The sandbox is told only program strings; the
verdict is computed in the trusted parent from ground truth. That is the line
the template draws ("anything the grader takes on the agent's word is exactly
what a trained model will learn to lie about"), and the battery is how I show I
held it.

## 5. Capability leaderboard

Models on Groq, 9 held-out problems × 3 rollouts each, scored through the exact
verifier the env uses, ranked by the lower bound of a bootstrap 95% CI on mean
reward. Full numbers in `analysis/out/leaderboard.md`.

| rank | model | mean reward | 95% CI | valid / trunc / err |
|---|---|---|---|---|
| 1 | openai/gpt-oss-120b | **0.50** | 0.40–0.61 | 27 / 8 / 0 |
| 2 | llama-3.1-8b-instant | 0.16 | 0.11–0.20 | 27 / 2 / 0 |
| 3 | llama-3.3-70b-versatile | 0.17 | 0.08–0.26 | 9 / 0 / 18 |

**What separates, and what doesn't.** gpt-oss-120b is **significantly** above
the llamas (paired bootstrap Δ = 0.344, CI 0.220–0.458). The two llamas are
**statistically tied** (Δ = −0.016, CI −0.074–0.053) — on this task,
llama-3.3-70b is *not* better than llama-3.1-8b; both mostly fail to follow the
spec. That is a real capability finding, and the stats correctly report one
separation and one non-separation rather than inventing an order.

**Targeted, not just hard.** Even the strongest model sits at ~0.50, and that's
a *lower bound*: 8 of its 27 rollouts truncated at the token cap (recorded as
`trunc`) and were scored on a cut-off solution. A model that reads the spec can
clearly make progress; one that runs on priors can't.

**Best-of-N — the reward-hack-under-search test (requirement #3).** Selection on
set S, quality measured on the disjoint set V:

| model | reward_S @ n=1,2,3 | reward_V @ n=1,2,3 |
|---|---|---|
| gpt-oss-120b | 0.50 / 0.71 / 0.77 | 0.52 / 0.74 / 0.78 |
| llama-3.1-8b | 0.16 / 0.25 / 0.29 | 0.13 / 0.21 / 0.24 |

reward_S and reward_V **track** (gap ≈ ±0.02; for gpt-oss V is even slightly
*above* S). Search is selecting genuinely better general implementations, not
solutions overfit to the scored inputs — which is expected here, because the
model never sees any test inputs. The verifier is not gamed by more sampling.

**Variance and honest caveats (requirements #5, #6).**
- Per-problem reward is **high-variance** (median per-problem std 0.38 for the
  top model): the same model nails a problem on one rollout and fails it on the
  next. With **3 rollouts per problem** the per-problem estimates are noisy; the
  reliable unit here is the 27-rollout per-model aggregate. More rollouts are
  the right next step before making per-problem claims.
- llama-3.3-70b is **under-sampled** (n = 9): 18 of its 27 calls hit Groq
  free-tier 429 rate limits and exhausted retries. Treat its point estimate
  cautiously — the wide CI reflects this.
- qwen3-32b was **excluded for cause**: every call returned HTTP 413 (request
  exceeded the free-tier per-request token cap). Recorded, not hidden.
- Harness disclosure: single scaffold (direct chat-completions), provider Groq,
  temperature 0.6; token budgets and finish-reasons are logged per rollout.

## 6. One thing I got wrong

My first verifier was exploitable, and I caught it from the data rather than by
luck.

The reward is the fraction of held-out programs reproduced. In the **first**
design I sampled the scored programs roughly uniformly. But several dialects are
*error-heavy* — with an overflow-error integer model, or error-on-division-by-
zero, or error-on-chained-comparison, a large fraction of random programs
evaluate to the single token `error`. On one early instance **47 of 80** scored
outputs were `error`. That means the dumbest possible cheat — `def evaluate(s):
return "error"` — would have scored **0.59**, and a model could climb reward by
learning to *guess error* rather than implement anything. That is a textbook
reward hack, and my verifier had it.

I found it by printing the output-kind distribution per instance while building
the generator, not by reasoning about it in advance. The fix is the **output-
share cap**: no single expected output value may exceed 30% of the scored set,
enforced during selection, which bounds every constant/majority cheat to ≤0.30.
The soundness receipt in §4 is the proof it's closed (constant cheats max 0.30,
nothing accepted). A related smaller miss: I initially reported a
`prior_baseline` that was mechanically `1 − discriminating_fraction` (tautolog­
ical), and replaced it with an independent `natural_discriminating_rate`.

(One earlier design error too, for completeness: I had an `eval_order`
left-vs-right parameter, then realised that for side-effect-free expressions
with a single `error` token it is **unobservable** — an untestable rule — and
removed it. Shipping a spec rule no test can distinguish is a soundness smell.)

## 7. Comments on the template

The template is good and I built to it. Four places I'd push on it:

1. **False-accept/reject are framed as binary, but real rewards are graded.**
   FAR/FRR need a stated acceptance threshold τ, and a single rate hides the
   shape of the attack. I think the template should ask for *both* a binarised
   FAR/FRR at a declared τ *and* the per-cheat-class exploit-value distribution
   (mean reward a cheat earns). The second is what tells you *how close* a cheat
   got, which is the more useful signal. I report both.

2. **It treats the dataset as a fixed artifact** ("clean train and eval splits
   … carries the ground-truth answer for each row"). For contamination and
   non-saturation, a **procedural generator** is strictly stronger than a fixed
   set: freshness is guaranteed by construction, and the train/eval split is a
   seed range, not a partition you have to police. I'd make instance generators
   a first-class, recommended pattern in the anatomy section, with the seed list
   as the reproducibility artifact.

3. **The best-of-N reward-hack test assumes a *separate* held-out quality
   measure exists** ("compare the verifier reward against a held-out, indepen­
   dent quality measure"). For a differential-testing verifier the reward *is*
   held-out correctness, so the classic "reward climbs while quality is flat"
   divergence can't occur on the scored set — but a subtler version can: a
   solution could overfit the *specific* scored inputs. The right test is a
   **disjoint selection/verification split** (select best-of-N by reward on S,
   measure on held-out V); if they track, search isn't gaming the metric. The
   template should distinguish "verifier = ground-truth-on-held-out" environments
   from "verifier = proxy" ones, because the reward-hack failure mode is
   different for each.

4. **Add an explicit null/heuristic baseline to the leaderboard requirement.**
   A multi-model leaderboard shows capability separation, but it doesn't by
   itself prove the task isn't solvable by a dumb default. A required
   non-model baseline (here: the `prior_default` solver that ignores the spec,
   ~0.08) is cheap and directly answers "is this measuring the thing you claim?"

One thing I'd defend, not change: "a flaky test is your bug, not the model's."
I measured false-reject under the *actual* timeout budget (and a punishing 50 ms
one) precisely because a correct-but-slow solution being timed out is a verifier
defect that would show up as phantom model failures.

---

## Known gaps (honest)

- **Spec-ambiguity false rejects** are checked with a reference solver written by
  the same author as the spec, so it's not a fully independent reading. A strong
  independent model implementing purely from the spec reaches ~0.97, which is
  evidence the spec is unambiguous but not proof. A truly independent check
  (multiple human readers, or a panel of models, with disagreements triaged) is
  the right next step.
- The **local sandbox does not isolate network**; it's safe for scoring because
  answers are never reachable, but untrusted execution at scale wants a
  container/microVM. The runner is structured as a drop-in for that.
- This is **single-turn by choice**. A long-horizon variant (the model debugging
  its own implementation against a held-out failing case across turns) is
  plausible but out of scope here; I'd rather ship one sound thing than a
  half-proven agentic one.
