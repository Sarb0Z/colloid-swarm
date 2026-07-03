"""Dataset generator: seeds -> task instances.

Each instance carries:
  - question: the rendered spec (the only thing the model sees)
  - info.params: the SemanticParams (held back; lets the verifier recompute)
  - info.tests: held-back (program, expected-output) pairs the model is scored on
  - info.stats: receipts about the instance (discriminating fraction, the
    prior-baseline reward, output-kind mix, deviation score)

The test set oversamples *discriminating* programs -- those where the sampled
dialect disagrees with the Python-/C-prior -- so the reward concentrates on
spec-faithfulness rather than generic arithmetic. `prior_baseline` is the score
a model would get by perfectly implementing *standard* semantics and ignoring
the spec; a low value is evidence the task is not solvable by default.
"""

from __future__ import annotations

import hashlib
import json
import random
from collections import Counter

from .exprgen import sample_programs
from .oracle import evaluate
from .semantics import DIFFICULTIES, deviation_score, prior_params, sample_params
from .spec import render_spec, worked_example_inputs

VERSION = "0.1.0"
_PRIOR = prior_params()
_TEST_DEPTH = {"easy": 3, "medium": 4, "hard": 5}


def _kind(out: str) -> str:
    if out in ("error", "nil"):
        return out
    if out in ("true", "false"):
        return "bool"
    return "int"


def _fingerprint(params_dict: dict) -> str:
    blob = json.dumps(params_dict, sort_keys=True).encode()
    return hashlib.sha256(blob).hexdigest()[:16]


# No single expected-output value may exceed this share of the scored set. This
# bounds the reward available to a constant-output / majority-class cheat.
_MAX_OUTPUT_SHARE = 0.30


def _select(prioritized: list[tuple[str, str]], n: int, cap: int) -> list[tuple[str, str]]:
    """Take up to `n` items, allowing at most `cap` of any one expected output.
    Backfill (ignoring the cap) only if the capped pass falls short."""
    counts: Counter[str] = Counter()
    chosen: list[tuple[str, str]] = []
    leftover: list[tuple[str, str]] = []
    for prog, exp in prioritized:
        if len(chosen) >= n:
            break
        if counts[exp] >= cap:
            leftover.append((prog, exp))
            continue
        chosen.append((prog, exp))
        counts[exp] += 1
    for prog, exp in leftover:
        if len(chosen) >= n:
            break
        chosen.append((prog, exp))
    return chosen


def make_instance(seed: int, difficulty: str, n_tests: int = 80) -> dict:
    """Build one fully self-contained task instance."""
    params = sample_params(seed, difficulty)
    depth = _TEST_DEPTH[difficulty]

    # Large candidate pool, then select.
    pool = sample_programs(seed=seed * 7919 + 1, params=params, n=n_tests * 10, depth=depth)
    excluded = set(worked_example_inputs(params))

    discriminating: list[tuple[str, str]] = []
    same: list[tuple[str, str]] = []
    for prog in pool:
        if prog in excluded:
            continue
        exp = evaluate(prog, params)
        prior = evaluate(prog, _PRIOR)
        (discriminating if exp != prior else same).append((prog, exp))

    # Independent receipt: how far the dialect departs from the prior across the
    # whole pool (not the engineered selection ratio).
    pool_n = len(discriminating) + len(same)
    natural_rate = round(len(discriminating) / pool_n, 4) if pool_n else 0.0

    rng = random.Random(f"select/{seed}/{difficulty}")
    rng.shuffle(discriminating)
    rng.shuffle(same)

    # Prioritise discriminating, but cap any single output value's share.
    cap = max(1, int(n_tests * _MAX_OUTPUT_SHARE))
    tests = _select(discriminating + same, n_tests, cap)
    rng.shuffle(tests)
    if not tests:
        raise RuntimeError(f"no tests generated for seed={seed} diff={difficulty}")

    # Receipts.
    n = len(tests)
    prior_correct = sum(1 for prog, exp in tests if evaluate(prog, _PRIOR) == exp)
    kinds: Counter[str] = Counter(_kind(exp) for _prog, exp in tests)
    value_counts = Counter(exp for _prog, exp in tests)
    params_dict = params.to_dict()
    stats = {
        "n_tests": n,
        "discriminating_fraction": round((n - prior_correct) / n, 4),
        "prior_baseline": round(prior_correct / n, 4),
        "natural_discriminating_rate": natural_rate,
        "deviation_score": deviation_score(params),
        "output_kinds": dict(kinds),
        "max_output_share": round(max(value_counts.values()) / n, 4),
        "test_depth": depth,
    }
    return {
        "example_id": f"{difficulty}-{seed:05d}",
        "question": render_spec(params),
        "answer": _fingerprint(params_dict),
        "info": {
            "version": VERSION,
            "seed": seed,
            "difficulty": difficulty,
            "params": params_dict,
            "tests": [list(t) for t in tests],
            "stats": stats,
        },
    }


def build_dataset(
    n_per_difficulty: int = 40,
    difficulties: tuple[str, ...] = DIFFICULTIES,
    start_seed: int = 0,
    n_tests: int = 80,
) -> list[dict]:
    """Build a flat list of instances across difficulties."""
    rows: list[dict] = []
    for difficulty in difficulties:
        for i in range(n_per_difficulty):
            rows.append(make_instance(start_seed + i, difficulty, n_tests=n_tests))
    return rows


def split_dataset(
    n_train: int = 40, n_eval: int = 20, difficulties: tuple[str, ...] = DIFFICULTIES,
    n_tests: int = 80,
) -> tuple[list[dict], list[dict]]:
    """Train and eval splits drawn from disjoint seed ranges (no leakage: a
    dialect in eval never appears in train, by construction of the seed space)."""
    train = build_dataset(n_train, difficulties, start_seed=0, n_tests=n_tests)
    eval_ = build_dataset(n_eval, difficulties, start_seed=1_000_000, n_tests=n_tests)
    return train, eval_
