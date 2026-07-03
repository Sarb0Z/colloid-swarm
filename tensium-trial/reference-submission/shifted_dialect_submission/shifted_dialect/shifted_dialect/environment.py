"""verifiers integration: `load_environment` for the shifted-dialect task.

This wires the pure-Python core (generator + sandboxed differential scorer) into
a verifiers SingleTurnEnv. The reward is the fraction of held-out programs the
model's `evaluate` reproduces exactly -- computed from ground truth in the
parent, never from anything the model reports about itself.
"""

from __future__ import annotations

import asyncio
import json
import re

import verifiers as vf
from datasets import Dataset

from .generate import build_dataset
from .scoring import score_code

SYSTEM_PROMPT = """\
You implement a function in Python from a precise specification.

The user gives the complete semantics of a small expression language. Reply with
your reasoning if you wish, then a SINGLE fenced Python code block that defines:

    def evaluate(src: str) -> str: ...

Requirements:
- Standard library only. No imports of third-party packages, no file or network
  access, no top-level side effects.
- `evaluate` must RETURN the result string (one of: an integer in decimal, the
  boolean spelling defined by the spec, the nil token if reachable, or the token
  `error`). It must not print the result, and must not raise on bad input --
  return `error` instead.
- The final fenced ```python code block in your reply is what gets graded.
"""

_CODE_FENCE = re.compile(r"```(?:python|py)?\s*\n(.*?)```", re.DOTALL)


def extract_code(text: str) -> str:
    """Return the last fenced code block; if there is none, the raw text."""
    blocks = _CODE_FENCE.findall(text or "")
    if blocks:
        return blocks[-1].strip()
    return (text or "").strip()


def _to_dataset(rows: list[dict]) -> Dataset:
    """Convert generator rows into an Arrow-friendly Dataset.

    `params`/`stats` are JSON-encoded into fixed-typed string fields so the
    dataset has a uniform schema (otherwise the variable keys in stats break
    Arrow struct inference). The scored `tests` stay as a list[list[str]].
    """
    records = []
    for r in rows:
        info = r["info"]
        records.append({
            "question": r["question"],
            "answer": r["answer"],
            "example_id": r["example_id"],
            "info": {
                "tests": [[a, b] for a, b in info["tests"]],
                "seed": info["seed"],
                "difficulty": info["difficulty"],
                "params_json": json.dumps(info["params"]),
                "stats_json": json.dumps(info["stats"]),
            },
        })
    return Dataset.from_list(records)


def load_environment(
    n_train_per_difficulty: int = 12,
    n_eval_per_difficulty: int = 8,
    n_tests: int = 60,
    difficulties: tuple[str, ...] = ("easy", "medium", "hard"),
    per_call_timeout: float = 0.5,
    total_timeout: float = 20.0,
    **kwargs,
) -> vf.Environment:
    train_rows = build_dataset(n_train_per_difficulty, difficulties, start_seed=0,
                               n_tests=n_tests)
    eval_rows = build_dataset(n_eval_per_difficulty, difficulties, start_seed=1_000_000,
                              n_tests=n_tests)
    train_ds = _to_dataset(train_rows)
    eval_ds = _to_dataset(eval_rows)

    parser = vf.Parser(extract_fn=extract_code)

    async def correct_fraction(parser, completion, info) -> float:
        """Fraction of held-out programs whose output the model reproduces."""
        code = parser.parse_answer(completion) or ""
        if not code.strip():
            return 0.0
        tests = info["tests"]
        result = await asyncio.to_thread(
            score_code, code, tests,
            per_call_timeout=per_call_timeout, total_timeout=total_timeout,
        )
        return float(result["reward"])

    def submitted_code(parser, completion) -> float:
        """Diagnostic only (weight 0): did the model emit a non-empty code block."""
        return 1.0 if (parser.parse_answer(completion) or "").strip() else 0.0

    rubric = vf.Rubric(
        funcs=[correct_fraction, submitted_code],
        weights=[1.0, 0.0],
        parser=parser,
    )

    return vf.SingleTurnEnv(
        dataset=train_ds,
        eval_dataset=eval_ds,
        system_prompt=SYSTEM_PROMPT,
        parser=parser,
        rubric=rubric,
        **kwargs,
    )
