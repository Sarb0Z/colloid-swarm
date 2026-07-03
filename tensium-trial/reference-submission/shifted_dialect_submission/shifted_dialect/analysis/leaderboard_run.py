"""Run a multi-model panel through the environment and save raw rollouts.

Drives rollouts itself (so we control repeated sampling, best-of-N, and the
selection/verification split) but scores through the EXACT verifier the env
uses: the same system prompt, the same code extractor, the same sandboxed
differential scorer. Only the rollout driver differs from `vf-eval`.

Each held-out problem's 80 tests are split into a selection set S (first 50,
used as the model's scored reward) and a disjoint verification set V (last 30,
used to check that best-of-N selection generalises -- the reward-hack-under-
search probe). Raw results stream to analysis/out/rollouts.jsonl.

Usage (key in env):
    set -a; . scratchpad/groq.env; set +a
    python -m analysis.leaderboard_run --problems-per-diff 6 --rollouts 4
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import time

import openai

from shifted_dialect.environment import SYSTEM_PROMPT, extract_code
from shifted_dialect.generate import make_instance
from shifted_dialect.scoring import score_detail

DIFFS = ("easy", "medium", "hard")
# Provider-agnostic: any OpenAI-compatible endpoint. Defaults to Groq, but a
# reviewer supplies THEIR OWN key/endpoint -- no key is shipped or required.
GROQ_BASE = "https://api.groq.com/openai/v1"
DEFAULT_BASE = os.environ.get("OPENAI_BASE_URL", GROQ_BASE)
OUT_DIR = os.path.join(os.path.dirname(__file__), "out")
ROLLOUTS_PATH = os.path.join(OUT_DIR, "rollouts.jsonl")

# Capability ladder on Groq (small -> large), plus per-model token budgets.
# max_tokens kept under the Groq free-tier per-request token cap (8192 triggers
# HTTP 413 for the reasoning models; 6000 + ~1.3k prompt fits).
MODELS = [
    {"id": "llama-3.1-8b-instant", "max_tokens": 4096},
    {"id": "llama-3.3-70b-versatile", "max_tokens": 4096},
    {"id": "qwen/qwen3-32b", "max_tokens": 6000},
    {"id": "openai/gpt-oss-120b", "max_tokens": 6000},
]

N_SELECT = 50  # first N_SELECT held-out tests are the scored selection set S


def build_problems(per_diff: int, n_tests: int = 80) -> list[dict]:
    """Held-out eval problems (disjoint seed range from any training seeds)."""
    probs = []
    for d in DIFFS:
        for i in range(per_diff):
            seed = 1_000_000 + i
            inst = make_instance(seed, d, n_tests=n_tests)
            probs.append({
                "problem_id": inst["example_id"],
                "difficulty": d,
                "question": inst["question"],
                "tests": inst["info"]["tests"],
                "stats": inst["info"]["stats"],
            })
    return probs


async def _one_rollout(client, sem, model, prob, ridx, temperature, max_tokens, retries=6):
    messages = [{"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": prob["question"]}]
    last_err = None
    for attempt in range(retries):
        try:
            async with sem:
                resp = await client.chat.completions.create(
                    model=model, messages=messages,
                    temperature=temperature, max_tokens=max_tokens,
                )
            content = resp.choices[0].message.content or ""
            finish = resp.choices[0].finish_reason
            code = extract_code(content)
            detail = await asyncio.to_thread(
                score_detail, code, prob["tests"],
                per_call_timeout=0.5, total_timeout=20.0,
            )
            correct = detail["correct"]
            nsel = min(N_SELECT, len(correct))
            reward_s = sum(correct[:nsel]) / nsel if nsel else 0.0
            reward_v = (sum(correct[nsel:]) / (len(correct) - nsel)
                        if len(correct) > nsel else 0.0)
            return {
                "model": model, "problem_id": prob["problem_id"],
                "difficulty": prob["difficulty"], "rollout": ridx,
                "reward_s": reward_s, "reward_v": reward_v,
                "finish_reason": finish, "fatal": detail["fatal"],
                "timed_out": detail["timed_out"],
                "code_len": len(code), "had_code": bool(code.strip()),
                "error": None,
            }
        except Exception as e:  # API/rate-limit/etc -> retry with backoff
            last_err = f"{type(e).__name__}: {str(e)[:120]}"
            if "413" in last_err or "too large" in last_err.lower():
                break  # non-retryable: request exceeds the token cap
            await asyncio.sleep(min(30.0, 3.0 * (2 ** attempt)))
    return {
        "model": model, "problem_id": prob["problem_id"],
        "difficulty": prob["difficulty"], "rollout": ridx,
        "reward_s": None, "reward_v": None, "finish_reason": "error",
        "fatal": None, "timed_out": False, "code_len": 0, "had_code": False,
        "error": last_err,
    }


async def run(per_diff: int, rollouts: int, temperature: float, concurrency: int,
              base_url: str | None = None, models: list[dict] | None = None):
    # Accept either a generic OPENAI_API_KEY (with OPENAI_BASE_URL) or GROQ_API_KEY.
    key = os.environ.get("OPENAI_API_KEY") or os.environ.get("GROQ_API_KEY")
    if not key:
        raise SystemExit("Set OPENAI_API_KEY (and OPENAI_BASE_URL for non-OpenAI "
                         "providers), or GROQ_API_KEY.")
    base_url = base_url or DEFAULT_BASE
    models = models or MODELS
    client = openai.AsyncOpenAI(api_key=key, base_url=base_url)
    problems = build_problems(per_diff)
    sem = asyncio.Semaphore(concurrency)

    os.makedirs(OUT_DIR, exist_ok=True)
    # Build per-model task lists, then interleave round-robin so that the
    # concurrent in-flight requests hit DIFFERENT models -- each model has its
    # own rate limit, so spreading across models avoids hammering one of them.
    per_model = []
    for m in models:
        lst = [(_one_rollout, client, sem, m["id"], prob, r, temperature, m["max_tokens"])
               for prob in problems for r in range(rollouts)]
        per_model.append(lst)
    interleaved = []
    for i in range(max(len(x) for x in per_model)):
        for lst in per_model:
            if i < len(lst):
                interleaved.append(lst[i])
    tasks = [fn(cl, s, mid, p, r, t, mt) for (fn, cl, s, mid, p, r, t, mt) in interleaved]

    print(f"endpoint={base_url}  {len(models)} models x {len(problems)} problems "
          f"x {rollouts} rollouts = {len(tasks)} calls")
    t0 = time.time()
    done = 0
    with open(ROLLOUTS_PATH, "w") as f:
        for coro in asyncio.as_completed(tasks):
            rec = await coro
            f.write(json.dumps(rec) + "\n")
            f.flush()
            done += 1
            if done % 20 == 0 or done == len(tasks):
                print(f"  {done}/{len(tasks)} ({time.time()-t0:.0f}s)")
    print(f"wrote {ROLLOUTS_PATH} in {time.time()-t0:.0f}s")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--problems-per-diff", type=int, default=6)
    ap.add_argument("--rollouts", type=int, default=4)
    ap.add_argument("--temperature", type=float, default=0.6)
    ap.add_argument("--concurrency", type=int, default=6)
    ap.add_argument("--base-url", default=None,
                    help="OpenAI-compatible endpoint (else $OPENAI_BASE_URL, else Groq)")
    ap.add_argument("--models", default=None,
                    help="comma-separated model ids to override the default panel")
    args = ap.parse_args()
    models = None
    if args.models:
        models = [{"id": mid.strip(), "max_tokens": 4096}
                  for mid in args.models.split(",") if mid.strip()]
    asyncio.run(run(args.problems_per_diff, args.rollouts, args.temperature,
                    args.concurrency, base_url=args.base_url, models=models))


if __name__ == "__main__":
    main()
